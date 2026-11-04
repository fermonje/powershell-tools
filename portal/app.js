const get = id => document.getElementById(id);
const companies = new Map();
const fileInput = get('file');
const dashboard = get('dashboard');
const status = get('status');
const formatter = new Intl.DateTimeFormat('es-AR', { dateStyle: 'short', timeStyle: 'short' });
const number = new Intl.NumberFormat('es-AR');
const percentage = new Intl.NumberFormat('es-AR', { style: 'percent', maximumFractionDigits: 1 });
const date = value => formatter.format(new Date(value));
const methodGroups = [
  ['ready', 'Con alternativa registrada'],
  ['smsOnly', 'Solo SMS o voz'],
  ['noMfa', 'Sin método MFA']
];
const authenticationMethods = [
  ['microsoftAuthenticatorPush', 'Authenticator (notificación)'],
  ['mobilePhone', 'SMS / llamada móvil'],
  ['softwareOneTimePasscode', 'App OATH / TOTP'],
  ['passKeyDeviceBoundAuthenticator', 'Passkey (Authenticator)'],
  ['fido2', 'Llave FIDO2']
];

function addMetricTooltip(row, label, count, total) {
  const trigger = document.createElement('button');
  trigger.type = 'button';
  trigger.className = 'metric-help';
  trigger.textContent = 'ⓘ';
  trigger.setAttribute('aria-label', 'Detalle de ' + label);

  const tooltip = document.createElement('span');
  tooltip.className = 'metric-tooltip';
  tooltip.setAttribute('role', 'tooltip');
  tooltip.id = row.parentElement.id + '-tooltip-' + row.parentElement.children.length;
  const detail = total
    ? number.format(count) + ' de ' + number.format(total) + ' usuarios (' + percentage.format(count / total) + ')'
    : 'Sin usuarios analizados';
  tooltip.textContent = label + ' · ' + detail;
  trigger.setAttribute('aria-describedby', tooltip.id);
  trigger.addEventListener('click', () => row.classList.toggle('show-tooltip'));
  trigger.addEventListener('blur', () => row.classList.remove('show-tooltip'));
  trigger.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      row.classList.remove('show-tooltip');
      trigger.blur();
    }
  });
  row.append(trigger, tooltip);
}

function renderMethods({ counts, methodCounts }) {
  const list = get('methods');
  list.replaceChildren();
  get('methods-note').textContent = methodCounts
    ? 'Usuarios por método registrado. Un usuario puede tener varios métodos.'
    : 'Este resumen no incluye el desglose por método.';
  if (!methodCounts) return;
  for (const [key, label] of authenticationMethods) {
    const row = document.createElement('li');
    const name = document.createElement('span');
    name.textContent = label;
    const count = methodCounts[key];
    const share = counts.total ? count / counts.total : 0;
    const bar = chartBar({ total: counts.total, registered: count }, [['registered']]);
    const value = document.createElement('strong');
    value.textContent = number.format(count) + ' · ' + (counts.total ? percentage.format(share) : '—');
    row.append(name, bar, value);
    list.append(row);
    addMetricTooltip(row, label, count, counts.total);
  }
}

function chartBar(counts, groups) {
  const ns = 'http://www.w3.org/2000/svg';
  const bar = document.createElementNS(ns, 'svg');
  bar.classList.add('chart-bar');
  bar.setAttribute('viewBox', '0 0 100 12');
  bar.setAttribute('preserveAspectRatio', 'none');
  bar.setAttribute('aria-hidden', 'true');
  let offset = 0;
  for (const [key, label] of groups) {
    const width = counts.total ? 100 * counts[key] / counts.total : 0;
    const segment = document.createElementNS(ns, 'rect');
    segment.classList.add(key);
    segment.setAttribute('x', offset);
    segment.setAttribute('width', width);
    segment.setAttribute('height', 12);
    if (label && width > 0) {
      const tooltip = document.createElementNS(ns, 'title');
      tooltip.textContent = label + ' · ' + number.format(counts[key]) + ' de ' +
        number.format(counts.total) + ' usuarios (' + percentage.format(width / 100) + ')';
      segment.append(tooltip);
    }
    bar.append(segment);
    offset += width;
  }
  return bar;
}

function renderCharts(reports) {
  renderMethods(reports[0]);
  const distribution = get('distribution');
  const trend = get('trend');
  distribution.replaceChildren();
  trend.replaceChildren();
  const { counts } = reports[0];
  get('distribution-bar').replaceChildren(chartBar(counts, methodGroups));
  for (const group of methodGroups) {
    const [key, label] = group;
    const row = document.createElement('li');
    const caption = document.createElement('span');
    const share = counts.total ? percentage.format(counts[key] / counts.total) : '—';
    row.className = key;
    caption.textContent = label;
    const value = document.createElement('strong');
    value.textContent = number.format(counts[key]) + ' · ' + share;
    row.append(caption, value);
    distribution.append(row);
    addMetricTooltip(row, label, counts[key], counts.total);
  }
  get('trend-note').textContent = reports.length === 1
    ? 'Hay un solo relevamiento. Cargá otro para ver la evolución.'
    : 'Porcentaje de usuarios por medición · Hasta 6 relevamientos recientes';
  const recent = reports.slice(0, 6).reverse();
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('class', 'trend-plot');
  svg.setAttribute('role', 'group');
  svg.setAttribute('aria-label', 'Evolución por relevamiento');
  const mark = (tag, attributes) => {
    const element = document.createElementNS(ns, tag);
    for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
    svg.append(element);
    return element;
  };
  for (const share of [1, .5, 0]) {
    const y = 14 + 198 * (1 - share);
    mark('line', { x1: '13%', x2: '95%', y1: y, y2: y, class: 'trend-grid' });
    mark('text', { x: '11%', y: y + 4, 'text-anchor': 'end' }).textContent = percentage.format(share);
  }
  const xAt = index => recent.length === 1 ? 54 : 13 + 82 * index / (recent.length - 1);
  const shortDate = new Intl.DateTimeFormat('es-AR', { day: '2-digit', month: '2-digit' });
  for (const [index, report] of recent.entries()) {
    mark('text', { x: xAt(index) + '%', y: 236, 'text-anchor': 'middle' }).textContent =
      shortDate.format(new Date(report.collectedAt));
  }
  for (const [key] of methodGroups) {
    let previous;
    for (const [index, report] of recent.entries()) {
      const { counts } = report;
      if (!counts.total) {
        previous = undefined;
        continue;
      }
      const x = xAt(index) + '%';
      const y = 14 + 198 * (1 - counts[key] / counts.total);
      if (previous) mark('line', { x1: previous.x, y1: previous.y, x2: x, y2: y, class: key });
      mark('circle', { cx: x, cy: y, r: 4, class: key });
      previous = { x, y };
    }
  }
  const tooltip = document.createElement('div');
  tooltip.id = 'trend-tooltip';
  tooltip.setAttribute('role', 'tooltip');
  tooltip.hidden = true;
  let activeTarget;
  for (const [index, report] of recent.entries()) {
    const x = xAt(index);
    const left = index === 0 ? 11 : (xAt(index - 1) + x) / 2;
    const right = index === recent.length - 1 ? 100 : (x + xAt(index + 1)) / 2;
    const target = mark('rect', {
      x: left + '%', y: 4, width: (right - left) + '%', height: 238,
      class: 'trend-target', tabindex: 0, role: 'button',
      'aria-label': 'Ver datos del ' + date(report.collectedAt)
    });
    const { counts } = report;
    const show = () => {
      activeTarget?.removeAttribute('aria-describedby');
      activeTarget = target;
      const heading = document.createElement('strong');
      heading.textContent = date(report.collectedAt) + ' · ' + number.format(counts.total) + ' usuarios';
      tooltip.replaceChildren(heading);
      for (const [key, label] of methodGroups) {
        const row = document.createElement('div');
        const share = counts.total ? percentage.format(counts[key] / counts.total) : '—';
        row.textContent = label + ' · ' + number.format(counts[key]) + ' (' + share + ')';
        tooltip.append(row);
      }
      tooltip.hidden = false;
      target.setAttribute('aria-describedby', tooltip.id);
    };
    const hide = () => {
      if (activeTarget !== target) return;
      tooltip.hidden = true;
      target.removeAttribute('aria-describedby');
      activeTarget = undefined;
    };
    target.addEventListener('pointerenter', show);
    target.addEventListener('pointerleave', () => {
      if (document.activeElement !== target) hide();
    });
    target.addEventListener('focus', show);
    target.addEventListener('blur', hide);
    target.addEventListener('click', show);
    target.addEventListener('keydown', event => {
      if (event.key === 'Escape') hide();
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        show();
      }
    });
  }
  trend.append(svg, tooltip);
}

async function request(url, options) {
  const response = await fetch(url, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error ?? 'Error de conexión.');
  return data;
}

function renderReports(reports, company) {
  get('tenant-context').textContent = 'Microsoft Entra ID · ' + company;
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
    const caption = document.createElement('span');
    caption.textContent = label;
    const heading = document.createElement('strong');
    heading.textContent = value;
    card.append(caption, heading);
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
  renderCharts(reports);
  dashboard.hidden = false;
}

async function readSummary(file) {
  if (file.size > 16384) throw new Error(file.name + ' excede el tamaño de un resumen.');
  let summary;
  try {
    summary = JSON.parse(await file.text());
  } catch {
    throw new Error(file.name + ' no contiene un JSON válido.');
  }
  const timestamp = Date.parse(summary?.collectedAt);
  const counts = summary?.counts;
  const fields = ['total', 'ready', 'smsOnly', 'noMfa', 'adminSms', 'guestsExcluded'];
  if (summary?.version !== 1 || !Number.isFinite(timestamp) ||
      fields.some(key => !Number.isSafeInteger(counts?.[key]) || counts[key] < 0 || counts[key] > 100000000) ||
      counts.ready + counts.smsOnly + counts.noMfa !== counts.total || counts.adminSms > counts.smsOnly) {
    throw new Error(file.name + ' no tiene el formato esperado de un resumen CIT.');
  }
  if (!companies.has(summary.tenantId)) {
    throw new Error(file.name + ' corresponde a un tenant que no está disponible.');
  }
  const { methodCounts } = summary;
  if (methodCounts !== undefined && authenticationMethods.some(([key]) => {
    const value = methodCounts?.[key];
    return !Number.isSafeInteger(value) || value < 0 || value > counts.total;
  })) {
    throw new Error(file.name + ' contiene conteos de métodos inválidos.');
  }
  return { tenantId: summary.tenantId, collectedAt: new Date(timestamp).toISOString(), counts, methodCounts };
}

const button = get('compare');
const changeFiles = get('change-files');
const controls = get('workspace-controls');
function setWorkspaceExpanded(expanded) {
  controls.hidden = !expanded;
  changeFiles.setAttribute('aria-expanded', String(expanded));
  changeFiles.textContent = expanded ? 'Ocultar carga' : 'Cambiar archivos';
}

changeFiles.addEventListener('click', () => {
  setWorkspaceExpanded(controls.hidden);
  if (!controls.hidden) fileInput.focus();
});

get('upload').addEventListener('submit', async event => {
  event.preventDefault();
  const files = Array.from(fileInput.files);
  if (!files.length) return;
  button.disabled = true;
  fileInput.disabled = true;
  dashboard.hidden = true;
  get('tenant-context').textContent = 'Microsoft Entra ID';
  status.textContent = 'Leyendo resúmenes…';
  try {
    const reports = await Promise.all(files.map(readSummary));
    const { tenantId } = reports[0];
    if (reports.some(report => report.tenantId !== tenantId)) {
      throw new Error('Seleccioná resúmenes de una misma empresa para compararlos.');
    }
    reports.sort((a, b) => b.collectedAt.localeCompare(a.collectedAt));
    renderReports(reports, companies.get(tenantId));
    get('milestone').hidden = true;
    document.body.classList.add('has-results');
    setWorkspaceExpanded(false);
    changeFiles.focus();
    status.textContent = reports.length === 1
      ? '1 resumen cargado en esta vista.'
      : reports.length + ' resúmenes cargados en esta vista.';
  } catch (error) {
    status.textContent = error.message;
  } finally {
    button.disabled = false;
    fileInput.disabled = false;
  }
});

try {
  const data = await request('/api/customers');
  get('demo').hidden = !data.demo;
  for (const item of data.customers) companies.set(item.id, item.name);
  button.disabled = false;
  fileInput.disabled = false;
} catch (error) {
  status.textContent = error.message;
}
