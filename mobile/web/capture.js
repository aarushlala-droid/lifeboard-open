const weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
const isoDay = date => ({ year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate() });
const addDays = (date, count) => { const next = new Date(date.getFullYear(), date.getMonth(), date.getDate() + count, 12); return isoDay(next); };
const asDate = day => new Date(day.year, day.month - 1, day.day, 12);
export const dayString = day => day ? `${day.year}-${String(day.month).padStart(2, "0")}-${String(day.day).padStart(2, "0")}` : "";
export const validDay = day => {
  if (!day || !Number.isInteger(day.year) || day.year < 1 || day.year > 9999) return false;
  const date = new Date(0); date.setFullYear(day.year, day.month - 1, day.day); date.setHours(12, 0, 0, 0);
  return date.getFullYear() === day.year && date.getMonth() + 1 === day.month && date.getDate() === day.day;
};
export const fromDayString = value => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const day = {year: Number(value.slice(0,4)), month: Number(value.slice(5,7)), day: Number(value.slice(8,10))};
  return validDay(day) ? day : null;
};
export const today = () => isoDay(new Date());
export const tomorrow = () => addDays(new Date(), 1);

function dateIn(text, now = new Date()) {
  const lower = text.toLowerCase();
  if (/\btomorrow\b/.test(lower)) return addDays(now, 1);
  if (/\b(today|tonight)\b/.test(lower)) return isoDay(now);
  if (/\bthis weekend\b/.test(lower)) {
    const untilSaturday = (6 - now.getDay() + 7) % 7;
    return addDays(now, untilSaturday);
  }
  if (/\bthis week\b/.test(lower)) return addDays(now, Math.max(1, 7 - now.getDay()));
  if (/\bnext week\b/.test(lower)) return addDays(now, 7);
  const written = lower.match(/\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?\b/);
  if (written) {
    const year = written[3] ? Number(written[3].length === 2 ? `20${written[3]}` : written[3]) : now.getFullYear();
    const candidate = new Date(year, Number(written[2])-1, Number(written[1]), 12);
    if (candidate.getDate() === Number(written[1]) && candidate.getMonth()+1 === Number(written[2])) return isoDay(candidate);
    return null;
  }
  const named = lower.match(/\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+(\d{4}))?\b/);
  if (named) {
    const month = months.findIndex(value => value.startsWith(named[2].slice(0, 3)));
    const year = named[3] ? Number(named[3]) : now.getFullYear();
    const candidate = new Date(year, month, Number(named[1]), 12);
    if (candidate.getDate() === Number(named[1]) && candidate.getMonth() === month) {
      if (!named[3] && candidate < new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12)) candidate.setFullYear(year + 1);
      return isoDay(candidate);
    }
    return null;
  }
  for (const [weekday, name] of weekdays.entries()) {
    if (!new RegExp(`\\b${name}\\b`).test(lower)) continue;
    let delta = (weekday - now.getDay() + 7) % 7;
    if (!delta) delta = 7;
    return addDays(now, delta);
  }
  return null;
}

function durationIn(text, fallback = 30) {
  const match = text.match(/\b(?:around|about|roughly|approx(?:imately)?\.?\s*)?(\d{1,3})\s*(minutes?|mins?|m|hours?|hrs?|h)\b/i);
  if (!match) return fallback;
  return Math.min(480, Math.max(5, Number(match[1]) * (/^h/i.test(match[2]) ? 60 : 1)));
}

function timeIn(text) {
  const match = text.match(/\b(?:at\s+)?(\d{1,2})(?::(\d{2}))\s*(am|pm)?\b|\b(?:at\s+)?(\d{1,2})\s*(am|pm)\b/i);
  if (!match) return null;
  let hour = Number(match[1] ?? match[4]);
  const minute = Number(match[2] ?? 0);
  const meridian = (match[3] ?? match[5] ?? "").toLowerCase();
  if (meridian && (hour < 1 || hour > 12)) return null;
  if (meridian === "pm" && hour < 12) hour += 12;
  if (meridian === "am" && hour === 12) hour = 0;
  return hour < 24 && minute < 60 ? hour * 60 + minute : null;
}

function contextID(line, items, aliases = {}) {
  const lower = line.toLowerCase();
  return items.find(item => {
    const names = [item.title.toLowerCase(), ...(aliases[item.title.toLowerCase()] || [])];
    return names.some(name => new RegExp(`\\b${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i").test(lower));
  })?.id ?? null;
}

function cleanedTitle(line) {
  return line
    .replace(/\b(?:for\s+)?(?:around|about|roughly|approx(?:imately)?\.?\s*)?\d{1,3}\s*(?:minutes?|mins?|m|hours?|hrs?|h)\b/gi, "")
    .replace(/\b(?:(?:on|by|due)\s+)?(?:today|tonight|tomorrow|this weekend|sometime this weekend|this week|next week|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/gi, "")
    .replace(/\b(?:(?:on|by|due)\s+)?\d{1,2}(?:st|nd|rd|th)?\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+\d{4})?\b/gi, "")
    .replace(/\b(?:(?:on|by|due)\s+)?\d{1,2}[/.]\d{1,2}(?:[/.]\d{2,4})?\b/g, "")
    .replace(/\b(?:high priority|medium priority|low priority|urgent|important|don['’]t schedule|do not schedule|no schedule|before|around|each)\b/gi, "")
    .replace(/\b(?:at\s*)?\d{1,2}:\d{2}\s*(?:am|pm)?\b|\b(?:at\s*)?\d{1,2}\s*(?:am|pm)\b/gi, "")
    .replace(/^[\s\-•☐□*\d.)]+/, "")
    .replace(/\s+/g, " ").trim()
    .replace(/^[,.:;!?\s]+|[,.:;!?\s]+$/g, "")
    .replace(/^[a-z]/, match => match.toUpperCase());
}

function draft(line, data, inheritedDay, now) {
  const explicitDay = dateIn(line, now);
  const day = explicitDay ?? inheritedDay;
  const time = timeIn(line);
  const noSchedule = /\b(?:don['’]t schedule|do not schedule|no schedule|unscheduled)\b/i.test(line);
  const intent = /\b(?:schedule|plan|put on calendar|tonight|at\s+\d+)\b/i.test(line) && !noSchedule;
  const event = /\b(?:meeting|appointment|lesson|class|call|dinner|lunch|exam|match|rehearsal)\b/i.test(line) && time !== null;
  const actionTask = /^(?:revise|study|prepare|practice|finish|do|write|read|make|learn|complete)\b/i.test(line.trim());
  const testDate = day && !actionTask && /\b(?:test|exam|assessment|mock)\b/i.test(line) && time === null;
  const deadline = day && !actionTask && /\bdeadline\b/i.test(line) && time === null;
  const title = cleanedTitle(line).replace(/^(?:Add|Move)\s+/i, "").replace(/\s+to$/i, "").trim();
  if (!title || /^[x✓✗✔☒]/i.test(line.trim())) return null;
  const subjectID = contextID(line, data.subjects || [], {
    mathematics: ["maths", "math"], "english language": ["english", "english lang"], "english literature": ["english lit"],
    chemistry: ["chem"], physics: ["phys"], biology: ["bio"], geography: ["geog"],
  });
  const projectID = contextID(line, data.projects || []);
  const move = /^move\s+/i.test(line);
  const existing = move ? (data.tasks || []).find(task => !task.isCompleted && task.title.toLowerCase().includes(title.toLowerCase())) : null;
  return {
    id: crypto.randomUUID(), included: true, title, kind: testDate || deadline ? "date" : event ? "event" : "task",
    category: testDate ? "Test" : deadline ? "Deadline" : null,
    dueDay: move ? null : day, scheduledDay: intent || move ? day : null,
    startMinutes: noSchedule ? null : time, estimatedMinutes: durationIn(line, data.settings?.defaultTaskMinutes || 30),
    priority: /\b(?:urgent|high priority|important)\b/i.test(line) ? "high" : /\bmedium priority\b/i.test(line) ? "medium" : /\blow priority\b/i.test(line) ? "low" : "none",
    subjectID, projectID, notes: "", existingID: existing?.id ?? null,
    originalText: line,
    needsReview: Boolean((move && !existing) || (!explicitDay && /\b\d{1,2}(?:st|nd|rd|th)?(?:[/.]\d{1,2}|\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec))/i.test(line)) || (!noSchedule && time !== null && !day) || (!noSchedule && time === null && /\bat\s+\d{1,2}(?::\d{2})?\b/i.test(line))),
    reviewReason: !noSchedule && time === null && /\bat\s+\d{1,2}(?::\d{2})?\b/i.test(line) ? "The time is invalid or ambiguous. Check the original input." : !noSchedule && time !== null && !day ? "A time needs a planned day. The due date does not schedule work." : null,
  };
}

export function interpretText(text, data, now = new Date()) {
  const lines = text.replace(/[•]/g, "\n").split(/[\n;]+/).map(line => line.trim()).filter(Boolean);
  const proposals = [];
  let headingDay = null;
  for (const line of lines) {
    if (/^(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this weekend)(?:\s+(?:planner|plan|tasks|to-?do))?\s*:?$/i.test(line)) {
      headingDay = dateIn(line, now); continue;
    }
    const paired = line.match(/^\s*([\w ]+?)\s+and\s+([\w ]+?)\s+(tonight|today|tomorrow|this weekend)\b(.+)$/i);
    if (paired && /\beach\b/i.test(paired[4])) {
      for (const item of [paired[1], paired[2]]) {
        const parsed = draft(`${item} ${paired[3]} ${paired[4]}`, data, headingDay, now);
        if (parsed) proposals.push(parsed);
      }
    } else {
      const parsed = draft(line, data, headingDay, now);
      if (parsed) proposals.push(parsed);
    }
  }
  return proposals;
}

export function previewPhotoWithTypedText(typedText, photoText, confidence, data, now = new Date()) {
  const typed = interpretText(typedText, data, now);
  const photo = interpretText(photoText, data, now);
  if (confidence < 72) photo.forEach(item => {
    item.needsReview = true;
    item.included = false;
    item.reviewReason = "Photo text may be inaccurate. Check the title and date, then tick Include to add it.";
  });
  return [...typed, ...photo];
}
