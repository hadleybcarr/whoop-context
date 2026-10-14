// WHOOP data through this site's backend (serve.py), which holds the OAuth tokens.
// WHOOP's API has sleep, workouts, recovery and daily strain, but no minute-level heart rate.

async function getJson(url, options) {
  const res = await fetch(url, { credentials: 'same-origin', ...options });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error ?? `Request failed (${res.status})`);
  return body;
}

// { backend, server_keys, configured, connected, name, redirect_uri }.
// On a static host there's no backend, so only sample data is on offer.
export async function whoopStatus() {
  try {
    return await getJson('/api/whoop/status');
  } catch {
    return { backend: false, configured: false, connected: false };
  }
}

// The client ID and secret of the visitor's own WHOOP developer app. Kept server-side, in their session.
export const saveWhoopKeys = (clientId, clientSecret) => getJson('/auth/whoop/credentials', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ client_id: clientId, client_secret: clientSecret }),
});

export function connectWhoop() {
  window.location.href = '/auth/whoop/login';
}

export const disconnectWhoop = () => getJson('/auth/whoop/logout', { method: 'POST' });

// Sleep, workouts, recovery and cycles between start and end, with times parsed to Dates.
export async function fetchWhoop(start, end) {
  const params = new URLSearchParams({ start: start.toISOString(), end: end.toISOString() });
  const data = await getJson(`/api/whoop/data?${params}`);
  const dates = (r, ...keys) => ({ ...r, ...Object.fromEntries(keys.map((k) => [k, r[k] ? new Date(r[k]) : null])) });
  return {
    sleep: data.sleep.map((s) => dates(s, 'start', 'end')),
    workouts: data.workouts.map((w) => dates(w, 'start', 'end')),
    recovery: data.recovery.map((r) => dates(r, 'wake')),
    cycles: data.cycles.map((c) => dates(c, 'start', 'end')),
  };
}

// Trains on the visitor's own labels. events_csv: export rows; days: one row per day (see train.py).
export const trainModel = (payload) => getJson('/api/train', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(payload),
});
