// JavaScript twin of NaturalLanguageTaskParser (Sources/LifeBoardCore/CaptureParsing.swift).
// Keep the rewrite rules, subject table and title cleaning identical in both.
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

const numericDatePattern = /\b(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?\b/i;
const namedDateBody = String.raw`(?<![:.])\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+(\d{4}))?\b`;
const namedDatePattern = new RegExp(namedDateBody, "i");
const comingSaturday = now => addDays(now, (6 - now.getDay() + 7) % 7);

function dateIn(text, now = new Date()) {
  const lower = text.toLowerCase();
  if (/\bday after tomorrow\b/.test(lower)) return addDays(now, 2);
  if (/\btomorrow\b/.test(lower)) return addDays(now, 1);
  if (/\b(today|tonight)\b/.test(lower)) return isoDay(now);
  if (/\bthis weekend\b/.test(lower)) return comingSaturday(now);
  if (/\bnext weekend\b/.test(lower)) return addDays(asDate(comingSaturday(now)), 7);
  if (/\bthis week\b/.test(lower)) return addDays(now, Math.max(1, 7 - now.getDay()));
  if (/\bnext week\b/.test(lower)) return addDays(now, 7);
  const written = lower.match(numericDatePattern);
  if (written) {
    const year = written[3] ? Number(written[3].length === 2 ? `20${written[3]}` : written[3]) : now.getFullYear();
    const candidate = new Date(year, Number(written[2])-1, Number(written[1]), 12);
    if (candidate.getDate() === Number(written[1]) && candidate.getMonth()+1 === Number(written[2])) return isoDay(candidate);
    return null;
  }
  const named = lower.match(namedDatePattern);
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

// Title cleaning. A removed token leaves a mark so a preposition left
// dangling in front of it ("due", "by", "at") can go too.
const removedMark = "\u0001";
const titleTokenPatterns = [
  String.raw`\b(?:for\s+)?(?:(?:around|about|roughly|approx(?:imately)?\.?)\s*)?\d{1,3}\s*(?:minutes?|mins?|m|hours?|hrs?|h)\b`,
  String.raw`\b(?:the\s+day\s+after\s+tomorrow|day\s+after\s+tomorrow|sometime\s+this\s+weekend|sometime\s+this\s+week|this\s+weekend|next\s+weekend|this\s+week|next\s+week|today|tonight|tomorrow|(?:(?:this|next)\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b`,
  namedDateBody,
  numericDatePattern.source,
  String.raw`\b(?:urgent|high priority|medium priority|low priority|important)\b`,
  String.raw`\b(?:at\s*)?\d{1,2}:\d{2}\s*(?:am|pm)?\b|\b(?:at\s*)?\d{1,2}\s*(?:am|pm)\b`,
  String.raw`\banytime\b`,
].map(source => new RegExp(source, "gi"));

function cleanedTitle(line) {
  let result = line;
  for (const pattern of titleTokenPatterns) result = result.replace(pattern, ` ${removedMark} `);
  return result
    .replace(/\b(?:don['’]t schedule|do not schedule|no schedule|unscheduled|around|each)\b/gi, "")
    .replace(/(?:\b(?:due|by|on|at|until|before)\s+)*\u0001/gi, " ")
    .replace(/^[\s\-•☐□*\d.)]+/, "")
    .replace(/\s+/g, " ").trim()
    .replace(/^[,.:;!?\s]+|[,.:;!?\s]+$/g, "")
    .replace(/^[a-z]/, match => match.toUpperCase());
}

// Abbreviations. Each rule rewrites shorthand to the one spelling the parser
// reads; every rewritten token is later removed from the title, so subject
// words and everything else stay exactly as typed.
const wordStart = String.raw`(?<![\p{L}\p{N}'’-])`;
const wordEnd = String.raw`(?![\p{L}\p{N}'’-])`;
const rewrite = (source, replace) => [new RegExp(source, "giu"), typeof replace === "string" ? () => replace : replace];
const minutesPhrase = total => `${Math.min(total, 480)} minutes`;
// Full weekday name, or null when written in capitals (SAT, SUN), which is
// far more often an acronym than a day.
const weekdayName = token => token === token.toUpperCase() ? null : weekdays.find(name => name.startsWith(token.toLowerCase().slice(0, 2)));

const rewrites = [
  rewrite(String.raw`[ \t]+`, " "),
  rewrite(String.raw`!{2,}`, " high priority "),
  rewrite(String.raw`(^|\s)@\s*(?=\d|noon\b|midday\b)`, g => (g[1] ?? "") + "at "),
  rewrite(String.raw`\b12\s*(?:noon|midday)\b`, "12pm"),
  rewrite(String.raw`\b(?:noon|midday)\b`, "12pm"),
  rewrite(String.raw`\b(\d{1,2}(?::\d{2})?)\s*([ap])\.\s?m\.?(?![\p{L}\p{N}])`, g => g[1] + g[2].toLowerCase() + "m"),
  // "3p" alone is a time; "3a" needs "at" or minutes because "ex 3a" is usually a question part.
  rewrite(String.raw`(?<![\p{L}\p{N}:])(at\s+)?(\d{1,2}(?::\d{2})?)([ap])(?![\p{L}\p{N}.'’-])`, g => {
    const letter = g[3].toLowerCase();
    if (g[1] === undefined && !g[2].includes(":") && letter !== "p") return null;
    return (g[1] ?? "") + g[2] + letter + "m";
  }),
  rewrite(String.raw`\b(?:a\s+)?quarter\s+(?:of\s+an\s+)?hour\b`, "15 minutes"),
  rewrite(String.raw`\b(?:an|one)\s+hour\s+and\s+a\s+half\b`, "90 minutes"),
  rewrite(String.raw`\b(?:a\s+)?half\s+(?:an\s+)?hour\b`, "30 minutes"),
  rewrite(String.raw`\b(?:an|one)\s+hour\b`, "60 minutes"),
  rewrite(String.raw`\b(\d{1,2})\.(\d{1,2})\s*(?:h|hrs?|hours?)\b`, g => minutesPhrase(Math.round(Number(`${g[1]}.${g[2]}`) * 60))),
  rewrite(String.raw`\b(\d{1,2})\s*(?:h|hrs?|hours?)\s*(?:and\s+)?(\d{1,2})\s*(?:m|mins?|minutes?)\b`, g => minutesPhrase(Number(g[1]) * 60 + Number(g[2]))),
  rewrite(String.raw`\b(\d{1,2})\s*(?:h|hrs?)(\d{1,2})\b`, g => minutesPhrase(Number(g[1]) * 60 + Number(g[2]))),
  rewrite(wordStart + String.raw`(?:tmrw?|tmw|tmro|tomo|2moro|2mrw)` + wordEnd, "tomorrow"),
  rewrite(wordStart + String.raw`(?:tdy|2day)` + wordEnd, "today"),
  rewrite(wordStart + String.raw`(?:tonite|2nite)` + wordEnd, "tonight"),
  rewrite(String.raw`\b(?:next|nxt)\s+(?:weekend|wknd|wkend)\b`, "next weekend"),
  rewrite(String.raw`\b(?:(?:at|on|over)\s+)?(?:the|this)\s+(?:weekend|wknd|wkend)\b`, "this weekend"),
  rewrite(String.raw`(?<!next\s)(?<!last\s)(?<!this\s)(?<!every\s)` + wordStart + String.raw`(?:weekend|wknd|wkend)` + wordEnd, "this weekend"),
  rewrite(String.raw`\b(?:next|nxt)\s+(?:wk|week)\b`, "next week"),
  rewrite(String.raw`\bthis\s+wk\b`, "this week"),
  rewrite(wordStart + String.raw`(mon|tues?|weds?|thu(?:rs?)?|fri)\.?` + wordEnd, g => weekdayName(g[1])),
  // "sat" and "sun" are ordinary words too, so they need a date word before them or the end of the line.
  rewrite(String.raw`\b(on|by|due|this|next|until|before)(\s+)(sat|sun)\.?` + wordEnd, g => { const name = weekdayName(g[3]); return name ? g[1] + g[2] + name : null; }),
  rewrite(String.raw`(?<!the\s)` + wordStart + String.raw`(sat|sun)\.?(?=\s*[.!?:]?\s*$)`, g => weekdayName(g[1])),
  // Month first ("nov 3rd") becomes day first, unless a day number already precedes the month ("3 nov 4").
  rewrite(String.raw`(?<![^\d:.]\d\s)(?<![^\d:.]\d\d\s)(?<!^\d\s)(?<!^\d\d\s)(?<!\d(?:st|nd|rd|th)\s)` + wordStart + String.raw`(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?![\p{L}\p{N}:'’-]|\.\d)(?!\s*(?:[ap]\.?m\b|minutes?\b|mins?\b|hours?\b|hrs?\b|h\b|m\b))(?:,?\s+(\d{4})(?![\p{L}\p{N}]))?`,
    g => `${g[2]} ${g[1]}${g[3] === undefined ? "" : ` ${g[3]}`}`),
  rewrite(String.raw`\basap\b`, "high priority"),
  rewrite(String.raw`\b(?:hi|high)\s+pri(?:o|ority)?\b`, "high priority"),
  rewrite(String.raw`\b(?:med|medium)\s+pri(?:o|ority)?\b`, "medium priority"),
  rewrite(String.raw`\blow\s+pri(?:o|ority)?\b`, "low priority"),
  rewrite(String.raw`\b(?:anytime|any\s+time|someday|some\s+day|no\s+date|whenever|undated)\b`, "anytime"),
];

function applyRewrite([regex, replace], text) {
  return text.replace(regex, (...args) => {
    const groups = args.slice(0, args.findIndex(arg => typeof arg === "number"));
    return replace(groups) ?? args[0];
  });
}

function normalised(text, subjects) {
  return rewrites.reduce((line, rule) => applyRewrite(rule, line), replacingPriorityCode(text, subjects));
}

// Title forms and the shorthand students use for them. A subject whose title
// contains a form also answers to every name in its group.
const subjectAliasGroups = [
  [["further mathematics", "further maths", "further math"], ["fm"]],
  [["mathematics", "maths", "math"], []],
  [["english language", "english lang"], ["eng lang", "lang", "english", "eng"]],
  [["english literature", "english lit"], ["eng lit", "lit"]],
  [["english"], ["eng"]],
  [["chemistry"], ["chem"]],
  [["physics"], ["phys"]],
  [["biology"], ["bio"]],
  [["geography"], ["geog", "geo"]],
  [["history"], ["hist"]],
  [["economics"], ["econ", "econs"]],
  [["psychology"], ["psych"]],
  [["sociology"], ["soc"]],
  [["politics"], ["pol"]],
  [["philosophy"], ["phil", "philo"]],
  [["music"], ["mus"]],
  [["computer science"], ["comp sci", "compsci", "cs"]],
  [["french"], ["fr"]],
  [["spanish"], ["sp", "span"]],
  [["german"], ["ger"]],
  [["latin"], ["lat"]],
  [["business"], ["bus", "biz"]],
  [["statistics"], ["stats"]],
];
const initialsConnectors = new Set(["and", "of", "the", "for"]);
// Lower-case initials that are ordinary words; typed in capitals they still count.
const initialsStoplist = new Set(["re", "am", "pm", "to", "in", "on", "at", "by", "of", "it", "is", "as", "an", "or", "do", "go", "me", "my", "no", "so", "up", "we", "us", "be", "he", "if",
  "id", "ok", "hi", "oh", "ah", "eh", "ex", "ch", "pg", "pp", "qs", "hw", "ws", "nb", "eg", "ie", "vs", "mr", "ms", "dr", "st"]);
const isLetters = text => /^\p{L}+$/u.test(text);

// Words with UTF-16 offsets (the same as Swift's NSString offsets). Edge
// apostrophes and hyphens and a possessive "'s" are not part of the word.
function tokens(text) {
  const words = [];
  for (const match of text.matchAll(/[\p{L}\p{N}'’-]+/gu)) {
    let start = match.index, end = start + match[0].length;
    while (start < end && "'’-".includes(text[start])) start++;
    while (end > start && "'’-".includes(text[end - 1])) end--;
    if (end - start > 2 && "sS".includes(text[end - 1]) && "'’".includes(text[end - 2])) end -= 2;
    if (end <= start) continue;
    const word = text.slice(start, end);
    words.push({ text: word, lower: word.toLowerCase(), start, end });
  }
  return words;
}

function subjectNames(title) {
  const titleWords = tokens(title).map(word => word.lower);
  if (!titleWords.length) return { titleWords, names: [] };
  const contains = part => part.length > 0 && part.length <= titleWords.length
    && titleWords.some((_, start) => start + part.length <= titleWords.length && part.every((word, offset) => titleWords[start + offset] === word));
  const names = [{ words: titleWords, extra: 0 }];
  for (const [forms, aliases] of subjectAliasGroups) {
    const extras = forms.map(form => tokens(form).map(word => word.lower)).filter(contains).map(form => titleWords.length - form.length);
    if (!extras.length) continue;
    const extra = Math.min(...extras);
    for (const name of [...forms, ...aliases]) names.push({ words: tokens(name).map(word => word.lower), extra });
  }
  return { titleWords, names };
}

function subjectCandidates(words, subjects) {
  const candidates = [];
  subjects.forEach((subject, index) => {
    const { titleWords, names } = subjectNames(subject.title || "");
    if (!titleWords.length) return;
    for (const name of names) {
      if (!name.words.length || name.words.length > words.length) continue;
      for (let first = 0; first + name.words.length <= words.length; first++) {
        if (!name.words.every((word, offset) => words[first + offset].lower === word)) continue;
        const last = first + name.words.length - 1;
        candidates.push({ index, first, last, length: words[last].end - words[first].start, extra: name.extra });
      }
    }
    if (titleWords.length === 1) {
      // "chem" or "hist": four or more letters that begin a one-word title.
      const [title] = titleWords;
      words.forEach((word, position) => {
        if (word.lower.length >= 4 && word.lower.length < title.length && isLetters(word.lower) && title.startsWith(word.lower)) {
          candidates.push({ index, first: position, last: position, length: word.end - word.start, extra: 0 });
        }
      });
    } else {
      // "CS", "DT", "PE": initials of a multi-word title.
      const initials = titleWords.filter(word => !initialsConnectors.has(word)).map(word => word[0]).join("");
      if (initials.length < 2) return;
      words.forEach((word, position) => {
        if (word.lower !== initials || !isLetters(word.text)) return;
        const capitals = word.text === word.text.toUpperCase();
        if (!capitals && initialsStoplist.has(word.lower)) return;
        if (["am", "pm"].includes(word.lower) && position > 0 && /^\p{N}+$/u.test(words[position - 1].text)) return;
        candidates.push({ index, first: position, last: position, length: word.end - word.start, extra: 0 });
      });
    }
  });
  return candidates;
}

// The most specific subject named in the text: the longest matched text, then
// the title with the fewest extra words, then the first listed.
function subjectFor(text, subjects) {
  let best = null;
  for (const candidate of subjectCandidates(tokens(text), subjects)) {
    if (!best || candidate.length > best.length || (candidate.length === best.length && (candidate.extra < best.extra || (candidate.extra === best.extra && candidate.index < best.index)))) best = candidate;
  }
  return best ? subjects[best.index] : null;
}

// Words that make a trailing "P1" read as Paper 1 rather than a priority.
const priorityCodeGuards = new Set([
  ...subjectAliasGroups.flatMap(([forms, aliases]) => [...forms, ...aliases].flatMap(name => name.split(" "))),
  "paper", "papers", "pp", "past", "mock", "mocks", "exam", "exams", "test", "tests", "unit", "component", "section", "q", "question", "questions", "qs", "ch", "chapter", "ex", "exercise", "pg", "page", "and", "or",
  "art", "drama", "dance", "media", "science", "sciences", "ict", "it", "re", "rs", "pe", "dt", "religious", "studies", "technology", "design",
]);

// "p1", "p2" and "p3" set the priority only as the last word, and never
// straight after a subject or exam word ("Maths P1" is Paper 1).
function replacingPriorityCode(text, subjects) {
  const match = text.match(/(?<![\p{L}\p{N}'’-])p([123])[.!]?\s*$/iu);
  if (!match) return text;
  const words = tokens(text);
  const previous = words.findLastIndex(word => word.end <= match.index);
  if (previous >= 0) {
    if (priorityCodeGuards.has(words[previous].lower)) return text;
    if (subjectCandidates(words, subjects).some(candidate => candidate.last === previous)) return text;
  }
  const level = { 1: "high", 2: "medium", 3: "low" }[match[1]];
  return `${text.slice(0, match.index)} ${level} priority`;
}

function draft(source, line, data, inheritedDay, now) {
  const explicitDay = dateIn(line, now);
  const dateMentioned = numericDatePattern.test(line) || namedDatePattern.test(line);
  // A typed date always wins; "anytime" only clears an inherited heading day.
  const anytime = !explicitDay && !dateMentioned && /\banytime\b/i.test(line);
  const day = anytime ? null : explicitDay ?? inheritedDay;
  const time = timeIn(line);
  const noSchedule = /\b(?:don['’]t schedule|do not schedule|no schedule|unscheduled)\b/i.test(line);
  const intent = /\b(?:schedule|plan|put on calendar|tonight|at\s+\d+)\b/i.test(line) && !noSchedule;
  const event = /\b(?:meeting|appointment|lesson|class|call|dinner|lunch|exam|match|rehearsal)\b/i.test(line) && time !== null;
  const actionTask = /^(?:revise|study|prepare|practice|finish|do|write|read|make|learn|complete)\b/i.test(line.trim());
  const testDate = day && !actionTask && /\b(?:test|exam|assessment|mock)\b/i.test(line) && time === null;
  const deadline = day && !actionTask && /\bdeadline\b/i.test(line) && time === null;
  const title = cleanedTitle(line).replace(/^(?:Add|Move)\s+/i, "").replace(/\s+to$/i, "").trim();
  if (!title || /^[x✓✗✔☒]/i.test(line.trim())) return null;
  const subjectID = subjectFor(source, data.subjects || [])?.id ?? null;
  const projectID = contextID(source, data.projects || []);
  const move = /^move\s+/i.test(line);
  const existing = move ? (data.tasks || []).find(task => !task.isCompleted && task.title.toLowerCase().includes(title.toLowerCase())) : null;
  return {
    id: crypto.randomUUID(), included: true, title, kind: testDate || deadline ? "date" : event ? "event" : "task",
    category: testDate ? "Test" : deadline ? "Deadline" : null,
    dueDay: move ? null : day, scheduledDay: intent || move ? day : null,
    startMinutes: noSchedule ? null : time, estimatedMinutes: durationIn(line, data.settings?.defaultTaskMinutes || 30),
    priority: /\b(?:urgent|high priority|important)\b/i.test(line) ? "high" : /\bmedium priority\b/i.test(line) ? "medium" : /\blow priority\b/i.test(line) ? "low" : "none",
    subjectID, projectID, notes: "", existingID: existing?.id ?? null,
    anytime,
    originalText: source,
    needsReview: Boolean((move && !existing) || (!explicitDay && /(?<![:.])\b\d{1,2}(?:st|nd|rd|th)?(?:[/.]\d{1,2}|\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec))/i.test(line)) || (!noSchedule && time !== null && !day) || (!noSchedule && time === null && /\bat\s+\d{1,2}(?::\d{2})?\b/i.test(line))),
    reviewReason: !noSchedule && time === null && /\bat\s+\d{1,2}(?::\d{2})?\b/i.test(line) ? "The time is invalid or ambiguous. Check the original input." : !noSchedule && time !== null && !day ? "A time needs a planned day. The due date does not schedule work." : null,
  };
}

export function interpretText(text, data, now = new Date()) {
  const lines = text.replace(/[•]/g, "\n").split(/[\n;]+/).map(line => line.trim()).filter(Boolean);
  const proposals = [];
  let headingDay = null;
  for (const source of lines) {
    // Abbreviations are rewritten to their full forms first, so every later
    // rule only has to know one spelling.
    const line = normalised(source, data.subjects || []);
    if (/^(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this weekend)(?:\s+(?:planner|plan|tasks|to-?do))?\s*:?$/i.test(line)) {
      headingDay = dateIn(line, now); continue;
    }
    const paired = line.match(/^\s*([\w ]+?)\s+and\s+([\w ]+?)\s+(tonight|today|tomorrow|this weekend)\b(.+)$/i);
    if (paired && /\beach\b/i.test(paired[4])) {
      for (const item of [paired[1], paired[2]]) {
        const itemText = `${item} ${paired[3]} ${paired[4]}`;
        const parsed = draft(itemText, itemText, data, headingDay, now);
        if (parsed) proposals.push(parsed);
      }
    } else {
      const parsed = draft(source, line, data, headingDay, now);
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
