// Disposable UI verification server. Never points at the owner's sync database.
// Every record below is synthetic and dated relative to the moment it starts.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { emptyDocument } from '../web/sync.js';

export function syntheticWeek(now = new Date()) {
  const data = emptyDocument();
  const stamp = new Date(now.getTime() - 3 * 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const day = offset => { const date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset, 12); return { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate() }; };
  const at = (offset, hour, minute = 0) => new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset, hour, minute).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const id = (prefix, index) => `${prefix}-0000-4000-8000-${String(index).padStart(12, '0')}`;
  const physics = id('20000000', 1), chemistry = id('20000000', 2), english = id('20000000', 3), maths = id('20000000', 4), history = id('20000000', 5);
  const research = id('30000000', 1), epq = id('30000000', 2), epqDraft = id('31000000', 1);
  data.subjects = [
    { id: physics, title: 'Physics', progress: 45, confidence: 3, notes: '', colour: 'blue', archived: false, topics: [{ id: id('40000000', 1), title: 'Waves', confidence: 2, progress: 30, notes: '' }, { id: id('40000000', 2), title: 'Electricity', confidence: 4, progress: 70, notes: '' }], confidenceHistory: [] },
    { id: chemistry, title: 'Chemistry', progress: 60, confidence: 3, notes: '', colour: 'green', archived: false, topics: [{ id: id('40000000', 3), title: 'Rates of reaction', confidence: 2, progress: 40, notes: '' }], confidenceHistory: [], lastActivity: stamp },
    { id: english, title: 'English Literature', progress: 52, confidence: 4, notes: '', colour: 'purple', archived: false, topics: [], confidenceHistory: [] },
    { id: maths, title: 'Mathematics', progress: 71, confidence: 4, notes: '', colour: 'indigo', archived: false, topics: [], confidenceHistory: [] },
    { id: history, title: 'History', progress: 38, confidence: 2, notes: '', colour: 'orange', archived: false, topics: [], confidenceHistory: [] },
  ];
  data.projects = [
    { id: research, title: 'Research project', summary: 'A sample project', notes: '', status: 'active', progress: 0, health: 3, colour: 'indigo', milestones: [], updates: [], progressHistory: [] },
    { id: epq, title: 'Extended Project essay', summary: 'Five thousand words on urban rivers', notes: '', status: 'active', progress: 35, health: 3, colour: 'teal', progressMode: 'milestones', milestones: [{ id: epqDraft, title: 'Full first draft', targetDay: day(16), isCompleted: false, notes: '' }, { id: id('31000000', 2), title: 'Literature review', targetDay: day(-6), isCompleted: true, notes: '' }], updates: [], progressHistory: [] },
  ];
  // The eight undated revision tasks are relied on by the browser verifiers.
  for (let i = 0; i < 8; i++) data.tasks.push({ id: id('10000000', i + 1), title: `Revision task ${i + 1}`, notes: 'Disposable preview data', createdAt: stamp, modifiedAt: stamp, isCompleted: i === 7, ...(i === 7 ? { completedAt: stamp, completionPercent: 100 } : {}), isArchived: false, estimatedMinutes: 30, priority: 'medium', tags: [], sortOrder: i, subjectID: physics, projectID: research });
  const task = (index, fields) => data.tasks.push({ id: id('11000000', index), notes: '', createdAt: stamp, modifiedAt: stamp, isCompleted: false, isArchived: false, estimatedMinutes: 30, priority: 'none', tags: [], sortOrder: 100 + index, ...fields });
  task(1, { title: 'Chemistry worksheet on rates of reaction', subjectID: chemistry, topicID: id('40000000', 3), scheduledDay: day(0), scheduledStartMinutes: 17 * 60 + 30, scheduledDurationMinutes: 45, estimatedMinutes: 45, dueDay: day(1), priority: 'high', completionPercent: 0 });
  task(2, { title: 'Read Macbeth Act 3', subjectID: english, scheduledDay: day(0), estimatedMinutes: 40, subtasks: [{ id: id('12000000', 1), title: 'Scene 1', isCompleted: true }, { id: id('12000000', 2), title: 'Scene 2', isCompleted: false }, { id: id('12000000', 3), title: 'Banquet scene notes', isCompleted: false }] });
  task(3, { title: 'Maths homework on quadratics', subjectID: maths, dueDay: day(0) });
  task(4, { title: 'History source analysis', subjectID: history, dueDay: day(-2), estimatedMinutes: 50, priority: 'high' });
  task(5, { title: 'Physics practical write-up', subjectID: physics, scheduledDay: day(-1), estimatedMinutes: 45 });
  task(6, { title: 'Vocabulary quiz preparation', scheduledDay: day(1), scheduledStartMinutes: 16 * 60 + 45, scheduledDurationMinutes: 30 });
  task(7, { title: 'Draft the EPQ introduction', projectID: epq, milestoneID: epqDraft, dueDay: day(5), estimatedMinutes: 90, priority: 'medium' });
  task(8, { title: 'Pack PE kit', scheduledDay: day(2), estimatedMinutes: 10, recurrence: { frequency: 'weekly', interval: 1, nextDay: day(2) } });
  task(9, { title: 'Biology flashcards', estimatedMinutes: 25, completionPercent: 40 });
  task(10, { title: 'Submit lab report', subjectID: chemistry, isCompleted: true, completedAt: at(0, Math.max(0, now.getHours() - 1)), completionPercent: 100 });
  // Older Mac-created record: uppercase ID, no completionPercent, no duration on its timed block.
  data.tasks.push({ id: '11000000-0000-4000-8000-0000000000AB'.toUpperCase(), title: 'Revise trig identities', notes: 'Created by an older LifeBoard on the Mac', createdAt: stamp, modifiedAt: stamp, isCompleted: false, isArchived: false, estimatedMinutes: 40, priority: 'low', tags: [], sortOrder: 200, subjectID: maths.toUpperCase(), scheduledDay: day(0), scheduledStartMinutes: 19 * 60 });
  data.events = [
    { id: id('50000000', 1), title: 'Netball training', day: day(0), startMinutes: 18 * 60 + 30, endMinutes: 19 * 60 + 30, notes: '', location: 'Sports hall' },
    { id: id('50000000', 2), title: 'Orchestra rehearsal', day: day(2), startMinutes: 16 * 60, endMinutes: 17 * 60 + 15, notes: '', location: '' },
  ];
  const external = (index, title, offset, start, end, calendarTitle = 'School timetable') => ({ id: `synthetic-calendar-${index}`, calendarID: 'synthetic-school', calendarTitle, title, day: day(offset), startMinutes: start[0] * 60 + start[1], endMinutes: end[0] * 60 + end[1], isAllDay: false, location: '', notes: '', startInstant: at(offset, ...start), endInstant: at(offset, ...end), timeZoneIdentifier: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC' });
  data.externalEvents = [
    external(1, 'Physics, period 1', 0, [9, 0], [10, 0]),
    external(2, 'English, period 2', 0, [10, 5], [11, 5]),
    external(3, 'Chemistry, period 5', 0, [13, 30], [14, 30]),
    external(4, 'Maths, period 1', 1, [9, 0], [10, 0]),
    { id: 'synthetic-calendar-5', calendarID: 'synthetic-family', calendarTitle: 'Family', title: 'Grandparents visiting', day: day(3), startMinutes: 0, endMinutes: 1440, isAllDay: true, location: '', notes: '', startInstant: at(3, 0), endInstant: at(4, 0), timeZoneIdentifier: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC' },
    // Older cached event from before instants were stored.
    { id: 'synthetic-calendar-6', calendarID: 'synthetic-school', calendarTitle: 'School timetable', title: 'Registration', day: day(1), startMinutes: 8 * 60 + 45, endMinutes: 9 * 60, isAllDay: false, location: '', notes: '' },
  ];
  data.yearMarkers = [
    { id: id('60000000', 1), title: 'Chemistry mock exam', startDay: day(9), category: 'Test', notes: 'Papers 1 and 2', subjectID: chemistry, colour: 'orange' },
    { id: id('60000000', 2), title: 'EPQ draft deadline', startDay: day(16), category: 'Deadline', notes: '', subjectID: null, colour: 'orange' },
    { id: id('60000000', 3), title: 'History essay hand-in', startDay: day(-10), category: 'Deadline', notes: '', subjectID: history, colour: 'orange' },
  ];
  data.activity = [{ id: id('70000000', 1), date: stamp, kind: 'taskCompleted', title: 'Completed “Literature review”', projectID: epq }];
  data.focusSessions = [{ id: id('80000000', 1), kind: 'focus', taskID: null, taskTitle: 'Focus session', startedAt: at(-1, 17, 0), endedAt: at(-1, 17, 25), focusedSeconds: 1500, completedTimer: true }];
  return data;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  let data = syntheticWeek(), revision = 1;
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1'); response.setHeader('Cache-Control', 'no-store');
    if (url.pathname === '/api/session') { response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify({ workspaceID: 'preview-workspace', sessionID: 'preview', ownerLegacy: false })); return; }
    if (url.pathname === '/api/snapshot') {
      response.setHeader('Content-Type', 'application/json');
      if (request.method === 'PUT') { let body = ''; for await (const part of request) body += part; if (Number(request.headers['if-match']) !== revision) { response.statusCode = 409; response.end('{}'); return; } data = JSON.parse(body); revision++; response.end(JSON.stringify({ revision })); }
      else response.end(JSON.stringify({ data, revision })); return;
    }
    if (url.pathname === '/api/logout') { response.end('{}'); return; }
    try { const path = url.pathname === '/' ? '/index.html' : url.pathname; if (path.includes('..')) throw Error(); const file = join(new URL('../web/', import.meta.url).pathname, path); const types = { '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json' }; response.setHeader('Content-Type', types[extname(file)] || 'application/octet-stream'); response.end(await readFile(file)); } catch { response.statusCode = 404; response.end('Not found'); }
  });
  const port = Number(process.env.PORT || 4173);
  server.listen(port, '127.0.0.1', () => console.log(`Disposable LifeBoard UI preview on http://127.0.0.1:${port}`));
}
