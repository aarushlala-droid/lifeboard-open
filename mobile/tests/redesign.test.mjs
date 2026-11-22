import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { tokensFromCSS } from '../scripts/export-tokens.mjs';
import { syntheticWeek } from '../scripts/preview-server.mjs';
import { validateDocument } from '../lib/validation.js';
import { iconNames } from '../web/icons.js';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8');

test('tokens.json mirrors tokens.css exactly for native reuse', () => {
  assert.deepEqual(JSON.parse(read('../web/tokens.json')), tokensFromCSS(read('../web/tokens.css')));
});

test('app.css uses only token colours and faces past its header', () => {
  const css = read('../web/app.css').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.equal(/#[0-9a-f]{3,8}\b/i.test(css), false, 'literal hex colour in app.css');
  assert.equal(/\brgba?\(|\bhsla?\(|\boklch\(/i.test(css), false, 'literal colour function in app.css');
  for (const [, value] of css.matchAll(/font-family:\s*([^;}]+)/g)) assert.match(value.trim(), /^var\(--lb-font-/);
  assert.equal(/transition:\s*all\b/.test(css), false);
});

test('synthetic preview week is a valid schema 3 document with older-style records', () => {
  const week = syntheticWeek(new Date(2026, 10, 21, 15, 0));
  assert.deepEqual(validateDocument(week), []);
  assert.equal(week.tasks.filter(task => task.id.startsWith('10000000-0000-4000-8000-')).length, 8);
  assert.ok(week.tasks.some(task => task.id === task.id.toUpperCase() && task.completionPercent === undefined && task.scheduledDurationMinutes === undefined));
  assert.ok(week.externalEvents.some(event => !event.startInstant));
  assert.equal(week.tasks.filter(task => task.isArchived).length, 0, 'Trash starts empty for the restore verifier');
});

test('every icon the view layer asks for exists', () => {
  const source = read('../web/app.js') + read('../web/index.html');
  const used = new Set([...source.matchAll(/icon\("([a-z-]+)"/g), ...source.matchAll(/data-icon="([a-z-]+)"/g)].map(match => match[1]));
  for (const name of used) assert.ok(iconNames.includes(name), `missing icon ${name}`);
});

test('interface copy writes sentences, not middle-dot strings', () => {
  for (const [index, line] of read('../web/app.js').split('\n').entries()) {
    if (!line.includes('·')) continue;
    assert.match(line, /sync\.status = "[^"]*·|replace\(\/ · /, `line ${index + 1} joins copy with a middle dot`);
  }
  for (const file of ['../web/index.html', '../web/connect.html']) assert.equal(read(file).includes('·'), false, file);
});

test('service worker shell lists every first-party view module', () => {
  const worker = read('../web/service-worker.js');
  for (const file of ['/tokens.css', '/app.css', '/app.js', '/icons.js', '/sync.js', '/scheduling.js', '/task-groups.js', '/task-features.js', '/capture.js', '/navigation.js']) assert.ok(worker.includes(`"${file}"`), file);
  assert.doesNotMatch(worker, /lifeboard-shell-v15"/);
});
