// ── Status view: voice & language (ph3b3-light) ─────────────────────────────
// Thin client: all state lives on the SELECTED server (via api()). No local
// persistence, no registry logic — just render what the server reports and POST
// changes back. Reuses the shared api()/authHeader/playAudio()/addSys() globals.
(function () {
    const overlay      = document.getElementById('status-overlay');
    const voiceSel     = document.getElementById('voice-select');
    const langSel      = document.getElementById('lang-select');
    const previewBtn   = document.getElementById('voice-preview-btn');
    const voiceCurrent = document.getElementById('voice-current');
    const langNote     = document.getElementById('lang-note');
    const webToggle    = document.getElementById('web-toggle');
    const webBackend   = document.getElementById('web-backend');
    const acctUser     = document.getElementById('acct-user');
    const acctPass     = document.getElementById('acct-pass');
    const acctPass2    = document.getElementById('acct-pass2');
    const acctSave     = document.getElementById('acct-save');
    const acctNote     = document.getElementById('acct-note');

    function openStatus()  { overlay.classList.add('open'); loadVoices(); loadLanguages(); loadWebAccess(); loadAccount(); }
    function closeStatus() { overlay.classList.remove('open'); }

    async function apiGet(path) {
        const r = await fetch(api(path), { headers: { 'Authorization': authHeader } });
        if (r.status === 401) { _clearAuth(); _showLogin('Session expired — please reconnect.'); throw new Error('401'); }
        if (r.status === 404) throw new Error('404');
        if (!r.ok) throw new Error('http ' + r.status);
        return r.json();
    }
    async function apiPost(path, body) {
        const r = await fetch(api(path), {
            method:  'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': authHeader },
            body:    JSON.stringify(body),
        });
        if (r.status === 401) { _clearAuth(); _showLogin('Session expired — please reconnect.'); throw new Error('401'); }
        return r;
    }

    async function loadVoices() {
        voiceSel.innerHTML = '<option>Loading…</option>';
        voiceCurrent.textContent = '';
        previewBtn.disabled = true;
        try {
            const d = await apiGet('/voice');
            voiceSel.innerHTML = '';
            let rendered = 0;
            for (const v of d.voices || []) {
                // Server owns approval. Honor it defensively: an unreviewed voice
                // (approved === false) never renders in light. Voices with no
                // approved field (e.g. local standalone) are shown as before.
                if (v.approved === false) continue;
                const o = document.createElement('option');
                o.value = v.id; o.textContent = v.label;
                if (v.id === d.current) o.selected = true;
                voiceSel.appendChild(o);
                rendered++;
            }
            const cur = (d.voices || []).find(v => v.id === d.current && v.approved !== false);
            voiceCurrent.textContent = cur ? `Current: ${cur.label}` : '';
            previewBtn.disabled = rendered === 0;
        } catch (e) {
            if (e.message === '404') {
                voiceSel.innerHTML = '<option>Not supported by this server</option>';
                voiceCurrent.textContent = 'This server does not expose voice controls.';
            } else if (e.message !== '401') {
                voiceSel.innerHTML = '<option>Unavailable</option>';
            }
        }
    }

    async function loadLanguages() {
        langSel.innerHTML = '<option>Loading…</option>';
        langNote.innerHTML = '';
        try {
            const d = await apiGet('/language');
            langSel.innerHTML = '';
            const mk = (label, arr) => {
                if (!arr.length) return;
                const og = document.createElement('optgroup'); og.label = label;
                for (const l of arr) {
                    const o = document.createElement('option');
                    o.value = l.code; o.textContent = l.label;
                    if (l.code === d.current) o.selected = true;
                    og.appendChild(o);
                }
                langSel.appendChild(og);
            };
            mk('Native voice (strong)',   (d.languages || []).filter(l => l.tier === 'strong'));
            mk('Translation (functional)', (d.languages || []).filter(l => l.tier === 'functional'));
            langNote.innerHTML =
                '<span class="tier-strong">Strong</span> = native voice installed · ' +
                '<span class="tier-functional">Functional</span> = translated, spoken with the current voice.';
        } catch (e) {
            if (e.message === '404') langSel.innerHTML = '<option>Not supported by this server</option>';
            else if (e.message !== '401') langSel.innerHTML = '<option>Unavailable</option>';
        }
    }

    voiceSel.addEventListener('change', async () => {
        const label = voiceSel.options[voiceSel.selectedIndex]?.text || voiceSel.value;
        try { await apiPost('/voice', { id: voiceSel.value }); await loadVoices(); await loadLanguages(); addSys(`Voice → ${label}`); }
        catch {}
    });
    langSel.addEventListener('change', async () => {
        const label = langSel.options[langSel.selectedIndex]?.text || langSel.value;
        try {
            const r = await apiPost('/language', { code: langSel.value });
            const d = await r.json().catch(() => ({}));
            await loadVoices(); await loadLanguages();
            addSys(`Language → ${label}` + (d.note ? ` — ${d.note}` : ''));
        } catch {}
    });
    previewBtn.addEventListener('click', async () => {
        const old = previewBtn.textContent;
        previewBtn.disabled = true; previewBtn.textContent = '…';
        try {
            const r = await apiPost('/voice/preview', { id: voiceSel.value });
            const d = await r.json().catch(() => ({}));
            if (d.audio) await playAudio(d.audio);
        } catch {}
        finally { previewBtn.textContent = old; previewBtn.disabled = false; }
    });

    // ── Web access (egress) toggle — server-side truth, synced across portals ──
    function setWebUI(d) {
        webToggle.disabled = false;
        webToggle.textContent = d.enabled ? 'ON' : 'OFF';
        webToggle.classList.toggle('on', !!d.enabled);
        webBackend.textContent = d.enabled ? ('via ' + (d.backend_label || 'web')) : '';
    }
    async function loadWebAccess() {
        if (!webToggle) return;
        webBackend.textContent = '';
        try { setWebUI(await apiGet('/web/config')); }
        catch (e) {
            if (e.message === '404') { webToggle.textContent = 'N/A'; webToggle.disabled = true; webBackend.textContent = 'not on this server'; }
            else if (e.message !== '401') { webToggle.textContent = '—'; }
        }
    }
    if (webToggle) webToggle.addEventListener('click', async () => {
        if (webToggle.disabled) return;
        const turnOn = webToggle.textContent !== 'ON';
        webToggle.disabled = true;
        try {
            const r = await apiPost('/web/toggle', { enabled: turnOn });
            const d = await r.json().catch(() => ({}));
            setWebUI(d);
            addSys('Web access → ' + (d.enabled ? ('ON · via ' + (d.backend_label || 'web')) : 'OFF'));
        } catch { webToggle.disabled = false; }
    });

    // ── Account (change login username/password) — local server only ───────────
    function _currentUser() {
        try { return atob((authHeader || '').replace(/^Basic /, '')).split(':')[0]; }
        catch { return ''; }
    }
    function loadAccount() {
        if (!acctSave) return;
        // Changing creds only makes sense for the server that served this page.
        const local = !currentServer().base;
        acctUser.disabled = acctPass.disabled = acctPass2.disabled = acctSave.disabled = !local;
        acctNote.className = 'status-note';
        if (local) {
            acctUser.value = _currentUser();
            acctPass.value = acctPass2.value = '';
            acctNote.textContent = 'Changes your login for this machine. You stay signed in — use the new details next time.';
        } else {
            acctNote.textContent = 'Login changes apply to the local server only. Switch to Local to change these.';
        }
    }
    if (acctSave) acctSave.addEventListener('click', async () => {
        const u = (acctUser.value || '').trim(), p = acctPass.value, p2 = acctPass2.value;
        acctNote.className = 'status-note';
        if (!u)                { acctNote.textContent = 'Username cannot be empty.'; return; }
        if (u.includes(':'))   { acctNote.textContent = 'Username cannot contain a colon.'; return; }
        if (p.length < 6)      { acctNote.textContent = 'Password must be at least 6 characters.'; return; }
        if (p !== p2)          { acctNote.textContent = 'Passwords do not match.'; return; }
        acctSave.disabled = true;
        try {
            const r = await apiPost('/auth/credentials', { username: u, password: p });
            if (r.ok) {
                _storeAuth(u, p);                       // keep this session alive with the new creds
                acctPass.value = acctPass2.value = '';
                acctNote.textContent = 'Saved — login updated.';
                addSys('Login updated for ' + currentServer().label);
            } else {
                acctNote.textContent = (await r.text().catch(() => '')) || ('Could not update (http ' + r.status + ').');
            }
        } catch (e) { if (e.message !== '401') acctNote.textContent = 'Could not reach the server.'; }
        finally { acctSave.disabled = false; }
    });

    document.getElementById('status-open').addEventListener('click', openStatus);
    document.getElementById('status-back').addEventListener('click', closeStatus);
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && overlay.classList.contains('open')) closeStatus();
    });
})();
