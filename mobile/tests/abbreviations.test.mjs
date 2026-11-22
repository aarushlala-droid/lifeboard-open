import test from 'node:test';
import assert from 'node:assert/strict';
import {interpretText, dayString} from '../web/capture.js';

// Shared Swift/JS abbreviation corpus. Tests/Planning/main.swift reads the JSON
// between the markers below, so both parsers are held to the same results.
// Keep it strict JSON. The reference day 2026-11-07 is a Saturday.
const corpus = /* abbreviation-corpus:start */ {
 "reference": "2026-11-07",
 "defaultMinutes": 25,
 "subjects": ["Mathematics", "Further Mathematics", "English Language", "English Literature", "Chemistry", "History", "Computer Science", "Design Technology", "Physical Education", "Religious Studies", "Religious Education", "Information Technology", "Spanish", "Business"],
 "cases": [
  {"input": "chem hw tmr", "title": "Chem hw", "day": "2026-11-08", "subject": "Chemistry"},
  {"input": "essay tmrw", "title": "Essay", "day": "2026-11-08"},
  {"input": "essay tmw", "title": "Essay", "day": "2026-11-08"},
  {"input": "essay tmro", "title": "Essay", "day": "2026-11-08"},
  {"input": "essay tomo", "title": "Essay", "day": "2026-11-08"},
  {"input": "essay 2moro", "title": "Essay", "day": "2026-11-08"},
  {"input": "essay 2mrw", "title": "Essay", "day": "2026-11-08"},
  {"input": "Essay TMR", "title": "Essay", "day": "2026-11-08"},
  {"input": "read notes tdy", "title": "Read notes", "day": "2026-11-07"},
  {"input": "read notes 2day", "title": "Read notes", "day": "2026-11-07"},
  {"input": "revise tonite", "title": "Revise", "day": "2026-11-07"},
  {"input": "revise 2nite", "title": "Revise", "day": "2026-11-07"},
  {"input": "essay day after tomorrow", "title": "Essay", "day": "2026-11-09"},
  {"input": "essay the day after tmr", "title": "Essay", "day": "2026-11-09"},

  {"input": "essay due mon", "title": "Essay", "day": "2026-11-09"},
  {"input": "quiz tue.", "title": "Quiz", "day": "2026-11-10"},
  {"input": "lab report due tues", "title": "Lab report", "day": "2026-11-10"},
  {"input": "film club wed", "title": "Film club", "day": "2026-11-11"},
  {"input": "drama weds", "title": "Drama", "day": "2026-11-11"},
  {"input": "maths hw thu", "title": "Maths hw", "day": "2026-11-12", "subject": "Mathematics"},
  {"input": "maths hw thur", "title": "Maths hw", "day": "2026-11-12", "subject": "Mathematics"},
  {"input": "maths hw thurs", "title": "Maths hw", "day": "2026-11-12", "subject": "Mathematics"},
  {"input": "essay by Fri", "title": "Essay", "day": "2026-11-13"},
  {"input": "netball on sat", "title": "Netball", "day": "2026-11-14"},
  {"input": "revise sun", "title": "Revise", "day": "2026-11-08"},
  {"input": "essay next mon", "title": "Essay", "day": "2026-11-09"},
  {"input": "essay next monday", "title": "Essay", "day": "2026-11-09"},
  {"input": "essay this sat", "title": "Essay", "day": "2026-11-14"},
  {"input": "essay due saturday", "title": "Essay", "day": "2026-11-14"},
  {"input": "practise for SAT on sat", "title": "Practise for SAT", "day": "2026-11-14"},
  {"input": "SAT prep", "title": "SAT prep"},
  {"input": "sat the test", "title": "Sat the test"},
  {"input": "buy sun cream", "title": "Buy sun cream"},
  {"input": "revise for SAT", "title": "Revise for SAT"},
  {"input": "SUN", "title": "SUN"},
  {"input": "fix sat-nav", "title": "Fix sat-nav"},
  {"input": "c'mon team", "title": "C'mon team"},
  {"input": "lie in the sun", "title": "Lie in the sun"},

  {"input": "plan coursework nxt wk", "title": "Plan coursework", "day": "2026-11-14"},
  {"input": "plan coursework next wk", "title": "Plan coursework", "day": "2026-11-14"},
  {"input": "plan coursework next week", "title": "Plan coursework", "day": "2026-11-14"},
  {"input": "tidy room this wk", "title": "Tidy room", "day": "2026-11-08"},
  {"input": "hike wknd", "title": "Hike", "day": "2026-11-07"},
  {"input": "hike this wknd", "title": "Hike", "day": "2026-11-07"},
  {"input": "hike wkend", "title": "Hike", "day": "2026-11-07"},
  {"input": "hike at the weekend", "title": "Hike", "day": "2026-11-07"},
  {"input": "weekend hike", "title": "Hike", "day": "2026-11-07"},
  {"input": "hike next weekend", "title": "Hike", "day": "2026-11-14"},

  {"input": "essay due 3 sept", "title": "Essay", "day": "2027-09-03"},
  {"input": "essay due 3 nov", "title": "Essay", "day": "2027-11-03"},
  {"input": "essay due nov 3", "title": "Essay", "day": "2027-11-03"},
  {"input": "essay due Nov 30th", "title": "Essay", "day": "2026-11-30"},
  {"input": "mock dec 1", "title": "Mock", "day": "2026-12-01"},
  {"input": "trip sept 5 2027", "title": "Trip", "day": "2027-09-05"},
  {"input": "essay nov 31", "title": "Essay", "review": true},
  {"input": "lunch dec 5 at 1pm", "title": "Lunch", "day": "2026-12-05", "time": 780},
  {"input": "lunch noon dec 31", "title": "Lunch", "day": "2026-12-31", "time": 720},
  {"input": "meet at 15:30 dec 5", "title": "Meet", "day": "2026-12-05", "time": 930},
  {"input": "print 3 nov 4 copies", "title": "Print 4 copies", "day": "2027-11-03"},

  {"input": "call Priya tmr @3pm", "title": "Call Priya", "day": "2026-11-08", "time": 900},
  {"input": "meet tmr @ 15:30", "title": "Meet", "day": "2026-11-08", "time": 930},
  {"input": "meet @ 3pm tmr", "title": "Meet", "day": "2026-11-08", "time": 900},
  {"input": "gym tmr at 6p", "title": "Gym", "day": "2026-11-08", "time": 1080},
  {"input": "gym tmr 6p", "title": "Gym", "day": "2026-11-08", "time": 1080},
  {"input": "gym tmr @7a", "title": "Gym", "day": "2026-11-08", "time": 420},
  {"input": "gym tmr 3 p.m.", "title": "Gym", "day": "2026-11-08", "time": 900},
  {"input": "gym tmr 9 a.m.", "title": "Gym", "day": "2026-11-08", "time": 540},
  {"input": "meet tmr 3:30p", "title": "Meet", "day": "2026-11-08", "time": 930},
  {"input": "lunch tmr at noon", "title": "Lunch", "day": "2026-11-08", "time": 720},
  {"input": "study tmr midday", "title": "Study", "day": "2026-11-08", "time": 720},
  {"input": "do ex 3a tmr", "title": "Do ex 3a", "day": "2026-11-08"},
  {"input": "read 1530 pages tmr", "title": "Read 1530 pages", "day": "2026-11-08"},
  {"input": "do 20 questions tmr", "title": "Do 20 questions", "day": "2026-11-08"},
  {"input": "meet tmr @ 25:00", "title": "Meet", "day": "2026-11-08", "review": true},
  {"input": "email jo@example.com tmr", "title": "Email jo@example.com", "day": "2026-11-08"},

  {"input": "revise 1.5h", "title": "Revise", "minutes": 90},
  {"input": "revise 1.5 hrs", "title": "Revise", "minutes": 90},
  {"input": "revise 1h30", "title": "Revise", "minutes": 90},
  {"input": "revise 1h 30m", "title": "Revise", "minutes": 90},
  {"input": "revise 1hr30", "title": "Revise", "minutes": 90},
  {"input": "revise 2 hours 15 mins", "title": "Revise", "minutes": 135},
  {"input": "revise for half an hour", "title": "Revise", "minutes": 30},
  {"input": "revise half hour", "title": "Revise", "minutes": 30},
  {"input": "revise for an hour", "title": "Revise", "minutes": 60},
  {"input": "revise one hour", "title": "Revise", "minutes": 60},
  {"input": "revise for a quarter of an hour", "title": "Revise", "minutes": 15},
  {"input": "revise for an hour and a half", "title": "Revise", "minutes": 90},
  {"input": "revise about 40 mins", "title": "Revise", "minutes": 40},
  {"input": "revise 9h", "title": "Revise", "minutes": 480},
  {"input": "revise 0.05h", "title": "Revise", "minutes": 5},

  {"input": "essay!!", "title": "Essay", "priority": "high"},
  {"input": "essay !!!", "title": "Essay", "priority": "high"},
  {"input": "essay asap", "title": "Essay", "priority": "high"},
  {"input": "essay urgent", "title": "Essay", "priority": "high"},
  {"input": "essay hi pri", "title": "Essay", "priority": "high"},
  {"input": "essay high pri", "title": "Essay", "priority": "high"},
  {"input": "essay p1", "title": "Essay", "priority": "high"},
  {"input": "essay med pri", "title": "Essay", "priority": "medium"},
  {"input": "essay p2", "title": "Essay", "priority": "medium"},
  {"input": "essay low pri", "title": "Essay", "priority": "low"},
  {"input": "essay P3", "title": "Essay", "priority": "low"},
  {"input": "maths hw tmr p1", "title": "Maths hw", "day": "2026-11-08", "priority": "high", "subject": "Mathematics"},
  {"input": "maths p1", "title": "Maths p1", "subject": "Mathematics"},
  {"input": "Chemistry P2", "title": "Chemistry P2", "subject": "Chemistry"},
  {"input": "physics p2", "title": "Physics p2"},
  {"input": "past paper p1", "title": "Past paper p1"},
  {"input": "p1 essay", "title": "P1 essay"},

  {"input": "maths hw", "title": "Maths hw", "subject": "Mathematics"},
  {"input": "math hw", "title": "Math hw", "subject": "Mathematics"},
  {"input": "further maths hw", "title": "Further maths hw", "subject": "Further Mathematics"},
  {"input": "fm ex 4", "title": "Fm ex 4", "subject": "Further Mathematics"},
  {"input": "eng lit essay", "title": "Eng lit essay", "subject": "English Literature"},
  {"input": "lit essay", "title": "Lit essay", "subject": "English Literature"},
  {"input": "english lit essay", "title": "English lit essay", "subject": "English Literature"},
  {"input": "eng lang essay", "title": "Eng lang essay", "subject": "English Language"},
  {"input": "lang essay", "title": "Lang essay", "subject": "English Language"},
  {"input": "eng essay", "title": "Eng essay", "subject": "English Language"},
  {"input": "english essay", "title": "English essay", "subject": "English Language"},
  {"input": "chem ws", "title": "Chem ws", "subject": "Chemistry"},
  {"input": "chemistry's practical", "title": "Chemistry's practical", "subject": "Chemistry"},
  {"input": "hist essay", "title": "Hist essay", "subject": "History"},
  {"input": "histo notes", "title": "Histo notes", "subject": "History"},
  {"input": "his notes", "title": "His notes"},
  {"input": "cs project", "title": "Cs project", "subject": "Computer Science"},
  {"input": "CS project", "title": "CS project", "subject": "Computer Science"},
  {"input": "comp sci hw", "title": "Comp sci hw", "subject": "Computer Science"},
  {"input": "compsci hw", "title": "Compsci hw", "subject": "Computer Science"},
  {"input": "DT coursework", "title": "DT coursework", "subject": "Design Technology"},
  {"input": "dt coursework", "title": "Dt coursework", "subject": "Design Technology"},
  {"input": "PE kit", "title": "PE kit", "subject": "Physical Education"},
  {"input": "RS essay", "title": "RS essay", "subject": "Religious Studies"},
  {"input": "RE homework", "title": "RE homework", "subject": "Religious Education"},
  {"input": "re-read notes", "title": "Re-read notes"},
  {"input": "Re-read notes", "title": "Re-read notes"},
  {"input": "re do notes", "title": "Re do notes"},
  {"input": "do it tonight", "title": "Do it", "day": "2026-11-07"},
  {"input": "IT coursework", "title": "IT coursework", "subject": "Information Technology"},
  {"input": "span vocab", "title": "Span vocab", "subject": "Spanish"},
  {"input": "biz case study", "title": "Biz case study", "subject": "Business"},
  {"input": "chemistry and further maths", "title": "Chemistry and further maths", "subject": "Further Mathematics"},
  {"input": "chemical safety sheet", "title": "Chemical safety sheet"},

  {"input": "tidy desk anytime", "title": "Tidy desk", "anytime": true},
  {"input": "tidy desk any time", "title": "Tidy desk", "anytime": true},
  {"input": "tidy desk someday", "title": "Tidy desk", "anytime": true},
  {"input": "tidy desk some day", "title": "Tidy desk", "anytime": true},
  {"input": "tidy desk no date", "title": "Tidy desk", "anytime": true},
  {"input": "tidy desk whenever", "title": "Tidy desk", "anytime": true},
  {"input": "tidy desk undated", "title": "Tidy desk", "anytime": true},
  {"input": "call gran at any time", "title": "Call gran", "anytime": true},
  {"input": "tidy desk anytime tmr", "title": "Tidy desk", "day": "2026-11-08"},
  {"input": "tidy desk someday 3 dec", "title": "Tidy desk", "day": "2026-12-03"},
  {"input": "tidy desk anytime 31/02", "title": "Tidy desk", "review": true},
  {"input": "tmr:\ntidy desk anytime", "title": "Tidy desk", "anytime": true},
  {"input": "tmr:\nread chapter 2", "title": "Read chapter 2", "day": "2026-11-08"},
  {"input": "fri:\nread chapter 2", "title": "Read chapter 2", "day": "2026-11-13"},
  {"input": "wknd:\nread chapter 2", "title": "Read chapter 2", "day": "2026-11-07"},

  {"input": "essay due on tmr", "title": "Essay", "day": "2026-11-08"},
  {"input": "essay due by fri", "title": "Essay", "day": "2026-11-13"},
  {"input": "essay until fri", "title": "Essay", "day": "2026-11-13"},
  {"input": "essay before fri", "title": "Essay", "day": "2026-11-13"},
  {"input": "revise before mock tmr", "title": "Revise before mock", "day": "2026-11-08"},
  {"input": "carry on tmr", "title": "Carry", "day": "2026-11-08"},
  {"input": "Chem hw due fri @4p 45m !!", "title": "Chem hw", "day": "2026-11-13", "time": 960, "minutes": 45, "priority": "high", "subject": "Chemistry"}
 ]
} /* abbreviation-corpus:end */;

const reference = new Date(2026, 10, 7, 12);
const subjects = corpus.subjects.map((title, index) => ({id: `subject-${index}`, title}));
const data = {subjects, settings: {defaultTaskMinutes: corpus.defaultMinutes}};
const subjectTitle = id => subjects.find(subject => subject.id === id)?.title ?? null;

test('shared Swift/JS abbreviation corpus', () => {
  for (const row of corpus.cases) {
    const [draft] = interpretText(row.input, data, reference);
    assert.ok(draft, row.input);
    assert.deepEqual({
      title: draft.title, day: dayString(draft.dueDay) || null, time: draft.startMinutes, minutes: draft.estimatedMinutes,
      priority: draft.priority, subject: subjectTitle(draft.subjectID), anytime: draft.anytime, review: draft.needsReview,
    }, {
      title: row.title, day: row.day ?? null, time: row.time ?? null, minutes: row.minutes ?? corpus.defaultMinutes,
      priority: row.priority ?? 'none', subject: row.subject ?? null, anytime: row.anytime ?? false, review: row.review ?? false,
    }, row.input);
  }
});

test('abbreviated tonight splits a shared "each" line', () => {
  const split = interpretText('maths and chem tonite 40 mins each', data, reference);
  assert.deepEqual(split.map(item => item.title), ['Maths', 'Chem']);
  assert.deepEqual(split.map(item => subjectTitle(item.subjectID)), ['Mathematics', 'Chemistry']);
  assert.ok(split.every(item => item.estimatedMinutes === 40 && dayString(item.dueDay) === '2026-11-07' && dayString(item.scheduledDay) === '2026-11-07'));
});

test('@ and abbreviations behave exactly like the full words, and the typed text is kept as the original', () => {
  const comparable = ({id, originalText, ...rest}) => rest;
  for (const [short, full] of [['call Priya tmr @3pm', 'call Priya tomorrow at 3pm'], ['meet fri @ 15:30', 'meet friday at 15:30'], ['essay nxt wk p1', 'essay next week high priority']]) {
    const [abbreviated] = interpretText(short, data, reference);
    const [written] = interpretText(full, data, reference);
    assert.deepEqual(comparable(abbreviated), comparable(written), short);
    assert.equal(abbreviated.originalText, short);
  }
  const [timed] = interpretText('meet fri @ 15:30', data, reference);
  assert.equal(dayString(timed.scheduledDay), '2026-11-13');
});

test('anytime is a boolean draft property and clears an inherited heading day', () => {
  const [plain] = interpretText('tidy desk', data, reference);
  assert.equal(plain.anytime, false);
  const [headed] = interpretText('fri:\ntidy desk whenever', data, reference);
  assert.equal(headed.anytime, true);
  assert.equal(headed.dueDay, null);
  assert.equal(headed.scheduledDay, null);
});

test('abbreviated test dates still become Important Dates', () => {
  const [proposal] = interpretText('Chemistry test fri', data, reference);
  assert.equal(proposal.kind, 'date');
  assert.equal(proposal.category, 'Test');
  assert.equal(proposal.title, 'Chemistry test');
  assert.equal(dayString(proposal.dueDay), '2026-11-13');
});
