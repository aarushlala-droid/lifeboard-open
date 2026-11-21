import test from 'node:test';
import assert from 'node:assert/strict';
import { emptyDocument, mergeSnapshots, inverseOperation, applyInverse, patchDraft, LifeBoardSync, DocumentStorage } from '../web/sync.js';
import { readRoute, routeHash, moreActive } from '../web/navigation.js';

const task = (id,title='Original') => ({id,title,notes:'Notes',priority:'none',isCompleted:false,isArchived:false});
test('Undo preserves unrelated remote creation and field edit',()=>{
  const before=emptyDocument();before.tasks=[task('a')];
  const after=structuredClone(before);after.tasks[0].priority='high';
  const operation=inverseOperation(before,after);
  const synced=structuredClone(after);synced.tasks.push(task('b'));synced.tasks[0].notes='Remote notes';
  assert.deepEqual(applyInverse(synced,operation),[]);
  assert.equal(synced.tasks.length,2);assert.equal(synced.tasks[0].priority,'none');assert.equal(synced.tasks[0].notes,'Remote notes');
});
test('Undo refuses to overwrite a newer edit to the affected field',()=>{
  const before=emptyDocument();before.tasks=[task('a')];const after=structuredClone(before);after.tasks[0].title='Local';
  const operation=inverseOperation(before,after);after.tasks[0].title='Remote';assert.deepEqual(applyInverse(after,operation),['a/title']);assert.equal(after.tasks[0].title,'Remote');
});
test('Trash inverse preserves a newer task note',()=>{
  const before=emptyDocument();before.tasks=[task('a')];const after=structuredClone(before);after.tasks[0].isArchived=true;
  const operation=inverseOperation(before,after);after.tasks[0].notes='New';applyInverse(after,operation);assert.equal(after.tasks[0].isArchived,false);assert.equal(after.tasks[0].notes,'New');
});
test('stale editor commits changed fields and detects same-field collisions',()=>{
  const original=task('a'), draft={...original,priority:'high'},current={...original,notes:'Remote'};
  assert.deepEqual(patchDraft(original,draft,current).data,{...current,priority:'high'});
  assert.deepEqual(patchDraft(original,{...original,notes:'Local'},current).conflicts,['notes']);
});
test('settings merge independently; same-field preference conflict is explicit',()=>{
  const before=emptyDocument(), local=structuredClone(before),remote=structuredClone(before);
  local.settings.defaultTaskMinutes=45;remote.settings.lastICloudBackup='2026-10-03T10:00:00Z';remote.settings.breakMinutes=15;
  let result=mergeSnapshots(before,local,remote);assert.equal(result.data.settings.defaultTaskMinutes,45);assert.equal(result.data.settings.breakMinutes,15);
  remote.settings.defaultTaskMinutes=60;result=mergeSnapshots(before,local,remote);assert.deepEqual(result.conflicts,['settings/defaultTaskMinutes']);
});
test('independent task fields merge and completed focus retires stale timer',()=>{
  const before=emptyDocument();before.tasks=[task('a')];before.activeFocus={id:'focus',startedAt:'2026-10-03T10:00:00Z'};
  const local=structuredClone(before),remote=structuredClone(before);local.tasks[0].priority='high';remote.tasks[0].notes='Remote';delete local.activeFocus;
  local.focusSessions=[{id:'focus',startedAt:before.activeFocus.startedAt,focusedSeconds:1500,completedTimer:true}];
  const result=mergeSnapshots(before,local,remote);assert.equal(result.data.tasks[0].notes,'Remote');assert.equal(result.data.tasks[0].priority,'high');assert.equal(result.data.activeFocus,undefined);
});
test('two devices finalise same Focus identity once',()=>{
  const before=emptyDocument(), local=structuredClone(before),remote=structuredClone(before);
  local.focusSessions=[{id:'focus',startedAt:'same',endedAt:'one',focusedSeconds:1499,completedTimer:false}];
  remote.focusSessions=[{id:'focus',startedAt:'same',endedAt:'two',focusedSeconds:1500,completedTimer:true}];
  const result=mergeSnapshots(before,local,remote);assert.equal(result.data.focusSessions.length,1);assert.equal(result.data.focusSessions[0].focusedSeconds,1500);
});
test('routes round-trip and More remains selected on each descendant',()=>{
  const route={view:'calendar',day:'2026-10-04'};const read=readRoute(routeHash(route));assert.equal(read.day,route.day);assert.equal(read.view,route.view);
  for(const view of ['focus','settings','projects','subjects','completed','trash','sync-centre'])assert.equal(moreActive(view),true);
  assert.equal(readRoute('#view=untrusted').view,'today');assert.equal(moreActive('calendar'),false);
});
test('quota failure keeps previous durable envelope and pending work, never says safe',async()=>{
  const oldStorage=Object.getOwnPropertyDescriptor(globalThis,'localStorage'), oldNavigator=Object.getOwnPropertyDescriptor(globalThis,'navigator');
  const values=new Map();let denied=false;
  Object.defineProperty(globalThis,'localStorage',{configurable:true,value:{getItem:key=>values.get(key)||null,setItem:(key,value)=>{if(denied)throw new Error('Quota');values.set(key,value);},removeItem:key=>values.delete(key)}});
  Object.defineProperty(globalThis,'navigator',{configurable:true,value:{onLine:false}});
  let sync;
  try{
    sync=new LifeBoardSync();await sync.ready;sync.mutate(d=>d.tasks.push(task('a')));await sync.persistence;
    const durable=values.get('lifeboard.mobile.state.v2');denied=true;sync.mutate(d=>d.tasks.push(task('b')));await sync.persistence;
    assert.equal(values.get('lifeboard.mobile.state.v2'),durable);assert.equal(sync.data.tasks.length,2);assert.equal(sync.durable,false);assert.match(sync.status,/Couldn't save/);
    const reload=new LifeBoardSync();await reload.ready;assert.equal(reload.data.tasks.length,1);
  }finally{clearTimeout(sync?.timer);for(const [key,value] of [['localStorage',oldStorage],['navigator',oldNavigator]]){if(value)Object.defineProperty(globalThis,key,value);else delete globalThis[key];}}
});
test('conflict resolution preserves unrelated records and detects a subsequent revision',()=>{
  const before=emptyDocument();before.tasks=[task('a')];const local=structuredClone(before),remote=structuredClone(before);local.tasks[0].title='Local';remote.tasks[0].title='Remote';remote.tasks.push(task('b'));
  const sync=Object.create(LifeBoardSync.prototype);Object.assign(sync,{base:before,data:local,conflicts:['tasks/a/title'],conflictRemote:remote,replace(next){this.data=next;}});
  sync.resolveConflicts({'tasks/a/title':'local'});
  let result=mergeSnapshots(sync.base,sync.data,remote);assert.equal(result.data.tasks.length,2);assert.equal(result.data.tasks[0].title,'Local');
  const newer=structuredClone(remote);newer.tasks[0].title='Even newer';result=mergeSnapshots(sync.base,sync.data,newer);assert.deepEqual(result.conflicts,['tasks/a/title']);
});

test('monthly recurrence clamps dates and occurrence identity deduplicates devices',async()=>{
  const {recurrenceDay,completeRecurringTask,occurrenceID}=await import('../web/task-features.js');
  assert.deepEqual(recurrenceDay({year:2026,month:1,day:31},{frequency:'monthly',interval:1}),{year:2026,month:2,day:28});
  const data=emptyDocument();const source={...task('10000000-0000-4000-8000-000000000001'),dueDay:{year:2026,month:10,day:3},recurrence:{frequency:'weekly',interval:1}};data.tasks.push(source);
  completeRecurringTask(data,source,'2026-10-03T12:00:00Z');completeRecurringTask(data,source,'2026-10-03T12:00:00Z');
  assert.equal(data.tasks.length,2);assert.equal(data.tasks[1].id,occurrenceID(source.id,{year:2026,month:10,day:10}));assert.equal(data.tasks[1].isCompleted,false);assert.deepEqual(data.tasks[1].dueDay,{year:2026,month:10,day:10});
});
