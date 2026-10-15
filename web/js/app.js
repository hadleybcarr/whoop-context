import { generateDemo, generateWhoopDemo } from './demo.js';
import { scoreDay, scoreEvent, localDate, METRICS, buildBlocks, typicalBedMinutes } from './scoring.js';
import { calendarConfigured, calendarConnected, connectCalendar, createEvent, fetchEvents, fetchIcsEvents, setGoogleClientId, updateEvent } from './calendar.js';
import { whoopStatus, connectWhoop, disconnectWhoop, fetchWhoop, saveWhoopKeys } from './whoop.js';

const HISTORY_DAYS = 21;
// How far ahead the date picker goes, for planned events.
const FUTURE_DAYS = 14;
const FEELINGS_KEY = 'final-thread:feelings';
const METRIC_KEY = 'final-thread:metric';
const CUSTOM_KEY = 'final-thread:custom-events';
const SAMPLE_WHOOP_KEY = 'final-thread:sample-whoop';
// Changes made here to calendar events: { [eventId]: { title, start, end } }, reapplied on every load.
const EDITS_KEY = 'final-thread:event-edits';
// A Google Calendar's private iCal address, when connected that way. Stays in this browser.
const ICAL_KEY = 'final-thread:ical-url';
// Used when there's no WHOOP sleep data for a day.
const DEFAULT_WAKE_MIN = 7 * 60;
const DEFAULT_BED_MIN = 23 * 60;

const FEELINGS = [
  { value: -2, label: 'DRAINED', color: 'var(--recovery-red)' },
  { value: -1, label: 'TENSE', color: 'var(--recovery-yellow)' },
  { value: 0, label: 'NEUTRAL', color: 'var(--muted)' },
  { value: 1, label: 'GOOD', color: '#8af27f' },
  { value: 2, label: 'GREAT', color: 'var(--recovery-green)' },
];

// WHOOP Stress Monitor bands.
const LEVELS = [
  { max: 1, label: 'LOW', color: 'var(--stress-low)' },
  { max: 2, label: 'MEDIUM', color: 'var(--stress-medium)' },
  { max: Infinity, label: 'HIGH', color: 'var(--stress-high)' },
];
// Bands use the value as displayed (one decimal), so "1.0" never reads as LOW.
const levelFor = (v) => LEVELS.find((l) => Math.round(v * 10) / 10 < l.max);

const $ = (id) => document.getElementById(id);

const today = new Date();
today.setHours(0, 0, 0, 0);

const demoEnd = new Date(today);
demoEnd.setDate(demoEnd.getDate() + FUTURE_DAYS);
const demo = generateDemo({ endDay: demoEnd, days: HISTORY_DAYS + FUTURE_DAYS });

const state = {
  events: demo.events,
  customEvents: loadCustomEvents(),
  samples: demo.samples,
  sleep: demo.sleep,
  feelings: { ...demo.feelings, ...loadFeelings() },
  calendarSource: 'Demo calendar',
  hrSource: 'demo heart rate',
  dayOffset: 0,
  metric: loadPref(METRIC_KEY, 'stress'),
  scored: [],
  insights: null,
  // Set once a private iCal address has actually loaded events; until then it's only saved.
  icalUrl: null,
  icalLoading: false,
  edits: loadEdits(),
  // WHOOP: workouts become events; daily holds recovery and strain by local date.
  // sample: showing generated WHOOP data alongside the demo calendar.
  // backend: true / false (no server) / null (not reached yet; see whoopStatus).
  whoop: { backend: null, configured: false, connected: false, sample: false },
  workouts: [],
  daily: {},
};

function loadFeelings() {
  try { return JSON.parse(localStorage.getItem(FEELINGS_KEY)) ?? {}; } catch { return {}; }
}

// Events added from unscheduled blocks (and not sent to Google Calendar) live here.
function loadCustomEvents() {
  try {
    return (JSON.parse(localStorage.getItem(CUSTOM_KEY)) ?? [])
      .map((e) => ({ ...e, start: new Date(e.start), end: new Date(e.end) }));
  } catch { return []; }
}

function saveCustomEvents() {
  try { localStorage.setItem(CUSTOM_KEY, JSON.stringify(state.customEvents)); } catch { /* storage unavailable */ }
}

function loadPref(key, fallback) {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}

function savePref(key, value) {
  try { localStorage.setItem(key, value); } catch { /* storage unavailable */ }
}

function loadEdits() {
  try { return JSON.parse(localStorage.getItem(EDITS_KEY)) ?? {}; } catch { return {}; }
}

function saveEdits() {
  try { localStorage.setItem(EDITS_KEY, JSON.stringify(state.edits)); } catch { /* storage unavailable */ }
}

// An event with this device's changes on top. `original` keeps the calendar's version for resetting.
function withEdits(e) {
  const ed = state.edits[e.id];
  if (!ed) return e;
  return {
    ...e,
    title: ed.title ?? e.title,
    start: ed.start ? new Date(ed.start) : e.start,
    end: ed.end ? new Date(ed.end) : e.end,
    original: { title: e.title, start: e.start, end: e.end },
  };
}

function saveFeelings() {
  try { localStorage.setItem(FEELINGS_KEY, JSON.stringify(state.feelings)); } catch { /* storage unavailable */ }
}

// ---- Scoring ----

function atMinutes(day, minutes) {
  const d = new Date(day);
  d.setHours(0, minutes, 0, 0);
  return d;
}

// Scores calendar events plus the unscheduled blocks between them, from wake-up to usual bedtime.
// Days ahead (negative i) only list their planned events: there's no free time to name yet.
function rescore() {
  const all = [...state.events, ...state.customEvents].map(withEdits).concat(state.workouts);
  const bedMin = typicalBedMinutes(state.sleep) ?? DEFAULT_BED_MIN;
  const now = new Date();
  state.scored = [];
  for (let i = -FUTURE_DAYS; i < HISTORY_DAYS; i++) {
    const day = new Date(today);
    day.setDate(day.getDate() - i);
    const key = localDate(day);
    const events = all.filter((e) => localDate(e.start) === key);
    const blocks = i < 0 ? [] : buildBlocks(events, {
      wake: state.sleep[key]?.wake ?? atMinutes(day, DEFAULT_WAKE_MIN),
      bedtime: atMinutes(day, bedMin),
      until: i === 0 ? now : null,
    });
    state.scored.push(...scoreDay([...events, ...blocks], state.samples, day).events);
  }
  state.scored.sort((a, b) => a.start - b.start || Number(!!a.block) - Number(!!b.block));
}

function currentDay() {
  const d = new Date(today);
  d.setDate(d.getDate() - state.dayOffset);
  return d;
}

function dayItems() {
  const key = localDate(currentDay());
  return state.scored.filter((e) => localDate(e.start) === key);
}

// Minutes in each stress band on `day`. Each reading counts until the next one, up to 5 minutes.
function stressBreakdown(day) {
  const start = new Date(day);
  const end = new Date(day); end.setDate(end.getDate() + 1);
  const xs = state.samples.filter((s) => s.t >= start && s.t < end && Number.isFinite(s.stress));
  const out = { low: 0, medium: 0, high: 0 };
  for (let i = 0; i < xs.length - 1; i++) {
    const minutes = Math.min(xs[i + 1].t - xs[i].t, 300000) / 60000;
    out[levelFor(xs[i].stress).label.toLowerCase()] += minutes;
  }
  out.total = out.low + out.medium + out.high;
  return out;
}

// Average breakdown over the other days in history on the same weekday.
function typicalBreakdown(day) {
  const others = [];
  for (let i = 1; i < HISTORY_DAYS; i++) {
    const d = new Date(today); d.setDate(d.getDate() - i);
    if (d.getDay() === day.getDay() && d.getTime() !== day.getTime()) {
      const b = stressBreakdown(d);
      if (b.total > 0) others.push(b);
    }
  }
  if (!others.length) return null;
  const avg = (k) => others.reduce((a, b) => a + b[k], 0) / others.length;
  const out = { low: avg('low'), medium: avg('medium'), high: avg('high') };
  out.total = out.low + out.medium + out.high;
  return out;
}

// ---- Formatting ----

const timeFmt = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });
const hourFmt = new Intl.DateTimeFormat(undefined, { hour: 'numeric' });
const dayFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
const weekdayFmt = new Intl.DateTimeFormat(undefined, { weekday: 'long' });

function dayLabel() {
  if (state.dayOffset === 0) return 'TODAY';
  if (state.dayOffset === 1) return 'YESTERDAY';
  if (state.dayOffset === -1) return 'TOMORROW';
  return dayFmt.format(currentDay()).toUpperCase();
}

const rangeLabel = (e) => `${timeFmt.format(e.start)} – ${timeFmt.format(e.end)}`;
const durationLabel = (e) => {
  const min = Math.round((e.end - e.start) / 60000);
  return min < 60 ? `${min}m` : `${Math.floor(min / 60)}h${min % 60 ? ` ${min % 60}m` : ''}`;
};
const hoursMinutes = (minutes) => `${Math.floor(Math.round(minutes) / 60)}:${String(Math.round(minutes) % 60).padStart(2, '0')}`;
const hhmm = (d) => `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
const pct = (v) => `${v >= 0 ? '+' : ''}${Math.round(v * 100)}%`;
const feelingFor = (v) => FEELINGS.find((f) => f.value === v);
const icon = (name, cls = 'row-icon') => `<svg class="${cls}"><use href="#i-${name}"/></svg>`;

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ---- Components ----

// Stress Monitor gauge: thin 240° arc, blue → green → yellow → orange, with a tick at the value.
function gaugeHtml(value, caption, { info = false } = {}) {
  const cx = 120, cy = 120, r = 104;
  const pt = (deg, radius = r) => {
    const a = (deg * Math.PI) / 180;
    return [cx + radius * Math.cos(a), cy + radius * Math.sin(a)];
  };
  const [sx, sy] = pt(150), [ex, ey] = pt(30);
  const arc = `M${sx.toFixed(1)} ${sy.toFixed(1)} A${r} ${r} 0 1 1 ${ex.toFixed(1)} ${ey.toFixed(1)}`;
  const level = value == null ? null : levelFor(value);
  let tick = '';
  if (value != null) {
    const deg = 150 + 240 * Math.max(0, Math.min(1, value / 3));
    const [x1, y1] = pt(deg, r - 11), [x2, y2] = pt(deg, r + 11);
    tick = `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="#fff" stroke-width="3.5" stroke-linecap="round"/>`;
  }
  return `
    <div class="gauge-wrap">
      <div class="gauge" role="img" aria-label="Stress ${value == null ? 'no data' : `${value.toFixed(1)}, ${level.label.toLowerCase()}`}">
        <svg viewBox="0 0 240 240" aria-hidden="true">
          <defs>
            <linearGradient id="gauge-grad" x1="0" y1="0" x2="1" y2="0">
              <stop offset="0" stop-color="var(--stress-low)"/>
              <stop offset="0.38" stop-color="var(--stress-medium)"/>
              <stop offset="0.75" stop-color="var(--recovery-yellow)"/>
              <stop offset="1" stop-color="var(--stress-high)"/>
            </linearGradient>
          </defs>
          <path d="${arc}" fill="none" stroke="var(--gauge-track)" stroke-width="10" stroke-linecap="round"/>
          <path d="${arc}" fill="none" stroke="url(#gauge-grad)" stroke-width="5" stroke-linecap="round" opacity="${value == null ? 0.3 : 1}"/>
          ${tick}
        </svg>
        <div class="gauge-center">
          <div class="big-number">${value == null ? '--' : value.toFixed(1)}</div>
          <div class="level" style="color:${level?.color ?? 'var(--muted)'}">${level?.label ?? 'NO DATA'}</div>
          <div class="gauge-caption">${escapeHtml(caption)}</div>
        </div>
        <div class="gauge-ends"><span>0.0</span><span>3.0</span></div>
        ${info ? `<button class="icon-btn gauge-info" data-open-info aria-label="How stress is scored"><svg><use href="#i-info"/></svg></button>` : ''}
      </div>
    </div>`;
}

// Line chart in WHOOP Stress Monitor style. bands: spans to shade; overlay: highlighted span.
// free: unscheduled stretches (dashed purple); extent: the whole stretch behind a partial overlay.
function lineChartHtml({ from, to, metricId, baseline, bands = [], free = [], extent = null, overlay = null, labels, now = null, id, key = false }) {
  const metric = METRICS[metricId];
  const pts = state.samples.filter((s) => s.t >= from && s.t <= to && Number.isFinite(s[metric.key]));
  if (pts.length < 2) return '';

  const W = 340, H = 150, left = 26;
  let lo, hi, ticks;
  if (metricId === 'stress') {
    lo = 0; hi = 3; ticks = [0, 1, 2, 3];
  } else {
    const vals = pts.map((p) => p[metric.key]).concat(baseline ?? []);
    lo = Math.floor((Math.min(...vals) - 4) / 10) * 10;
    hi = Math.ceil((Math.max(...vals) + 4) / 10) * 10;
    ticks = [];
    for (let v = lo; v <= hi; v += 10) ticks.push(v);
  }
  const x = (t) => left + ((t - from) / (to - from)) * (W - left);
  const y = (v) => 6 + (1 - (v - lo) / (hi - lo)) * (H - 12);
  const path = pts.map((p, i) => `${i ? 'L' : 'M'}${x(p.t).toFixed(1)},${y(p[metric.key]).toFixed(1)}`).join('');
  const stroke = metricId === 'stress' ? `url(#${id}-line)` : '#fff';
  const last = pts[pts.length - 1];

  return `
    <div class="chart">
      <svg viewBox="0 0 ${W} ${H + 22}" role="img" aria-label="${metric.label} from ${timeFmt.format(from)} to ${timeFmt.format(to)}"
           data-from="${from.getTime()}" data-to="${to.getTime()}" data-left="${left}" data-w="${W}">
        <defs>
          <linearGradient id="${id}-line" gradientUnits="userSpaceOnUse" x1="0" y1="${y(0)}" x2="0" y2="${y(3)}">
            <stop offset="0" stop-color="var(--stress-low)"/>
            <stop offset="0.4" stop-color="var(--stress-medium)"/>
            <stop offset="0.7" stop-color="var(--recovery-yellow)"/>
            <stop offset="1" stop-color="var(--stress-high)"/>
          </linearGradient>
        </defs>
        ${ticks.map((v) => `
          <line x1="${left}" x2="${W}" y1="${y(v)}" y2="${y(v)}" stroke="rgba(255,255,255,0.08)"/>
          <text x="0" y="${y(v) + 3}" fill="var(--muted)" font-size="9" font-weight="600">${metricId === 'stress' ? v.toFixed(1) : v}</text>`).join('')}
        ${bands.filter((b) => b.start < to && b.end > from).map((b) => {
          const bx = x(new Date(Math.max(b.start, from))), bw = x(new Date(Math.min(b.end, to))) - bx;
          return `<rect x="${bx}" y="6" width="${Math.max(2, bw)}" height="${H - 12}" fill="var(--band)"/>`;
        }).join('')}
        ${[...free, ...(extent ? [extent] : [])].filter((b) => b.start < to && b.end > from).map((b) => {
          const bx = x(new Date(Math.max(b.start, from))), bw = x(new Date(Math.min(b.end, to))) - bx;
          return `<rect class="chart-free" x="${bx + 0.5}" y="6.5" width="${Math.max(1, bw - 1)}" height="${H - 13}" rx="4"/>`;
        }).join('')}
        ${overlay ? `<rect class="chart-overlay" x="${x(overlay.start)}" y="6" width="${x(overlay.end) - x(overlay.start)}" height="${H - 12}" rx="5"/>` : ''}
        ${baseline != null && metricId === 'hr' ? `<line x1="${left}" x2="${W}" y1="${y(baseline)}" y2="${y(baseline)}" stroke="var(--muted)" stroke-dasharray="4 5" stroke-width="1.2"/>` : ''}
        <path d="${path}" fill="none" stroke="${stroke}" stroke-width="1.8" stroke-linejoin="round"/>
        ${now ? `
          <line x1="${x(now)}" x2="${x(now)}" y1="0" y2="${H}" stroke="#fff" stroke-dasharray="2 3" opacity="0.7"/>
          <circle cx="${x(last.t)}" cy="${y(last[metric.key])}" r="4" fill="${metricId === 'stress' ? levelFor(last.stress).color : '#fff'}"/>` : ''}
        ${labels.map((t, i) => `<text x="${x(t)}" y="${H + 16}" fill="${i === labels.length - 1 ? '#fff' : 'var(--muted)'}" font-size="9" font-weight="600" text-anchor="${i === 0 ? 'start' : i === labels.length - 1 ? 'end' : 'middle'}"${overlay && i === 0 ? ' class="ax-start"' : ''}${overlay && i === labels.length - 2 ? ' class="ov-start"' : ''}${overlay && i === labels.length - 1 ? ' class="ov-end"' : ''}>${timeFmt.format(t)}</text>`).join('')}
      </svg>
      ${key ? `<div class="chart-key"><span><i class="key-event"></i>Calendar event</span><span><i class="key-free"></i>Unscheduled</span></div>` : ''}
    </div>`;
}

// Moves a chart's highlighted span to [start, end] with a soft spring (slight overshoot).
// Interrupting mid-flight keeps the current velocity, so quick changes stay fluid.
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

function springOverlay(svg, start, end, { from: initial } = {}) {
  const rect = svg?.querySelector('.chart-overlay');
  if (!rect) return;
  const { from, to, left, w } = Object.fromEntries(Object.entries(svg.dataset).map(([k, v]) => [k, Number(v)]));
  const px = (t) => left + ((t - from) / (to - from)) * (w - left);
  const target = [px(start), px(end)];
  const labels = [svg.querySelector('.ov-start'), svg.querySelector('.ov-end')];
  const axisStart = svg.querySelector('.ax-start');
  labels[0] && (labels[0].textContent = timeFmt.format(start));
  labels[1] && (labels[1].textContent = timeFmt.format(end));

  const st = rect._spring ??= { pos: initial ?? target.slice(), vel: [0, 0], raf: 0 };
  if (initial) st.pos = initial.slice();
  st.target = target;
  const paint = () => {
    const [a, b] = st.pos;
    rect.setAttribute('x', Math.min(a, b));
    rect.setAttribute('width', Math.max(0, Math.abs(b - a)));
    labels[0]?.setAttribute('x', a);
    labels[1]?.setAttribute('x', b);
    // Don't let the moving start time sit on top of the chart's first time label.
    axisStart?.setAttribute('opacity', a - left < 64 ? 0 : 1);
  };
  // No animation frames run in a hidden tab, so jump straight there.
  if (reduceMotion.matches || document.hidden) { st.pos = target.slice(); st.vel = [0, 0]; paint(); return; }

  cancelAnimationFrame(st.raf);
  const stiffness = 320, damping = 24; // damping ratio ≈ 0.67: one small, quick bounce
  let last = performance.now();
  const step = (now) => {
    const dt = Math.min(0.032, (now - last) / 1000);
    last = now;
    let moving = false;
    for (let i = 0; i < 2; i++) {
      const force = -stiffness * (st.pos[i] - st.target[i]) - damping * st.vel[i];
      st.vel[i] += force * dt;
      st.pos[i] += st.vel[i] * dt;
      if (Math.abs(st.pos[i] - st.target[i]) > 0.05 || Math.abs(st.vel[i]) > 0.05) moving = true;
    }
    if (!moving) { st.pos = st.target.slice(); st.vel = [0, 0]; }
    paint();
    if (moving) st.raf = requestAnimationFrame(step);
  };
  st.raf = requestAnimationFrame(step);
}

function insightBox(title, text, link) {
  return `
    <div class="insight-box">
      ${title ? `<div class="insight-title"><span class="w-badge"><svg><use href="#w-mark"/></svg></span>${escapeHtml(title)}</div>` : ''}
      <p>${escapeHtml(text)}</p>
      ${link ? `<button class="link" data-open-coach>${escapeHtml(link)}<svg><use href="#i-arrow"/></svg></button>` : ''}
    </div>`;
}

// One grouped card of statistic rows, WHOOP-style. rows: { icon, label, value, unit?, trend?, metric? }
function statGroupHtml(rows, foot) {
  return `
    <div class="stat-group">
      ${rows.map((r) => {
        const tag = r.metric ? 'button' : 'div';
        return `
          <${tag} class="group-row${r.metric && r.metric === state.metric ? ' selected' : ''}" ${r.metric ? `data-metric="${r.metric}"` : ''}>
            ${icon(r.icon)}
            <span class="row-label">${r.label}</span>
            <span class="row-num">${r.value}</span>${r.unit ? `<span class="row-unit">${r.unit}</span>` : ''}
            ${r.trend ? `<i class="tri ${r.trend}" aria-label="${r.trend === 'up' ? 'higher' : r.trend === 'down' ? 'lower' : 'about the same'}"></i>` : ''}
          </${tag}>`;
      }).join('')}
      ${foot ? `<div class="group-foot"><span class="tri-pair"><i class="tri up"></i><i class="tri down"></i></span>${escapeHtml(foot)}</div>` : ''}
    </div>`;
}

const trend = (v, eps = 0.03) => (v > eps ? 'up' : v < -eps ? 'down' : 'flat');

// fraction: 0..1 → bar length; score: text shown in the knob.
// stress: colors the bar by its low / medium / high band (left purple when absent, e.g. workouts).
// block: an unscheduled stretch of time, offered for naming as an event.
// expand: HTML for a drop-down shown under the row when it's tapped.
function threadHtml({ id, name, meta, fraction, score, noData, feeling, block, expand, stress }) {
  const width = noData ? 14 : 18 + Math.max(0, Math.min(1, fraction)) * 52;
  const color = !noData && stress != null ? `;--bar:${levelFor(stress).color}` : '';
  const dot = feeling != null ? `<i class="thread-feel" style="background:${feelingFor(feeling).color}"></i>` : '';
  const classes = ['thread', noData && 'no-data', block && 'block', expand && 'name-left'].filter(Boolean).join(' ');
  return `
    <li>
      <button class="${classes}" ${id ? `data-id="${escapeHtml(id)}"` : expand ? 'data-toggle aria-expanded="false"' : 'tabindex="-1"'}
              aria-label="${block ? 'Unscheduled' : escapeHtml(name)}${meta ? `, ${escapeHtml(meta)}` : ''}${block ? ', add an event' : ''}">
        <span class="thread-bar${color ? ' leveled' : ''}" style="width:${width}%${color}"><span class="thread-knob">${escapeHtml(score ?? '')}</span></span>
        <span class="thread-name">${block ? '<span class="add-icon"><svg><use href="#i-plus"/></svg></span>Unscheduled' : escapeHtml(name)}</span>
        <span class="thread-time">${escapeHtml(meta ?? '')}${dot}${expand ? '<svg class="chev"><use href="#i-chevron-down"/></svg>' : ''}</span>
      </button>
      ${expand ? `<div class="occ"><div class="occ-inner">${expand}</div></div>` : ''}
    </li>`;
}

// ---- Timeline ----

function renderTimeline() {
  const items = dayItems();
  const stressItems = items.filter((e) => e.hasData && !e.active);
  const avgStress = stressItems.length ? stressItems.reduce((a, e) => a + e.stress, 0) / stressItems.length : null;
  const now = new Date();
  const isToday = state.dayOffset === 0;
  const isFuture = state.dayOffset < 0;

  $('date-label').textContent = dayLabel();
  $('next-day').disabled = state.dayOffset <= -FUTURE_DAYS;
  $('prev-day').disabled = state.dayOffset >= HISTORY_DAYS - 1;
  $('threads-title').textContent = isToday ? "TODAY'S THREADS" : isFuture ? 'PLANNED' : 'THREADS';

  $('gauge-slot').innerHTML = gaugeHtml(avgStress, isToday ? `Last updated ${timeFmt.format(now)}` : isFuture ? 'Not happened yet' : 'Day average', { info: true });
  $('whoop-day-slot').innerHTML = whoopDayHtml(currentDay());

  // The day's stress line, with calendar events shaded like WHOOP's activity bands.
  if (items.length) {
    const from = items[0].start;
    const to = isToday ? now : items[items.length - 1].end;
    const mid = new Date((from.getTime() + to.getTime()) / 2);
    $('day-chart-slot').innerHTML = lineChartHtml({
      from, to, metricId: state.metric, id: 'day',
      baseline: items.find((e) => e.hasData)?.baselineHr,
      bands: items.filter((e) => !e.block),
      free: items.filter((e) => e.block),
      key: true,
      labels: [from, mid, to],
      now: isToday ? now : null,
    });
  } else {
    $('day-chart-slot').innerHTML = '';
  }

  const peak = stressItems.reduce((best, e) => (!best || e.stress > best.stress ? e : best), null);
  const calm = stressItems.reduce((best, e) => (!best || e.stress < best.stress ? e : best), null);
  $('day-insight').innerHTML = peak
    ? insightBox(null,
      `${peak.block ? `Unscheduled time at ${timeFmt.format(peak.start)}` : peak.title} was the most stressful part of your day at ${peak.stress.toFixed(1)}, with heart rate ${pct(peak.deltaPct)} vs. your baseline. Your calmest stretch was ${calm.block ? rangeLabel(calm) : calm.title} (${calm.stress.toFixed(1)}).`,
      'Explore insights')
    : isFuture ? insightBox(null, items.length
      ? `${items.length} event${items.length === 1 ? '' : 's'} planned. Each one is scored once it happens.`
      : 'Nothing planned yet.')
    : insightBox(null, state.whoop.connected && !state.samples.length
      ? "Event stress needs minute-by-minute heart rate, which WHOOP's API doesn't share, so events aren't scored yet."
      : 'Scores appear once WHOOP has heart-rate data for this day.');

  const metric = METRICS[state.metric];
  const rows = items.map((e) => {
    const m = e.metrics[state.metric];
    return threadHtml({
      id: e.id,
      name: e.title,
      block: e.block,
      meta: `${e.block ? `${timeFmt.format(e.start)} · ${durationLabel(e)}` : timeFmt.format(e.start)}${e.hasData ? '' : e.whoop ? ` · strain ${e.whoop.strain.toFixed(1)}` : e.start > now ? ' · upcoming' : ' · no data'}`,
      fraction: m?.fraction ?? 0,
      score: m ? metric.format(m.value) : '',
      noData: !m,
      feeling: state.feelings[e.id],
      stress: e.hasData && !e.active ? e.stress : null,
    });
  });
  if (isToday) {
    const i = items.findIndex((e) => e.start > now);
    rows.splice(i < 0 ? rows.length : i, 0, `
      <li class="now-marker" aria-label="Current time">
        <span class="now-pill">NOW · ${timeFmt.format(now)}</span>
      </li>`);
  }
  $('threads').innerHTML = rows.join('');
  $('timeline-empty').hidden = items.length > 0;
  $('timeline-empty').textContent = 'Nothing on this day yet.';
  $('plus-btn').hidden = !latestBlock();

  $('breakdown-slot').innerHTML = breakdownHtml(currentDay());
}

// Longest unbroken run of high-stress readings on `day` (gaps over 5 minutes end a run).
// Workouts are skipped: a high heart rate there is effort, not stress.
function longestHighStretch(day) {
  const start = new Date(day);
  const end = new Date(day); end.setDate(end.getDate() + 1);
  const workouts = state.scored.filter((e) => e.active && e.start < end && e.end > start);
  const xs = state.samples.filter((s) => s.t >= start && s.t < end && Number.isFinite(s.stress)
    && !workouts.some((w) => s.t >= w.start && s.t < w.end));
  let best = null, run = null;
  for (let i = 0; i < xs.length; i++) {
    const high = levelFor(xs[i].stress).label === 'HIGH';
    const joined = run && xs[i].t - xs[i - 1].t <= 300000;
    if (high && joined) run.end = xs[i].t;
    else if (high) run = { start: xs[i].t, end: xs[i].t };
    else run = null;
    if (run && (!best || run.end - run.start > best.end - best.start)) best = { ...run };
  }
  return best && { start: best.start, minutes: Math.max(1, Math.round((best.end - best.start) / 60000) + 2) };
}

// One-line summary under Total Day, in the style of WHOOP's Stress Monitor.
function totalDayInsight(day, b, typical) {
  const main = ['low', 'medium', 'high'].reduce((a, k) => (b[k] > b[a] ? k : a), 'low');
  const parts = [`Most of your time was spent in the ${main} stress zone.`];
  // Only call out sustained stress; a reading or two above the line isn't a stretch.
  const run = longestHighStretch(day);
  parts.push(run && run.minutes >= 10
    ? `Your longest stretch of high stress started at ${timeFmt.format(run.start)} and lasted ${run.minutes} minutes.`
    : 'You had no sustained stretches of high stress.');
  if (typical?.high) {
    const change = (b.high - typical.high) / typical.high;
    if (Math.abs(change) >= 0.05) {
      parts.push(`That's ${Math.round(Math.abs(change) * 100)}% ${change > 0 ? 'more' : 'less'} high stress than a typical ${weekdayFmt.format(day)}.`);
    }
  }
  return parts.join(' ');
}

// The day's WHOOP numbers: that morning's recovery and the day's strain.
function whoopDayHtml(day) {
  const d = state.daily[localDate(day)];
  if (!d) return '';
  const rows = [];
  if (d.recovery != null) {
    rows.push({ icon: 'pulse', label: 'Recovery', value: `${Math.round(d.recovery)}%` });
    rows.push({ icon: 'trend', label: 'HRV', value: Math.round(d.hrv), unit: 'ms' });
    rows.push({ icon: 'heart', label: 'Resting heart rate', value: Math.round(d.rhr), unit: 'bpm' });
  }
  if (d.strain != null) rows.push({ icon: 'peak', label: 'Day strain', value: d.strain.toFixed(1) });
  return rows.length ? `<div class="whoop-day"><div class="section-label">FROM WHOOP</div>${statGroupHtml(rows)}</div>` : '';
}

function breakdownHtml(day) {
  const b = stressBreakdown(day);
  if (!b.total) return '';
  const typical = typicalBreakdown(day);
  const bar = (x, h, cls = '') => `
    <div class="bar ${cls}" style="height:${h}px">
      <i style="flex:${x.low};background:var(--stress-low)"></i>
      <i style="flex:${x.medium};background:var(--stress-medium)"></i>
      <i style="flex:${x.high};background:var(--stress-high)"></i>
    </div>`;
  const col = (key, level) => {
    const t = typical?.[key];
    const change = t ? (b[key] - t) / t : null;
    return `
      <div>
        <div class="num">${hoursMinutes(b[key])}<small>hrs</small></div>
        ${change != null ? `<div class="change">${change >= 0 ? '▲' : '▼'} ${Math.round(Math.abs(change) * 100)}%</div>` : ''}
        <div class="level" style="color:${level.color}">${level.label}</div>
      </div>`;
  };
  return `
    <div class="card">
      <div class="card-title">${icon('day', '')}TOTAL DAY</div>
      <div class="breakdown-head">${dayFmt.format(day).toUpperCase()}${typical ? ` <span>VS. TYPICAL ${weekdayFmt.format(day).toUpperCase()}</span>` : ''}</div>
      <p class="card-insight">${escapeHtml(totalDayInsight(day, b, typical))}</p>
      <div class="bars">${bar(b, 9)}${typical ? bar(typical, 5, 'typical') : ''}</div>
      <div class="columns">${col('low', LEVELS[0])}${col('medium', LEVELS[1])}${col('high', LEVELS[2])}</div>
    </div>`;
}

const latestBlock = () => [...dayItems()].reverse().find((e) => e.block && e.hasData);

// ---- Detail sheet ----

// What's being typed into an unscheduled block's form, kept across re-renders of its sheet.
let draft = null;

// The part of the block the form currently describes, scored on its own (null if the times are invalid).
function scoreDraft(block) {
  if (!(draft.end > draft.start) || draft.start < block.start || draft.end > block.end) return null;
  const scored = scoreEvent({ ...block, id: 'draft', start: draft.start, end: draft.end }, state.samples, { baseline: block.baselineHr });
  return scored.hasData ? scored : null;
}

const whenHtml = (e, span) => `${dayFmt.format(e.start).toUpperCase()} · ${rangeLabel(span)}`;

// The gauge (stress) or big number (heart rate) for a span.
function figureHtml(span) {
  const m = span.metrics[state.metric];
  if (!m) return '';
  return state.metric === 'stress'
    ? gaugeHtml(m.value, durationLabel(span))
    : `<div class="hr-hero"><div class="big-number">${Math.round(m.value)}</div><div class="level" style="color:var(--muted)">AVG HEART RATE</div></div>`;
}

function detailBodyHtml(e, span) {
  const dayAvg = (() => {
    const xs = dayItems().filter((x) => x.hasData && !x.active);
    return xs.length ? xs.reduce((a, x) => a + x.stress, 0) / xs.length : span.stress;
  })();
  return statGroupHtml([
      { icon: 'pulse', label: 'Stress', value: span.stress.toFixed(1), trend: trend((span.stress - dayAvg) / 3, 0.02), metric: 'stress' },
      { icon: 'heart', label: 'Avg heart rate', value: Math.round(span.avgHr), unit: 'bpm', trend: trend(span.deltaPct), metric: 'hr' },
      { icon: 'peak', label: 'Peak heart rate', value: Math.round(span.peakHr), unit: 'bpm', trend: trend((span.peakHr - span.baselineHr) / span.baselineHr) },
      { icon: 'trend', label: 'Vs. baseline', value: pct(span.deltaPct), trend: trend(span.deltaPct) },
    ], `${e.block ? 'This stretch' : 'This event'} vs. your day and resting baseline`);
}

function detailChartHtml(e, span) {
  return lineChartHtml({
    from: new Date(e.start.getTime() - 3600000), to: new Date(e.end.getTime() + 3600000),
    metricId: state.metric, id: 'detail', baseline: e.baselineHr, overlay: span, extent: e.block ? e : null,
    labels: [new Date(e.start.getTime() - 3600000), span.start, span.end],
  });
}

function updateDraftView(block) {
  const scored = scoreDraft(block);
  const span = scored ?? block;
  $('when-slot').textContent = whenHtml(block, span);
  $('hero-slot').innerHTML = figureHtml(span);
  if ($('stats-slot')) $('stats-slot').innerHTML = detailBodyHtml(block, span);
  springOverlay($('chart-slot')?.querySelector('svg'), span.start, span.end);
  bindSheetControls(block);
}

function bindSheetControls(e) {
  $('sheet').querySelectorAll('[data-metric]').forEach((btn) => btn.addEventListener('click', () => {
    setMetric(btn.dataset.metric);
    openSheet(e.id);
  }));
}

function openSheet(id) {
  const e = state.scored.find((ev) => ev.id === id);
  if (!e) return;
  const feeling = state.feelings[e.id];
  if (e.block && draft?.blockId !== e.id) draft = { blockId: e.id, title: '', start: e.start, end: e.end };

  let body;
  if (!e.hasData && e.whoop) {
    body = `${statGroupHtml([
      { icon: 'heart', label: 'Avg heart rate', value: Math.round(e.whoop.avgHr), unit: 'bpm' },
      { icon: 'peak', label: 'Max heart rate', value: Math.round(e.whoop.maxHr), unit: 'bpm' },
      { icon: 'trend', label: 'Strain', value: e.whoop.strain.toFixed(1) },
    ], 'Workout totals from WHOOP')}
    ${insightBox('Physical activity', 'Your heart rate rose from effort, not stress, so workouts are left out of stress labels.')}`;
  } else if (!e.hasData) {
    body = insightBox(e.start > new Date() ? 'Coming up' : 'No data', e.start > new Date()
      ? "This hasn't happened yet. It will be scored once WHOOP has data for it."
      : `No heart-rate readings cover this time. Import data that overlaps ${dayFmt.format(e.start)} to score it.`);
  } else {
    let note = '';
    if (e.active) note = insightBox('Physical activity', 'Your heart rate rose from effort, not stress, so this is left out of stress labels.');
    else if (!e.block && e.carryoverPct != null && e.carryoverPct > 0.08) {
      note = insightBox('Lingering stress', `Your heart rate stayed ${pct(e.carryoverPct)} above baseline for 30 minutes after this ended.`);
    }
    body = `<div id="chart-slot">${detailChartHtml(e, e)}</div><div id="stats-slot">${detailBodyHtml(e, e)}</div>${note}`;
  }

  // Free time leads with the form for naming it; events end with how they felt.
  const footer = e.block ? '' : `
    <div class="section-label">HOW DID IT FEEL?</div>
    <div class="feel-row">
      ${FEELINGS.map((f) => `
        <button class="feel${feeling === f.value ? ' selected' : ''}" data-feel="${f.value}" style="${feeling === f.value ? `border-color:${f.color}` : ''}">
          <i style="background:${f.color}"></i>${f.label}
        </button>`).join('')}
    </div>
    ${similarHtml(e)}
    ${e.custom ? '<button class="text-btn" id="remove-event">Remove this event</button>' : ''}`;

  $('sheet').innerHTML = `
    <div class="nav-row">
      <button class="icon-btn" data-close aria-label="Back"><svg><use href="#i-back"/></svg></button>
      <h2 class="sheet-title">${state.metric === 'stress' ? 'STRESS MONITOR' : 'HEART RATE'}</h2>
      ${editable(e) ? '<button class="icon-btn" data-edit-event aria-label="Edit event"><svg><use href="#i-edit"/></svg></button>' : '<span></span>'}
    </div>
    <div class="hero"><h2 id="sheet-heading">${escapeHtml(e.block ? 'Unscheduled time' : e.title)}</h2><div class="when" id="when-slot">${whenHtml(e, e)}${e.original ? ' · EDITED' : ''}</div></div>
    ${e.block ? addEventForm(e) : ''}
    <div class="hero-meta" id="hero-slot">${figureHtml(e)}</div>
    ${body}
    ${footer}`;

  $('sheet').querySelector('[data-edit-event]')?.addEventListener('click', () => openEditSheet(e));
  $('add-form')?.addEventListener('submit', (ev) => onAddEvent(ev, e));
  $('add-form')?.addEventListener('input', (ev) => {
    const form = new FormData(ev.currentTarget);
    draft.title = form.get('title');
    draft.start = timeOnDay(e.start, form.get('start')) ?? draft.start;
    draft.end = timeOnDay(e.start, form.get('end')) ?? draft.end;
    $('add-submit').disabled = !draft.title.trim();
    updateDraftView(e);
  });
  if (e.block) updateDraftView(e);
  // The highlight opens out from its center.
  const svg = $('chart-slot')?.querySelector('svg');
  const span = e.block ? (scoreDraft(e) ?? e) : e;
  const rect = svg?.querySelector('.chart-overlay');
  if (rect) {
    const mid = Number(rect.getAttribute('x')) + Number(rect.getAttribute('width')) / 2;
    springOverlay(svg, span.start, span.end, { from: [mid, mid] });
  }
  $('remove-event')?.addEventListener('click', () => {
    state.customEvents = state.customEvents.filter((c) => c.id !== e.id);
    delete state.feelings[e.id];
    delete state.edits[e.id];
    saveCustomEvents();
    saveFeelings();
    saveEdits();
    closeSheets();
    refresh();
  });
  bindSheetControls(e);
  $('sheet').querySelectorAll('[data-feel]').forEach((btn) => btn.addEventListener('click', () => {
    const v = Number(btn.dataset.feel);
    if (state.feelings[e.id] === v) delete state.feelings[e.id];
    else state.feelings[e.id] = v;
    saveFeelings();
    renderTimeline();
    openSheet(e.id);
  }));
  showSheet('sheet');
}

// Words that don't make two titles "similar".
const STOP_WORDS = new Set(['with', 'the', 'and', 'for', 'from', 'to', 'of', 'a', 'an', 'at', 'on', 'in', 'my', 'our', 'call', 'meeting']);
const titleWords = (title) => new Set(title.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 2 && !STOP_WORDS.has(w)));

// Other events whose titles share a meaningful word with this one (same title included), newest first.
function similarEvents(e, limit = 30) {
  const words = titleWords(e.title);
  if (!words.size) return [];
  return state.scored
    .filter((x) => !x.block && x.hasData && x.id !== e.id && [...titleWords(x.title)].some((w) => words.has(w)))
    .sort((a, b) => b.start - a.start)
    .slice(0, limit);
}

// Summary row (count, average stress and mood) that expands to the list.
function similarHtml(e) {
  const xs = similarEvents(e);
  if (!xs.length) return '';
  const avgStress = xs.reduce((a, x) => a + x.stress, 0) / xs.length;
  const rated = xs.map((x) => state.feelings[x.id]).filter((f) => f != null);
  const avgMood = rated.length ? rated.reduce((a, f) => a + f, 0) / rated.length : null;
  return `
    <div class="section-label">SIMILAR EVENTS</div>
    <ul class="similar-group"><li>
      <button class="similar-head" data-toggle aria-expanded="false">
        <span class="sim-count">${xs.length} event${xs.length === 1 ? '' : 's'}</span>
        <span class="sim-avg"><small>AVG STRESS</small><b style="color:${levelFor(avgStress).color}">${avgStress.toFixed(1)}</b></span>
        ${avgMood != null ? `<span class="sim-avg"><small>AVG MOOD</small><b>${avgMood >= 0 ? '+' : ''}${avgMood.toFixed(1)}</b></span>` : ''}
        <svg class="chev"><use href="#i-chevron-down"/></svg>
      </button>
      <div class="occ"><div class="occ-inner">
    <ul class="occ-list similar">${xs.map((x) => `
      <li><button class="occ-row" data-occ="${escapeHtml(x.id)}">
        <span class="sim-text"><span class="sim-title">${escapeHtml(x.title)}</span>
          <span class="occ-time">${dayFmt.format(x.start)} · ${timeFmt.format(x.start)}</span></span>
        <span class="occ-val" style="color:${levelFor(x.stress).color}">${x.stress.toFixed(1)}</span>
      </button></li>`).join('')}</ul>
      </div></div>
    </li></ul>`;
}

// Calendar events (and ones added here) can be renamed and retimed; WHOOP workouts and free time can't.
const editable = (e) => !e.block && !e.whoop;

function openEditSheet(e) {
  const writeBack = e.source === 'google' && calendarConnected();
  $('sheet').innerHTML = `
    <div class="nav-row">
      <button class="icon-btn" data-edit-cancel aria-label="Cancel"><svg><use href="#i-back"/></svg></button>
      <h2 class="sheet-title">EDIT EVENT</h2>
      <span></span>
    </div>
    <div class="hero"><div class="when">${dayFmt.format(e.start).toUpperCase()}</div></div>
    <form class="add-form" id="edit-form">
      <input class="text-input" name="title" placeholder="Event name" maxlength="120" autocomplete="off" required value="${escapeHtml(e.title)}" aria-label="Event name">
      <div class="stat-group">
        <label class="group-row">${icon('clock')}<span class="row-label">From</span>
          <input class="time-input" type="time" name="start" value="${hhmm(e.start)}" required></label>
        <label class="group-row">${icon('clock')}<span class="row-label">To</span>
          <input class="time-input" type="time" name="end" value="${hhmm(e.end)}" required></label>
        ${writeBack ? `<label class="group-row check">${icon('trend')}<span class="row-label">Also update in Google Calendar</span><input type="checkbox" name="google" checked></label>` : ''}
      </div>
      <p class="form-hint">${writeBack ? 'Leave the box unchecked to change it here only.' : e.custom ? 'This event lives on this device.' : 'Changes are saved on this device. Your Google Calendar stays as it is.'}</p>
      <button class="primary-btn" type="submit">SAVE</button>
    </form>
    ${e.original ? '<button class="text-btn neutral" id="reset-edit">Reset to calendar version</button>' : ''}`;

  $('sheet').querySelector('[data-edit-cancel]').addEventListener('click', () => openSheet(e.id));
  $('reset-edit')?.addEventListener('click', () => {
    delete state.edits[e.id];
    saveEdits();
    refresh();
    openSheet(e.id);
    toast('Back to the calendar version.');
  });
  $('edit-form').addEventListener('submit', (ev) => {
    ev.preventDefault();
    const form = new FormData(ev.target);
    const title = form.get('title').trim();
    const start = timeOnDay(e.start, form.get('start'));
    const end = timeOnDay(e.start, form.get('end'));
    if (!title || !start || !end) return;
    if (end <= start) { toast('End time needs to be after the start time.'); return; }
    whileBusy(ev.target, 'SAVING…', async () => {
      try {
        if (form.get('google')) await updateEvent(e.id, { title, start, end });
      } catch (err) {
        toast(err.message);
        return;
      }
      state.edits[e.id] = { title, start: start.toISOString(), end: end.toISOString() };
      saveEdits();
      refresh();
      openSheet(e.id);
      toast(form.get('google') ? 'Saved here and in Google Calendar.' : 'Saved.');
    });
  });
}

function addEventForm(block) {
  return `
    <div class="section-label">ADD AN EVENT · ${durationLabel(block).toUpperCase()}</div>
    <form class="add-form" id="add-form">
      <input class="text-input" name="title" placeholder="What were you doing?" maxlength="120" autocomplete="off" required value="${escapeHtml(draft.title)}">
      <div class="stat-group">
        <label class="group-row">${icon('clock')}<span class="row-label">From</span>
          <input class="time-input" type="time" name="start" value="${hhmm(draft.start)}" min="${hhmm(block.start)}" max="${hhmm(block.end)}" required></label>
        <label class="group-row">${icon('clock')}<span class="row-label">To</span>
          <input class="time-input" type="time" name="end" value="${hhmm(draft.end)}" min="${hhmm(block.start)}" max="${hhmm(block.end)}" required></label>
        ${calendarConnected() ? `<label class="group-row check">${icon('trend')}<span class="row-label">Also add to Google Calendar</span><input type="checkbox" name="google" checked></label>` : ''}
      </div>
      <p class="form-hint">Pick any part of this ${durationLabel(block)} stretch.</p>
      <button class="primary-btn" id="add-submit" type="submit" ${draft.title.trim() ? '' : 'disabled'}>ADD EVENT</button>
    </form>`;
}

// "HH:MM" from a time input → that time on `day`'s date.
function timeOnDay(day, value) {
  if (!/^\d{2}:\d{2}/.test(value ?? '')) return null;
  const [h, m] = value.split(':').map(Number);
  const d = new Date(day);
  d.setHours(h, m, 0, 0);
  return d;
}

async function onAddEvent(ev, block) {
  ev.preventDefault();
  const form = new FormData(ev.target);
  const title = form.get('title').trim();
  const start = timeOnDay(block.start, form.get('start'));
  const end = timeOnDay(block.start, form.get('end'));
  if (!start || !end || !title) return;
  if (end <= start) { toast('End time needs to be after the start time.'); return; }
  if (start < block.start || end > block.end) {
    toast(`Pick a time between ${timeFmt.format(block.start)} and ${timeFmt.format(block.end)}.`);
    return;
  }

  let event;
  try {
    if (form.get('google')) {
      event = await createEvent({ title, start, end });
      state.events.push(event);
    } else {
      event = { id: `custom-${Date.now()}`, title, start, end, attendees: 0, recurring: false, custom: true };
      state.customEvents.push(event);
      saveCustomEvents();
    }
  } catch (err) {
    toast(err.message);
    return;
  }
  draft = null;
  refresh();
  openSheet(event.id);
  toast(`Added "${title}". Rate how it felt below.`);
}

// ---- Thread Coach (reads the ML model's output) ----

async function loadInsights() {
  try {
    const res = await fetch('insights.json', { cache: 'no-store' });
    if (res.ok) state.insights = { ...(await res.json()), demo: true };
  } catch { /* not generated yet */ }
}

// The demo model's results don't describe live data, so they're hidden once real data is in.
// Google Calendar is live through sign-in or through a private iCal address.
const calendarLive = () => calendarConnected() || Boolean(state.icalUrl);
const liveData = () => state.whoop.connected || calendarLive();
const currentInsights = () => (state.insights?.demo && liveData() ? null : state.insights);

// Every past occurrence of an event title, newest first, for the Drains / Lifts drop-downs.
function occurrencesHtml(title) {
  const occ = state.scored.filter((e) => !e.block && e.hasData && e.title === title).sort((a, b) => b.start - a.start);
  if (!occ.length) return { count: 0, html: '<p class="occ-empty">No recent events with this name.</p>' };
  return {
    count: occ.length,
    html: `<ul class="occ-list">${occ.map((e) => `<li><button class="occ-row" data-occ="${escapeHtml(e.id)}">
        <span class="occ-date">${dayFmt.format(e.start).toUpperCase()}</span>
        <span class="occ-time">${timeFmt.format(e.start)}</span>
        <span class="occ-val" style="color:${levelFor(e.stress).color}">${e.stress.toFixed(1)}</span>
      </button></li>`).join('')}</ul>`,
  };
}

// A keyword (one or two words from the model, e.g. "lunch sam") matches a title containing every word.
function titleMatches(title, keyword) {
  const words = new Set(title.toLowerCase().split(/[^a-z0-9]+/));
  return keyword.toLowerCase().split(' ').every((w) => words.has(w));
}

let coachFilter = null;

function openCoach() {
  coachFilter = null;
  renderCoach();
  showSheet('coach');
}

function renderCoach() {
  const ins = currentInsights();
  const header = `
    <div class="nav-row">
      <button class="icon-btn" data-close aria-label="Back"><svg><use href="#i-back"/></svg></button>
      <h2 class="sheet-title" id="coach-title">INSIGHTS</h2>
      <span></span>
    </div>`;
  if (!ins) {
    $('coach').innerHTML = `${header}
      <div class="coach-msg"><span class="w-badge"><svg><use href="#w-mark"/></svg></span>
        <p>Insights are built from the demo data, so they're hidden while your own calendar or WHOOP is connected.</p></div>`;
    return;
  }
  const matching = ins.events.filter((e) => !coachFilter || titleMatches(e.title, coachFilter));
  const limit = 3;
  // Each event goes in one list only: above your average stress it drains, below it lifts.
  const scored = ins.events.filter((e) => e.stress != null);
  const avgStress = scored.reduce((a, e) => a + e.stress, 0) / (scored.length || 1);
  const drains = matching.filter((e) => e.stress != null && e.stress >= avgStress).sort((a, b) => b.stress - a.stress).slice(0, limit);
  const lifts = matching.filter((e) => e.stress != null && e.stress < avgStress).sort((a, b) => a.stress - b.stress).slice(0, limit);
  const top = ins.events.filter((e) => e.stress != null).sort((a, b) => b.stress - a.stress)[0];
  const calm = ins.events.filter((e) => e.stress != null).sort((a, b) => a.stress - b.stress)[0];
  const words = (title, list) => list?.length ? `
    <div class="section-label">${title}</div>
    <div class="words">${list.map((w) => `<button class="word${coachFilter === w ? ' on' : ''}" data-chip="${escapeHtml(w)}" aria-pressed="${coachFilter === w}">${escapeHtml(w)}</button>`).join('')}</div>` : '';
  const empty = '<p class="occ-empty">No events with this word.</p>';
  const row = (e) => {
    const occ = occurrencesHtml(e.title);
    const n = occ.count || e.n;
    return threadHtml({
      name: e.title,
      meta: `${n} event${n === 1 ? '' : 's'}`,
      fraction: e.stress / 3,
      score: e.stress.toFixed(1),
      stress: e.stress,
      expand: occ.html,
    });
  };

  $('coach').innerHTML = `${header}
    <div class="coach-msg"><span class="w-badge"><svg><use href="#w-mark"/></svg></span>
      <p>Across ${ins.n_events} events, <strong>${escapeHtml(top?.title ?? '')}</strong> drains you the most and
      <strong>${escapeHtml(calm?.title ?? '')}</strong> is your calmest. Tap a word to filter, or a row to see each time it happened.</p></div>
    ${words('LINKED TO STRESS', ins.words?.stress_up)}
    ${words('LINKED TO CALM', ins.words?.stress_down)}
    ${coachFilter ? `<div class="filter-bar"><span>SHOWING EVENTS WITH <b>"${escapeHtml(coachFilter.toUpperCase())}"</b></span><button data-chip-clear>CLEAR</button></div>` : ''}
    <div class="section-header"><span>DRAINS</span><span style="color:var(--muted)">AVG STRESS</span></div>
    ${drains.length ? `<ol class="threads">${drains.map(row).join('')}</ol>` : empty}
    <div class="section-header"><span>LIFTS</span><span style="color:var(--muted)">AVG STRESS</span></div>
    ${lifts.length ? `<ol class="threads">${lifts.map(row).join('')}</ol>` : empty}`;
}

// Which parts of the page are generated demo data right now, said plainly in the scoring popup.
function mockNote() {
  const demoCalendar = state.calendarSource === 'Demo calendar';
  const demoHr = state.hrSource === 'demo heart rate';
  if (demoCalendar && demoHr) {
    return `Everything here is a mock-up: the events, heart rate and stress scores are generated demo data, not real readings${state.whoop.sample ? ', and so are the WHOOP recovery and strain numbers' : ''}. Connect your own data from the gear menu.`;
  }
  const parts = [demoCalendar && 'calendar events', demoHr && 'heart rate and stress scores', state.whoop.sample && 'WHOOP recovery and strain numbers'].filter(Boolean);
  if (!parts.length) return null;
  const list = parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts.at(-1)}` : parts[0];
  return `The ${list} shown here are mock-up demo data, not real readings.`;
}

function openInfo() {
  const mock = mockNote();
  $('info').innerHTML = `
    <div class="sheet-handle"></div>
    <h2 class="sheet-title" id="info-title">HOW STRESS IS SCORED</h2>
    ${mock ? insightBox('Mock-up data', mock) : ''}
    <p>Each minute, your heart rate is compared with your resting baseline for the day (the lowest 10% of your awake readings). 40% or more above baseline is the top of WHOOP's 0–3 stress scale.</p>
    <p>An event's score is the average over its minutes. Workouts are scored but left out of stress labels, since a higher heart rate there is effort. Free time between events is grouped into Unscheduled stretches you can name.</p>`;
  showSheet('info');
}

// ---- Date picker ----

const monthFmt = new Intl.DateTimeFormat(undefined, { month: 'long', year: 'numeric' });
const narrowWeekday = new Intl.DateTimeFormat(undefined, { weekday: 'narrow' });
let calMonth = null; // first day of the month on show

const offsetOf = (d) => Math.round((today - d) / 86400000);

// Drops down from the date label, centered under it.
function openCalendar() {
  const d = currentDay();
  calMonth = new Date(d.getFullYear(), d.getMonth(), 1);
  renderCalendar();
  const cal = $('calendar');
  cal.style.top = `${$('date-label').getBoundingClientRect().bottom - cal.offsetParent.getBoundingClientRect().top + 10}px`;
  showSheet('calendar');
}

// Month grid. Days in range can be picked; each day with events gets a dot colored by its
// average stress, or grey when nothing on it has been scored yet (planned days).
function renderCalendar() {
  const y = calMonth.getFullYear(), m = calMonth.getMonth();
  const first = new Date(today); first.setDate(first.getDate() - (HISTORY_DAYS - 1));
  const last = new Date(today); last.setDate(last.getDate() + FUTURE_DAYS);
  // Same average as the day's gauge: events and unscheduled time, workouts left out.
  const days = {};
  for (const e of state.scored) {
    const d = (days[localDate(e.start)] ??= { n: 0, stress: [] });
    if (!e.block) d.n++;
    if (e.hasData && !e.active) d.stress.push(e.stress);
  }
  const cells = Array.from({ length: new Date(y, m, 1).getDay() }, () => '<span></span>');
  for (let n = 1; n <= new Date(y, m + 1, 0).getDate(); n++) {
    const date = new Date(y, m, n);
    const info = days[localDate(date)];
    const avg = info?.stress.length ? info.stress.reduce((a, b) => a + b, 0) / info.stress.length : null;
    const dot = info && (info.n || avg != null) ? `<i style="background:${avg == null ? 'var(--muted)' : levelFor(avg).color}"></i>` : '';
    const offset = offsetOf(date);
    const classes = ['cal-day', offset === 0 && 'today', offset === state.dayOffset && 'selected'].filter(Boolean).join(' ');
    cells.push(`<button class="${classes}" data-offset="${offset}" ${date < first || date > last ? 'disabled' : ''}
      aria-label="${escapeHtml(dayFmt.format(date))}${info?.n ? `, ${info.n} event${info.n === 1 ? '' : 's'}` : ''}"><span>${n}</span>${dot}</button>`);
  }
  const weekdays = Array.from({ length: 7 }, (_, i) => narrowWeekday.format(new Date(2024, 0, 7 + i))); // Jan 7 2024 was a Sunday
  $('calendar').innerHTML = `
    <div class="cal-head">
      <button data-cal-month="-1" aria-label="Previous month" ${new Date(y, m, 0) < first ? 'disabled' : ''}><svg><use href="#i-left"/></svg></button>
      <h2 class="sheet-title" id="calendar-title">${monthFmt.format(calMonth).toUpperCase()}</h2>
      <button data-cal-month="1" aria-label="Next month" ${new Date(y, m + 1, 1) > last ? 'disabled' : ''}><svg><use href="#i-right"/></svg></button>
    </div>
    <div class="cal-grid">${weekdays.map((w) => `<span class="cal-wd">${w}</span>`).join('')}${cells.join('')}</div>
    <div class="cal-foot">
      <span class="cal-key"><i style="background:var(--stress-low)"></i><i style="background:var(--stress-medium)"></i><i style="background:var(--stress-high)"></i>Avg stress
        <i style="background:var(--muted)"></i>Planned</span>
      <button data-offset="0">TODAY</button>
    </div>`;
}

// ---- Sheets ----

function showSheet(id) {
  $('scrim').hidden = false;
  $(id).setAttribute('aria-hidden', 'false');
  // Skip the slide-in if the sheet was closed again before the next frame.
  requestAnimationFrame(() => { if ($(id).getAttribute('aria-hidden') === 'false') $(id).classList.add('open'); });
}

function closeSheets() {
  for (const id of ['sheet', 'coach', 'info', 'settings', 'whoop-setup', 'calendar', 'calendar-setup']) {
    $(id).classList.remove('open');
    $(id).setAttribute('aria-hidden', 'true');
  }
  $('scrim').hidden = true;
}

// ---- Metric picker ----

function renderMetricPicker() {
  if (!METRICS[state.metric]) state.metric = 'stress';
  $('metric-select').innerHTML = Object.entries(METRICS)
    .map(([id, m]) => `<option value="${id}"${id === state.metric ? ' selected' : ''}>${m.label}</option>`).join('');
}

function setMetric(id) {
  state.metric = id;
  savePref(METRIC_KEY, id);
  renderMetricPicker();
  renderTimeline();
}

// ---- Data sources ----

function renderSource() {
  const { whoop } = state;
  $('source-label').textContent = `${state.calendarSource} · ${state.hrSource}${whoop.connected ? ' · WHOOP' : whoop.sample ? ' · sample WHOOP' : ''}`;
  $('whoop-status').textContent = whoop.connected ? 'SYNC' : whoop.sample ? 'SAMPLE' : 'SET UP';
  $('whoop-status').classList.toggle('connected', whoop.connected || whoop.sample);
  $('disconnect-whoop').hidden = !(whoop.connected || whoop.sample);
  $('disconnect-whoop').textContent = whoop.sample ? 'Stop using sample WHOOP data' : 'Disconnect WHOOP';
  // CONNECTED only once events have loaded; a saved link that's still loading says so.
  $('calendar-status').textContent = calendarLive() ? 'CONNECTED' : state.icalLoading ? 'LOADING…' : 'CONNECT';
  $('calendar-status').classList.toggle('connected', calendarLive());
}

let toastTimer;
function toast(msg) {
  const t = $('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 3800);
}

function refresh() {
  rescore();
  renderMetricPicker();
  renderTimeline();
  renderSource();
}

// Real data shouldn't sit next to invented data: drop whatever demo pieces are still loaded.
function dropDemo() {
  if (state.calendarSource === 'Demo calendar') {
    state.events = [];
    state.calendarSource = 'No calendar yet';
  }
  if (state.hrSource === 'demo heart rate') {
    state.samples = [];
    state.sleep = {};
    state.hrSource = 'no heart rate yet';
  }
}

const titleCase = (s) => s.replace(/[-_]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());

function applyWhoop(data, { sample = false } = {}) {
  if (!sample) dropDemo();
  state.sleep = Object.fromEntries(data.sleep.map((s) => [localDate(s.end), { wake: s.end, bed: s.start }]));
  state.workouts = data.workouts.map((w) => ({
    id: `whoop-${w.id}`, title: titleCase(w.sport), start: w.start, end: w.end,
    attendees: 0, recurring: false, active: true,
    whoop: { strain: w.strain, avgHr: w.avg_hr, maxHr: w.max_hr },
  }));
  state.daily = {};
  const day = (key) => (state.daily[key] ??= {});
  for (const r of data.recovery) Object.assign(day(localDate(r.wake)), { recovery: r.score, hrv: r.hrv, rhr: r.rhr });
  // A cycle runs from one sleep onset to the next, so 12 hours in lands on the day it belongs to.
  for (const c of data.cycles) day(localDate(new Date(c.start.getTime() + 12 * 3600000))).strain = c.strain;
}

// Asks the server how WHOOP stands. While a sleeping server wakes up, asks again every few seconds
// (for about two minutes), and refreshes the WHOOP sheet if it's open and waiting.
const STATUS_RETRY_MS = 5000;
const STATUS_TRIES = 24;

async function loadWhoop({ announce = false, attempt = 1 } = {}) {
  state.whoop = { ...(await whoopStatus()), sample: state.whoop.sample && !state.whoop.connected };
  setGoogleClientId(state.whoop.google_client_id);
  renderSource();
  if (state.whoop.backend === null && attempt < STATUS_TRIES) {
    setTimeout(() => loadWhoop({ announce, attempt: attempt + 1 }), STATUS_RETRY_MS);
    return;
  }
  if ($('whoop-setup').classList.contains('open')) renderWhoopSetup();
  if (!state.whoop.connected) return;
  const start = new Date(today);
  start.setDate(start.getDate() - HISTORY_DAYS);
  try {
    const data = await fetchWhoop(start, new Date());
    applyWhoop(data);
    refresh();
    if (announce) toast(`WHOOP synced: ${data.recovery.length} recoveries, ${data.workouts.length} workouts.`);
  } catch (err) {
    toast(err.message);
  }
}

// ---- WHOOP setup ----

// Steps for connecting WHOOP. A visitor without the site owner's keys registers their own WHOOP
// developer app and pastes its keys; anyone can skip straight to sample data instead.
function openWhoopSetup() {
  renderWhoopSetup();
  closeSheets();
  showSheet('whoop-setup');
}

function renderWhoopSetup() {
  const w = state.whoop;
  let connect;
  if (w.backend === null) {
    connect = `<p>Waking up the server… After it's been idle this can take up to a minute. This updates by itself.</p>`;
  } else if (w.server_keys) {
    connect = `
      <p>Sign in with your WHOOP account to bring in sleep, workouts, recovery and strain.</p>
      <button class="primary-btn" data-whoop-signin>SIGN IN WITH WHOOP</button>`;
  } else if (w.backend === false) {
    connect = `<p>Connecting WHOOP needs this app's server (<code>serve.py</code>). This copy is running without one, so only sample data is available.</p>`;
  } else {
    connect = `
      <p>WHOOP only shares data with apps registered to a WHOOP account, so you'll set up your own. It's free and takes about five minutes.</p>
      <ol class="setup-steps">
        <li>Open <a href="https://developer-dashboard.whoop.com" target="_blank" rel="noopener">developer-dashboard.whoop.com</a> and sign in with your WHOOP account.</li>
        <li>Create a team if it asks, then <b>Create App</b>. Any name works.</li>
        <li>Under scopes, turn on <b>read:profile</b>, <b>read:sleep</b>, <b>read:workout</b>, <b>read:recovery</b> and <b>read:cycles</b> (and <b>offline</b> if it's listed).</li>
        <li>Add this redirect URL:
          <span class="copy-row"><code id="redirect-uri">${escapeHtml(w.redirect_uri)}</code><button type="button" class="copy-btn" data-copy-redirect>COPY</button></span></li>
        <li>Save, then paste the app's <b>Client ID</b> and <b>Client Secret</b> here:</li>
      </ol>
      <form class="add-form" id="whoop-keys">
        <input class="text-input" name="id" placeholder="Client ID" autocomplete="off" spellcheck="false" required>
        <input class="text-input" name="secret" type="password" placeholder="Client Secret" autocomplete="off" required>
        <p class="form-hint">Your keys are kept on this server for your session only.</p>
        <button class="primary-btn" type="submit">CONNECT WHOOP</button>
        <p class="form-hint busy-hint" hidden>Saving your keys. If the server was idle, this can take up to a minute.</p>
      </form>`;
  }
  $('whoop-setup').innerHTML = `
    <div class="sheet-handle"></div>
    <h2 class="sheet-title" id="whoop-setup-title">CONNECT WHOOP</h2>
    <div class="setup">${connect}</div>
    <div class="setup-or"><span>NO WHOOP ACCOUNT?</span></div>
    <div class="setup">
      <p>Try it with sample WHOOP data that matches the demo calendar: daily recovery, HRV, resting heart rate and strain.</p>
      <button class="secondary-btn" data-whoop-sample>USE SAMPLE DATA</button>
    </div>`;
  $('whoop-keys')?.addEventListener('submit', (ev) => {
    ev.preventDefault();
    const form = new FormData(ev.target);
    whileBusy(ev.target, 'CONNECTING…', async () => {
      try {
        await saveWhoopKeys(form.get('id'), form.get('secret'));
        connectWhoop();
      } catch (err) {
        toast(err.message);
      }
    });
  });
}

function useSampleWhoop({ quiet = false } = {}) {
  if (calendarLive()) {
    if (!quiet) toast('Sample WHOOP data goes with the demo calendar. Disconnect your calendar to use it.');
    return;
  }
  state.whoop.sample = true;
  savePref(SAMPLE_WHOOP_KEY, '1');
  applyWhoop(generateWhoopDemo(demo), { sample: true });
  refresh();
  if (quiet) return;
  closeSheets();
  toast('Showing sample WHOOP data.');
}

function stopSampleWhoop() {
  state.whoop.sample = false;
  try { localStorage.removeItem(SAMPLE_WHOOP_KEY); } catch { /* storage unavailable */ }
  state.daily = {};
  state.workouts = [];
  if (state.calendarSource === 'Demo calendar') state.sleep = demo.sleep;
}

// The days the page shows: history plus the days ahead.
function calendarRange() {
  const start = new Date(today);
  start.setDate(start.getDate() - (HISTORY_DAYS - 1));
  const end = new Date(today);
  end.setDate(end.getDate() + FUTURE_DAYS + 1);
  return [start, end];
}

function useCalendarEvents(events) {
  // Demo HR and sleep against real events would invent results, so drop them.
  dropDemo();
  if (state.whoop.sample) stopSampleWhoop();
  state.events = events;
  state.calendarSource = 'Google Calendar';
  refresh();
}

async function signInWithGoogle() {
  try {
    await connectCalendar();
    useCalendarEvents(await fetchEvents(...calendarRange()));
    closeSheets();
    toast(`Loaded ${state.events.length} events.`);
  } catch (err) {
    toast(err.message);
  }
}

// Shows a form's submit button as busy until `work` settles. A server that's been idle can take a
// minute to wake, and without this the button looks like it did nothing.
async function whileBusy(form, label, work) {
  const button = form.querySelector('[type=submit]');
  const hint = form.querySelector('.busy-hint');
  const idle = button.textContent;
  button.disabled = true;
  button.textContent = label;
  hint && (hint.hidden = false);
  try {
    await work();
  } finally {
    button.disabled = false;
    button.textContent = idle;
    hint && (hint.hidden = true);
  }
}

// Connects (or, on page load, reconnects) through a private iCal address. A gateway error (502-504)
// usually means the server is still waking up: on page load that's retried quietly.
// The calendar only counts as connected once events have loaded. A saved link that's rejected as a
// bad address (400) is forgotten; any other failure keeps it for next time.
async function connectIcal(url, { quiet = false, attempt = 1 } = {}) {
  try {
    const events = await fetchIcsEvents(url, ...calendarRange());
    state.icalUrl = url;
    state.icalLoading = false;
    savePref(ICAL_KEY, url);
    useCalendarEvents(events);
    if (!quiet) {
      closeSheets();
      toast(`Loaded ${events.length} events from Google Calendar.`);
    }
  } catch (err) {
    const waking = !err.status || (err.status >= 502 && err.status <= 504);
    if (waking && quiet && attempt < STATUS_TRIES) {
      setTimeout(() => connectIcal(url, { quiet, attempt: attempt + 1 }), STATUS_RETRY_MS);
      return;
    }
    state.icalLoading = false;
    if (quiet && err.status === 400) {
      try { localStorage.removeItem(ICAL_KEY); } catch { /* storage unavailable */ }
      toast('Your saved Google Calendar link stopped working, so it was disconnected. Paste it again from the gear menu.');
    } else {
      toast(!waking ? err.message : quiet
        ? "Couldn't reach the server to load your Google Calendar. It'll try again next time you open the page."
        : 'The server is still waking up. Try again in a moment.');
    }
    renderSource();
  }
}

// Ways to connect Google Calendar: sign in (when this site has a Google client ID), or paste the
// calendar's private iCal address, which needs no setup on anyone's part.
function openCalendarSetup() {
  const signIn = calendarConfigured() ? `
    <div class="setup">
      <p>Sign in to read your events and add new ones from unscheduled time.</p>
      <button class="primary-btn" data-cal-signin>SIGN IN WITH GOOGLE</button>
    </div>
    <div class="setup-or"><span>OR USE A PRIVATE LINK</span></div>` : '';
  let link;
  if (state.icalLoading) {
    link = `<p>Loading your calendar from its private address…</p>`;
  } else if (state.icalUrl) {
    link = `
      <p>Connected with your calendar's private address. Events refresh each time you open the page.</p>
      <button class="text-btn" data-cal-disconnect>Disconnect calendar</button>`;
  } else if (state.whoop.backend === false) {
    // Only when there's definitely no server; a sleeping one just makes the request wait.
    link = `<p>Reading a calendar link needs this app's server (<code>serve.py</code>), which this copy is running without.</p>`;
  } else {
    link = `
      <p>Every Google Calendar has a private, read-only address. Paste it here to bring in your events:</p>
      <ol class="setup-steps">
        <li>On a computer, open <a href="https://calendar.google.com/calendar/r/settings" target="_blank" rel="noopener">Google Calendar settings</a>.</li>
        <li>On the left, under <b>Settings for my calendars</b>, pick your calendar.</li>
        <li>Scroll to <b>Integrate calendar</b> and copy the <b>Secret address in iCal format</b>.</li>
      </ol>
      <form class="add-form" id="ical-form">
        <input class="text-input" name="url" type="url" placeholder="https://calendar.google.com/calendar/ical/…/basic.ics" autocomplete="off" spellcheck="false" required>
        <p class="form-hint">Keep this address private: anyone with it can see your events. It stays in this browser. Some work and school accounts hide this option.</p>
        <button class="primary-btn" type="submit">CONNECT CALENDAR</button>
        <p class="form-hint busy-hint" hidden>Reading your calendar. If the server was idle, this can take up to a minute.</p>
      </form>`;
  }
  $('calendar-setup').innerHTML = `
    <div class="sheet-handle"></div>
    <h2 class="sheet-title" id="calendar-setup-title">GOOGLE CALENDAR</h2>
    ${signIn}
    <div class="setup">${link}</div>`;
  $('ical-form')?.addEventListener('submit', (ev) => {
    ev.preventDefault();
    whileBusy(ev.target, 'CONNECTING…', () => connectIcal(new FormData(ev.target).get('url').trim()));
  });
  closeSheets();
  showSheet('calendar-setup');
}

// ---- Wiring ----

$('prev-day').addEventListener('click', () => { state.dayOffset++; renderTimeline(); });
$('next-day').addEventListener('click', () => { state.dayOffset--; renderTimeline(); });
$('date-label').addEventListener('click', openCalendar);
$('calendar').addEventListener('click', (ev) => {
  const month = ev.target.closest('[data-cal-month]');
  const day = ev.target.closest('[data-offset]');
  if (month) {
    calMonth = new Date(calMonth.getFullYear(), calMonth.getMonth() + Number(month.dataset.calMonth), 1);
    renderCalendar();
  } else if (day) {
    state.dayOffset = Number(day.dataset.offset);
    closeSheets();
    renderTimeline();
  }
});
$('threads').addEventListener('click', (ev) => {
  const btn = ev.target.closest('[data-id]');
  if (btn) openSheet(btn.dataset.id);
});
$('plus-btn').addEventListener('click', () => { const b = latestBlock(); if (b) openSheet(b.id); });
$('open-settings').addEventListener('click', () => showSheet('settings'));
$('back-home').addEventListener('click', () => toast('This page opens from WHOOP Home.'));
document.addEventListener('click', (ev) => {
  if (ev.target.closest('[data-close]')) closeSheets();
  else if (ev.target.closest('[data-open-coach]')) { closeSheets(); openCoach(); }
  else if (ev.target.closest('[data-chip]')) {
    const w = ev.target.closest('[data-chip]').dataset.chip;
    coachFilter = coachFilter === w ? null : w;
    renderCoach();
  } else if (ev.target.closest('[data-chip-clear]')) {
    coachFilter = null;
    renderCoach();
  } else if (ev.target.closest('[data-toggle]')) {
    const btn = ev.target.closest('[data-toggle]');
    const open = btn.getAttribute('aria-expanded') !== 'true';
    btn.setAttribute('aria-expanded', String(open));
    btn.closest('li').classList.toggle('open', open);
  } else if (ev.target.closest('[data-occ]')) {
    const id = ev.target.closest('[data-occ]').dataset.occ;
    closeSheets();
    openSheet(id);
  }
  else if (ev.target.closest('[data-open-info]')) openInfo();
});
$('scrim').addEventListener('click', closeSheets);
document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') closeSheets(); });
$('connect-calendar').addEventListener('click', openCalendarSetup);
$('calendar-setup').addEventListener('click', (ev) => {
  if (ev.target.closest('[data-cal-signin]')) signInWithGoogle();
  else if (ev.target.closest('[data-cal-disconnect]')) {
    try { localStorage.removeItem(ICAL_KEY); } catch { /* storage unavailable */ }
    location.reload();
  }
});
$('connect-whoop').addEventListener('click', () => (state.whoop.connected ? loadWhoop({ announce: true }) : openWhoopSetup()));
$('disconnect-whoop').addEventListener('click', async () => {
  if (state.whoop.sample) {
    stopSampleWhoop();
    refresh();
    return;
  }
  await disconnectWhoop().catch(() => {});
  toast('WHOOP disconnected. Reload to start over on demo data.');
  state.whoop.connected = false;
  renderSource();
});
$('whoop-setup').addEventListener('click', (ev) => {
  if (ev.target.closest('[data-whoop-signin]')) connectWhoop();
  else if (ev.target.closest('[data-whoop-sample]')) useSampleWhoop();
  else if (ev.target.closest('[data-copy-redirect]')) {
    navigator.clipboard?.writeText($('redirect-uri').textContent).then(() => toast('Redirect URL copied.'), () => {});
  }
});
$('metric-select').addEventListener('change', (ev) => setMetric(ev.target.value));
// Keep the "now" marker and today's stretches current.
setInterval(() => { if (state.dayOffset === 0) { rescore(); renderTimeline(); } }, 60000);

refresh();
loadInsights();
// On narrow screens the Home tabs scroll sideways; keep this page's tab (the last) in view.
document.querySelector('.top-tabs').scrollLeft = document.querySelector('.top-tabs').scrollWidth;
// Back from WHOOP's sign-in page: say how it went, then tidy the URL.
const whoopResult = new URLSearchParams(location.search).get('whoop');
if (whoopResult) {
  history.replaceState(null, '', location.pathname);
  if (whoopResult === 'denied') toast('WHOOP access was not granted.');
  else if (whoopResult === 'error') toast('WHOOP sign-in failed. Check the redirect URL and keys, then try again.');
}
const savedIcal = loadPref(ICAL_KEY, '');
if (savedIcal) {
  state.icalLoading = true;
  renderSource();
  connectIcal(savedIcal, { quiet: true });
}
loadWhoop({ announce: whoopResult === 'connected' }).then(() => {
  if (!state.whoop.connected && loadPref(SAMPLE_WHOOP_KEY, '') === '1') useSampleWhoop({ quiet: true });
  if (whoopResult === 'setup') openWhoopSetup();
});
