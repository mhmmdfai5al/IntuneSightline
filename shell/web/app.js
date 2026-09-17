// Theme. The system preference wins until the reader chooses otherwise; the
// choice is theirs and outlives the page, so it is remembered per browser
// rather than per tenant.
(function () {
  const KEY = 'sightline-theme';
  const root = document.documentElement;
  const button = document.getElementById('theme-toggle');

  function systemPrefersDark() {
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  }

  function currentlyDark() {
    const chosen = root.getAttribute('data-theme');
    if (chosen) return chosen === 'dark';
    return systemPrefersDark();
  }

  function label() {
    if (button) button.textContent = currentlyDark() ? 'Light' : 'Dark';
  }

  let saved = null;
  try { saved = localStorage.getItem(KEY); } catch (err) { /* private mode */ }
  if (saved === 'dark' || saved === 'light') root.setAttribute('data-theme', saved);
  label();

  if (button) {
    button.addEventListener('click', function () {
      const next = currentlyDark() ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem(KEY, next); } catch (err) { /* private mode */ }
      label();
    });
  }

  // Follow the system only while the reader has expressed no preference.
  if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () {
      if (!root.getAttribute('data-theme')) label();
    });
  }
})();

'use strict';

const api = {
  async get(path) {
    const r = await fetch(path, { cache: 'no-store' });
    if (!r.ok) throw new Error((await r.json()).error || r.statusText);
    return r.json();
  },
  async post(path, body) {
    const r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || r.statusText);
    return data;
  }
};

const text = (el, value) => { document.getElementById(el).textContent = value; };
const el   = (id) => document.getElementById(id);

const GUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const DOMAIN = /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/;

const validTenant = (v) => GUID.test(v.trim()) || DOMAIN.test(v.trim());
const validClient = (v) => GUID.test(v.trim());

function refreshConnectButton() {
  const t = el('tenant-id').value;
  const c = el('client-id').value;
  el('connect-btn').disabled = !(validTenant(t) && validClient(c));
}

async function applyState(s) {
  text('f-tenant',  s.connected ? (s.tenant || 'unknown') : 'not connected');
  text('f-account', s.connected ? (s.account || '—') : '—');
  const clientEl = el('f-client');
  if (s.clientName) {
    clientEl.textContent = s.clientName;
    clientEl.classList.remove('path');
    clientEl.classList.add('hoverable');
    clientEl.title = s.clientId;
  } else {
    clientEl.textContent = s.clientId || '—';
    clientEl.classList.add('path');
    clientEl.classList.remove('hoverable');
    clientEl.title = s.clientId ? 'Display name not resolved - needs Application.Read.All' : '';
  }
  text('f-output',  s.outputRoot);
  text('f-version', s.version ? 'v' + s.version : '');
  renderUpdateBanner(s);

  // Read the permissions the token actually carries, not the string we asked
  // for. Since the request is now ".default", the requested list is a single
  // resource identifier and says nothing about what was granted.
  const noise = ['offline_access', 'openid', 'profile', 'email'];
  const scopes = (s.granted && s.granted.length ? s.granted : (s.scopes || []))
    .filter(x => !noise.includes(x) && !x.startsWith('https://'));
  const scopeEl = el('f-scopes');
  scopeEl.textContent = s.connected
    ? (scopes.length ? scopes.length + ' permission' + (scopes.length === 1 ? '' : 's') : 'none')
    : '—';
  scopeEl.title = scopes.length ? scopes.slice().sort().join('\n') : '';
  scopeEl.classList.toggle('absent', s.connected && scopes.length === 0);
  scopeEl.classList.toggle('hoverable', s.connected && scopes.length > 0);

  const panel = el('connect');
  const btn   = el('connect-btn');
  const note  = el('conn-note');

  panel.classList.toggle('connected', s.connected);

  if (s.connected) {
    el('connect-title').textContent = 'Connected';
    el('connect-lede').textContent =
      'Signed in as ' + (s.account || 'unknown') + '. Disconnecting clears the token and forgets this tenant.';
    btn.textContent = 'Disconnect';
    btn.className = 'run disconnect';
    btn.disabled = false;
    note.textContent = '';
    note.className = 'conn-note';

    if (s.noRefresh) {
      let n = document.getElementById('norefresh');
      if (!n) {
        n = document.createElement('p');
        n.id = 'norefresh';
        n.className = 'discarded';
        panel.appendChild(n);
      }
      n.textContent = 'This tenant would not issue a refresh token, so the session expires in about an hour. ' +
        'A long collection may fail partway through — reconnect and run it again.';
    }

    const discarded = (s.discarded || []).filter(x => !['offline_access','openid','profile','email'].includes(x));
    let d = document.getElementById('discarded');
    if (discarded.length) {
      if (!d) {
        d = document.createElement('p');
        d.id = 'discarded';
        d.className = 'discarded';
        panel.appendChild(d);
      }
      d.textContent = discarded.length + ' write permission' + (discarded.length === 1 ? '' : 's') +
        ' discarded and never used: ' + discarded.join(', ');
    } else if (d) {
      d.remove();
    }
  } else {
    el('connect-title').textContent = 'Connect to a tenant';
    el('connect-lede').textContent =
      'Permissions belong to an application, not to you. Enter the tenant and the ' +
      'application registration whose Intune read permissions you want to use.';
    btn.textContent = 'Connect';
    btn.className = 'run';

    if (s.savedTenantId && !el('tenant-id').value) el('tenant-id').value = s.savedTenantId;
    if (s.savedClientId && !el('client-id').value) el('client-id').value = s.savedClientId;
    if (s.savedTenantId) { note.textContent = 'Last used values filled in.'; }

    refreshConnectButton();
    const d = document.getElementById('discarded');
    if (d) d.remove();
  }

  el('lede').hidden = !s.connected;
  return s;
}

function showConnectError(message) {
  const e = el('connect-error');
  e.textContent = message;
  e.hidden = false;
}

function buildField(field) {
  const wrap = document.createElement('label');
  const id = 'f_' + field.id;

  if (field.type === 'boolean') {
    wrap.className = 'field-inline';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.id = id;
    input.checked = field.default === true;
    wrap.append(input, document.createTextNode(field.label));
    return { node: wrap, read: () => input.checked };
  }

  wrap.className = 'field';
  const caption = document.createElement('span');
  caption.textContent = field.label + (field.required ? ' (required)' : '');
  wrap.appendChild(caption);

  if (field.type === 'select') {
    const sel = document.createElement('select');
    sel.id = id;
    (field.options || []).forEach(opt => {
      const o = document.createElement('option');
      o.value = o.textContent = opt;
      sel.appendChild(o);
    });
    if (field.default) sel.value = field.default;
    wrap.appendChild(sel);
    return { node: wrap, read: () => sel.value };
  }

  if (field.type === 'multiselect') {
    const box = document.createElement('div');
    box.className = 'checks';
    const inputs = (field.options || []).map(opt => {
      const l = document.createElement('label');
      const i = document.createElement('input');
      i.type = 'checkbox';
      i.value = opt;
      i.checked = !field.default || field.default.includes(opt);
      l.append(i, document.createTextNode(opt));
      box.appendChild(l);
      return i;
    });
    wrap.appendChild(box);
    return { node: wrap, read: () => inputs.filter(i => i.checked).map(i => i.value) };
  }

  const input = document.createElement('input');
  input.type = field.type === 'number' ? 'number' : 'text';
  input.id = id;
  if (field.required) input.dataset.required = '1';
  if (field.default !== undefined && field.default !== null) input.value = field.default;
  if (field.placeholder) input.placeholder = field.placeholder;
  wrap.appendChild(input);

  // Live format feedback, so a typo is caught before a long collection runs.
  if (field.pattern) {
    const rx = new RegExp(field.pattern);
    const note = document.createElement('p');
    note.className = 'hint bad';
    note.hidden = true;
    note.textContent = field.patternMessage || 'Not in the expected format.';
    wrap.appendChild(note);

    const check = () => {
      const v = input.value.trim();
      const bad = v !== '' && !rx.test(v);
      note.hidden = !bad;
      input.classList.toggle('invalid', bad);
      input.dispatchEvent(new CustomEvent('sightline-validity', { bubbles: true }));
    };
    input.addEventListener('input', check);
    input.dataset.pattern = field.pattern;
  }

  if (field.hint) {
    const hint = document.createElement('p');
    hint.className = 'hint';
    hint.textContent = field.hint;
    wrap.appendChild(hint);
  }

  return {
    node: wrap,
    read: () => field.type === 'number' ? Number(input.value) : input.value.trim()
  };
}

function renderTool(tool, options) {
  const opts = options || {};
  const row = document.createElement('div');
  row.className = 'tool' + (tool.available ? '' : ' unavailable');

  const head = document.createElement('button');
  head.className = 'tool-head';
  head.type = 'button';
  head.setAttribute('aria-expanded', 'false');
  head.innerHTML =
    '<span class="tool-name"></span><span class="tool-desc"></span><span class="tool-ver"></span>';
  head.querySelector('.tool-name').textContent = opts.displayName || tool.name;
  // A short description keeps the row scannable; the full one still reaches the
  // manifest, the README and the export, where there is room for it.
  head.querySelector('.tool-desc').textContent =
    opts.hideDescription ? '' : (tool.shortDescription || tool.description);
  head.querySelector('.tool-ver').textContent = 'v' + tool.version;

  const body = document.createElement('div');
  body.className = 'tool-body';
  body.hidden = true;

  if (!tool.available) {
    head.disabled = true;
    head.title = tool.unavailableWhy || 'Unavailable';

    const blocked = document.createElement('p');
    blocked.className = 'blocked';
    blocked.textContent = tool.unavailableWhy || 'Unavailable with the current permissions.';
    row.append(head, blocked);
    return row;
  }

  if (tool.note) {
    const note = document.createElement('p');
    note.className = 'tool-note';
    note.textContent = tool.note;
    body.appendChild(note);
  }

  const readers = {};
  (tool.fields || []).forEach(field => {
    const built = buildField(field);
    body.appendChild(built.node);
    readers[field.id] = built.read;
  });

  const actions = document.createElement('div');
  actions.className = 'actions';
  const runBtn = document.createElement('button');
  runBtn.className = 'run';
  runBtn.type = 'button';
  runBtn.textContent = 'Run';
  actions.appendChild(runBtn);
  body.appendChild(actions);

  const status = document.createElement('div');
  body.appendChild(status);

  const refreshRun = () => {
    const bad = body.querySelector('input.invalid');
    const missing = Array.from(body.querySelectorAll('input[data-required="1"]'))
      .some(i => i.value.trim() === '');
    runBtn.disabled = Boolean(bad) || missing;
  };
  body.addEventListener('sightline-validity', refreshRun);
  body.addEventListener('input', refreshRun);

  head.addEventListener('click', () => {
    const open = body.hidden;
    body.hidden = !open;
    head.setAttribute('aria-expanded', String(open));
  });

  runBtn.addEventListener('click', async () => {
    const parameters = {};
    Object.keys(readers).forEach(k => { parameters[k] = readers[k](); });

    runBtn.disabled = true;
    status.innerHTML = '';

    try {
      // The export cannot read this page's saved choice - a file:// report and
      // a localhost page are different origins - so the choice travels with the
      // run and is stamped into the generated HTML.
      parameters.theme = document.documentElement.getAttribute('data-theme') ||
        (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');

      const job = await api.post('/api/run', { toolId: tool.id, parameters });
      await followJob(job.JobId, status, runBtn);
    } catch (err) {
      showError(status, err.message);
      runBtn.disabled = false;
    }
  });

  row.append(head, body);
  return row;
}

function showError(container, message) {
  container.innerHTML = '';
  const box = document.createElement('div');
  box.className = 'result failed';
  box.innerHTML = '<h3>Could not run</h3>';
  const p = document.createElement('p');
  p.textContent = message;
  box.appendChild(p);
  container.appendChild(box);
}

async function followJob(jobId, container, runBtn) {
  container.innerHTML =
    '<div class="progress"><div class="progress-track"><div class="progress-fill"></div></div>' +
    '<div class="progress-line"><p class="progress-step">Starting</p></div></div>';

  const fill = container.querySelector('.progress-fill');
  const step = container.querySelector('.progress-step');
  const line = container.querySelector('.progress-line');

  // A collection can run for many minutes. Being able to stop it is what makes
  // that acceptable - without it the only way out is killing the server.
  const cancelBtn = document.createElement('button');
  cancelBtn.className = 'ghost cancel';
  cancelBtn.type = 'button';
  cancelBtn.textContent = 'Stop';
  line.appendChild(cancelBtn);

  let stopping = false;

  cancelBtn.addEventListener('click', async () => {
    if (stopping) return;
    stopping = true;
    cancelBtn.disabled = true;
    cancelBtn.textContent = 'Stopping…';
    step.textContent = 'Stopping — waiting for the current request to finish';
    try {
      await api.post('/api/job/' + jobId + '/cancel');
    } catch (err) {
      cancelBtn.disabled = false;
      cancelBtn.textContent = 'Stop';
      stopping = false;
      step.textContent = 'Could not stop: ' + err.message;
    }
  });

  while (true) {
    await new Promise(r => setTimeout(r, 700));
    let job;
    try {
      job = await api.get('/api/job/' + jobId);
    } catch (err) {
      showError(container, err.message);
      runBtn.disabled = false;
      return;
    }

    fill.style.width = (job.Percent || 0) + '%';
    if (!stopping) step.textContent = job.Step || 'Working';

    if (job.Status !== 'Running') {
      renderResult(container, job);
      runBtn.disabled = false;
      return;
    }
  }
}

function renderResult(container, job) {
  container.innerHTML = '';
  const result = job.Result;
  const status = result ? result.Status : job.Status;

  const box = document.createElement('div');
  box.className = 'result' + (status === 'Failed' || job.Status === 'Failed' ? ' failed'
    : (job.Status === 'Cancelled' || status === 'PartialSuccess') ? ' partial' : '');

  const title = document.createElement('h3');
  title.textContent =
    job.Status === 'Cancelled' ? 'Cancelled'
    : status === 'Failed' ? 'Failed'
    : status === 'PartialSuccess' ? 'Finished with gaps'
    : 'Finished';
  box.appendChild(title);

  if (job.Message) {
    const p = document.createElement('p');
    p.textContent = job.Message;
    // Failure detail carries a stack trace; keep its line breaks readable.
    if (job.Status === 'Failed') {
      p.style.whiteSpace = 'pre-wrap';
      p.style.fontFamily = 'var(--mono)';
      p.style.fontSize = '12px';
    }
    box.appendChild(p);
  }

  if (result && result.Coverage && result.Coverage.length) {
    const cov = document.createElement('div');
    cov.className = 'coverage';
    result.Coverage.forEach(c => {
      const line = document.createElement('div');
      const state = c.Complete ? 'complete' : 'incomplete';
      line.innerHTML = '<span class="' + state + '"></span>';
      line.querySelector('span').textContent =
        c.Source + ' — ' + c.Count + ' item(s), ' + state;
      cov.appendChild(line);
    });
    box.appendChild(cov);
  }

  if (result && result.Warnings && result.Warnings.length) {
    const ul = document.createElement('ul');
    result.Warnings.forEach(w => {
      const li = document.createElement('li');
      li.textContent = w;
      ul.appendChild(li);
    });
    box.appendChild(ul);
  }

  if (result && result.OutputPath) {
    const path = document.createElement('p');
    path.className = 'path';
    path.textContent = result.OutputPath;
    box.appendChild(path);

    const actions = document.createElement('div');
    actions.className = 'actions';
    const open = document.createElement('button');
    open.className = 'ghost';
    open.type = 'button';
    open.textContent = 'Open folder';
    open.addEventListener('click', async () => {
      try { await api.post('/api/open', { path: result.OutputPath }); }
      catch (err) { open.textContent = err.message; }
    });
    actions.appendChild(open);
    box.appendChild(actions);
  }

  container.appendChild(box);
}


function reattachRunningJob(state) {
  // The job lives in a runspace in the PowerShell process, not in the page.
  // A refresh only loses the browser's copy of the job id, so pick it back up
  // rather than leaving a running collection invisible.
  if (!state.running || !state.running.JobId) return false;

  const host = document.getElementById('tools');
  const banner = document.createElement('div');
  banner.className = 'tool';
  banner.id = 'reattached';

  const head = document.createElement('div');
  head.className = 'tool-head';
  head.innerHTML = '<span class="tool-name"></span><span class="tool-desc"></span>';
  head.querySelector('.tool-name').textContent = state.running.ToolName || 'Running';
  head.querySelector('.tool-desc').textContent = 'Still running from before the page was reloaded.';

  const body = document.createElement('div');
  body.className = 'tool-body';

  banner.append(head, body);
  host.parentNode.insertBefore(banner, host);

  const fakeBtn = { disabled: true, textContent: '' };
  followJob(state.running.JobId, body, fakeBtn).then(() => {
    loadTools(true);
    const b = document.getElementById('reattached');
    if (b) setTimeout(() => b.remove(), 30000);
  });

  return true;
}

async function loadTools(connected) {
  const host = el('tools');
  const existing = document.querySelector('.preflight');
  if (existing) existing.remove();

  if (!connected) {
    host.innerHTML = '<p class="empty">Connect to a tenant to see the available tools.</p>';
    return;
  }

  const { tools } = await api.get('/api/tools');
  host.innerHTML = '';

  if (!tools.length) {
    host.innerHTML = '<p class="empty">No tools found in the tools folder.</p>';
    return;
  }

  const blocked = tools.filter(t => !t.available);
  if (blocked.length) {
    const missing = [...new Set(blocked.flatMap(t => t.missingScopes || []))];
    const panel = document.createElement('div');
    panel.className = 'preflight';
    const h = document.createElement('h2');
    h.textContent = blocked.length + ' of ' + tools.length +
      ' tool(s) unavailable with this application\u2019s permissions';
    panel.appendChild(h);
    const p = document.createElement('p');
    p.style.margin = '0 0 8px';
    p.textContent = 'These are not consented for the application you signed in as. ' +
      'Consent belongs to an application, not to you \u2014 another registration in your ' +
      'tenant may already have them.';
    panel.appendChild(p);
    const ul = document.createElement('ul');
    missing.forEach(m => {
      const li = document.createElement('li');
      const c = document.createElement('code');
      c.textContent = m;
      li.appendChild(c);
      ul.appendChild(li);
    });
    panel.appendChild(ul);
    host.parentNode.insertBefore(panel, host);
  }

  renderGroupedTools(host, tools);
}

// Sections carry Intune's own headings, so an admin reads the words they see in
// the portal every day rather than a vocabulary this tool invented. A tool whose
// category is unknown falls into "Other" rather than vanishing.
// A section's description belongs to the section, not to any tool in it. Where
// the tools differ only by platform, repeating "how a device was enrolled..."
// four times makes the reader hunt the middle of each line for the one word
// that changes. Hoisting it leaves rows that scan in a glance.
const SECTION_ORDER = [
  { key: 'Devices',     lead: 'Devices',               qualifier: 'by platform',
    blurb: 'How a device was enrolled, the groups that resulted, and everything that reaches it.',
    terse: true },
  { key: 'Assignments', lead: 'Apps and policies',     qualifier: 'assignments',
    blurb: 'What targets what across the tenant, and what targets nothing at all.' },
  { key: 'Scripts',     lead: 'Scripts and remediations' },
  { key: 'Audit',       lead: 'Tenant administration', qualifier: 'audit logs' },
  { key: 'Other',       lead: 'Other' }
];

// Shown instead of the full name where a section is terse. The platform is the
// only thing that distinguishes these four, so it is the only thing shown.
const SHORT_NAMES = {
  'device-journey':  'Windows',
  'apple-journey':   'iOS/iPadOS',
  'macos-journey':   'macOS',
  'android-journey': 'Android'
};

function renderGroupedTools(host, tools) {
  const bySection = {};
  tools.forEach(tool => {
    const key = SECTION_ORDER.some(s => s.key === tool.category) ? tool.category : 'Other';
    (bySection[key] = bySection[key] || []).push(tool);
  });

  SECTION_ORDER.forEach(section => {
    const group = bySection[section.key];
    if (!group || group.length === 0) return;

    // Within a section, an explicit order wins - platforms belong in Intune's
    // order, not alphabetical, which would put Android before Windows.
    group.sort((a, b) => {
      const ao = typeof a.order === 'number' ? a.order : 999;
      const bo = typeof b.order === 'number' ? b.order : 999;
      if (ao !== bo) return ao - bo;
      return a.name.localeCompare(b.name);
    });

    const heading = document.createElement('p');
    heading.className = 'section-heading';
    heading.appendChild(document.createTextNode(section.lead));
    if (section.qualifier) {
      const q = document.createElement('span');
      q.className = 'section-qualifier';
      q.textContent = ' \u00b7 ' + section.qualifier;
      heading.appendChild(q);
    }
    host.appendChild(heading);

    if (section.blurb) {
      const blurb = document.createElement('p');
      blurb.className = 'section-blurb';
      blurb.textContent = section.blurb;
      host.appendChild(blurb);
    }

    const wrap = document.createElement('div');
    wrap.className = 'section';
    group.forEach(tool => {
      // A terse section shows the short name and drops the description, which
      // the section heading already carries.
      const short = section.terse ? SHORT_NAMES[tool.id] : null;
      wrap.appendChild(renderTool(tool, { displayName: short, hideDescription: !!short }));
    });
    host.appendChild(wrap);
  });
}

(async function start() {
  ['tenant-id', 'client-id'].forEach(id => {
    el(id).addEventListener('input', () => {
      el('connect-error').hidden = true;
      refreshConnectButton();
    });
  });

  el('connect-btn').addEventListener('click', async () => {
    const btn = el('connect-btn');
    const connected = btn.textContent === 'Disconnect';
    btn.disabled = true;

    try {
      if (connected) {
        await api.post('/api/disconnect');
        el('tenant-id').value = '';
        el('client-id').value = '';
        await loadTools(false);
        await applyState(await api.get('/api/state'));
      } else {
        const { authUrl } = await api.post('/api/connect', {
          tenantId: el('tenant-id').value.trim(),
          clientId: el('client-id').value.trim()
        });
        window.location.href = authUrl;
      }
    } catch (err) {
      showConnectError(err.message);
      btn.disabled = false;
    }
  });

  const state = await applyState(await api.get('/api/state'));
  await loadTools(state.connected);
  reattachRunningJob(state);
})();


// Notice only - Phase 1. No download, no install; a link to the release page
// is the whole feature. Rendered once per state poll, replaced rather than
// duplicated so repeated polls do not stack banners.
function renderUpdateBanner(state) {
  const host = document.getElementById('facts');
  if (!host) return;
  const existing = document.getElementById('update-banner');
  if (existing) existing.remove();

  if (!state.updateAvailable || !state.latestVersion) return;

  const banner = document.createElement('div');
  banner.id = 'update-banner';
  banner.className = 'update-banner';

  const text = document.createElement('span');
  text.textContent = 'v' + state.latestVersion + ' is available.';
  banner.appendChild(text);

  if (state.updateUrl) {
    const link = document.createElement('a');
    link.href = state.updateUrl;
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = 'View release';
    banner.appendChild(link);
  }

  host.parentNode.insertBefore(banner, host.nextSibling);
}
