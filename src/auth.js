const { page } = require('./layout');

// Lets async route handlers pass errors to Express's error handler.
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function requireLogin(req, res, next) {
  if (!req.user) return res.redirect('/login');
  next();
}

function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.user) return res.redirect('/login');
    if (!roles.includes(req.user.role)) {
      return res.status(403).send(page({
        title: 'No access',
        user: req.user,
        body: '<p>Your account can’t open this page.</p><p><a href="/dashboard">Back to your dashboard</a></p>',
      }));
    }
    next();
  };
}

module.exports = { wrap, requireLogin, requireRole };
