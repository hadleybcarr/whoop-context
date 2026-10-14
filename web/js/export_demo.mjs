// Writes the demo dataset as a labeled CSV for the ML pipeline:
//   node web/js/export_demo.mjs > ml/data/demo_events.csv
import { generateDemo } from './demo.js';
import { scoreDay, localDate, toCsvRows, CSV_COLUMNS } from './scoring.js';

const days = Number(process.argv[2] ?? 60);
const { events, samples, feelings } = generateDemo({ days });

const byDay = new Map();
for (const e of events) {
  const key = localDate(e.start);
  if (!byDay.has(key)) byDay.set(key, []);
  byDay.get(key).push(e);
}
const scored = [...byDay.values()].flatMap((evs) => scoreDay(evs, samples, evs[0].start).events);

console.log([CSV_COLUMNS.join(','), ...toCsvRows(scored, feelings)].join('\n'));
