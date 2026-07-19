"""metis_module.py — Metis web search for Ph3b3 (standalone port).

Dual backend, selected by PH3B3_SEARCH_BACKEND (auto | searxng | ddg):
  * searxng — a user-run SearXNG instance (URL in PH3B3_SEARXNG_URL). Queries are
    aggregated and anonymised through your own instance.
  * ddg     — a direct DuckDuckGo HTML scrape via httpx + BeautifulSoup. Zero
    setup, so "clone and it works on any Windows PC" holds. Queries go straight
    to DuckDuckGo.
  * auto (default) — use SearXNG if it's configured and reachable at boot,
    otherwise fall back to DDG. The active backend is logged and surfaced on the
    WEB ACCESS card so the user knows their privacy posture at a glance.

Security walls (per the brief):
  * Egress is OFF by default (privacy-first for a public repo) and gated by a
    runtime toggle — one server-side truth.
  * The fetcher refuses non-http(s), and any host resolving to a private/RFC1918,
    loopback, link-local, reserved, or CGNAT/tailnet address (no LAN/WSL-host
    probing). SSRF via redirect is blocked by validating every hop before fetch.
  * Timeouts + size caps on every request; extracted text is capped.
  * Parser failures fail LOUD (SearchBroken) — never a silent zero-result answer.
  * Modest per-minute rate cap so a chatty session doesn't hammer the backend.
  * No search history is kept here beyond the normal chat transcript.

The untrusted-content directive and the tool-less summarize pass live in
server.py; this module only gathers and normalises. Portable verbatim to the og
stack.
"""
import ipaddress
import logging
import os
import socket
import time
from collections import deque
from urllib.parse import urlparse, parse_qs, unquote

import httpx
from bs4 import BeautifulSoup

log = logging.getLogger("ph3b3.metis")

# ── Config ──────────────────────────────────────────────────────────────────
BACKEND      = os.getenv("PH3B3_SEARCH_BACKEND", "auto").strip().lower()   # auto|searxng|ddg
SEARXNG_URL  = os.getenv("PH3B3_SEARXNG_URL", "").strip().rstrip("/")
# Fresh-clone default is OFF (public repo, privacy-first). Env can pre-arm it.
_DEFAULT_ON  = os.getenv("PH3B3_WEB_ACCESS", "off").strip().lower() in ("1", "on", "true", "yes")

RESULT_CAP    = 7            # top-N results returned
FETCH_PAGES   = 2            # fetch up to N top result pages for the summary
PAGE_BYTES    = 2_000_000    # hard download cap per page
EXTRACT_CHARS = 6000         # extracted-text cap per page
HTTP_TIMEOUT  = 12.0
MAX_REDIRECTS = 4
RATE_MAX      = 12           # searches per window
RATE_WINDOW   = 60.0         # seconds

_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

# Refuse beyond ipaddress.is_private: CGNAT / Tailscale (100.64.0.0/10).
_EXTRA_DENY = [ipaddress.ip_network("100.64.0.0/10")]


class SearchBroken(Exception):
    """Parser or endpoint failure. Must surface LOUDLY — never as empty results."""


class MetisModule:
    def __init__(self):
        self._enabled = _DEFAULT_ON
        self._hits: deque = deque()          # rate-limit timestamps
        self.backend = self._resolve_backend()
        log.info(f"Metis ready — backend={self.backend} ({self.backend_label()}), "
                 f"web_access={'on' if self._enabled else 'off'}")

    # ── Backend resolution (AUTO) ────────────────────────────────────────────
    def _searxng_reachable(self) -> bool:
        if not SEARXNG_URL:
            return False
        for path in ("/healthz", "/"):
            try:
                r = httpx.get(SEARXNG_URL + path, timeout=3.0)
                if r.status_code < 500:
                    return True
            except Exception:
                continue
        return False

    def _resolve_backend(self) -> str:
        if BACKEND == "searxng":
            return "searxng"
        if BACKEND == "ddg":
            return "ddg"
        return "searxng" if self._searxng_reachable() else "ddg"   # auto

    def backend_label(self) -> str:
        return "SearXNG" if self.backend == "searxng" else "DuckDuckGo"

    # ── Toggle (server-side truth for both portals) ──────────────────────────
    def is_enabled(self) -> bool:
        return self._enabled

    def set_enabled(self, on: bool) -> bool:
        self._enabled = bool(on)
        log.info(f"web_access -> {'on' if self._enabled else 'off'}")
        return self._enabled

    def status(self) -> dict:
        return {"enabled": self._enabled, "backend": self.backend,
                "backend_label": self.backend_label()}

    # ── Rate courtesy ────────────────────────────────────────────────────────
    def _rate_ok(self) -> bool:
        now = time.time()
        while self._hits and now - self._hits[0] > RATE_WINDOW:
            self._hits.popleft()
        if len(self._hits) >= RATE_MAX:
            return False
        self._hits.append(now)
        return True

    # ── Search (dispatch + one retry + fail-loud) ────────────────────────────
    async def search(self, query: str) -> list:
        """Normalised [{title, snippet, url}]. Raises SearchBroken on parser/
        endpoint failure — a broken scrape is never returned as empty results."""
        q = (query or "").strip()
        if not q:
            return []
        if not self._rate_ok():
            raise SearchBroken("rate limit — too many searches this minute")
        fn = self._search_searxng if self.backend == "searxng" else self._search_ddg
        last = None
        for attempt in (1, 2):                # one retry, then honest error
            try:
                return await fn(q)
            except SearchBroken as e:
                last = e
                log.warning(f"search attempt {attempt} failed loudly: {e}")
        raise last or SearchBroken("search failed")

    async def _search_ddg(self, q: str) -> list:
        """HTML endpoint first, then the lite endpoint — lite is more scraper-
        friendly and dodges DDG's 202 throttle on some (long) queries. Only after
        BOTH fail do we surface SearchBroken (fail-loud, never silent-empty)."""
        try:
            return await self._ddg_html(q)
        except SearchBroken as e:
            log.info(f"DDG html failed ({e}); falling back to lite endpoint")
            return await self._ddg_lite(q)

    async def _ddg_html(self, q: str) -> list:
        try:
            async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, headers={"User-Agent": _UA},
                                         follow_redirects=True) as c:
                r = await c.get("https://html.duckduckgo.com/html/",
                                params={"q": q, "kp": "1"})   # kp=1 = safe-search strict
        except Exception as e:
            raise SearchBroken(f"DuckDuckGo unreachable: {e}")
        if r.status_code != 200:
            raise SearchBroken(f"DuckDuckGo HTTP {r.status_code}")
        html = r.text
        soup = BeautifulSoup(html, "lxml")
        out, seen = [], set()
        for res in soup.select(".result__body, .web-result"):
            a = res.select_one("a.result__a")
            if not a:
                continue
            title = a.get_text(" ", strip=True)
            url = self._ddg_unwrap(a.get("href", ""))
            snip = res.select_one(".result__snippet")
            snippet = snip.get_text(" ", strip=True) if snip else ""
            if title and url and url not in seen:
                seen.add(url)
                out.append({"title": title, "snippet": snippet, "url": url})
            if len(out) >= RESULT_CAP:
                break
        if not out:
            low = html.lower()
            if "no results" in low or "no more results" in low:
                return []          # genuinely empty — a legit answer
            raise SearchBroken("DuckDuckGo returned a page but 0 results parsed "
                               "(markup likely changed)")
        return out

    @staticmethod
    def _ddg_unwrap(href: str) -> str:
        # DDG result links are //duckduckgo.com/l/?uddg=<encoded-real-url>
        if href.startswith("//"):
            href = "https:" + href
        try:
            qs = parse_qs(urlparse(href).query)
            if "uddg" in qs:
                return unquote(qs["uddg"][0])
        except Exception:
            pass
        return href if href.startswith("http") else ""

    async def _ddg_lite(self, q: str) -> list:
        try:
            async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, headers={"User-Agent": _UA},
                                         follow_redirects=True) as c:
                r = await c.post("https://lite.duckduckgo.com/lite/",
                                 data={"q": q, "kp": "1"})
        except Exception as e:
            raise SearchBroken(f"DuckDuckGo lite unreachable: {e}")
        if r.status_code != 200:
            raise SearchBroken(f"DuckDuckGo lite HTTP {r.status_code}")
        soup = BeautifulSoup(r.text, "lxml")
        out, seen = [], set()
        for a in soup.select("a.result-link"):
            title = a.get_text(" ", strip=True)
            url = self._ddg_unwrap(a.get("href", ""))
            snippet = ""
            tr = a.find_parent("tr")
            nxt = tr.find_next_sibling("tr") if tr else None
            snip = nxt.select_one("td.result-snippet") if nxt else None
            if snip:
                snippet = snip.get_text(" ", strip=True)
            if title and url and url not in seen:
                seen.add(url)
                out.append({"title": title, "snippet": snippet, "url": url})
            if len(out) >= RESULT_CAP:
                break
        if not out:
            if "no results" in r.text.lower():
                return []
            raise SearchBroken("DuckDuckGo lite returned a page but 0 results parsed")
        return out

    async def _search_searxng(self, q: str) -> list:
        if not SEARXNG_URL:
            raise SearchBroken("SearXNG URL not configured")
        try:
            async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, headers={"User-Agent": _UA}) as c:
                r = await c.get(SEARXNG_URL + "/search",
                                params={"q": q, "format": "json", "safesearch": "1"})
        except Exception as e:
            raise SearchBroken(f"SearXNG unreachable: {e}")
        if r.status_code != 200:
            raise SearchBroken(f"SearXNG HTTP {r.status_code}")
        try:
            data = r.json()
        except Exception as e:
            raise SearchBroken(f"SearXNG returned non-JSON: {e}")
        results = data.get("results")
        if results is None:
            raise SearchBroken("SearXNG response missing 'results' (format changed?)")
        out = []
        for res in results[:RESULT_CAP]:
            title = (res.get("title") or "").strip()
            url = (res.get("url") or "").strip()
            snippet = (res.get("content") or "").strip()
            if title and url:
                out.append({"title": title, "snippet": snippet, "url": url})
        return out

    # ── Page fetcher (SSRF-guarded per hop, size-capped, readability-ish) ────
    def _url_safe(self, url: str):
        p = urlparse(url)
        if p.scheme not in ("http", "https"):
            return False, "non-http(s)"
        host = (p.hostname or "").lower()
        if not host or host == "localhost" or host.endswith((".local", ".internal", ".lan")):
            return False, "localhost/local host"
        try:
            infos = socket.getaddrinfo(host, None)
        except Exception:
            return False, "DNS unresolvable"
        for info in infos:
            try:
                ip = ipaddress.ip_address(info[4][0])
            except ValueError:
                continue
            if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved
                    or ip.is_multicast or ip.is_unspecified
                    or any(ip in net for net in _EXTRA_DENY)):
                return False, f"private/reserved address ({ip})"
        return True, ""

    async def fetch_page(self, url: str) -> str:
        """Return readability-ish extracted text, or "" if refused/unfetchable.
        Validates every redirect hop before fetching it (SSRF-safe) and caps size."""
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, headers={"User-Agent": _UA},
                                     follow_redirects=False) as c:
            for _ in range(MAX_REDIRECTS):
                ok, why = self._url_safe(url)
                if not ok:
                    log.info(f"fetch refused ({why}): {url}")
                    return ""
                try:
                    async with c.stream("GET", url) as r:
                        if r.is_redirect:
                            loc = r.headers.get("location")
                            if not loc:
                                return ""
                            url = str(httpx.URL(url).join(loc))
                            continue
                        if r.status_code != 200:
                            return ""
                        ctype = r.headers.get("content-type", "")
                        if "html" not in ctype and "text/" not in ctype:
                            return ""
                        total, chunks = 0, []
                        async for chunk in r.aiter_bytes():
                            chunks.append(chunk)
                            total += len(chunk)
                            if total > PAGE_BYTES:
                                break
                        return self._extract(b"".join(chunks).decode("utf-8", "replace"))
                except Exception as e:
                    log.info(f"fetch error: {e}")
                    return ""
        return ""   # too many redirects

    @staticmethod
    def _extract(html: str) -> str:
        soup = BeautifulSoup(html, "lxml")
        for tag in soup(["script", "style", "noscript", "template", "svg",
                         "nav", "header", "footer", "form", "aside"]):
            tag.decompose()
        main = soup.select_one("main, article, [role=main]") or soup.body or soup
        return main.get_text(" ", strip=True)[:EXTRACT_CHARS]

    # ── Gather: search + fetch top pages into one delimited block ────────────
    async def gather(self, query: str) -> dict:
        """Assumes the caller already checked is_enabled() and the safety floor.
        Raises SearchBroken on a broken search. Returns:
          {status: 'ok'|'empty', results, block, sources}."""
        results = await self.search(query)
        if not results:
            return {"status": "empty", "results": [], "block": "", "sources": []}
        pages = []
        for res in results[:FETCH_PAGES]:
            text = await self.fetch_page(res["url"])
            if text:
                pages.append((res, text))
        return {
            "status": "ok",
            "results": results,
            "block": self._build_block(query, results, pages),
            "sources": [r["url"] for r in results],
        }

    def _build_block(self, query: str, results: list, pages: list) -> str:
        lines = [f'Web search for: "{query}"  (via {self.backend_label()})', ""]
        lines.append("Top results:")
        for i, r in enumerate(results, 1):
            lines.append(f"[{i}] {r['title']}")
            if r["snippet"]:
                lines.append(f"    {r['snippet']}")
            lines.append(f"    {r['url']}")
        if pages:
            lines.append("")
            lines.append("Fetched page text (excerpts):")
            for r, text in pages:
                lines.append(f"--- from {r['url']} ---")
                lines.append(text)
        return "\n".join(lines)
