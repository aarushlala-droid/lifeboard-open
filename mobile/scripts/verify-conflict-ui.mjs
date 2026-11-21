// Real browser conflict-resolution UI against a disposable localhost snapshot.
// No production credentials, storage profile, service or planner data is used.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

const modulePath = process.env.LIFEBOARD_PLAYWRIGHT_MODULE;
if (!modulePath) throw Error('Set LIFEBOARD_PLAYWRIGHT_MODULE to the bundled Playwright index.mjs');
const { chromium } = await import(pathToFileURL(modulePath));
const port = process.env.LIFEBOARD_CONFLICT_UI_PORT || '4176';
const base = process.env.LIFEBOARD_UI_BASE || `http://127.0.0.1:${port}`;
if (new URL(base).hostname !== '127.0.0.1' || new URL(base).protocol !== 'http:') throw Error('Only the disposable localhost preview server is allowed');
const output = new URL('../../output/playwright/conflicts/', import.meta.url).pathname;
await mkdir(output, { recursive: true });
let server;
if (!process.env.LIFEBOARD_UI_BASE) {
  const script = process.env.LIFEBOARD_PREVIEW_SERVER || new URL('./preview-server.mjs', import.meta.url).pathname;
  server = spawn(process.execPath, [script], { env: { ...process.env, PORT: port }, stdio: ['ignore', 'pipe', 'pipe'] });
  await new Promise((resolve, reject) => {
    server.stdout.once('data', resolve);
    server.once('error', reject);
    server.once('exit', code => reject(Error(`Disposable server exited ${code}`)));
  });
}
const identity = await (await fetch(base + '/api/session')).json();
if (identity.workspaceID !== 'preview-workspace') { server?.kill(); throw Error('Refusing to edit anything except the disposable preview-workspace'); }
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const contexts = await Promise.all([0, 1].map(() => browser.newContext({ viewport: { width: 390, height: 844 }, acceptDownloads: true })));
const pages = await Promise.all(contexts.map(context => context.newPage()));
const errors = [];
for (const [index, page] of pages.entries()) { page.setDefaultTimeout(15_000); page.on('pageerror', error => errors.push({ device: index, message: error.message })); }
const passes = [];
const pass = message => { passes.push(message); console.log('PASS ' + message); };
const taskID = '10000000-0000-4000-8000-000000000001';
const snapshot = async () => (await (await fetch(base + '/api/snapshot')).json());
const serverTask = async () => (await snapshot()).data.tasks.find(task => task.id === taskID);

async function durableState(page) {
  return page.evaluate(async () => {
    const request = indexedDB.open('lifeboard-private-v2', 1);
    const db = await new Promise((resolve, reject) => { request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); });
    try { return await new Promise((resolve, reject) => { const query = db.transaction('state').objectStore('state').get('workspace:preview-workspace'); query.onsuccess = () => resolve(query.result); query.onerror = () => reject(query.error); }); }
    finally { db.close(); }
  });
}
async function waitDurableTitle(page, title) {
  await page.waitForFunction(async ({ taskID, title }) => {
    const request = indexedDB.open('lifeboard-private-v2', 1);
    const db = await new Promise(resolve => { request.onsuccess = () => resolve(request.result); });
    try { return await new Promise(resolve => { const q = db.transaction('state').objectStore('state').get('workspace:preview-workspace'); q.onsuccess = () => resolve(q.result?.data?.tasks?.some(task => task.id === taskID && task.title === title)); }); }
    finally { db.close(); }
  }, { taskID, title });
}
async function synced(page) { await page.getByRole('status').filter({ hasText: /Synced just now/ }).waitFor(); }
async function todo(page) {
  await page.goto(base + '/#view=todo');
  await page.getByRole('heading', { name: 'To Do', exact: true }).waitFor();
  await page.getByRole('tab', { name: /Anytime/ }).click();
}
async function edit(page, title, nextTitle, notes) {
  await page.getByRole('button', { name: new RegExp(title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '.*30 min') }).click();
  if (nextTitle) await page.getByLabel('Title', { exact: true }).fill(nextTitle);
  if (notes !== undefined) await page.getByLabel('Notes', { exact: true }).fill(notes);
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  if (nextTitle) await waitDurableTitle(page, nextTitle);
}
async function add(page, title) {
  await page.getByRole('button', { name: '＋ Add To Do', exact: true }).click();
  await page.getByLabel('Title', { exact: true }).fill(title);
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await synced(page);
  assert.ok((await snapshot()).data.tasks.some(task => task.title === title));
}
async function syncCentre(page) {
  await page.getByRole('button', { name: 'More', exact: true }).click();
  await page.getByRole('button', { name: /Settings/ }).click();
  await page.getByRole('button', { name: 'Open Sync Centre', exact: true }).click();
  await page.getByRole('heading', { name: 'Sync Centre', exact: true }).waitFor();
}
async function review(page, local, remote, name) {
  await page.getByRole('status').filter({ hasText: /Sync needs review/ }).waitFor();
  await syncCentre(page);
  const form = page.locator('#conflict-form');
  await form.waitFor();
  assert.equal(await form.getByLabel('Keep', { exact: true }).count(), 1);
  const text = await form.innerText();
  assert.ok(text.includes('tasks/' + taskID + '/title'), text);
  assert.ok(text.includes(local) && text.includes(remote), text);
  await page.screenshot({ path: output + name + '.png', fullPage: true });
  const state = await durableState(page);
  assert.deepEqual(state.conflicts, ['tasks/' + taskID + '/title']);
}
async function choose(page, version, name) {
  await page.locator('#conflict-form').getByLabel('Keep', { exact: true }).selectOption(version);
  const downloaded = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Resolve and sync safely', exact: true }).click();
  const recovery = await downloaded;
  await recovery.saveAs(output + name + '-recovery.json');
  assert.equal(recovery.suggestedFilename(), 'LifeBoard-conflict-recovery.json');
}
async function assertConvergence(title, notes, additions) {
  const current = await snapshot();
  assert.equal(current.data.tasks.find(task => task.id === taskID).title, title);
  assert.equal(current.data.tasks.find(task => task.id === taskID).notes, notes);
  for (const addition of additions) assert.ok(current.data.tasks.some(task => task.title === addition));
  assert.equal(current.data.tasks.filter(task => task.id.startsWith('10000000-0000-4000-8000-')).length, 8);
  for (const page of pages) {
    await page.reload(); await synced(page); await waitDurableTitle(page, title);
    const state = await durableState(page);
    assert.deepEqual(state.conflicts, []);
    assert.equal(state.data.tasks.find(task => task.id === taskID).notes, notes);
    for (const addition of additions) assert.ok(state.data.tasks.some(task => task.title === addition));
    assert.deepEqual(state.data, current.data);
  }
}

try {
  await Promise.all(pages.map(todo)); await Promise.all(pages.map(synced));
  const initial = await snapshot();
  assert.equal(initial.data.tasks.find(task => task.id === taskID).title, 'Revision task 1');
  for (const context of contexts) await context.setOffline(true);
  await edit(pages[0], 'Revision task 1', 'Chosen local title');
  await edit(pages[1], 'Revision task 1', 'Competing remote title');
  await contexts[1].setOffline(false); await synced(pages[1]);
  await edit(pages[1], 'Competing remote title', null, 'Independent remote note'); await synced(pages[1]);
  await add(pages[1], 'Independent remote task B');
  await contexts[0].setOffline(false);
  await review(pages[0], 'Chosen local title', 'Competing remote title', 'keep-local-review');
  await pages[0].reload();
  await pages[0].getByRole('heading', { name: 'Sync Centre', exact: true }).waitFor();
  await pages[0].locator('#conflict-form').waitFor();
  assert.equal((await durableState(pages[0])).conflicts.length, 1);
  pass('Same-field offline edits produce a durable Sync Centre review showing both versions after reload');
  await choose(pages[0], 'local', 'keep-local'); await synced(pages[0]);
  await assertConvergence('Chosen local title', 'Independent remote note', ['Independent remote task B']);
  pass('Actual This device choice converges both contexts and server while preserving remote note, addition and all original tasks');

  await Promise.all(pages.map(todo));
  for (const context of contexts) await context.setOffline(true);
  await edit(pages[0], 'Chosen local title', 'Discarded local title');
  await edit(pages[1], 'Chosen local title', 'Kept remote title');
  await contexts[1].setOffline(false); await synced(pages[1]);
  await edit(pages[1], 'Kept remote title', null, 'Second independent remote note'); await synced(pages[1]);
  await add(pages[1], 'Independent remote task C');
  await contexts[0].setOffline(false);
  await review(pages[0], 'Discarded local title', 'Kept remote title', 'keep-remote-review');
  await choose(pages[0], 'remote', 'keep-remote'); await synced(pages[0]);
  await assertConvergence('Kept remote title', 'Second independent remote note', ['Independent remote task B', 'Independent remote task C']);
  pass('Actual Other device choice converges both contexts and server with independent remote changes preserved');

  await Promise.all(pages.map(todo));
  for (const context of contexts) await context.setOffline(true);
  await edit(pages[0], 'Kept remote title', 'Reviewed local title');
  await edit(pages[1], 'Kept remote title', 'First reviewed remote title');
  await contexts[1].setOffline(false); await synced(pages[1]);
  await contexts[0].setOffline(false);
  await review(pages[0], 'Reviewed local title', 'First reviewed remote title', 'revision-race-before');
  const reviewedRevision = (await snapshot()).revision;
  await edit(pages[1], 'First reviewed remote title', 'Newest remote revision title', 'Newest independent remote note'); await synced(pages[1]);
  await add(pages[1], 'Independent remote task D');
  assert.ok((await snapshot()).revision > reviewedRevision);
  await choose(pages[0], 'local', 'revision-race-stale-choice');
  await pages[0].getByRole('status').filter({ hasText: /Sync needs review/ }).waitFor();
  await pages[0].locator('#conflict-form').filter({ hasText: 'Newest remote revision title' }).waitFor();
  assert.equal((await serverTask()).title, 'Newest remote revision title');
  assert.equal((await durableState(pages[0])).data.tasks.find(task => task.id === taskID).title, 'Reviewed local title');
  await pages[0].screenshot({ path: output + 'revision-race-refreshed-review.png', fullPage: true });
  pass('A new remote revision during review is detected through the actual UI before any server overwrite');
  await choose(pages[0], 'local', 'revision-race-reviewed-choice'); await synced(pages[0]);
  await assertConvergence('Reviewed local title', 'Newest independent remote note', ['Independent remote task B', 'Independent remote task C', 'Independent remote task D']);
  pass('Fresh reviewed choice converges durable IndexedDB and server, preserving additions received during the revision race');

  assert.deepEqual(errors, []);
  await writeFile(output + 'verification.json', JSON.stringify({ base, workspace: identity.workspaceID, passes, errors, finalRevision: (await snapshot()).revision, contexts: 2 }, null, 2));
  await writeFile(output + 'final-server.json', JSON.stringify(await snapshot(), null, 2));
  console.log('LifeBoard browser conflict UI verification passed');
} catch (error) {
  for (const [index, page] of pages.entries()) {
    await page.screenshot({ path: output + `failure-device-${index}.png`, fullPage: true }).catch(() => {});
    await writeFile(output + `failure-device-${index}.txt`, await page.locator('body').innerText().catch(() => 'Unavailable'));
  }
  await writeFile(output + 'failure.json', JSON.stringify({ message: error.message, stack: error.stack, passes, errors }, null, 2));
  throw error;
} finally {
  for (const context of contexts) await context.close();
  await browser.close(); server?.kill();
}
