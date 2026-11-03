const get = id => document.getElementById(id);
const customer = get('customer');
const dashboard = get('dashboard');
const status = get('status');
const formatter = new Intl.DateTimeFormat('es-AR', { dateStyle: 'short', timeStyle: 'short' });
const number = new Intl.NumberFormat('es-AR');
const percentage = new Intl.NumberFormat('es-AR', { style: 'percent', maximumFractionDigits: 1 });
const date = value => formatter.format(new Date(value));
const reportUrl = id => '/api/reports/' + encodeURIComponent(id);
let loadVersion = 0;

async function request(url, options) {
  const response = await fetch(url, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error ?? 'Error de conexión.');
  return data;
}

async function refresh(message = '') {
  const version = ++loadVersion;
  dashboard.hidden = true;
  status.textContent = 'Cargando…';
  try {
    const reports = await request(reportUrl(customer.value));
    if (version !== loadVersion) return;
    status.textContent = message || (reports.length ? '' : 'Todavía no hay relevamientos para esta empresa.');
    if (!reports.length) return;
    const latest = reports[0];
    get('collected').textContent = date(latest.collectedAt);
    const cards = get('cards');
    cards.replaceChildren();
    const c = latest.counts;
    const indicators = [
      ['Usuarios analizados', number.format(c.total)],
      ['Con alternativa registrada', c.total ? percentage.format(c.ready / c.total) : '—'],
      ['Solo SMS o voz', number.format(c.smsOnly)],
      ['Sin método MFA', number.format(c.noMfa)],
      ['Admins con solo SMS o voz', number.format(c.adminSms)],
      ['Invitados excluidos', number.format(c.guestsExcluded)]
    ];
    for (const [label, value] of indicators) {
      const card = document.createElement('article');
      const heading = document.createElement('strong');
      heading.textContent = value;
      card.append(heading, label);
      cards.append(card);
    }
    const history = get('history');
    history.replaceChildren();
    for (const { counts, collectedAt } of reports) {
      const row = history.insertRow();
      for (const value of [date(collectedAt), ...['total', 'ready', 'smsOnly', 'noMfa'].map(key => number.format(counts[key]))]) {
        row.insertCell().textContent = value;
      }
    }
    dashboard.hidden = false;
  } catch (error) {
    if (version === loadVersion) status.textContent = error.message;
  }
}

customer.addEventListener('change', () => refresh());
get('upload').addEventListener('submit', async event => {
  event.preventDefault();
  const file = get('file').files[0];
  const button = event.submitter;
  const id = customer.value;
  if (!file || !id) return;
  if (file.size > 16384) {
    status.textContent = 'Seleccioná el JSON agregado que genera el script.';
    return;
  }
  button.disabled = true;
  customer.disabled = true;
  try {
    await request(reportUrl(id), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: await file.text() });
    event.target.reset();
    await refresh('Resumen guardado.');
  } catch (error) {
    status.textContent = error.message;
  } finally {
    button.disabled = false;
    customer.disabled = false;
  }
});

try {
  const data = await request('/api/customers');
  get('demo').hidden = !data.demo;
  for (const item of data.customers) customer.add(new Option(item.name, item.id));
  if (customer.value) await refresh();
} catch (error) {
  status.textContent = error.message;
}
