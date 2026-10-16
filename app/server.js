const express = require('express');
const app = express();
const port = process.env.PORT || 3000;
const host = process.env.HOST || '127.0.0.1';

const crypto = require('crypto');

function sameText(a, b) {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function basicAuth(req, res, next) {
  const expectedUser = process.env.USERNAME;
  const expectedPass = process.env.PASSWORD;
  if (!expectedUser || !expectedPass) {
    return res.status(500).send('Server is not configured');
  }

  const [scheme, encoded] = (req.headers.authorization || '').split(' ');
  if (scheme === 'Basic' && encoded) {
    const decoded = Buffer.from(encoded, 'base64').toString();
    const colon = decoded.indexOf(':');
    const user = decoded.slice(0, colon);
    const pass = decoded.slice(colon + 1);
    if (colon !== -1 && sameText(user, expectedUser) && sameText(pass, expectedPass)) {
      return next();
    }
  }

  res.set('WWW-Authenticate', 'Basic realm="secret"');
  res.status(401).send('Invalid username or password');
}

app.get('/secret', basicAuth, (req, res) => {
  res.send(process.env.SECRET_MESSAGE);
});

app.get('/', (req, res) => {
  res.send('Good Morning World! (おはようせかい)');
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.listen(port, host, () => {
  console.log(`Server is running on http://${host}:${port}`);
});
