// Minute-level import from CSV. Needs a timestamp column and a heart-rate column; a stress
// column is used when present. Works with an Apple Health export converted to CSV, or a
// third-party WHOOP export.
const TIME_COLS = ['timestamp', 'time', 'datetime', 'date', 'startdate', 'start', 'cycle start time'];
const HR_COLS = ['bpm', 'heart_rate', 'heartrate', 'heart rate', 'hr', 'value', 'heart rate (bpm)'];
// Optional extra minute-level columns, read when present.
const EXTRA_COLS = {
  stress: ['stress', 'stress_score', 'stress score'],
};

function splitCsvLine(line) {
  const out = [];
  let cur = '';
  let quoted = false;
  for (const ch of line) {
    if (ch === '"') quoted = !quoted;
    else if (ch === ',' && !quoted) { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out.map((s) => s.trim());
}

export function parseHeartRateCsv(text) {
  const lines = text.split(/\r?\n/).filter(Boolean);
  const header = splitCsvLine(lines[0]).map((h) => h.toLowerCase());
  const ti = header.findIndex((h) => TIME_COLS.includes(h));
  const hi = header.findIndex((h) => HR_COLS.includes(h));
  if (ti < 0 || hi < 0) {
    throw new Error(`Need a time column (${TIME_COLS.join('/')}) and a heart-rate column (${HR_COLS.join('/')})`);
  }
  const extras = Object.entries(EXTRA_COLS)
    .map(([key, names]) => [key, header.findIndex((h) => names.includes(h))])
    .filter(([, i]) => i >= 0);
  const samples = [];
  for (const line of lines.slice(1)) {
    const cols = splitCsvLine(line);
    const t = new Date(cols[ti]);
    const bpm = Number(cols[hi]);
    if (Number.isNaN(t.getTime()) || !(bpm > 25 && bpm < 230)) continue;
    const sample = { t, bpm };
    for (const [key, i] of extras) {
      if (cols[i] !== '' && Number.isFinite(Number(cols[i]))) sample[key] = Number(cols[i]);
    }
    samples.push(sample);
  }
  if (!samples.length) throw new Error('No heart-rate rows could be read');
  return samples.sort((a, b) => a.t - b.t);
}
