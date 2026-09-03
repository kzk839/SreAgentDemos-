'use strict';

const elements = {
  form: document.getElementById('create-form'), name: document.getElementById('item-name'),
  body: document.getElementById('items-body'), empty: document.getElementById('empty-state'),
  count: document.getElementById('item-count'), refresh: document.getElementById('refresh-button'),
  message: document.getElementById('message'), dbIndicator: document.getElementById('db-indicator'),
  dbState: document.getElementById('db-state'), workloadState: document.getElementById('workload-state'),
  activities: document.getElementById('activity-list'),
};

function showMessage(text, error = false) {
  elements.message.textContent = text;
  elements.message.classList.toggle('error', error);
}

async function request(url, options) {
  const response = await fetch(url, {
    ...options,
    headers: { 'content-type': 'application/json', 'x-operation-id': crypto.randomUUID(), ...options?.headers },
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(body.error || `Request failed (${response.status})`);
  }
  return response.status === 204 ? null : response.json();
}

function actionButton(symbol, title, className) {
  const button = document.createElement('button');
  Object.assign(button, { type: 'button', className: `icon-button ${className}`, textContent: symbol, title });
  button.setAttribute('aria-label', title);
  return button;
}

function renderItems(items) {
  elements.body.replaceChildren();
  elements.count.textContent = String(items.length);
  elements.empty.hidden = items.length !== 0;
  for (const item of items) {
    const row = document.createElement('tr');
    const idCell = document.createElement('td');
    const nameCell = document.createElement('td');
    const statusCell = document.createElement('td');
    const createdCell = document.createElement('td');
    const actionsCell = document.createElement('td');
    const statusInput = document.createElement('input');
    idCell.textContent = `#${item.Id}`;
    nameCell.textContent = item.Name;
    statusInput.value = item.Status;
    statusInput.maxLength = 50;
    statusInput.setAttribute('aria-label', `Status for item ${item.Id}`);
    statusCell.append(statusInput);
    createdCell.textContent = new Date(item.CreatedAt).toLocaleString('ja-JP');
    actionsCell.className = 'row-actions';
    const save = actionButton('✓', `Save item ${item.Id}`, 'save');
    save.addEventListener('click', async () => mutateItem(`/api/items/${item.Id}`, {
      method: 'PUT', body: JSON.stringify({ status: statusInput.value }),
    }, `Item #${item.Id} updated.`));
    const remove = actionButton('×', `Delete item ${item.Id}`, 'delete');
    remove.addEventListener('click', async () => mutateItem(`/api/items/${item.Id}`, {
      method: 'DELETE',
    }, `Item #${item.Id} deleted.`));
    actionsCell.append(save, remove);
    row.append(idCell, nameCell, statusCell, createdCell, actionsCell);
    elements.body.append(row);
  }
}

function renderStatus(status) {
  elements.dbIndicator.classList.toggle('online', status.dbConnected);
  elements.dbState.textContent = status.dbConnected ? 'Database connected' : 'Database unavailable';
  elements.workloadState.textContent = `Workload: ${status.workload.state}`;
  elements.activities.replaceChildren();
  for (const activity of status.recentActivities.filter(item => item.source === 'USER').slice(0, 8)) {
    const entry = document.createElement('li');
    entry.className = activity.success ? 'success' : 'failure';
    const summary = document.createElement('span');
    const timing = document.createElement('time');
    summary.textContent = `${activity.operationType} · ${activity.detail}`;
    timing.dateTime = activity.timestamp;
    timing.textContent = `${new Date(activity.timestamp).toLocaleTimeString('ja-JP')} · ${activity.durationMs} ms`;
    entry.append(summary, timing);
    elements.activities.append(entry);
  }
}

async function mutateItem(url, options, successMessage) {
  try {
    await request(url, options);
    showMessage(successMessage);
    await refreshAll();
  } catch (err) { showMessage(err.message, true); }
}

async function refreshAll() {
  try {
    const [items, status] = await Promise.all([request('/api/items'), request('/api/status')]);
    renderItems(items);
    renderStatus(status);
  } catch (err) { showMessage(err.message, true); }
}

elements.form.addEventListener('submit', async (event) => {
  event.preventDefault();
  await mutateItem('/api/items', { method: 'POST', body: JSON.stringify({ name: elements.name.value }) }, 'Item added.');
  elements.form.reset();
});
elements.refresh.addEventListener('click', refreshAll);
void refreshAll();
setInterval(refreshAll, 3000);