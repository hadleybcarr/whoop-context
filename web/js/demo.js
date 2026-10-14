// Deterministic demo data: a few weeks of calendar events plus minute-level heart rate,
// so the page and the ML pipeline work before Google Calendar / HR data are connected.
// Each template has a hidden effect on HR (hr) and on how it felt (joy) for the model to recover.

const TEMPLATES = [
  { title: 'Morning Activity', start: [7, 0], min: 45, hr: 0.55, joy: 1.2, days: [1, 3, 5, 6] },
  { title: 'Team Standup', start: [9, 30], min: 15, hr: 0.08, joy: 0, days: [1, 2, 3, 4, 5], attendees: 6, recurring: true },
  { title: 'Deep Work Block', start: [10, 0], min: 90, hr: 0.02, joy: 0.6, days: [1, 2, 4] },
  { title: 'Organic Chemistry Lecture', start: [11, 0], min: 80, hr: 0.12, joy: -0.6, days: [2, 4], recurring: true },
  { title: 'Lunch with Sam', start: [12, 30], min: 60, hr: 0.06, joy: 1.6, days: [3], attendees: 2 },
  { title: '1:1 with Manager', start: [14, 0], min: 30, hr: 0.22, joy: -0.4, days: [2], attendees: 2, recurring: true },
  { title: 'Exam Review Session', start: [15, 0], min: 90, hr: 0.27, joy: -1.3, days: [4] },
  { title: 'Design Critique', start: [16, 0], min: 60, hr: 0.2, joy: -0.2, days: [1, 3], attendees: 8 },
  { title: 'Investor Pitch Practice', start: [13, 0], min: 45, hr: 0.32, joy: -0.8, days: [5], attendees: 4 },
  { title: 'Coffee with Friends', start: [16, 30], min: 45, hr: 0.03, joy: 1.5, days: [5, 6], attendees: 3 },
  { title: 'Dentist Appointment', start: [10, 0], min: 45, hr: 0.18, joy: -1.0, days: [6], once: 3 },
  { title: 'Family Call', start: [19, 0], min: 30, hr: -0.02, joy: 1.1, days: [0] },
  { title: 'Yoga', start: [18, 0], min: 60, hr: 0.3, joy: 1.3, days: [0, 2] },
  { title: 'Budget Review', start: [15, 30], min: 45, hr: 0.19, joy: -1.1, days: [3], attendees: 3 },
  { title: 'Office Hours', start: [17, 0], min: 60, hr: 0.1, joy: 0.2, days: [1, 4] },
];

function mulberry32(seed) {
  return function () {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function gauss(rand) {
  const u = Math.max(rand(), 1e-9);
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rand());
}

function at(day, [h, m], jitterMin = 0) {
  const d = new Date(day);
  d.setHours(h, m + jitterMin, 0, 0);
  return d;
}

function startOfToday(now) { const d = new Date(now); d.setHours(0, 0, 0, 0); return d; }

// Returns { events, samples, feelings, sleep } for `days` days ending on `endDay`.
// Days after today get planned events only: no heart rate or ratings yet.
// sleep: { 'YYYY-MM-DD': { wake: Date, bed: Date } }, as WHOOP's sleep tracking would give.
export function generateDemo({ endDay = new Date(), days = 21, seed = 7, now = new Date() } = {}) {
  const rand = mulberry32(seed);
  const events = [];
  const samples = [];
  const feelings = {};
  const sleep = {};

  for (let i = days - 1; i >= 0; i--) {
    const day = new Date(endDay);
    day.setHours(0, 0, 0, 0);
    day.setDate(day.getDate() - i);
    const dow = day.getDay();
    const restHr = 60 + gauss(rand) * 2;
    const wakeMin = 6 * 60 + 15 + Math.round(rand() * 60);
    const bedMin = 22 * 60 + 15 + Math.round(rand() * 80);
    const key = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, '0')}-${String(day.getDate()).padStart(2, '0')}`;
    sleep[key] = {
      wake: new Date(day.getTime() + wakeMin * 60000),
      bed: new Date(day.getTime() + bedMin * 60000),
    };
    // Off-calendar stress (commute, errands, a hard conversation) for the time blocks to catch.
    const episodes = Array.from({ length: 1 + Math.floor(rand() * 2) }, () => {
      const startMin = wakeMin + 60 + Math.floor(rand() * (bedMin - wakeMin - 180));
      return { from: startMin, to: startMin + 30 + Math.floor(rand() * 40), hr: 0.12 + rand() * 0.18 };
    });

    const todays = TEMPLATES
      .filter((t) => t.days.includes(dow) && (!t.once || i % 7 === t.once))
      .filter(() => rand() > 0.1)
      .map((t) => {
        const jitter = Math.round(gauss(rand) * 5);
        const start = at(day, t.start, jitter);
        const id = `demo-${day.toISOString().slice(0, 10)}-${t.title.toLowerCase().replace(/\W+/g, '-')}`;
        const event = {
          id,
          title: t.title,
          start,
          end: new Date(start.getTime() + t.min * 60000),
          attendees: t.attendees ?? 0,
          recurring: !!t.recurring,
          _hr: t.hr + gauss(rand) * 0.04,
          _joy: t.joy,
        };
        // Leave ~25% of past events unrated, like real users would. Today and later aren't rated yet.
        if (day < startOfToday(now) && rand() > 0.25) {
          feelings[id] = Math.max(-2, Math.min(2, Math.round(t.joy + gauss(rand) * 0.6)));
        }
        return event;
      })
      .sort((a, b) => a.start - b.start);

    // Minute-level HR from wake-up to bedtime, every 2 minutes.
    let drift = 0;
    for (let m = wakeMin; m < bedMin; m += 2) {
      const t = new Date(day.getTime() + m * 60000);
      if (t > now) break;
      const circadian = 4 * Math.sin(((m / 60 - 9) / 24) * 2 * Math.PI);
      drift = drift * 0.9 + gauss(rand) * 0.8;
      let effect = 0;
      let inEvent = null;
      for (const ep of episodes) if (m >= ep.from && m < ep.to) effect = Math.max(effect, ep.hr);
      for (const e of todays) {
        if (t >= e.start && t < e.end) { effect = Math.max(effect, e._hr); inEvent = e; }
        // Stressful events linger for a while after they end.
        const sinceEnd = (t - e.end) / 60000;
        if (sinceEnd >= 0 && sinceEnd < 40 && e._hr > 0) effect = Math.max(effect, e._hr * 0.5 * (1 - sinceEnd / 40));
      }
      const bpm = restHr * (1 + effect) + circadian + drift + gauss(rand) * 2;
      // Between events you walk now and then; in meetings you mostly sit.
      const walking = !inEvent && rand() < 0.12;
      samples.push({ t, bpm: Math.round(bpm + (walking ? 12 : 0)) });
    }

    for (const e of todays) {
      delete e._hr; delete e._joy;
      events.push(e);
    }
  }

  return { events, samples, feelings, sleep };
}

// Sample WHOOP data to go with the demo calendar, for trying the page without a WHOOP account.
// Same shape as fetchWhoop() in whoop.js. Recovery dips the morning after a stressful day (and
// effort raises strain), so the next-morning recovery model has a real pattern to find.
// No sample workouts: the demo calendar already has its activities, with heart rate.
export function generateWhoopDemo({ events, sleep }, { seed = 11, now = new Date() } = {}) {
  const rand = mulberry32(seed);
  const byTitle = Object.fromEntries(TEMPLATES.map((t) => [t.title, t]));
  const dayKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  // Hours of stressful time, and hours of effort, on each date.
  const load = {};
  for (const e of events) {
    const t = byTitle[e.title];
    if (!t) continue;
    const l = (load[dayKey(e.start)] ??= { stress: 0, effort: 0 });
    l[/activity|yoga/i.test(t.title) ? 'effort' : 'stress'] += (t.hr * (e.end - e.start)) / 3600000;
  }
  const keys = Object.keys(sleep).sort().filter((k) => sleep[k].wake <= now);
  const out = { sleep: [], workouts: [], recovery: [], cycles: [] };
  keys.forEach((key, i) => {
    const wake = sleep[key].wake;
    const start = i ? sleep[keys[i - 1]].bed : new Date(wake.getTime() - 8 * 3600000);
    const before = load[keys[i - 1]] ?? { stress: 0, effort: 0 };
    const today = load[key] ?? { stress: 0, effort: 0 };
    const score = Math.round(Math.max(12, Math.min(99, 74 - 55 * before.stress + gauss(rand) * 3)));
    out.sleep.push({ start, end: wake });
    out.recovery.push({ wake, score, hrv: 34 + score * 0.5 + gauss(rand) * 4, rhr: 63 - score * 0.09 + gauss(rand) });
    out.cycles.push({
      start, end: i < keys.length - 1 ? sleep[key].bed : null,
      strain: Math.min(21, 6 + 9 * today.effort + 5 * today.stress + rand() * 2),
    });
  });
  return out;
}
