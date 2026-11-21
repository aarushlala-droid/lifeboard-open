import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {interpretText, dayString, fromDayString} from '../web/capture.js';
import {suggestSchedule, intervalLanes, taskSegment, externalSegment} from '../web/scheduling.js';
import {groupTasks} from '../web/task-groups.js';
const subjects = [{id:'geo',title:'Geography'},{id:'math',title:'Mathematics'},{id:'chem',title:'Chemistry'}];
const corpus = JSON.parse(fs.readFileSync(new URL('../../fixtures/capture.json', import.meta.url)));
test('shared Swift/JS capture intent corpus', () => {
 for(const fixture of corpus) {
  const [draft] = interpretText(fixture.input, {subjects,settings:{defaultTaskMinutes:30}},new Date(2026,9,3,12));
  assert.equal(draft.title,fixture.title, fixture.input);
  assert.equal(dayString(draft.dueDay)||null,fixture.day);
  assert.equal(draft.estimatedMinutes,fixture.duration);
  assert.equal(draft.priority,fixture.priority);
  assert.equal(subjects.find(s=>s.id===draft.subjectID)?.title??null,fixture.subject);
  assert.equal(draft.needsReview,fixture.review);
  assert.equal(draft.scheduledDay, /\bat\b/.test(fixture.input) ? draft.dueDay : null);
 }
 assert.equal(fromDayString('2026-02-31'),null); assert.ok(fromDayString('2028-02-29'));
});
test('free intervals respect full duration, now, breaks, exact conflicts, overflow',()=>{
 const requests=[{id:'long',duration:90},{id:'short',duration:30},{id:'overflow',duration:90}];
 const plan=suggestSchedule(requests,{busy:[{id:'calendar',start:1080,end:1140}],windowStart:1020,hardStop:1320,breakMinutes:10,notBefore:1035});
 assert.deepEqual(plan.map(p=>p.start),[1150,1035,null]);
 assert.ok(plan[2].reason);
 assert.equal(suggestSchedule([{id:'past',duration:30,explicitStart:1020}],{windowStart:1020,hardStop:1320,notBefore:1035})[0].start,null);
 assert.equal(suggestSchedule([{id:'collision',duration:30,explicitStart:1095}],{busy:[{start:1080,end:1140}],windowStart:0,hardStop:1440})[0].start,null);
});
test('overlap lanes and overnight task segments preserve minute positions',()=>{
 const lanes=intervalLanes([{id:'a',start:1140,end:1200},{id:'b',start:1170,end:1260},{id:'c',start:1185,end:1215},{id:'d',start:1410,end:1440}]);
 assert.deepEqual(lanes.map(x=>x.laneCount),[3,3,3,1]);
 const task={id:'night',scheduledDay:{year:2026,month:10,day:3},scheduledStartMinutes:1410,estimatedMinutes:90};
 assert.deepEqual(taskSegment(task,{year:2026,month:10,day:4}),{id:'night',start:0,end:60});
});
test('external all-day and overnight intervals retain original source',()=>{
 const event={id:'trip',startInstant:'2026-10-03T22:30:00Z',endInstant:'2026-10-05T08:00:00Z',isAllDay:false};
 assert.deepEqual(externalSegment(event,{year:2026,month:10,day:4}),{id:'trip',start:0,end:1440});
 assert.deepEqual(externalSegment({...event,isAllDay:true},{year:2026,month:10,day:4}),{id:'trip',start:0,end:1440});
 assert.equal(event.endInstant,'2026-10-05T08:00:00Z');
});
test('missed plans are distinct from missed deadlines and count Today workload',()=>{
 const day={year:2026,month:10,day:3};
 const tasks=[{id:'carry',scheduledDay:{...day,day:2},dueDay:{...day,day:8}},{id:'late',dueDay:{...day,day:2}},{id:'timed',scheduledDay:day,scheduledStartMinutes:1155}];
 const groups=groupTasks(tasks,'2026-10-03','2026-10-04');
 assert.deepEqual(groups.carryOver.map(t=>t.id),['carry']);assert.deepEqual(groups.filters.Overdue.map(t=>t.id),['late']);
 assert.equal(groups.todayWorkload.length,3);assert.equal(groups.todayUntimed.length,0);assert.equal(groups.filters.Upcoming.length,0);
});
test('DST fallback busy interval covers both occurrences of repeated wall hour',()=>{
 const original = process.env.TZ; process.env.TZ = 'Europe/London';
 try {
  const event={id:'dst',startInstant:'2026-10-25T00:30:00Z',endInstant:'2026-10-25T01:45:00Z',isAllDay:false};
  const segment=externalSegment(event,{year:2026,month:10,day:25});
  assert.equal(segment.start,90);assert.ok(segment.end>=165);
 } finally { if(original===undefined) delete process.env.TZ; else process.env.TZ=original; }
});
