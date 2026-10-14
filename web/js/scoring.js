// Turns minute-level WHOOP samples + calendar events into per-event scores.
// Pure functions, no DOM — also imported by Node (export_demo.mjs) to build the ML dataset.
//
// A sample is { t: Date, bpm, stress? }. Stress is derived from heart rate when the source
// doesn't provide it.

// Titles that imply physical exertion. Their HR rise is effort, not stress, so they are
// scored but excluded from stress labels.
const ACTIVE_PATTERN = /\b(run|running|gym|lift|lifting|workout|yoga|swim|ride|cycling|bike|hike|climb|climbing|soccer|tennis|basketball|crossfit|pilates|spin|morning activity)\b/i;

// HR this far above baseline (as a fraction) maps to the top of the 0–3 stress scale,
// mirroring the 0–3 range of WHOOP's Stress Monitor.
const STRESS_FULL_SCALE = 0.4;
const CARRYOVER_MIN = 30;

// The minute-by-minute stats the page can toggle between. `fraction` maps an event's average to bar length.
export const METRICS = {
  hr: {
    label: 'Heart Rate', unit: 'bpm', key: 'bpm',
    format: (v) => String(Math.round(v)),
    fraction: (v, day) => (v - day.baseline) / day.baseline / STRESS_FULL_SCALE,
  },
  stress: {
    label: 'Stress', unit: '0–3', key: 'stress',
    format: (v) => v.toFixed(1),
    fraction: (v) => v / 3,
  },
};

export function isActiveEvent(event) {
  return event.active ?? ACTIVE_PATTERN.test(event.title);
}

function percentile(sorted, p) {
  if (!sorted.length) return NaN;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.round(p * (sorted.length - 1))));
  return sorted[i];
}

function samplesBetween(samples, start, end) {
  return samples.filter((s) => s.t >= start && s.t < end);
}

const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
const values = (samples, key) => samples.map((s) => s[key]).filter(Number.isFinite);

function awakeSamples(samples, day) {
  const start = new Date(day); start.setHours(7, 0, 0, 0);
  const end = new Date(day); end.setHours(23, 0, 0, 0);
  return samplesBetween(samples, start, end);
}

// Awake resting baseline: 10th percentile of the day's heart rate between 7am and 11pm.
export function dayBaseline(samples, day) {
  return percentile(values(awakeSamples(samples, day), 'bpm').sort((a, b) => a - b), 0.1);
}

export function minuteStress(bpm, baseline) {
  return Math.max(0, Math.min(3, (3 * (bpm - baseline)) / baseline / STRESS_FULL_SCALE));
}

export function scoreEvent(event, samples, day) {
  const during = samplesBetween(samples, event.start, event.end);
  const afterEnd = new Date(event.end.getTime() + CARRYOVER_MIN * 60000);
  const after = values(samplesBetween(samples, event.end, afterEnd), 'bpm');
  const bpm = values(during, 'bpm');
  const active = isActiveEvent(event);

  if (!bpm.length || !Number.isFinite(day.baseline)) {
    return { ...event, active, hasData: false, metrics: {} };
  }

  const metrics = {};
  for (const [id, m] of Object.entries(METRICS)) {
    const xs = values(during, m.key);
    if (!xs.length) continue;
    const value = mean(xs);
    const fraction = Math.max(0, Math.min(1, m.fraction(value, day)));
    metrics[id] = { value, peak: Math.max(...xs), fraction };
  }

  const avg = mean(bpm);
  return {
    ...event,
    active,
    hasData: true,
    metrics,
    avgHr: avg,
    peakHr: Math.max(...bpm),
    baselineHr: day.baseline,
    deltaPct: (avg - day.baseline) / day.baseline,
    carryoverPct: after.length ? (mean(after) - day.baseline) / day.baseline : null,
    stress: metrics.stress.value,
  };
}

export function scoreDay(events, samples, dayStart) {
  const daySamples = samplesBetween(samples, startOfDay(dayStart), endOfDay(dayStart));
  const day = { baseline: dayBaseline(daySamples, dayStart) };
  // Fill in minute-level stress where the source didn't provide it.
  if (Number.isFinite(day.baseline)) {
    for (const s of daySamples) {
      if (!Number.isFinite(s.stress)) s.stress = minuteStress(s.bpm, day.baseline);
    }
  }
  return { ...day, events: events.map((e) => scoreEvent(e, daySamples, day)) };
}

// ---- Unscheduled time ----
// Calendar events take priority. Each stretch of free time between them, within the waking
// day (wake time rounded down to the hour → usual bedtime rounded up to the hour, at most
// 11:59pm), becomes one
// unscheduled block whose scores average over the whole stretch. Gaps under 15 minutes are skipped.

const MIN_GAP = 15 * 60000;

// Local-time rounding to the hour.
function floorHour(d) { const x = new Date(d); x.setMinutes(0, 0, 0); return x; }
function ceilHour(d) { const x = floorHour(d); if (x < d) x.setHours(x.getHours() + 1); return x; }

export function buildBlocks(events, { wake, bedtime, until = null }) {
  const dayStart = floorHour(wake);
  // Stop at 11:59pm so a block never ends on the next date (time pickers can't express that).
  const lastMinute = new Date(wake); lastMinute.setHours(23, 59, 0, 0);
  let dayEnd = new Date(Math.min(ceilHour(bedtime), lastMinute));
  if (until && until < dayEnd) dayEnd = until;
  if (dayEnd <= dayStart) return [];

  const busy = events
    .map((e) => [e.start, e.end])
    .filter(([s, e]) => e > dayStart && s < dayEnd)
    .sort((a, b) => a[0] - b[0]);

  const blocks = [];
  const add = (start, end) => {
    if (end - start >= MIN_GAP) {
      blocks.push({ id: `block-${start.toISOString()}`, title: '', start, end, block: true, active: false });
    }
  };
  let cursor = dayStart;
  for (const [s, e] of busy) {
    if (s > cursor) add(cursor, s);
    if (e > cursor) cursor = e;
  }
  if (cursor < dayEnd) add(cursor, dayEnd);
  return blocks;
}

// Usual bedtime as minutes after midnight (median across nights). Bedtimes after midnight
// count as the end of the day, since blocks don't cross into the next date.
export function typicalBedMinutes(sleepByDate) {
  const mins = Object.values(sleepByDate)
    .map(({ bed }) => bed.getHours() * 60 + bed.getMinutes())
    .map((m) => (m < 4 * 60 ? 24 * 60 : m))
    .sort((a, b) => a - b);
  return mins.length ? mins[Math.floor(mins.length / 2)] : null;
}

export function startOfDay(d) { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; }
export function endOfDay(d) { const x = startOfDay(d); x.setDate(x.getDate() + 1); return x; }

export function localDate(d) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export const CSV_COLUMNS = [
  'event_id', 'date', 'start', 'end', 'start_hour', 'weekday', 'title', 'duration_min', 'attendees', 'recurring',
  'active', 'avg_hr', 'peak_hr', 'baseline_hr', 'delta_pct', 'carryover_pct',
  'stress', 'feeling',
];

// feelings: { [eventId]: -2..2 } — the self-reported happiness label.
export function toCsvRows(scoredEvents, feelings = {}) {
  const fmt = (v, d = 3) => (v == null || Number.isNaN(v) ? '' : typeof v === 'number' ? v.toFixed(d) : v);
  const esc = (s) => `"${String(s).replace(/"/g, '""')}"`;
  return scoredEvents
    .filter((e) => e.hasData && !e.block)
    .map((e) => [
      esc(e.id),
      localDate(e.start),
      e.start.toISOString(),
      e.end.toISOString(),
      (e.start.getHours() + e.start.getMinutes() / 60).toFixed(2),
      e.start.getDay(),
      esc(e.title),
      Math.round((e.end - e.start) / 60000),
      e.attendees ?? 0,
      e.recurring ? 1 : 0,
      e.active ? 1 : 0,
      fmt(e.avgHr, 1),
      fmt(e.peakHr, 0),
      fmt(e.baselineHr, 1),
      fmt(e.deltaPct),
      fmt(e.carryoverPct),
      fmt(e.stress),
      feelings[e.id] ?? '',
    ].join(','));
}
