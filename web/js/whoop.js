// WHOOP data through this site's backend (serve.py), which holds the OAuth tokens.
// WHOOP's API has sleep, workouts, recovery and daily strain, but no minute-level heart rate.

async function getJson(url, options) {
  const res = await fetch(url, { credentials: 'same-origin', ...options });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(body.error ?? `Request failed (${res.status})`), { status: res.status });
  return body;
}

// { backend, server_keys, configured, connected, name, redirect_uri, google_client_id }.
// google_client_id rides along so the page needn't wait on the server to start.
// backend is false only when the site has no server at all (a static host answers 404), so only
// sample data is on offer. It's null when the server can't be reached yet: a host that sleeps
// when idle (Render's free plan) can take a minute to wake, so that's worth asking again.
export async function whoopStatus() {
  try {
    return await getJson('/api/whoop/status');
  } catch (err) {
    return { backend: err.status === 404 ? false : null, configured: false, connected: false };
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
