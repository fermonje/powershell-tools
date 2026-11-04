import { createServer } from 'node:http';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';

const demo = process.argv.includes('--demo');
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const fields = ['total', 'ready', 'smsOnly', 'noMfa', 'adminSms', 'guestsExcluded'];
const tenant = '11111111-1111-4111-8111-111111111111';
const secondTenant = '22222222-2222-4222-8222-222222222222';
const customers = demo
  ? { [tenant]: { name: 'Empresa demo A' }, [secondTenant]: { name: 'Empresa demo B' } }
  : JSON.parse(process.env.CIT_CUSTOMERS ?? '{}');
const issuerTenant = process.env.CIT_LOGIN_TENANT;
const origin = demo ? 'http://127.0.0.1:3000' : process.env.CIT_ORIGIN;
const directory = demo ? resolve('.demo-data') : process.env.CIT_DATA_DIR;
if (!demo && (!process.env.WEBSITE_SITE_NAME || !uuid.test(issuerTenant ?? '') ||
    !directory || !origin || new URL(origin).origin !== origin || !origin.startsWith('https://'))) {
  throw new Error('Configura App Service Authentication, CIT_LOGIN_TENANT, CIT_DATA_DIR y CIT_ORIGIN.');
}
for (const [id, customer] of Object.entries(customers)) {
  if (!uuid.test(id) || typeof customer.name !== 'string' || (!demo &&
      (!Array.isArray(customer.members) || customer.members.some(member => !uuid.test(member)) ||
       (customer.ingestHash !== undefined && !/^[0-9a-f]{64}$/.test(customer.ingestHash))))) {
    throw new Error('Configuración CIT_CUSTOMERS inválida.');
  }
}
const index = await readFile(new URL('./index.html', import.meta.url));
const script = await readFile(new URL('./app.js', import.meta.url));
const css = await readFile(new URL('./style.css', import.meta.url));
const logo = await readFile(new URL('./cit-logo.svg', import.meta.url));
const digest = value => createHash('sha256').update(value).digest();

function memberships(req) {
  if (demo) return Object.keys(customers);
  try {
    const principal = JSON.parse(Buffer.from(req.headers['x-ms-client-principal'], 'base64'));
    if (principal.auth_typ !== 'aad') return [];
    const claim = (short, mapped) => principal.claims.find(({ typ }) => typ === short || typ === mapped)?.val;
    const tid = claim('tid', 'http://schemas.microsoft.com/identity/claims/tenantid');
    const oid = claim('oid', 'http://schemas.microsoft.com/identity/claims/objectidentifier');
    if (tid !== issuerTenant || !uuid.test(oid ?? '')) return [];
    return Object.keys(customers).filter(id => customers[id].members.includes(oid));
  } catch {
    return [];
  }
}

function canonicalReport(input, id) {
  const timestamp = Date.parse(input?.collectedAt);
  if (input?.version !== 1 || input.tenantId !== id ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$/.test(input.collectedAt) ||
      !Number.isFinite(timestamp) || timestamp > Date.now() + 300000) return;
  const counts = Object.fromEntries(fields.map(key => [key, input.counts?.[key]]));
  if (Object.values(counts).some(value => !Number.isSafeInteger(value) || value < 0 || value > 100000000) ||
      counts.ready + counts.smsOnly + counts.noMfa !== counts.total || counts.adminSms > counts.smsOnly) return;
  const report = { version: 1, tenantId: id, collectedAt: new Date(timestamp).toISOString(), counts };
  if (input.methodCounts !== undefined) {
    const keys = ['microsoftAuthenticatorPush', 'mobilePhone', 'softwareOneTimePasscode', 'passKeyDeviceBoundAuthenticator', 'fido2'];
    const entries = keys.map(key => [key, input.methodCounts?.[key]]);
    if (entries.some(([, value]) => !Number.isSafeInteger(value) || value < 0 || value > counts.total)) return;
    report.methodCounts = Object.fromEntries(entries);
  }
  return report;
}

async function storeReport(id, report) {
  const folder = join(directory, id);
  const content = JSON.stringify(report);
  const filename = digest(content).toString('hex') + '.json';
  await mkdir(folder, { recursive: true });
  const temp = join(folder, randomUUID() + '.tmp');
  try {
    await writeFile(temp, content, { flag: 'wx' });
    await rename(temp, join(folder, filename));
  } finally {
    await rm(temp, { force: true });
  }
}

const server = createServer(async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
  const send = (status, content, type = 'application/json') => {
    res.writeHead(status, { 'Content-Type': type });
    res.end(type === 'application/json' ? JSON.stringify(content) : content);
  };
  try {
    const path = req.url;
    const allowed = memberships(req);
    if (req.method === 'GET' && ['/', '/app.js', '/style.css', '/cit-logo.svg', '/api/customers'].includes(path)) {
      if (!allowed.length) return send(403, { error: 'La cuenta no tiene empresas asignadas.' });
      if (path === '/') return send(200, index, 'text/html; charset=utf-8');
      if (path === '/app.js') return send(200, script, 'text/javascript; charset=utf-8');
      if (path === '/style.css') return send(200, css, 'text/css; charset=utf-8');
      if (path === '/cit-logo.svg') return send(200, logo, 'image/svg+xml');
      if (path === '/api/customers') return send(200, {
        demo, customers: allowed.map(id => ({ id, name: customers[id].name }))
      });
    }
    const ingest = path === '/api/ingest' && req.method === 'POST';
    const id = /^\/api\/reports\/([a-f0-9-]+)$/.exec(path)?.[1];
    if (!ingest && (!uuid.test(id ?? '') || !Object.hasOwn(customers, id))) {
      return send(404, { error: 'Ruta no disponible.' });
    }
    if (req.method === 'GET') {
      if (!allowed.includes(id)) return send(403, { error: 'Acceso denegado.' });
      const folder = join(directory, id);
      const names = await readdir(folder).catch(error => {
        if (error.code === 'ENOENT') return [];
        throw error;
      });
      const reports = await Promise.all(names.filter(name => /^[a-f0-9]{64}\.json$/.test(name))
        .map(async name => JSON.parse(await readFile(join(folder, name), 'utf8'))));
      return send(200, reports.sort((a, b) => b.collectedAt.localeCompare(a.collectedAt)));
    }
    if (req.method === 'POST') {
      if (!ingest && !(allowed.includes(id) && req.headers.origin === origin)) {
        return send(403, { error: 'Carga no autorizada.' });
      }
      if (req.headers['content-type']?.split(';')[0] !== 'application/json') {
        return send(415, { error: 'Se requiere JSON.' });
      }
      let body = '';
      for await (const chunk of req.setEncoding('utf8')) {
        body += chunk;
        if (body.length > 16384) {
          send(413, { error: 'Resumen demasiado grande.' });
          return;
        }
      }
      let input;
      try { input = JSON.parse(body); } catch { return send(400, { error: 'JSON inválido.' }); }
      const reportTenant = ingest ? input?.tenantId : id;
      if (ingest) {
        const authorization = req.headers.authorization ?? '';
        const hash = typeof reportTenant === 'string' && uuid.test(reportTenant) &&
          customers[reportTenant]?.ingestHash;
        if (!hash || !/^Bearer [a-f0-9]{64}$/.test(authorization) ||
            !timingSafeEqual(digest(authorization.slice(7)), Buffer.from(hash, 'hex'))) {
          return send(403, { error: 'Carga no autorizada.' });
        }
      }
      const report = canonicalReport(input, reportTenant);
      if (!report) return send(400, { error: 'Resumen inválido o tenant distinto al seleccionado.' });
      await storeReport(reportTenant, report);
      return send(201, { collectedAt: report.collectedAt });
    }
    return send(405, { error: 'Método no permitido.' });
  } catch (error) {
    console.error('Error del portal:', error.code ?? error.name);
    if (!res.headersSent) send(500, { error: 'No se pudo procesar la solicitud.' });
  }
});

server.listen(demo ? 3000 : Number(process.env.PORT ?? 8080), demo ? '127.0.0.1' : '0.0.0.0', () => {
  console.log(demo ? 'Demo local en http://127.0.0.1:3000' : 'Portal CIT iniciado.');
});
