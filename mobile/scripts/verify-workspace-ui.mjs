// Real IndexedDB workspace-transition recovery against a disposable localhost
// server. Never connects to production or reads the owner's browser profile.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { emptyDocument } from '../web/sync.js';

const modulePath = process.env.LIFEBOARD_PLAYWRIGHT_MODULE;
if (!modulePath) throw Error('Set LIFEBOARD_PLAYWRIGHT_MODULE to the installed Playwright index.mjs');
const { chromium } = await import(pathToFileURL(modulePath));
const out = new URL('../../output/playwright/workspace/', import.meta.url).pathname;
await mkdir(out, { recursive: true });
const oldID = 'preview-workspace-old', newID = 'preview-workspace-new';
const oldDocument = emptyDocument(), newDocument = emptyDocument();
oldDocument.tasks.push({ id: '10000000-0000-4000-8000-000000000001', title: 'Private cached workspace A task', notes: 'Synthetic recovery marker A', createdAt: '2026-10-03T12:00:00Z', modifiedAt: '2026-10-03T12:00:00Z', isCompleted: false, isArchived: false, estimatedMinutes: 30, priority: 'medium', tags: [], sortOrder: 0 });
const snapshots = new Map([[oldID, { data: oldDocument, revision: 1 }], [newID, { data: newDocument, revision: 1 }]]);
let connected = oldID;
const requests = [], passes = [], errors = [];
const pass = message => { passes.push(message); console.log('PASS ' + message); };
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    response.setHeader('Cache-Control', 'no-store');
    if (url.pathname === '/api/session') {
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify({ workspaceID: connected, sessionID: 'disposable', ownerLegacy: false })); return;
    }
    if (url.pathname === '/api/snapshot') {
      response.setHeader('Content-Type', 'application/json');
      const pinned = request.headers['x-lifeboard-workspace'];
      if (pinned !== connected) { response.statusCode = 403; response.end('{}'); return; }
      const current = snapshots.get(connected);
      if (request.method === 'PUT') {
        let body = ''; for await (const chunk of request) body += chunk;
        requests.push({ workspaceID: connected, method: 'PUT', data: JSON.parse(body) });
        if (Number(request.headers['if-match']) !== current.revision) { response.statusCode = 409; response.end('{}'); return; }
        current.data = JSON.parse(body); current.revision++;
        response.end(JSON.stringify({ revision: current.revision }));
      } else { requests.push({ workspaceID: connected, method: 'GET' }); response.end(JSON.stringify(current)); }
      return;
    }
    const path = url.pathname === '/' ? '/index.html' : url.pathname;
    if (path.includes('..')) throw Error('Invalid preview path');
    const file = join(new URL('../web/', import.meta.url).pathname, path);
    const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
    response.setHeader('Content-Type', types[extname(file)] || 'application/octet-stream');
    response.end(await readFile(file));
  } catch { response.statusCode = 404; response.end('Disposable preview resource unavailable'); }
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
const base = `http://127.0.0.1:${server.address().port}`;
let browser, context, page;
async function durable(key) {
  return page.evaluate(async key => {
    const request = indexedDB.open('lifeboard-private-v2', 1);
    const db = await new Promise((resolve, reject) => { request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error); });
    try { return await new Promise((resolve, reject) => { const query = db.transaction('state').objectStore('state').get(key); query.onsuccess = () => resolve(query.result); query.onerror = () => reject(query.error); }); }
    finally { db.close(); }
  }, key);
}
async function synced() { await page.getByRole('status').filter({ hasText: /Synced just now/ }).waitFor(); }
try {
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  context = await browser.newContext({ viewport: { width: 820, height: 1000 }, acceptDownloads: true });
  page = await context.newPage(); page.setDefaultTimeout(15_000); page.on('pageerror', error => errors.push(error.message));
  await page.goto(base + '/#view=todo'); await synced();
  await page.getByRole('tab', { name: /Anytime/ }).click();
  await page.getByRole('button', { name: /Private cached workspace A task.*30 min/ }).click();
  await page.getByRole('dialog').waitFor({ state: 'visible' });
  assert.equal((await durable('workspace:' + oldID)).data.tasks[0].notes, 'Synthetic recovery marker A');
  pass('Workspace A is durably cached in real IndexedDB and its editor is open');

  await page.evaluate(newID => {
    const original = IDBObjectStore.prototype.get;
    window.auditRestoreGet = () => { IDBObjectStore.prototype.get = original; };
    IDBObjectStore.prototype.get = function (key) {
      if (key === 'workspace:' + newID) throw new DOMException('Synthetic new-workspace read denial', 'UnknownError');
      return original.call(this, key);
    };
  }, newID);
  connected = newID;
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.getByRole('button', { name: 'Retry connection', exact: true }).waitFor();
  await page.getByRole('dialog').waitFor({ state: 'hidden' });
  const recoveryControls = await Promise.all([
    page.getByRole('button', { name: 'Export cached work', exact: true }).boundingBox(),
    page.getByRole('button', { name: 'Retry connection', exact: true }).boundingBox(),
    page.getByRole('link', { name: 'Reconnect', exact: true }).boundingBox(),
  ]);
  for (let index = 1; index < recoveryControls.length; index++) {
    assert.ok(recoveryControls[index].y >= recoveryControls[index - 1].y + recoveryControls[index - 1].height + 8, 'Recovery actions must remain separately spaced without overlap');
  }
  assert.ok(!(await page.locator('body').innerText()).includes('Private cached workspace A task'));
  assert.equal(await durable('lastWorkspace'), oldID);
  assert.deepEqual((await durable('workspace:' + oldID)).data, snapshots.get(oldID).data);
  assert.equal(requests.filter(request => request.workspaceID === newID).length, 0);
  await page.screenshot({ path: out + 'connection-unverified.png', fullPage: true });
  pass('Failed new-scope IndexedDB read hides old rows, closes the editor and retains the old durable pointer without sending old data');

  const pendingDownload = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export cached work', exact: true }).click();
  const download = await pendingDownload; await download.saveAs(out + 'cached-recovery.json');
  assert.deepEqual(JSON.parse(await readFile(out + 'cached-recovery.json', 'utf8')), snapshots.get(oldID).data);
  pass('The gated recovery UI exports the complete previous cached workspace');

  await page.evaluate(() => window.auditRestoreGet());
  await page.getByRole('button', { name: 'Retry connection', exact: true }).click(); await synced();
  await page.getByRole('heading', { name: 'To Do', exact: true }).waitFor();
  assert.equal(await durable('lastWorkspace'), newID);
  assert.equal((await durable('workspace:' + newID)).data.tasks.length, 0);
  assert.deepEqual((await durable('workspace:' + oldID)).data, snapshots.get(oldID).data);
  assert.ok(!(await page.locator('body').innerText()).includes('Private cached workspace A task'));
  await page.getByRole('button', { name: '＋ Add To Do', exact: true }).click();
  await page.getByLabel('Title', { exact: true }).fill('New workspace B task');
  await page.getByRole('button', { name: 'Save', exact: true }).click(); await synced();
  const newWrites = requests.filter(request => request.workspaceID === newID && request.method === 'PUT');
  assert.ok(newWrites.length > 0);
  for (const request of newWrites) assert.ok(request.data.tasks.every(task => task.title !== 'Private cached workspace A task' && task.notes !== 'Synthetic recovery marker A'));
  assert.deepEqual(snapshots.get(newID).data.tasks.map(task => task.title), ['New workspace B task']);
  await page.screenshot({ path: out + 'retry-new-workspace.png', fullPage: true });
  pass('Retry pins and loads the new workspace safely; subsequent edits upload only new-workspace records and preserve the old recovery cache');
  assert.deepEqual(errors, []);
  await writeFile(out + 'verification.json', JSON.stringify({ base, passes, errors, snapshotRequests: requests.map(({ workspaceID, method }) => ({ workspaceID, method })) }, null, 2));
} catch (error) {
  await page?.screenshot({ path: out + 'failure.png', fullPage: true }).catch(() => {});
  await writeFile(out + 'failure.json', JSON.stringify({ message: error.message, stack: error.stack, passes, errors }, null, 2));
  throw error;
} finally {
  await context?.close(); await browser?.close();
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
}
