import { dayString } from './capture.js';
const dateFor = day => new Date(day.year, day.month - 1, day.day, 12);
const deltaDays = (a, b) => Math.round((Date.UTC(b.year, b.month - 1, b.day) - Date.UTC(a.year, a.month - 1, a.day)) / 86400000);
export function taskSegment(task, day) {
  if (task.isArchived || task.isCompleted || !task.scheduledDay || task.scheduledStartMinutes == null) return null;
  const start = task.scheduledStartMinutes - deltaDays(task.scheduledDay, day) * 1440;
  const end = start + (task.scheduledDurationMinutes ?? task.estimatedMinutes);
  return start < 1440 && end > 0 ? {id: task.id, start: Math.max(0, start), end: Math.min(1440, end)} : null;
}
export function externalSegment(event, day) {
  if (event.startInstant && event.endInstant) {
    const midnight = dateFor(day); midnight.setHours(0, 0, 0, 0);
    const next = new Date(midnight); next.setDate(next.getDate() + 1);
    const start = new Date(event.startInstant), end = new Date(event.endInstant);
    if (!(start < next && end > midnight && end > start)) return null;
    if (event.isAllDay) return {id: event.id, start: 0, end: 1440};
    const a = new Date(Math.max(+start, +midnight)), b = new Date(Math.min(+end, +next));
    const first = +a === +midnight ? 0 : a.getHours() * 60 + a.getMinutes();
    const last = +b === +next ? 1440 : b.getHours() * 60 + b.getMinutes();
    return {id: event.id, start: Math.min(first, last), end: Math.min(1440, Math.max(first + Math.ceil((b - a) / 60000), last))};
  }
  return dayString(event.day) === dayString(day) ? {id: event.id, start: event.isAllDay ? 0 : event.startMinutes, end: event.isAllDay ? 1440 : event.endMinutes} : null;
}
export function busyIntervals(data, day, excluding = []) {
  const excluded = new Set(excluding.map(id => String(id).toLowerCase()));
  return [
    ...(data.tasks || []).filter(task => !excluded.has(String(task.id).toLowerCase())).map(task => taskSegment(task, day)),
    ...(data.events || []).map(event => {
      const start = event.startMinutes - deltaDays(event.day, day) * 1440, end = event.endMinutes - deltaDays(event.day, day) * 1440;
      return start < 1440 && end > 0 ? {id: event.id, start: Math.max(0, start), end: Math.min(1440, end)} : null;
    }),
    ...(data.externalEvents || []).map(event => externalSegment(event, day)),
  ].filter(Boolean);
}
export function suggestSchedule(requests, {busy = [], windowStart, hardStop, breakMinutes = 0, notBefore = 0}) {
  const occupied = [...busy], lower = Math.max(0, windowStart, notBefore), upper = Math.min(1440, hardStop), rest = Math.max(0, breakMinutes);
  return requests.map(request => {
    if (!(request.duration > 0)) return {id: request.id, start: null, reason: 'Duration must be positive'};
    let candidate = request.explicitStart ?? lower;
    const clashes = () => occupied.filter(item => candidate < item.end + rest && candidate + request.duration + rest > item.start);
    if (request.explicitStart == null) while (clashes().length) candidate = Math.max(...clashes().map(item => item.end + rest));
    const reason = candidate < lower ? 'This time is in the past or outside the planning window' : candidate + request.duration > upper ? 'Full duration does not fit before the hard stop' : clashes().length ? 'This time conflicts with another item or its break' : null;
    if (reason) return {id: request.id, start: null, reason};
    occupied.push({id: request.id, start: candidate, end: candidate + request.duration});
    return {id: request.id, start: candidate, reason: null};
  });
}
export function planDay(requests, data, day, now = new Date()) {
  const current = {year: now.getFullYear(), month: now.getMonth()+1, day: now.getDate()};
  const notBefore = dayString(day) < dayString(current) ? 1440 : dayString(day) === dayString(current) ? now.getHours()*60 + now.getMinutes() + (now.getSeconds() ? 1 : 0) : 0;
  return suggestSchedule(requests, {busy: busyIntervals(data, day, requests.map(item => item.id)), windowStart: data.settings.eveningStartMinutes, hardStop: data.settings.eveningEndMinutes, breakMinutes: data.settings.breakMinutes, notBefore});
}
export function intervalLanes(intervals) {
  const result = []; let group = [], ends = [], groupEnd = -1;
  const flush = () => { result.push(...group.map(item => ({...item, laneCount: Math.max(1, ends.length)}))); group = []; ends = []; groupEnd = -1; };
  for (const interval of [...intervals].sort((a,b) => a.start-b.start || a.id.localeCompare(b.id))) {
    if (interval.start >= groupEnd) flush();
    let lane = ends.findIndex(end => end <= interval.start); if (lane < 0) lane = ends.length;
    ends[lane] = interval.end; group.push({...interval, lane}); groupEnd = Math.max(groupEnd, interval.end);
  }
  flush(); return result;
}
export function calendarSegments(event, day) {
  if (event.calendarID != null || event.startInstant != null || event.isAllDay) return externalSegment(event, day);
  const start = event.startMinutes - deltaDays(event.day, day) * 1440;
  const end = event.endMinutes - deltaDays(event.day, day) * 1440;
  return start < 1440 && end > 0 ? {id: event.id, start: Math.max(0, start), end: Math.min(1440, end)} : null;
}
