const esc = (v) =>
  String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const ROLE_LABELS = { customer: 'Customer', builder: 'Builder', admin: 'Admin' };

function nav(user) {
  if (!user) return '<a href="/login">Log in</a><a href="/register">Create account</a>';
  const links = ['<a href="/dashboard">Dashboard</a>'];
  if (user.role !== 'customer') links.push(`<a href="/jobs">${user.role === 'admin' ? 'All jobs' : 'My jobs'}</a>`, `<a href="/calendar">${user.role === 'admin' ? 'Calendar' : 'My diary'}</a>`);
  if (user.role === 'admin') {
    links.push('<a href="/admin/certificates">Certificates</a>', '<a href="/admin/templates">Pricing</a>', '<a href="/admin/users">People</a>', '<a href="/admin/emails">Emails</a>', '<a href="/admin/backups">Backups</a>', '<a href="/admin/settings">Settings</a>');
  }
  links.push('<a href="/account">My account</a>');
  links.push('<form method="post" action="/logout" class="inline"><button class="linkish">Log out</button></form>');
  return links.join('');
}

function page({ title, user, body, notice, error }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} | TheHandyTrio</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow:wght@400;500;600&family=Barlow+Condensed:wght@600;700&display=swap">
<link rel="stylesheet" href="/style.css">
<script src="/js/photos.js" defer></script>
</head>
<body>
<header class="top">
  <a class="brand" href="/">TheHandyTrio</a>
  <nav>${nav(user)}</nav>
</header>
<div class="stripe" aria-hidden="true"></div>
<main>
  ${user ? `<p class="who">Signed in as ${esc(user.name)} (${esc(ROLE_LABELS[user.role] || user.role)})</p>` : ''}
  <h1>${esc(title)}</h1>
  ${notice ? `<div class="notice" role="status">${esc(notice)}</div>` : ''}
  ${error ? `<div class="error" role="alert">${esc(error)}</div>` : ''}
  ${body}
</main>
<footer class="foot"><a href="/privacy">Privacy notice</a></footer>
</body>
</html>`;
}

module.exports = { esc, page, ROLE_LABELS };
