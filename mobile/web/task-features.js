// Recurrence produces a deterministic occurrence identity, so two devices
// completing the same task cannot create duplicate next occurrences.
export function recurrenceDay(day, recurrence) {
  if (!day || !recurrence) return null;
  const interval = recurrence.interval || 1;
  const date = new Date(day.year,day.month-1,day.day,12);
  if (recurrence.frequency === 'daily') date.setDate(date.getDate()+interval);
  else if (recurrence.frequency === 'weekly') date.setDate(date.getDate()+7*interval);
  else if (recurrence.frequency === 'monthly') {
    const original=date.getDate();date.setDate(1);date.setMonth(date.getMonth()+interval);
    const max=new Date(date.getFullYear(),date.getMonth()+1,0,12).getDate();date.setDate(Math.min(original,max));
  } else return null;
  return {year:date.getFullYear(),month:date.getMonth()+1,day:date.getDate()};
}
export function occurrenceID(id, day) {
  // UUID bytes mixed with calendar ordinal; mirrored by native RecurrenceEngine.
  const bytes=id.replaceAll('-','').match(/.{2}/g)?.map(b=>parseInt(b,16));
  if(bytes?.length!==16 || bytes.some(b=>!Number.isFinite(b)))return null;
  const value=day.year*372+(day.month-1)*31+day.day;
  for(let i=0;i<4;i++)bytes[12+i]^=(value>>>((3-i)*8))&255;
  bytes[6]=(bytes[6]&15)|80;bytes[8]=(bytes[8]&63)|128;
  const hex=bytes.map(b=>b.toString(16).padStart(2,'0')).join('');
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
export function completeRecurringTask(data,task, stamp) {
  if(!task.recurrence)return;
  const day=recurrenceDay(task.recurrence.nextDay||task.scheduledDay||task.dueDay||{year:new Date(stamp).getFullYear(),month:new Date(stamp).getMonth()+1,day:new Date(stamp).getDate()},task.recurrence);
  const id=occurrenceID(task.recurrenceSeriesID||task.id,day);if(!id||data.tasks.some(t=>t.id.toLowerCase()===id))return;
  const next=structuredClone(task);Object.assign(next,{id,isCompleted:false,isArchived:false,completionPercent:0,createdAt:stamp,modifiedAt:stamp});delete next.completedAt;delete next.actualMinutes;
  if(task.scheduledDay)next.scheduledDay=day;if(task.dueDay)next.dueDay=day;
  next.recurrenceSeriesID=task.recurrenceSeriesID||task.id;next.recurrence={...task.recurrence,nextDay:day};next.subtasks=next.subtasks?.map(s=>({...s,isCompleted:false}));data.tasks.push(next);
}
