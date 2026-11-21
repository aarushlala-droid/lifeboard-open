import assert from 'node:assert/strict';
import {performance} from 'node:perf_hooks';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import crypto from 'node:crypto';
const root = path.resolve(process.argv[2] || path.join(import.meta.dirname, '../../..'));
const {groupTasks} = await import(pathToFileURL(path.join(root,'mobile/web/task-groups.js')));
const {busyIntervals, intervalLanes, planDay, calendarSegments} = await import(pathToFileURL(path.join(root,'mobile/web/scheduling.js')));
const {emptyDocument, mergeSnapshots} = await import(pathToFileURL(path.join(root,'mobile/web/sync.js')));
const reference = {year:2026,month:10,day:3};
const day = offset => ({year:2026,month:10,day:3+offset});
const results = [];
function measure(operation, count, actual, budget, work) {
  work(); const times = []; let checksum = 0;
  for(let index=0;index<5;index++){const start=performance.now();checksum+=work();times.push(performance.now()-start);}
  times.sort((a,b)=>a-b);
  results.push({engine:`Node ${process.version}`,operation,nominalRecords:count,actualCalendarRecords:actual,samples:5,minimumMS:times[0],medianMS:times[2],p95MS:times[4],budgetMS:budget,budgetPassed:times[4]<=budget,checksum});
}
function fixture(count) {
 const data=emptyDocument();
 data.tasks=Array.from({length:count},(_,index)=>({id:crypto.randomUUID(),title:`Synthetic revision task ${index}`,notes:'',createdAt:'2026-10-01T12:00:00Z',modifiedAt:'2026-10-01T12:00:00Z',estimatedMinutes:[30,45,60,90][index%4],priority:['none','low','medium','high'][index%4],dueDay:day(index%9-2),isCompleted:index%11===0,isArchived:index%23===0,...index%5!==0?{scheduledDay:day(index%7-2),scheduledStartMinutes:390+(index%60)*15}:{}}));
 data.events=Array.from({length:Math.max(1,Math.floor(count/10))},(_,index)=>({id:crypto.randomUUID(),title:`Synthetic lesson ${index}`,day:day(index%7-2),startMinutes:480+(index%40)*15,endMinutes:540+(index%40)*15}));
 data.externalEvents=Array.from({length:Math.max(1,Math.floor(count/20))},(_,index)=>({id:`synthetic-${index}`,calendarID:'synthetic',calendarTitle:'Synthetic calendar',title:`Synthetic meeting ${index}`,day:day(index%7-2),startMinutes:600+(index%30)*15,endMinutes:630+(index%30)*15,isAllDay:index%29===0}));
 return data;
}
for(const count of [100,1000,5000]) {
 const data=fixture(count),actual=data.tasks.length+data.events.length+data.externalEvents.length;
 const readBudget=count===100?16:count===1000?50:250;
 const bulkBudget=count===100?50:count===1000?300:1500;
 measure('group_tasks',count,actual,readBudget,()=>{const groups=groupTasks(data.tasks,'2026-10-03','2026-10-04');return groups.todayWorkload.length+groups.filters.Upcoming.length;});
 const requests=Array.from({length:count},()=>({id:crypto.randomUUID(),duration:30}));
 const excluding=requests.map(item=>item.id);
 measure('busy_intervals_with_exclusions',count,actual,readBudget,()=>busyIntervals(data,reference,excluding).length);
 measure('schedule_full_candidates',count,actual,bulkBudget,()=>{const plan=planDay(requests,data,reference,new Date(2026,9,3,16));assert.equal(plan.length,count);return plan.filter(item=>item.start==null).length;});
 measure('calendar_week_busy_lanes_and_segments',count,actual,readBudget,()=>Array.from({length:7},(_,index)=>{
  const current=day(index),lanes=intervalLanes(busyIntervals(data,current));
  const segments=[...data.events,...data.externalEvents].map(event=>calendarSegments(event,current)).filter(Boolean);
  return lanes.reduce((result,item)=>result+item.laneCount+item.end-item.start,0)+segments.length;
 }).reduce((a,b)=>a+b,0));
 const base=structuredClone(data),local=structuredClone(data),remote=structuredClone(data);
 for(let index=0;index<count;index++){if(index%3===0)local.tasks[index].title+=' local edit';if(index%3===1)remote.tasks[index].notes='Independent remote note';}
 measure('merge_independent_edits',count,actual,count===100?50:count===1000?250:1000,()=>{const merged=mergeSnapshots(base,local,remote);assert.deepEqual(merged.conflicts,[]);assert.equal(merged.data.tasks.length,count);return merged.data.tasks.filter(task=>task.notes).length;});
 const conflict=structuredClone(remote); conflict.tasks[0].title+=' conflicting remote edit';
 measure('merge_conflicting_edits',count,actual,count===100?50:count===1000?250:1000,()=>{const merged=mergeSnapshots(base,local,conflict);assert.equal(merged.data,null);assert.ok(merged.conflicts.some(field=>field.endsWith('/title')));return merged.conflicts.length;});
}
console.log(JSON.stringify(results,null,2));
