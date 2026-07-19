"""web_harm_floor.py — harm classifier for the chat / web-search INTENT layer.

The morpheus image floor (six welded categories) is about *image generation*
(minors/sexual, real-person intimate, …). A web query — or a direct answer the
model gives without searching — can raise a different class of harm: CBRN,
weapons/explosives, and illicit synthesis. This floor covers that class.

Applied at the intent layer (on the user's turn, before routing/answering), so it
fires whether or not a search tool is invoked. harm_check() returns a category
string or None.

Honest limit (same as the image floor): this is a keyword/pattern wall. It stops
plain-language misuse; deliberate euphemism or coded language can evade it. Build
the floor; do not over-claim it as adversary-proof.
"""
import re

# Standalone blocks — the term itself is unambiguous enough to gate on its own.
_STANDALONE = frozenset([
    "nerve agent", "nerve gas", "vx agent", "sarin", "tabun", "soman", "cyclosarin",
    "novichok", "mustard gas", "chemical weapon", "chemical weapons",
    "bioweapon", "bioweapons", "biological weapon", "biological weapons",
    "weaponize anthrax", "weaponise anthrax", "aerosolize anthrax", "aerosolise anthrax",
    "weaponized anthrax", "ricin toxin", "botulinum toxin", "weaponize a virus",
    "dirty bomb", "radiological weapon", "nuclear weapon design", "build a nuclear weapon",
    "improvised explosive device", "pipe bomb", "pipe bombs", "pressure cooker bomb",
    "how to make vx", "synthesize vx", "synthesise vx",
])

# Intent-combined: a harm noun blocks only alongside an action verb.
_ACTIONS = (
    "how to make", "how do i make", "how to build", "how to synthesize",
    "how to synthesise", "how to produce", "how to manufacture", "how to create",
    "recipe for", "steps to make", "steps to build", "instructions for",
    "how to cook", "make your own", "build your own", "diy ", "homemade",
)
_HARM_NOUNS = (
    "bomb", "explosive", "explosives", "detonator", "grenade", "landmine",
    "napalm", "thermite", "c4 charge",
    "methamphetamine", "crystal meth", "cook meth", "fentanyl", "carfentanil",
    "nerve agent", "poison gas", "chemical weapon", "bioweapon", "biological weapon",
    "ghost gun", "untraceable gun", "auto sear", "full auto conversion",
)


def _norm(text: str) -> str:
    s = (text or "").lower()
    s = re.sub(r"(?<=[a-z])[_.\-](?=[a-z])", "", s)   # de-obfuscate n_e_r_v_e -> nerve
    return re.sub(r"\s+", " ", s).strip()


def harm_check(text: str) -> str | None:
    s = _norm(text)
    for t in _STANDALONE:
        if t in s:
            return "cbrn-weapons"
    if any(a in s for a in _ACTIONS) and any(n in s for n in _HARM_NOUNS):
        return "illicit-synthesis-weapons"
    return None
