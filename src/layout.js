// The page shell: a sidebar on desktop, a tab bar on phones, and a simple centred card when logged out.
const { AsyncLocalStorage } = require('async_hooks');
const { brand } = require('./brand');

// Remembers which page is being shown, so the menu can highlight it.
const requestContext = new AsyncLocalStorage();

const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin', manager: 'Manager' };

// Simple line icons (24px grid, drawn with strokes).
const ICON_PATHS = {
  home: '<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V20h14V9.5"/><path d="M10 20v-6h4v6"/>',
  plus: '<circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/>',
  jobs: '<rect x="3" y="7" width="18" height="13" rx="2"/><path d="M9 7V5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2"/><path d="M3 12h18"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  cert: '<path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5"/><path d="m10 14 2 2 4-4"/>',
  badge: '<circle cx="12" cy="9" r="5"/><path d="m9 13-2 8 5-3 5 3-2-8"/>',
  chart: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
  tag: '<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
  people: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6 6 0 0 1 3.5 6"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
  backup: '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v6c0 1.7 3.6 3 8 3s8-1.3 8-3V6"/><path d="M4 12v6c0 1.7 3.6 3 8 3s8-1.3 8-3v-6"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  more: '<circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/>',
  logout: '<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/><path d="M10 17l-5-5 5-5M5 12h11"/>',
  shield: '<path d="M12 3 4 6v6c0 4.5 3.4 8.3 8 9 4.6-.7 8-4.5 8-9V6z"/>',
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON_PATHS[name] || ''}</svg>`;

// Menu items for each kind of person: [section, href, label, icon, showOnPhoneTabBar]
function navItems(user) {
  if (!user) return [];
  if (user.role === 'customer') {
    return [
      ['', '/dashboard', 'Dashboard', 'home', true],
      ['', '/jobs/new', 'Request a job', 'plus', true],
      ['', '/account', 'My account', 'user', true],
      ['', '/privacy', 'Privacy', 'shield', false],
    ];
  }
  if (user.role === 'builder') {
    return [
      ['', '/dashboard', 'Dashboard', 'home', true],
      ['', '/jobs', 'My jobs', 'jobs', true],
      ['', '/calendar', 'My diary', 'calendar', true],
      ['', '/availability', 'My availability', 'clock', false],
      ['', '/certify', 'Certify', 'badge', false],
      ['', '/account', 'My account', 'user', false],
    ];
  }
  const items = [
    ['', '/dashboard', 'Dashboard', 'home', true],
    ['', '/jobs', 'All jobs', 'jobs', true],
    ['', '/calendar', 'Calendar', 'calendar', true],
    ['', '/admin/certificates', 'Certificates', 'cert', false],
    ['', '/admin/reports', 'Reports', 'chart', true],
  ];
  if (user.isManager) items.push(['My work', '/availability', 'My availability', 'clock', false], ['My work', '/certify', 'Certify', 'badge', false]);
  items.push(
    ['Business', '/admin/templates', 'Pricing', 'tag', false],
    ['Business', '/admin/users', 'People', 'people', false],
    ['Business', '/admin/emails', 'Messages', 'mail', false],
    ['Business', '/admin/backups', 'Backups', 'backup', false],
    ['Business', '/admin/settings', 'Settings', 'settings', false],
    ['Business', '/account', 'My account', 'user', false],
  );
  return items;
}

// The menu item that best matches the current address.
function activeHref(items, path) {
  let best = '';
  for (const [, href] of items) {
    const match = href === '/dashboard' ? path === '/dashboard' || path === '/' : path === href || path.startsWith(href + '/');
    if (match && href.length > best.length) best = href;
  }
  // Pricing covers all its tabs; Messages covers reminders too.
  if (!best && /^\/admin\/(price-list|suppliers|access-options)/.test(path)) best = '/admin/templates';
  if (!best && path.startsWith('/admin/reminders')) best = '/admin/emails';
  return best;
}

const initials = (name) => String(name || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase();

function brandBlock(b) {
  const logo = b.hasLogo ? `/brand/logo?v=${b.logoVersion}` : '';
  return `<a class="brand" href="/">${logo ? `<img src="${logo}" alt="">` : `<span class="mark">${esc(initials(b.name))}</span>`}<span>${esc(b.name)}</span></a>`;
}

function sidebar(user, items, current) {
  let lastSection = '';
  const links = items.map(([section, href, label, ic]) => {
    const head = section && section !== lastSection ? `<div class="navsection">${esc(section)}</div>` : '';
    lastSection = section || lastSection;
    return `${head}<a href="${href}" ${href === current ? 'aria-current="page"' : ''}>${icon(ic)}<span>${esc(label)}</span></a>`;
  }).join('');
  return `<aside class="side">
    ${brandBlock(brand())}
    <nav class="navlist" aria-label="Main">${links}</nav>
    <div class="sidefoot">
      <a class="usercard" href="/account"><span class="avatar">${esc(initials(user.name))}</span>
        <span class="who2"><strong>${esc(user.name)}</strong><span>${esc(user.email || ROLE_LABELS[user.realRole || user.role])}</span></span></a>
      <form method="post" action="/logout" class="navlist"><button>${icon('logout')}<span>Log out</span></button></form>
    </div>
  </aside>`;
}

function tabbar(items, current) {
  const tabs = items.filter((i) => i[4]).slice(0, 4);
  const onMore = current && !tabs.some((t) => t[1] === current);
  return `<nav class="tabbar" aria-label="Main">
    ${tabs.map(([, href, label, ic]) => `<a href="${href}" ${href === current ? 'aria-current="page"' : ''}>${icon(ic)}<span>${esc(label.replace('Request a job', 'Request'))}</span></a>`).join('')}
    <a href="/menu" ${onMore || current === '/menu' ? 'aria-current="page"' : ''}>${icon('more')}<span>More</span></a>
  </nav>`;
}

function head(title, b) {
  const logo = b.hasLogo ? `/brand/logo?v=${b.logoVersion}` : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)} | ${esc(b.name)}</title>${logo ? `\n<link rel="icon" href="${logo}">` : ''}
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap">
<link rel="stylesheet" href="/style.css">
<style>:root { --brand: ${b.primary}; --brand-ink: ${b.primaryInk}; }</style>
<script src="/js/photos.js" defer></script>
</head>`;
}

function page({ title, subtitle, actions, user, body, notice, error }) {
  const b = brand();
  const flash = `${notice ? `<div class="notice" role="status">${esc(notice)}</div>` : ''}${error ? `<div class="error" role="alert">${esc(error)}</div>` : ''}`;

  if (!user) {
    return `${head(title, b)}
<body>
<div class="solo">
  ${brandBlock(b)}
  <main class="card ${/privacy/i.test(title) ? 'wide' : ''}">
    <h1>${esc(title)}</h1>
    ${subtitle ? `<p class="muted">${esc(subtitle)}</p>` : ''}
    ${flash}
    ${body}
  </main>
  <footer class="foot"><a href="/privacy">Privacy notice</a></footer>
</div>
</body>
</html>`;
  }

  const ctx = requestContext.getStore();
  const items = navItems(user);
  const current = activeHref(items, (ctx && ctx.path) || '');
  return `${head(title, b)}
<body>
<div class="app">
  ${sidebar(user, items, current)}
  <div class="main">
    <header class="pagehead">
      <div><h1>${esc(title)}</h1>${subtitle ? `<p>${esc(subtitle)}</p>` : ''}</div>
      ${actions || ''}
    </header>
    <main class="content">
      ${flash}
      ${body}
    </main>
    <footer class="foot">${esc(b.name)} · <a href="/privacy">Privacy notice</a></footer>
  </div>
</div>
${tabbar(items, current)}
</body>
</html>`;
}

module.exports = { esc, page, ROLE_LABELS, requestContext, navItems, icon, initials };
