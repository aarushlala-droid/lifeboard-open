import assert from "node:assert/strict";
import test from "node:test";
import { interpretText, previewPhotoWithTypedText } from "../web/capture.js";
import { emptyDocument, LifeBoardSync, mergeSnapshots } from "../web/sync.js";
import { groupTasks } from "../web/task-groups.js";
import { assessOCR } from "../web/ocr-quality.js";

const context = {
  ...emptyDocument(),
  subjects: [{ id: "chem", title: "Chemistry" }, { id: "maths", title: "Mathematics" }, { id: "phys", title: "Physics" }, { id: "bio", title: "Biology" }],
  tasks: [{ id: "existing", title: "Chemistry revision", isCompleted: false }],
};
const now = new Date(2026, 9, 1, 12);

test("capture keeps due dates separate from optional schedule", () => {
  const [proposal] = interpretText("chemistry tomorrow 30 mins", context, now);
  assert.equal(proposal.title, "Chemistry");
  assert.deepEqual(proposal.dueDay, { year: 2026, month: 10, day: 2 });
  assert.equal(proposal.scheduledDay, null);
  assert.equal(proposal.subjectID, "chem");
});

test("capture splits shared duration and updates a matching task", () => {
  const split = interpretText("maths and physics tonight around 40 mins each", context, now);
  assert.deepEqual(split.map(item => item.title), ["Maths", "Physics"]);
  assert.ok(split.every(item => item.estimatedMinutes === 40 && item.scheduledDay?.day === 1));
  const [move] = interpretText("move chemistry to tomorrow", context, now);
  assert.equal(move.title, "chemistry");
  assert.equal(move.existingID, "existing");
  assert.equal(move.scheduledDay.day, 2);
});

test("school test becomes an Important Date without a calendar block", () => {
  const [proposal] = interpretText("Biology kidney test Monday", context, now);
  assert.equal(proposal.kind, "date");
  assert.equal(proposal.category, "Test");
  assert.equal(proposal.title, "Biology kidney test");
  assert.equal(proposal.subjectID, "bio");
  assert.deepEqual(proposal.dueDay, { year: 2026, month: 10, day: 5 });
  assert.equal(proposal.scheduledDay, null);
  const [revision] = interpretText("Revise biology kidneys Monday", context, now);
  assert.equal(revision.kind, "task");
  assert.equal(revision.subjectID, "bio");
  const [testRevision] = interpretText("Revise for Biology kidney test Monday", context, now);
  assert.equal(testRevision.kind, "task");
  assert.deepEqual(testRevision.dueDay, { year: 2026, month: 10, day: 5 });
});

test("written dates are recognised and removed from captured titles", () => {
  const [proposal] = interpretText("Physics test 9th October", context, now);
  assert.equal(proposal.kind, "date");
  assert.equal(proposal.title, "Physics test");
  assert.deepEqual(proposal.dueDay, { year: 2026, month: 10, day: 9 });
  const [deadline] = interpretText("Research deadline 5 October", context, now);
  assert.equal(deadline.kind, "date");
  assert.equal(deadline.category, "Deadline");
  const [essay] = interpretText("English essay due Friday", context, now);
  assert.equal(essay.kind, "task");
});

test("smart apostrophe in don't schedule keeps calendar clear", () => {
  const [proposal] = interpretText("English essay Friday, don’t schedule", context, now);
  assert.equal(proposal.title, "English essay");
  assert.equal(proposal.scheduledDay, null);
  assert.equal(proposal.dueDay.day, 2);
});

test("planner photo heading supplies the date without becoming a task", () => {
  const proposals = interpretText("Friday planner\nChemistry revision 30 mins\nEnglish essay 45 mins\nFilm club slides", context, now);
  assert.deepEqual(proposals.map(item => item.title), ["Chemistry revision", "English essay", "Film club slides"]);
  assert.ok(proposals.every(item => item.dueDay?.day === 2 && item.scheduledDay === null));
  assert.deepEqual(proposals.map(item => item.estimatedMinutes), [30, 45, 30]);
});

test("photo OCR accepts readable planner lines and rejects scattered nonsense", () => {
  assert.equal(assessOCR("Monday planner\nBiology kidney test\nRevise cells 30 mins", 76).accepted, true);
  assert.equal(assessOCR("Biology kidney test Monday", 61).accepted, true);
  const noisy = "4 re Ee\naid CUE Re\nCl aa Fi GE Es\nJ i CER EE Re\nConds BR ER\nSai\nLo\nhi UE er\no Sst\nli Se GRD\nEF EL\nEee\nLine\nfo\nCina\nSale a\nop al\nCoden ;\npadi ake\nCor\nwi cata\n) — |\na 9 2 I tes] kris i we\n4 Eo i - 4 ne A\nL ade ~\n: 3 =\nee: J\n- ea a an . E.3 8\npe a I. Wl ba\nEee a 3 4) i § #";
  assert.equal(assessOCR(noisy, 82).accepted, false);
  assert.equal(assessOCR("Biology kidney test Monday", 22).accepted, false);
});

test("uncertain photo suggestions need an explicit tick while typed text stays included", () => {
  const suggestions = previewPhotoWithTypedText("Biology kidney test Monday", "Revise kidney diagram Friday", 59, context, now);
  assert.deepEqual(suggestions.map(item => item.included), [true, false]);
  assert.equal(suggestions[0].title, "Biology kidney test");
  assert.equal(suggestions[1].needsReview, true);
  assert.match(suggestions[1].reviewReason, /Photo text/);
});

test("sync merges independent records and stops a conflicting edit", () => {
  const base = emptyDocument();
  const local = structuredClone(base), remote = structuredClone(base);
  local.tasks.push({ id: "phone", title: "Phone task" });
  remote.tasks.push({ id: "mac", title: "Mac task" });
  assert.deepEqual(mergeSnapshots(base, local, remote).data.tasks.map(item => item.id), ["mac", "phone"]);
  base.tasks.push({ id: "shared", title: "Original" });
  local.tasks = [{ id: "shared", title: "Phone edit" }];
  remote.tasks = [{ id: "shared", title: "Mac edit" }];
  const conflict = mergeSnapshots(base, local, remote);
  assert.equal(conflict.data, null);
  assert.deepEqual(conflict.conflicts, ["tasks/shared/title"]);
});

test("sync preserves task progress and important dates across devices", () => {
  const base = emptyDocument();
  const phone = structuredClone(base), mac = structuredClone(base);
  phone.tasks.push({ id: "revision", title: "Revise physics", isCompleted: false, completionPercent: 45 });
  mac.yearMarkers.push({ id: "test", title: "Physics test", startDay: { year: 2026, month: 10, day: 8 }, category: "Test", subjectID: "phys" });
  const merged = mergeSnapshots(base, phone, mac);
  assert.deepEqual(merged.conflicts, []);
  assert.equal(merged.data.tasks[0].completionPercent, 45);
  assert.equal(merged.data.yearMarkers[0].subjectID, "phys");
});

test("an edit made during upload survives and syncs afterwards", async () => {
  const previous = {
    fetch: globalThis.fetch,
    navigator: Object.getOwnPropertyDescriptor(globalThis, "navigator"),
    localStorage: Object.getOwnPropertyDescriptor(globalThis, "localStorage"),
  };
  const values = new Map();
  const storage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { onLine: true } });
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: storage });
  let server = emptyDocument();
  server.tasks.push({ id: "revision", title: "Original", isCompleted: false });
  let revision = 1;
  let releaseFirstUpload;
  let uploadStarted;
  const firstUploadStarted = new Promise(resolve => { uploadStarted = resolve; });
  const firstUploadReleased = new Promise(resolve => { releaseFirstUpload = resolve; });
  let uploads = 0;
  globalThis.fetch = async (_url, options = {}) => {
    if (!options.method) return { ok: true, json: async () => ({ revision, data: structuredClone(server) }) };
    uploads++;
    if (uploads === 1) { uploadStarted(); await firstUploadReleased; }
    server = JSON.parse(options.body);
    revision++;
    return { ok: true, status: 200, json: async () => ({ revision }) };
  };
  let sync;
  try {
    sync = new LifeBoardSync();
    sync.data = structuredClone(server);
    sync.base = structuredClone(server);
    sync.revision = revision;
    sync.mutate(data => { data.tasks[0].title = "First edit"; });
    const firstSync = sync.sync();
    await firstUploadStarted;
    sync.mutate(data => { data.tasks[0].title = "Later edit"; });
    releaseFirstUpload();
    await firstSync;
    assert.equal(sync.data.tasks[0].title, "Later edit");
    for (let attempt = 0; attempt < 100 && (uploads < 2 || sync.busy || sync.status !== "Synced just now"); attempt++) {
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.equal(uploads, 2);
    assert.equal(server.tasks[0].title, "Later edit");
    assert.equal(sync.data.tasks[0].title, "Later edit");
  } finally {
    clearTimeout(sync?.timer);
    globalThis.fetch = previous.fetch;
    for (const key of ["navigator", "localStorage"]) {
      if (previous[key]) Object.defineProperty(globalThis, key, previous[key]);
      else delete globalThis[key];
    }
  }
});

test("unfinished tasks planned yesterday carry into phone Today", () => {
  const yesterday = { year: 2026, month: 10, day: 2 };
  const today = { year: 2026, month: 10, day: 3 };
  const tasks = [
    { id: "carry", scheduledDay: yesterday, scheduledStartMinutes: 18 * 60, isCompleted: false },
    { id: "due", dueDay: yesterday, isCompleted: false },
    { id: "both", scheduledDay: yesterday, dueDay: yesterday, isCompleted: false },
    { id: "today", scheduledDay: today, isCompleted: false },
    { id: "done", scheduledDay: yesterday, isCompleted: true },
  ];
  const groups = groupTasks(tasks, "2026-10-03", "2026-10-04");
  assert.deepEqual(groups.carryOver.map(task => task.id), ["carry", "both"]);
  assert.deepEqual(groups.overdue.map(task => task.id), ["due"]);
  assert.deepEqual(groups.todayUntimed.map(task => task.id), ["today"]);
  assert.deepEqual(groups.filters.Today.map(task => task.id), ["carry", "due", "both", "today"]);
  assert.deepEqual(groups.filters.Overdue.map(task => task.id), ["due", "both"]);
});
