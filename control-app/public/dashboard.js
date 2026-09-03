'use strict';

const state = { chart: null, faults: [], pendingFault: null };
const elements = Object.fromEntries(['window', 'bucket', 'source', 'type', 'success', 'failure', 'rate', 'updated', 'faults', 'fault-message', 'confirm', 'confirm-copy', 'delay-field', 'delay'].map(id => [id, document.getElementById(id)]));

async function request(url, options) {
  const response = await fetch(url, { headers: { 'Content-Type': 'application/json' }, ...options });
  if (response.status === 401) { window.location.assign('/.auth/login/aad'); throw new Error('Authentication required'); }
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || 'Request failed');
  return body;
}

function renderChart(series) {
  const data = {
    labels: series.map(point => new Date(point.start).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })),
    datasets: [
      { type: 'bar', label: 'Success', data: series.map(point => point.successCount), backgroundColor: '#16855b', stack: 'count', yAxisID: 'count' },
      { type: 'bar', label: 'Failure', data: series.map(point => point.failureCount), backgroundColor: '#cc3d45', stack: 'count', yAxisID: 'count' },
      { type: 'line', label: 'Success rate', data: series.map(point => point.successRate), borderColor: '#2457a6', backgroundColor: '#2457a6', pointRadius: 0, borderWidth: 2, spanGaps: false, yAxisID: 'rate' },
    ],
  };
  if (state.chart) { state.chart.data = data; state.chart.update('none'); return; }
  state.chart = new Chart(document.getElementById('activity-chart'), { type: 'bar', data, options: { responsive: true, maintainAspectRatio: false, interaction: { mode: 'index', intersect: false }, scales: { x: { stacked: true, grid: { display: false } }, count: { stacked: true, beginAtZero: true, title: { display: true, text: 'Operations' } }, rate: { position: 'right', min: 0, max: 100, grid: { drawOnChartArea: false }, ticks: { callback: value => `${value}%` } } } } });
}

async function loadDashboard() {
  const query = new URLSearchParams({ window: elements.window.value, bucket: elements.bucket.value, source: elements.source.value, type: elements.type.value });
  const data = await request(`/api/dashboard?${query}`);
  elements.success.textContent = data.summary.successCount.toLocaleString();
  elements.failure.textContent = data.summary.failureCount.toLocaleString();
  elements.rate.textContent = data.summary.successRate === null ? '--' : `${data.summary.successRate}%`;
  elements.updated.textContent = `Updated ${new Date(data.generatedAt).toLocaleTimeString()}`;
  renderChart(data.series);
}

function time(value) { return value ? new Date(value).toLocaleString() : 'Not reported'; }

function renderFaults() {
  elements.faults.replaceChildren(...state.faults.map(fault => {
    const row = document.createElement('article');
    row.className = 'fault-row';
    const activeIntent = fault.state.desiredState === 'active';
    row.innerHTML = `<div class="fault-main"><div><span class="target">${fault.target}</span><h3>${fault.id}</h3></div><p>${fault.description}</p><small>${fault.impact}</small></div><div class="fault-state"><span class="status status-${fault.state.status}">${fault.state.status}</span><dl><div><dt>Desired</dt><dd>${fault.state.desiredState}</dd></div><div><dt>Observed</dt><dd>${fault.state.observedState}</dd></div><div><dt>Heartbeat</dt><dd>${time(fault.state.lastHeartbeatAt)}</dd></div></dl></div><div class="fault-action"><button data-id="${fault.id}" data-action="${activeIntent ? 'stop' : 'start'}" class="${activeIntent ? 'secondary' : 'primary'}">${activeIntent ? 'Stop' : 'Start'}</button></div>`;
    return row;
  }));
}

async function loadFaults() { const data = await request('/api/faults'); state.faults = data.faults; renderFaults(); }

async function mutate(url, body) {
  elements['fault-message'].textContent = 'Requesting change...';
  try { await request(url, { method: 'POST', body: JSON.stringify(body || {}) }); await Promise.all([loadFaults(), loadDashboard()]); elements['fault-message'].textContent = 'Change requested'; }
  catch (error) { elements['fault-message'].textContent = error.message; }
}

elements.faults.addEventListener('click', event => {
  const button = event.target.closest('button[data-id]');
  if (!button) return;
  if (button.dataset.action === 'stop') { void mutate(`/api/faults/${button.dataset.id}/stop`); return; }
  state.pendingFault = state.faults.find(fault => fault.id === button.dataset.id);
  elements['confirm-copy'].textContent = `${state.pendingFault.target}: ${state.pendingFault.impact}. This fault continues until explicitly stopped.`;
  elements['delay-field'].hidden = state.pendingFault.id !== 'app-latency';
  elements.confirm.showModal();
});
elements.confirm.addEventListener('close', () => {
  if (elements.confirm.returnValue !== 'confirm' || !state.pendingFault) return;
  const parameters = state.pendingFault.id === 'app-latency' ? { delayMs: Number(elements.delay.value) } : {};
  void mutate(`/api/faults/${state.pendingFault.id}/start`, { parameters });
});
document.getElementById('emergency').addEventListener('click', () => { if (window.confirm('Request all faults to stop?')) void mutate('/api/faults/emergency-stop'); });
document.getElementById('reset').addEventListener('click', () => { if (window.confirm('Stop all faults and clear activity events? Audit history is preserved.')) void mutate('/api/reset'); });
for (const id of ['window', 'bucket', 'source', 'type']) elements[id].addEventListener('change', () => void loadDashboard());

async function refresh() { try { await Promise.all([loadDashboard(), loadFaults()]); } catch (error) { elements['fault-message'].textContent = error.message; } }
void refresh();
setInterval(() => void refresh(), 3000);