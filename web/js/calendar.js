// Google Calendar (read-only) via Google Identity Services token flow.
import { GOOGLE_CLIENT_ID, CALENDAR_SCOPE, CALENDAR_WRITE_SCOPE } from './config.js';

let accessToken = null;

export const calendarConfigured = () => Boolean(GOOGLE_CLIENT_ID);
export const calendarConnected = () => Boolean(accessToken);

function loadGis() {
  if (window.google?.accounts?.oauth2) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://accounts.google.com/gsi/client';
    s.onload = resolve;
    s.onerror = () => reject(new Error('Could not load Google sign-in'));
    document.head.appendChild(s);
  });
}

async function requestToken(scope) {
  await loadGis();
  return new Promise((resolve, reject) => {
    const client = window.google.accounts.oauth2.initTokenClient({
      client_id: GOOGLE_CLIENT_ID,
      scope,
      callback: (res) => (res.error ? reject(new Error(res.error)) : resolve(res.access_token)),
    });
    client.requestAccessToken();
  });
}

export async function connectCalendar() {
  accessToken = await requestToken(CALENDAR_SCOPE);
}

let writeToken = null;

// Adds an event to the primary calendar. Asks for write access the first time, separately
// from the read-only connection.
export async function createEvent({ title, start, end }) {
  writeToken ??= await requestToken(CALENDAR_WRITE_SCOPE);
  const res = await fetch('https://www.googleapis.com/calendar/v3/calendars/primary/events', {
    method: 'POST',
    headers: { Authorization: `Bearer ${writeToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      summary: title,
      start: { dateTime: start.toISOString() },
      end: { dateTime: end.toISOString() },
    }),
  });
  if (!res.ok) throw new Error(`Could not add to Google Calendar (${res.status})`);
  const item = await res.json();
  return { id: item.id, title, start, end, attendees: 0, recurring: false };
}

// Timed events from the primary calendar between start and end. All-day events are skipped:
// they have no time window to compare heart rate against.
export async function fetchEvents(start, end) {
  if (!accessToken) throw new Error('Calendar not connected');
  const params = new URLSearchParams({
    timeMin: start.toISOString(),
    timeMax: end.toISOString(),
    singleEvents: 'true',
    orderBy: 'startTime',
    maxResults: '2500',
  });
  const events = [];
  let pageToken;
  do {
    if (pageToken) params.set('pageToken', pageToken);
    const res = await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!res.ok) throw new Error(`Calendar request failed (${res.status})`);
    const body = await res.json();
    for (const item of body.items ?? []) {
      if (!item.start?.dateTime || item.status === 'cancelled') continue;
      events.push({
        id: item.id,
        title: item.summary || '(No title)',
        start: new Date(item.start.dateTime),
        end: new Date(item.end.dateTime),
        attendees: item.attendees?.length ?? 0,
        recurring: Boolean(item.recurringEventId),
      });
    }
    pageToken = body.nextPageToken;
  } while (pageToken);
  return events;
}
