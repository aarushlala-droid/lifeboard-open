// View layer for the LifeBoard companion. Data, sync, scheduling and parsing
// live in sync.js, scheduling.js, task-groups.js, task-features.js and
// capture.js; this file only renders them and turns gestures into mutations.
import { LifeBoardSync, valueAtPath, inverseOperation, applyInverse, patchDraft, sameID } from "/sync.js";
import { interpretText, previewPhotoWithTypedText, dayString, fromDayString, today, tomorrow } from "/capture.js";
import { completeRecurringTask } from "/task-features.js";
import { taskSegment, calendarSegments, busyIntervals, intervalLanes } from "/scheduling.js";
import { groupTasks } from "/task-groups.js";
import { readRoute, routeHash, moreActive } from "/navigation.js";
import { icon } from "/icons.js";

const HOUR = 60; // px per hour in the day timeline; mirrors --lb-hour (one minute per pixel)
const sync = new LifeBoardSync();
const timestamp = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const screen = document.getElementById("screen");
const statusNode = document.getElementById("sync-status");
const tabbar = document.getElementById("tabbar");
const topbar = document.getElementById("topbar");
const navLeading = document.getElementById("nav-leading");
const navTitle = document.getElementById("nav-title");
const sheet = document.getElementById("sheet");
const toast = document.getElementById("toast");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let route = readRoute(location.hash);
let view = route.view;
let calendarDay = fromDayString(route.day) || today();
let calendarMode = "day";
let pendingCalendarScroll = view === "calendar";
let contextKind = route.kind, contextID = route.id;
let editingTaskID = null;
let sheetReturnFocus = null;
let sheetBaseline = null;
let filter = "Today";
let captureText = safeRead("lifeboard.capture.draft") || "";
let previews = [];
let captureNotice = "";
let captureTimer;
let searchText = "";
let toastTimer;
let undoOperation = null;
let focusMinutes = 25;
let focusCustom = false;
let focusTaskID = "";
let renderedState = null;
const recentlyDone = new Map(); // id -> timer; completed rows stay in place briefly

/* Formatting */
const esc = value => String(value ?? "").replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
const todayKey = () => dayString(today());
const asDate = day => new Date(day.year, day.month - 1, day.day, 12);
const shiftDay = (day, count) => { const date = asDate(day); date.setDate(date.getDate() + count); return { year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate() }; };
const dateLabel = day => day ? asDate(day).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }) : "Anytime";
const longDate = day => asDate(day).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" });
const timeLabel = minutes => `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
const nowMinute = () => { const now = new Date(); return now.getHours() * 60 + now.getMinutes(); };
const daysFromToday = day => Math.round((Date.UTC(day.year, day.month - 1, day.day) - Date.UTC(...todayKey().split("-").map((part, index) => Number(part) - (index === 1 ? 1 : 0)))) / 86400000);
function relativeDay(day) {
  const delta = daysFromToday(day);
  return delta === 0 ? "Today" : delta === 1 ? "Tomorrow" : delta === -1 ? "Yesterday" : dateLabel(day);
}
const inlineDay = day => { const label = relativeDay(day); return ["Today", "Tomorrow", "Yesterday"].includes(label) ? label.toLowerCase() : label; };
const taskActive = task => !task.isCompleted && !task.isArchived;
const subjectName = id => sync.data.subjects.find(item => sameID(item.id, id))?.title;
const projectName = id => sync.data.projects.find(item => sameID(item.id, id))?.title;
const dateParts = day => day ? dayString(day) : "";
const plural = (count, word, words = `${word}s`) => `${count} ${count === 1 ? word : words}`;
const categoryLabel = category => ({ Test: "Test or exam", Deadline: "Deadline", "Important Date": "Important date" })[category] || category || "Important date";
// Sync messages use a compact separator internally; the interface writes sentences.
const statusText = raw => String(raw || "").replace(/ · (\w)/g, (_, first) => `. ${first.toUpperCase()}`);
const statusTone = raw => /review|expired|reconnect|couldn't|unavailable|export|not verified/i.test(raw || "") ? "attention" : "calm";

function safeRead(key) { try { return localStorage.getItem(key); } catch { return null; } }
function safeWrite(key, value) { try { if (value === null) localStorage.removeItem(key); else localStorage.setItem(key, value); } catch { showToast("Draft storage is unavailable. Keep this page open or export your work."); } }
function downloadJSON(value, name) {
  const link = document.createElement("a"); link.href = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2)], { type: "application/json" })); link.download = name; link.click(); setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

/* Building blocks */
// A large title that hands over to the navigation bar's inline title once it
// scrolls away, as on iOS. The back button lives in the navigation bar.
function pageHead(title, subtitle = "") {
  return `<div class="page-head"><h1 class="page-title" id="page-title">${esc(title)}</h1>${subtitle ? `<p class="page-sub">${esc(subtitle)}</p>` : ""}</div>`;
}
function section(title, body, { count = "", tone = "", note = "", className = "" } = {}) {
  return `<section class="section ${className}"><div class="section-head ${tone}"><h2>${esc(title)}</h2>${count !== "" ? `<span class="count">${esc(count)}</span>` : ""}</div>${note ? `<p class="section-note">${esc(note)}</p>` : ""}${body}</section>`;
}
function empty(title, detail, action = "") { return `<div class="empty"><strong>${esc(title)}</strong><p>${esc(detail)}</p>${action}</div>`; }
const meta = (iconName, text, className = "") => `<span class="meta ${className}">${iconName ? icon(iconName) : ""}<span>${esc(text)}</span></span>`;

function taskMeta(task) {
  const parts = [];
  const key = todayKey();
  if (task.scheduledDay && task.scheduledStartMinutes != null) {
    const end = task.scheduledStartMinutes + (task.scheduledDurationMinutes || task.estimatedMinutes || 30);
    parts.push(meta("clock", `${dayString(task.scheduledDay) === key ? "" : `${relativeDay(task.scheduledDay)} `}${timeLabel(task.scheduledStartMinutes)}–${timeLabel(end % 1440)}`, dayString(task.scheduledDay) < key && taskActive(task) ? "overdue" : ""));
  } else if (task.scheduledDay && !(view === "today" && dayString(task.scheduledDay) === key)) {
    parts.push(meta("calendar", `Planned ${inlineDay(task.scheduledDay)}`, dayString(task.scheduledDay) < key && taskActive(task) ? "overdue" : ""));
  }
  if (task.dueDay) {
    const overdue = dayString(task.dueDay) < key && taskActive(task);
    parts.push(meta("due", overdue ? `Was due ${dateLabel(task.dueDay)}` : `Due ${inlineDay(task.dueDay)}`, overdue ? "overdue" : ""));
  }
  const context = subjectName(task.subjectID) || projectName(task.projectID);
  if (context) parts.push(meta("", context));
  if (task.estimatedMinutes) parts.push(meta("", `${task.estimatedMinutes} min`));
  if (task.subtasks?.length) parts.push(meta("checklist", `${task.subtasks.filter(item => item.isCompleted).length} of ${task.subtasks.length} steps`));
  if (task.recurrence?.frequency) parts.push(meta("repeat", task.recurrence.frequency[0].toUpperCase() + task.recurrence.frequency.slice(1)));
  return parts.join("");
}
// The progress slider sits on every open To Do, as in LifeBoard on the Mac:
// it saves when released, and 100% completes the To Do.
function progressSlider(task) {
  const percent = Math.round(task.completionPercent ?? 0);
  return `<label class="task-progress"><input class="range" type="range" min="0" max="100" step="5" value="${percent}" style="--p:${percent}%" data-progress-id="${esc(task.id)}" aria-label="Progress for ${esc(task.title)}"><output>${percent}%</output></label>`;
}
function taskRow(task) {
  const done = Boolean(task.__done) || task.isCompleted;
  const metaHTML = taskMeta(task);
  return `<div class="task-row ${done ? "is-done" : ""}">
    <button class="task-check ${done ? "checked" : ""}" type="button" data-action="toggle" data-id="${esc(task.id)}" aria-label="${done ? "Mark incomplete" : "Complete"} ${esc(task.title)}">${icon("check")}</button>
    <div class="task-body">
      <button class="task-main" type="button" data-action="edit" data-id="${esc(task.id)}"><div class="task-title">${task.priority === "high" && !done ? '<span class="prio" aria-label="High priority">!!</span>' : task.priority === "medium" && !done ? '<span class="prio" aria-label="Medium priority">!</span>' : ""}${esc(task.title)}</div>${metaHTML ? `<div class="task-meta">${metaHTML}</div>` : ""}</button>
      ${done ? "" : progressSlider(task)}
    </div>
    <button class="row-more" type="button" data-action="task-menu" data-id="${esc(task.id)}" aria-label="More options for ${esc(task.title)}">${icon("ellipsis")}</button>
  </div>`;
}
const addRow = (label = "New To Do") => `<button class="add-row" type="button" data-action="manual-add"><span class="add-dot">${icon("plus")}</span><span>${esc(label)}</span></button>`;
const taskList = (tasks, emptyTitle = "Nothing here", emptyDetail = "Add a To Do whenever something is on your mind.") =>
  tasks.length ? `<div class="group">${tasks.map(taskRow).join("")}</div>` : empty(emptyTitle, emptyDetail);
const priorityRank = task => ({ high: 3, medium: 2, low: 1, none: 0 })[task.priority] || 0;
const byPlan = (a, b) => (a.scheduledStartMinutes ?? 9999) - (b.scheduledStartMinutes ?? 9999) || priorityRank(b) - priorityRank(a) || dateParts(a.dueDay || a.scheduledDay).localeCompare(dateParts(b.dueDay || b.scheduledDay)) || (a.sortOrder || 0) - (b.sortOrder || 0);

// Recently completed rows keep their place for a moment, as in Reminders,
// while the completion itself is already saved.
function viewTasks() {
  if (!recentlyDone.size) return sync.data.tasks;
  return sync.data.tasks.map(task => recentlyDone.has(String(task.id).toLowerCase()) && task.isCompleted && !task.isArchived ? { ...task, isCompleted: false, __done: true } : task);
}

/* Schedule model */
function scheduleFor(day) {
  return [
    ...sync.data.tasks.map(task => { const span = taskSegment(task, day); return span ? { kind: "task", id: task.id, title: task.title, start: span.start, end: span.end, taskID: task.id } : null; }),
    ...sync.data.events.map(event => { const span = calendarSegments(event, day); return span ? { kind: "event", id: event.id, title: event.title, start: span.start, end: span.end, detail: event.location || "" } : null; }),
    ...sync.data.externalEvents.map(event => { const span = calendarSegments(event, day); return span ? { kind: "external", id: event.id, title: event.title, start: span.start, end: span.end, allDay: event.isAllDay || (span.start === 0 && span.end === 1440), detail: event.calendarTitle || "Connected calendar" } : null; }),
  ].filter(Boolean).sort((a, b) => Number(Boolean(b.allDay)) - Number(Boolean(a.allDay)) || a.start - b.start || a.end - b.end);
}
function nowAndNext() {
  const minute = nowMinute();
  const items = scheduleFor(today()).filter(item => !item.allDay && item.end > minute);
  const current = items.find(item => item.start <= minute);
  return current ? { item: current, running: true } : items[0] ? { item: items[0], running: false } : null;
}

function agendaRows(day, { markNow = false } = {}) {
  const minute = nowMinute();
  return scheduleFor(day).map(item => {
    const time = item.allDay ? "All day" : timeLabel(item.start);
    const detail = item.allDay ? item.detail : `${timeLabel(item.start)}–${timeLabel(item.end % 1440)}${item.detail ? `, ${item.detail}` : ""}`;
    const isNow = markNow && !item.allDay && item.start <= minute && item.end > minute;
    const inner = `<span class="agenda-time">${esc(time)}</span><span><span class="agenda-title">${esc(item.title)}</span><span class="agenda-detail">${esc(detail)}</span></span>`;
    const classes = `agenda-row ${item.kind === "external" ? "is-external" : item.kind === "event" ? "is-event" : ""} ${isNow ? "is-now" : ""}`;
    return item.taskID
      ? `<button class="${classes}" type="button" data-action="edit" data-id="${esc(item.taskID)}">${inner}</button>`
      : `<div class="${classes}">${inner}</div>`;
  });
}

/* Today: the hub. Every open To Do is here, today's work first. */
function todayView() {
  const key = todayKey();
  const groups = groupTasks(viewTasks(), key, dayString(tomorrow()));
  const { carryOver, overdue } = groups;
  const todayList = groups.todayWorkload.filter(task => !carryOver.includes(task) && !overdue.includes(task)).sort(byPlan);
  const anytime = groups.filters.Anytime.sort((a, b) => priorityRank(b) - priorityRank(a) || (a.sortOrder || 0) - (b.sortOrder || 0));
  const later = [...groups.filters.Tomorrow, ...groups.filters.Upcoming].sort((a, b) => dateParts(a.scheduledDay || a.dueDay).localeCompare(dateParts(b.scheduledDay || b.dueDay)) || byPlan(a, b));
  const next = nowAndNext();
  const nowCard = next
    ? `<button class="now-card" type="button" data-action="${next.item.taskID ? "edit" : "calendar"}" ${next.item.taskID ? `data-id="${esc(next.item.taskID)}"` : ""}>
        <span class="now-head"><span class="now-label">${next.running ? "Now" : next.item.start - nowMinute() <= 90 ? `In ${plural(next.item.start - nowMinute(), "minute")}` : "Next"}</span><span class="now-title">${esc(next.item.title)}</span></span>
        <span class="now-time">${next.running ? `Until ${timeLabel(next.item.end % 1440)}` : `${timeLabel(next.item.start)}–${timeLabel(next.item.end % 1440)}`}${next.item.kind === "external" ? `, ${esc(next.item.detail)}` : ""}</span>
      </button>`
    : `<div class="now-card is-clear"><span class="now-head"><span class="now-label">Next</span><span class="now-title">Nothing else scheduled today</span></span><span class="now-time">Your To Dos are still here when you want them.</span></div>`;
  const agenda = agendaRows(today(), { markNow: true });
  const upcoming = sync.data.yearMarkers.filter(item => dayString(item.startDay) >= key).sort((a, b) => dayString(a.startDay).localeCompare(dayString(b.startDay))).slice(0, 3);
  const conflictBanner = sync.conflicts.length ? `<button class="banner" type="button" data-action="view" data-value="sync-centre">${icon("sync")}<span><strong>Review sync conflicts</strong>${plural(sync.conflicts.length, "change")} on two devices need a choice.</span></button>`
    : statusTone(sync.status) === "attention" ? `<button class="banner" type="button" data-action="view" data-value="settings">${icon("sync")}<span><strong>Sync needs attention</strong>${esc(statusText(sync.status))}</span></button>` : "";
  const todayGroup = `<div class="group">${todayList.map(taskRow).join("")}${addRow()}</div>`;
  return `${pageHead("Today", longDate(today()))}
    <div class="today-now">${conflictBanner}${nowCard}</div>
    <div class="today-primary">
      ${overdue.length ? section("Overdue", taskList(overdue.sort(byPlan)), { count: overdue.length, tone: "signal" }) : ""}
      ${carryOver.length ? section("Carry over", taskList(carryOver.sort(byPlan)), { count: carryOver.length }) : ""}
      ${section("To do today", todayGroup, { count: todayList.length || "" })}
      ${anytime.length ? section("Anytime", taskList(anytime), { count: anytime.length }) : ""}
      ${later.length ? section("Upcoming", taskList(later), { count: later.length }) : ""}
    </div>
    <div class="today-secondary">
      ${section("Schedule", agenda.length ? `<div class="group">${agenda.join("")}</div>` : empty("No time blocks today", "To Dos can stay unscheduled until you choose a time."), { count: agenda.length || "" })}
      ${upcoming.length ? section("Coming up", `<div class="group">${upcoming.map(dateRow).join("")}</div>`) : ""}
    </div>`;
}
function dateRow(item) {
  const days = daysFromToday(item.startDay);
  const when = days === 0 ? "Today" : days === 1 ? "Tomorrow" : days > 0 ? `In ${days} days` : dateLabel(item.startDay);
  const subject = item.subjectID ? subjectName(item.subjectID) : "";
  return `<button class="row" type="button" data-action="edit-date" data-id="${esc(item.id)}"><span class="row-label">${esc(item.title)}<small>${esc(categoryLabel(item.category))}, ${esc(dateLabel(item.startDay))}${subject ? `, ${esc(subject)}` : ""}</small>${item.notes ? `<small>${esc(item.notes)}</small>` : ""}</span><span class="row-value">${esc(when)}</span>${icon("disclosure", "icon chevron")}</button>`;
}

/* To Do */
function todoView() {
  const groups = groupTasks(viewTasks(), todayKey(), dayString(tomorrow())).filters;
  const order = ["Today", "Tomorrow", "Upcoming", "Anytime", "Overdue", "Carry over"];
  const selected = [...(groups[filter] || groups.Today)].sort((a, b) => priorityRank(b) - priorityRank(a) || byPlan(a, b));
  const open = sync.data.tasks.filter(taskActive).length;
  const emptyCopy = { Today: ["Nothing for today", "Plan something from Upcoming or Anytime."], Tomorrow: ["Nothing for tomorrow", "Tomorrow is clear so far."], Upcoming: ["Nothing upcoming", "Dated work will collect here."], Anytime: ["No undated To Dos", "Everything has a date or a plan."], Overdue: ["Nothing overdue", "Every deadline is on track."], "Carry over": ["No missed plans", "Nothing slipped from an earlier day."] }[filter] || ["Nothing here", ""];
  return `${pageHead("To Do", plural(open, "open To Do", "open To Dos"))}
    <div class="chips" role="tablist" aria-label="To Do filters">${order.map(name => `<button type="button" class="chip ${["Overdue", "Carry over"].includes(name) && groups[name].length ? "signal" : ""}" role="tab" id="filter-${name.replace(/\s/g, "-")}" aria-controls="todo-panel" aria-selected="${name === filter}" data-action="filter" data-value="${name}">${name}${groups[name].length ? ` <span class="chip-count">${groups[name].length}</span>` : ""}</button>`).join("")}</div>
    <div id="todo-panel" role="tabpanel" aria-labelledby="filter-${filter.replace(/\s/g, "-")}">${taskList(selected, ...emptyCopy)}</div>`;
}

/* Capture */
const formRow = (label, control, extra = "") => `<label class="form-row">${label ? `<span>${esc(label)}</span>` : ""}${control}${extra}</label>`;
const optionList = (values, selected) => values.map(([value, label]) => `<option value="${esc(value)}" ${value === selected ? "selected" : ""}>${esc(label)}</option>`).join("");
const priorityOptions = selected => optionList([["none", "None"], ["low", "Low"], ["medium", "Medium"], ["high", "High"]], selected || "none");
const categoryOptions = selected => optionList([["Test", "Test or exam"], ["Deadline", "Deadline"], ["Important Date", "Important date"]], selected);
function previewItem(item, index) {
  const isDate = item.kind === "date";
  const field = (name, attributes = "") => `data-preview-field="${name}" ${attributes}`;
  const subjects = `<option value="">None</option>${sync.data.subjects.filter(subject => !subject.archived).map(subject => `<option value="${esc(subject.id)}" ${subject.id === item.subjectID ? "selected" : ""}>${esc(subject.title)}</option>`).join("")}`;
  const projects = `<option value="">None</option>${sync.data.projects.filter(project => project.status !== "archived").map(project => `<option value="${esc(project.id)}" ${project.id === item.projectID ? "selected" : ""}>${esc(project.title)}</option>`).join("")}`;
  return `<div class="preview-item" data-preview-id="${esc(item.id)}">
    <label class="preview-head"><input type="checkbox" aria-label="Include ${esc(item.title)}" ${field("included")} ${item.included ? "checked" : ""}><span>${isDate ? "Important date" : item.existingID ? "Update To Do" : "New item"} ${index + 1}</span></label>
    ${item.needsReview ? `<p class="review-note">${esc(item.reviewReason || "Check this item before adding. The existing task could not be matched confidently.")}</p>` : ""}
    <div class="form-group">
      <label class="form-row stack"><span>Title</span><input class="form-input" aria-label="Title" ${field("title")} value="${esc(item.title)}"></label>
      ${formRow("Type", `<select ${field("kind")}>${optionList([["task", "To Do"], ["date", "Important date"], ["event", "Timed event"]], item.kind)}</select>`)}
      ${isDate ? `${formRow("Date", `<input type="date" ${field("dueDay")} value="${dateParts(item.dueDay)}">`)}${formRow("Category", `<select ${field("category")}>${categoryOptions(item.category || "Important Date")}</select>`)}`
        : `${formRow("Planned date", `<input type="date" ${field("scheduledDay")} value="${dateParts(item.scheduledDay)}">`)}${formRow("Due date", `<input type="date" ${field("dueDay")} value="${dateParts(item.dueDay)}">`)}
      ${formRow("Time", `<input type="time" ${field("startMinutes")} value="${item.startMinutes == null ? "" : timeLabel(item.startMinutes)}">`)}${formRow("Minutes", `<input type="number" inputmode="numeric" min="5" max="480" ${field("estimatedMinutes")} value="${item.estimatedMinutes}">`)}`}
      ${formRow("Subject", `<select ${field("subjectID")}>${subjects}</select>`)}
      ${isDate ? "" : `${formRow("Project", `<select ${field("projectID")}>${projects}</select>`)}${formRow("Priority", `<select ${field("priority")}>${priorityOptions(item.priority)}</select>`)}`}
    </div>
  </div>`;
}
function capturePreview() {
  const count = previews.filter(item => item.included).length;
  return previews.length ? section("Check before adding", `${previews.map(previewItem).join("")}<div class="sticky-action"><button class="button primary full" type="button" data-action="add-previews">Add ${plural(count, "item")}</button></div>`, { count: `${count} of ${previews.length}` }) : "";
}
function captureView() {
  return `${pageHead("Capture", "One item per line. Nothing is added until you check it.")}
    <div class="group"><label><span class="visually-hidden">What needs doing?</span><textarea class="capture-input" id="capture-text" placeholder="chem worksheet tmr 30m&#10;English essay fri, don’t schedule&#10;Physics test 4/12">${esc(captureText)}</textarea></label></div>
    ${captureNotice ? `<p class="review-note" role="status" id="capture-notice">${esc(captureNotice)}</p>` : ""}
    <div class="capture-actions">
      <label class="button secondary upload">${icon("photo")}<span>Add photo</span><input id="capture-image" type="file" accept="image/*" aria-label="Read tasks from a photo or screenshot"></label>
      <button class="button primary" type="button" data-action="interpret">Review items</button>
    </div>
    <div id="capture-preview">${capturePreview()}</div>`;
}

/* Calendar */
function weekStart(day) {
  const mondayFirst = sync.data.settings?.weekStartsMonday !== false;
  const weekday = asDate(day).getDay();
  return shiftDay(day, -((weekday - (mondayFirst ? 1 : 0) + 7) % 7));
}
function dayMarkers(day) {
  const key = dayString(day);
  const untimed = sync.data.tasks.filter(task => taskActive(task) && dayString(task.scheduledDay) === key && task.scheduledStartMinutes == null);
  const markers = sync.data.yearMarkers.filter(item => dayString(item.startDay) === key);
  const milestones = sync.data.projects.flatMap(project => (project.milestones || []).filter(item => !item.isCompleted && dayString(item.targetDay) === key));
  return { untimed, markers, milestones };
}
function timeline(day) {
  const items = scheduleFor(day).filter(item => !item.allDay);
  const lanes = new Map(intervalLanes(items.map((item, index) => ({ id: String(index), start: item.start, end: Math.max(item.end, item.start + 20) }))).map(lane => [lane.id, lane]));
  const blocks = items.map((item, index) => {
    const lane = lanes.get(String(index)) || { lane: 0, laneCount: 1 };
    const height = Math.max(22, (item.end - item.start) * HOUR / 60 - 2);
    const style = `top:${item.start * HOUR / 60 + 1}px;height:${height}px;left:calc(${lane.lane} * (100% - 6px) / ${lane.laneCount} + 3px);width:calc((100% - 6px) / ${lane.laneCount} - 3px)`;
    const time = `${timeLabel(item.start)}–${timeLabel(item.end % 1440)}`;
    const label = `<span class="block-title">${esc(item.title)}</span><span class="block-time">${esc(time)}${item.kind === "external" ? `, ${esc(item.detail)}` : ""}</span>`;
    const short = item.end - item.start < 40 ? "is-short" : item.end - item.start < 56 ? "is-compact" : "";
    return item.taskID
      ? `<button class="block task ${short}" type="button" data-action="edit" data-id="${esc(item.taskID)}" style="${style}">${label}</button>`
      : `<div class="block ${item.kind} ${short}" style="${style}">${label}</div>`;
  }).join("");
  const isToday = dayString(day) === todayKey();
  const minute = nowMinute();
  const hours = Array.from({ length: 23 }, (_, index) => `<span class="hour-label ${isToday && Math.abs((index + 1) * 60 - minute) < 14 ? "is-covered" : ""}" data-minute="${(index + 1) * 60}" style="top:${(index + 1) * HOUR}px">${timeLabel((index + 1) * 60)}</span>`).join("");
  return `<div class="timeline" aria-label="Schedule for ${esc(longDate(day))}">
      <div class="hours" aria-hidden="true">${hours}${isToday ? `<span class="now-stamp" id="now-stamp" style="top:${minute * HOUR / 60}px">${timeLabel(minute)}</span>` : ""}</div>
      <div class="timeline-grid" data-slot-day="${dayString(day)}" title="Tap an empty time to add a To Do there">${blocks}${isToday ? `<div class="now-line" id="now-line" style="top:${minute * HOUR / 60}px"></div>` : ""}</div>
    </div>`;
}
function calendarDayView(day) {
  const { untimed, markers, milestones } = dayMarkers(day);
  const allDay = scheduleFor(day).filter(item => item.allDay);
  const strip = [];
  if (allDay.length) strip.push(`<div class="strip-group"><span class="strip-label">All day</span>${allDay.map(item => `<span class="pill">${icon("calendar")}${esc(item.title)}</span>`).join("")}</div>`);
  if (markers.length || milestones.length) strip.push(`<div class="strip-group"><span class="strip-label">Dates</span>${markers.map(item => `<button class="pill" type="button" data-action="edit-date" data-id="${esc(item.id)}">${icon("dates")}${esc(item.title)}</button>`).join("")}${milestones.map(item => `<span class="pill">${icon("flag")}${esc(item.title)}</span>`).join("")}</div>`);
  if (untimed.length) strip.push(`<div class="strip-group"><span class="strip-label">Planned, no time</span>${untimed.map(task => `<button class="pill task" type="button" data-action="edit" data-id="${esc(task.id)}">${icon("todo")}${esc(task.title)}</button>`).join("")}</div>`);
  return `${strip.join("")}${timeline(day)}`;
}
function calendarWeekView(start) {
  return Array.from({ length: 7 }, (_, offset) => {
    const day = shiftDay(start, offset);
    const rows = agendaRows(day, { markNow: dayString(day) === todayKey() });
    const { untimed } = dayMarkers(day);
    const body = rows.length || untimed.length
      ? `${rows.length ? `<div class="group">${rows.join("")}</div>` : ""}${untimed.length ? `<div class="strip-group" style="margin-top:8px">${untimed.map(task => `<button class="pill task" type="button" data-action="edit" data-id="${esc(task.id)}">${icon("todo")}${esc(task.title)}</button>`).join("")}</div>` : ""}`
      : `<p class="section-note">Nothing scheduled</p>`;
    return section(`${relativeDay(day) === dateLabel(day) ? dateLabel(day) : `${relativeDay(day)}, ${dateLabel(day)}`}`, body);
  }).join("");
}
function calendarView() {
  const day = calendarDay;
  const start = weekStart(day);
  const days = Array.from({ length: 7 }, (_, index) => shiftDay(start, index));
  const key = dayString(day);
  const weekStrip = `<div class="week-strip" role="group" aria-label="Choose a day">${days.map(item => {
    const itemKey = dayString(item);
    const busy = scheduleFor(item).length || dayMarkers(item).untimed.length;
    return `<button type="button" class="week-day ${itemKey === todayKey() ? "is-today" : ""} ${busy ? "has-items" : ""}" data-action="calendar-pick" data-value="${itemKey}" aria-pressed="${itemKey === key}" aria-label="${esc(longDate(item))}${itemKey === todayKey() ? ", today" : ""}${busy ? ", has plans" : ""}"><span class="weekday" aria-hidden="true">${asDate(item).toLocaleDateString("en-GB", { weekday: "narrow" })}</span><span class="date-number" aria-hidden="true">${item.day}</span><span class="load" aria-hidden="true"></span></button>`;
  }).join("")}</div>`;
  const step = calendarMode === "week" ? "week" : "day";
  return `${pageHead("Calendar", calendarMode === "week" ? `${dateLabel(start)} to ${dateLabel(shiftDay(start, 6))}` : longDate(day))}
    <div class="cal-bar">
      <button class="step" type="button" data-action="calendar-step" data-value="-1" aria-label="Previous ${step}">${icon("back")}</button>
      <label class="date-pill"><span aria-hidden="true">${esc(relativeDay(day))}</span><input type="date" id="calendar-day" value="${dateParts(day)}" aria-label="Choose date"></label>
      <button class="step" type="button" data-action="calendar-step" data-value="1" aria-label="Next ${step}">${icon("forward")}</button>
      ${key !== todayKey() ? `<button class="button plain" type="button" data-action="calendar-today">Today</button>` : ""}
      <div class="segmented" role="group" aria-label="Calendar view">${["day", "week"].map(mode => `<button type="button" data-action="calendar-mode" data-value="${mode}" aria-pressed="${mode === calendarMode}">${mode === "day" ? "Day" : "Week"}</button>`).join("")}</div>
    </div>
    ${calendarMode === "day" ? `${weekStrip}${calendarDayView(day)}` : calendarWeekView(start)}`;
}

/* More and secondary screens */
function moreView() {
  const upcomingDates = sync.data.yearMarkers.filter(item => dayString(item.startDay) >= todayKey()).length;
  const completed = sync.data.tasks.filter(task => task.isCompleted && !task.isArchived).length;
  const trash = sync.data.tasks.filter(task => task.isArchived).length;
  // Settings-style rows: a coloured tile per destination, the value on the right.
  const row = (id, iconName, label, value = "", tile = "") => `<button type="button" class="row" data-action="view" data-value="${id}"><span class="tile ${tile}">${icon(iconName)}</span><span class="row-label">${label}</span>${value !== "" ? `<span class="row-value">${esc(value)}</span>` : ""}${icon("disclosure", "icon chevron")}</button>`;
  const group = rows => `<div class="section"><div class="group group-with-icons">${rows.join("")}</div></div>`;
  return `${pageHead("Browse")}
    ${group([row("focus", "focus", "Focus", sync.data.activeFocus ? "Running" : "", "lamp"), row("capture", "capture", "Capture", "", "accent"), row("dates", "dates", "Important Dates", upcomingDates || "", "marker"), row("revision", "revision", "Revision overview", "", "event")])}
    ${group([row("subjects", "subjects", "Subjects", sync.data.subjects.filter(item => !item.archived).length || "", "accent"), row("projects", "projects", "Projects", sync.data.projects.filter(item => item.status !== "archived").length || "", "connected")])}
    ${group([row("completed", "completed", "Completed", completed || "", "done"), row("trash", "trash", "Trash", trash || "")])}
    ${group([row("sync-centre", "sync", "Sync Centre", sync.conflicts.length ? `${sync.conflicts.length} to review` : "", "done"), row("backups", "backups", "Backups"), row("settings", "settings", "Settings"), row("about", "about", "About LifeBoard")])}`;
}

function datesView() {
  const dates = [...sync.data.yearMarkers].sort((a, b) => dayString(a.startDay).localeCompare(dayString(b.startDay)));
  const upcoming = dates.filter(item => dayString(item.startDay) >= todayKey());
  const past = dates.filter(item => dayString(item.startDay) < todayKey()).reverse();
  return `${pageHead("Important Dates", "Tests, exams and deadlines to prepare for, without adding a calendar block.")}
    <div class="button-stack"><button class="button tinted full" type="button" data-action="add-date">${icon("plus")}<span>Add test or date</span></button></div>
    ${section("Coming up", upcoming.length ? `<div class="group">${upcoming.map(dateRow).join("")}</div>` : empty("Nothing coming up", "Add a test or date you need to prepare for."))}
    ${past.length ? section("Past", `<div class="group">${past.slice(0, 15).map(dateRow).join("")}</div>`) : ""}`;
}

function progressBar(value) { const amount = Math.max(0, Math.min(100, Number(value) || 0)); return `<div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(amount)}" aria-label="Progress"><i style="transform:scaleX(${amount / 100})"></i></div>`; }
function taskCompletion(id) { const rows = sync.data.tasks.filter(t => sameID(t.projectID, id) && !t.isArchived); return rows.length ? Math.round(rows.filter(t => t.isCompleted).length * 100 / rows.length) : 0; }
function milestoneCompletion(project) { const rows = project.milestones || []; return rows.length ? Math.round(rows.filter(m => m.isCompleted).length * 100 / rows.length) : 0; }
function projectProgress(project) { return project.progressMode === "tasks" ? taskCompletion(project.id) : project.progressMode === "milestones" ? milestoneCompletion(project) : Math.round(project.progress || 0); }
const progressModeLabel = mode => mode === "tasks" ? "From tasks" : mode === "milestones" ? "From milestones" : "Set manually";

function projectsView() {
  const projects = sync.data.projects.filter(project => project.status !== "archived");
  return `${pageHead("Projects", "Longer pieces of work and their next steps.")}${projects.length ? projects.map(project => {
    const active = sync.data.tasks.filter(task => taskActive(task) && sameID(task.projectID, project.id));
    const milestone = project.milestones?.filter(item => !item.isCompleted).sort((a, b) => dayString(a.targetDay).localeCompare(dayString(b.targetDay)))[0];
    const progress = projectProgress(project);
    return section(project.title, `<div class="group">
      <div class="row"><span class="row-label">${esc(project.summary || plural(active.length, "active To Do", "active To Dos"))}${milestone ? `<small>Next milestone: ${esc(milestone.title)}, ${esc(dateLabel(milestone.targetDay))}</small>` : ""}${progressBar(progress)}</span><span class="row-value">${progress}%<small class="row-detail">${progressModeLabel(project.progressMode)}</small></span></div>
      ${active.slice(0, 5).map(taskRow).join("")}
      <button class="row" type="button" data-action="context" data-kind="project" data-id="${esc(project.id)}"><span class="row-label">Show all ${active.length} active tasks and milestones</span>${icon("disclosure", "icon chevron")}</button>
    </div>`);
  }).join("") : empty("No projects yet", "Projects you create on your Mac appear here.")}`;
}

function subjectsView() {
  const subjects = sync.data.subjects.filter(subject => !subject.archived);
  return `${pageHead("Subjects", "Course progress and confidence, with the work linked to each.")}${subjects.length ? `<div class="group">${subjects.map(subject => {
    const active = sync.data.tasks.filter(task => taskActive(task) && sameID(task.subjectID, subject.id));
    const nextTest = sync.data.yearMarkers.filter(item => sameID(item.subjectID, subject.id) && dayString(item.startDay) >= todayKey()).sort((a, b) => dayString(a.startDay).localeCompare(dayString(b.startDay)))[0];
    return `<button class="row" type="button" data-action="context" data-kind="subject" data-id="${esc(subject.id)}"><span class="row-label">${esc(subject.title)}<small>${plural(active.length, "To Do", "To Dos")}${subject.lastActivity ? `, worked on ${new Date(subject.lastActivity).toLocaleDateString("en-GB", { day: "numeric", month: "short" })}` : ""}</small>${nextTest ? `<small>Next: ${esc(nextTest.title)}, ${esc(dateLabel(nextTest.startDay))}</small>` : ""}${progressBar(subject.progress)}</span><span class="row-value">${Math.round(subject.progress || 0)}%</span>${icon("disclosure", "icon chevron")}</button>`;
  }).join("")}</div>` : empty("No subjects yet", "Subjects you create on your Mac appear here.")}`;
}

function focusRemaining(active) {
  if (!active) return focusMinutes * 60;
  const end = active.pausedAt ? new Date(active.pausedAt).getTime() : Date.now();
  const elapsed = Math.max(0, (end - new Date(active.startedAt).getTime()) / 1000 - (active.pausedSeconds || 0));
  return Math.max(0, Math.ceil(active.plannedMinutes * 60 - elapsed));
}
const clockText = seconds => `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
const RING = 2 * Math.PI * 45;
function ringOffset(active) { return active ? RING * (focusRemaining(active) / Math.max(1, active.plannedMinutes * 60)) : RING; }
function focusView() {
  const active = sync.data.activeFocus;
  const remaining = focusRemaining(active);
  const state = !active ? "is-idle" : active.pausedAt ? "is-paused" : "is-running";
  const tasks = sync.data.tasks.filter(taskActive);
  return `${pageHead("Focus", "Choose one thing, then give it your attention.")}
    ${!active ? `<div class="section" style="margin-top:8px"><div class="segmented" style="margin:0 var(--lb-gutter)" role="group" aria-label="Focus length">${[25, 50].map(value => `<button type="button" data-action="focus-preset" data-value="${value}" aria-pressed="${!focusCustom && focusMinutes === value}">${value} min</button>`).join("")}<button type="button" data-action="focus-custom" aria-pressed="${focusCustom}">Custom</button></div></div>
      <div class="form-group">${focusCustom ? formRow("Minutes", `<input id="focus-minutes" type="number" inputmode="numeric" min="1" max="240" value="${focusMinutes}">`) : ""}
      ${formRow("Work on", `<select id="focus-task"><option value="">General focus</option>${tasks.map(task => `<option value="${esc(task.id)}" ${sameID(task.id, focusTaskID) ? "selected" : ""}>${esc(task.title)}</option>`).join("")}</select>`)}</div>` : ""}
    <div class="focus-face">
      <div class="focus-dial ${state}">
        <svg viewBox="0 0 100 100" aria-hidden="true"><circle class="focus-track" cx="50" cy="50" r="45" fill="none" stroke-width="4"/><circle id="focus-progress" class="focus-progress" cx="50" cy="50" r="45" fill="none" stroke-width="4" stroke-linecap="round" stroke-dasharray="${RING.toFixed(2)}" stroke-dashoffset="${ringOffset(active).toFixed(2)}"/></svg>
        <div class="focus-clock" role="timer"><span class="visually-hidden">${active ? (active.pausedAt ? "Paused with " : "Time remaining ") : "Focus length "}</span><span id="focus-clock">${clockText(remaining)}</span></div>
      </div>
      <p class="focus-subject">${esc(active ? (active.kind === "shortBreak" ? "Short break" : active.taskTitle) : "Ready when you are")}</p>
      <div class="round-buttons">${active
        ? `<button class="round" type="button" data-action="focus-stop">Stop</button><button class="round ${active.pausedAt ? "start" : "pause"}" type="button" data-action="${active.pausedAt ? "focus-resume" : "focus-pause"}">${active.pausedAt ? "Resume" : "Pause"}</button>`
        : `<span></span><button class="round start" type="button" data-action="focus-start" aria-label="Start Focus">Start</button>`}</div>
      ${active ? `<button class="button plain" type="button" data-action="focus-reset">Reset timer</button>` : ""}
    </div>
    <p class="focus-note">Elapsed time is recovered when you reopen LifeBoard. This phone does not sound an alarm while it is locked.</p>`;
}

function searchView() {
  const query = searchText.trim().toLowerCase();
  const has = values => values.some(value => (value || "").toLowerCase().includes(query));
  const matchingTasks = query ? sync.data.tasks.filter(task => !task.isArchived && has([task.title, task.notes])) : [];
  const matches = query ? [
    ...sync.data.events.filter(item => has([item.title, item.notes, item.location])).map(item => ({ type: "Event", title: item.title, detail: dateLabel(item.day), action: `data-action="search-calendar" data-value="${dayString(item.day)}"` })),
    ...sync.data.projects.filter(item => has([item.title, item.notes, item.summary, ...(item.milestones || []).map(x => x.title)])).map(item => ({ type: "Project", title: item.title, action: `data-action="context" data-kind="project" data-id="${esc(item.id)}"` })),
    ...sync.data.subjects.filter(item => has([item.title, item.notes, ...(item.topics || []).map(x => x.title)])).map(item => ({ type: "Subject", title: item.title, action: `data-action="context" data-kind="subject" data-id="${esc(item.id)}"` })),
    ...sync.data.yearMarkers.filter(item => has([item.title, item.notes, item.category])).map(item => ({ type: "Important date", title: item.title, detail: dateLabel(item.startDay), action: `data-action="edit-date" data-id="${esc(item.id)}"` })),
  ] : [];
  return `${pageHead("Search")}
    <label class="search-field">${icon("search")}<span class="visually-hidden">Search LifeBoard</span><input id="search-input" type="search" enterkeyhint="search" placeholder="To Dos, projects, subjects, notes" value="${esc(searchText)}" autocomplete="off"></label>
    ${query ? `${section("To Dos", taskList(matchingTasks, "No matching To Dos", "Try a shorter word."), { count: matchingTasks.length })}${matches.length ? section("Other results", `<div class="group">${matches.map(item => `<button class="row" type="button" ${item.action}><span class="row-label">${esc(item.title)}<small>${esc(item.type)}${item.detail ? `, ${esc(item.detail)}` : ""}</small></span>${icon("disclosure", "icon chevron")}</button>`).join("")}</div>`) : ""}` : empty("Search your LifeBoard", "Find To Dos, events, projects, milestones, subjects and notes.")}`;
}

function settingsView() {
  const installed = window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone;
  const dismissed = safeRead("lifeboard.install.dismissed");
  return `${pageHead("Settings")}
    ${section("Sync", `<div class="group"><div class="row"><span class="row-label">LifeBoard Sync<small>${esc(statusText(sync.status))}</small></span><span class="row-value">${sync.revision ? "On" : "Waiting"}</span></div></div>
      <div class="button-stack"><button class="button secondary full" type="button" data-action="view" data-value="sync-centre">Open Sync Centre</button><button class="button secondary full" type="button" data-action="export-data">Export current phone data</button><button class="button destructive full" type="button" data-action="logout">Sign out and clear this device</button></div>`)}
    ${section("Notifications", `<div class="group"><div class="row"><span class="row-label">Phone notifications<small>${"Notification" in window ? "Reminders and locked-phone Focus alarms are not implemented. The timer catches up when you reopen LifeBoard." : "Reminders and locked-phone alarms are not implemented."}</small></span></div></div>`)}
    ${!installed && !dismissed ? section("Home Screen", `<div class="group"><div class="row"><span class="row-label">Put LifeBoard on your Home Screen<small>In Safari, tap Share, then Add to Home Screen. It opens straight to Today, full screen.</small></span></div></div><div class="button-stack"><button class="button plain" type="button" data-action="dismiss-install">Got it</button></div>`) : ""}`;
}
function backupsView() {
  return `${pageHead("Backups", "Sync keeps your devices aligned. Backups are separate copies.")}
    ${section("On your Mac", `<div class="group"><div class="row"><span class="row-label">Export and restore<small>Restoring a backup and automatic iCloud backup happen on your Mac. You can export this phone’s current data here. Exports contain readable private records.</small></span></div></div>`)}
    <div class="button-stack"><button class="button secondary full" type="button" data-action="export-data">${icon("export")}<span>Export phone recovery copy</span></button></div>`;
}
function recoveryView(trash = false) {
  const rows = sync.data.tasks.filter(task => trash ? task.isArchived : task.isCompleted && !task.isArchived)
    .sort((a, b) => String(b.completedAt || b.archivedAt || b.modifiedAt || "").localeCompare(String(a.completedAt || a.archivedAt || a.modifiedAt || "")));
  return `${pageHead(trash ? "Trash" : "Completed", trash ? "Deleted To Dos stay here until you restore them." : "Finished work. Restore anything to make it active again.")}${rows.length ? `<div class="group">${rows.map(task => `<div class="row recovery-row"><span class="row-label">${esc(task.title)}<small>${task.completedAt && !trash ? `Completed ${new Date(task.completedAt).toLocaleDateString("en-GB", { day: "numeric", month: "short" })}` : task.modifiedAt ? `Changed ${new Date(task.modifiedAt).toLocaleDateString("en-GB", { day: "numeric", month: "short" })}` : ""}</small></span><button class="button tinted" type="button" data-action="restore-task" data-id="${esc(task.id)}">Restore</button></div>`).join("")}</div>` : empty("Nothing to restore", "Restored To Dos return to your list.")}`;
}
function contextView() {
  const project = contextKind === "project", item = (project ? sync.data.projects : sync.data.subjects).find(x => sameID(x.id, contextID));
  if (!item) return `${pageHead("Item unavailable")}${empty("This item was removed", "Go back to More to choose another.")}`;
  const rows = sync.data.tasks.filter(t => !t.isArchived && sameID(project ? t.projectID : t.subjectID, item.id));
  const milestones = (item.milestones || []).slice().sort((a, b) => dayString(a.targetDay).localeCompare(dayString(b.targetDay)));
  return `${pageHead(item.title, project ? "Overall progress can be set manually or calculated from tasks or milestones." : "Course and topic progress are maintained by you. Confidence is your own rating from 1 to 5.")}
    ${project ? `${section("Progress", `<div class="group"><div class="row"><span class="row-label">${rows.filter(t => t.isCompleted).length} of ${rows.length} tasks completed${progressBar(projectProgress(item))}</span><span class="row-value">${projectProgress(item)}%</span></div></div>
      <label class="field" style="margin-top:12px">Overall progress calculation<select id="project-progress-mode"><option value="manual" ${!item.progressMode || item.progressMode === "manual" ? "selected" : ""}>Manual overall progress</option><option value="tasks" ${item.progressMode === "tasks" ? "selected" : ""}>Completed task count</option><option value="milestones" ${item.progressMode === "milestones" ? "selected" : ""}>Completed milestone count</option></select><span class="field-hint">Full project editing and the board view are on your Mac.</span></label>`)}
      ${section("Milestones", milestones.length ? `<div class="group group-with-icons">${milestones.map(m => `<div class="row">${icon(m.isCompleted ? "completed" : "flag")}<span class="row-label">${esc(m.title)}<small>${m.isCompleted ? "Done" : dateLabel(m.targetDay)}</small></span></div>`).join("")}</div>` : empty("No milestones", "Add milestones on your Mac."))}`
    : section("Topics", (item.topics || []).length ? `<div class="group">${item.topics.map(t => `<div class="row"><span class="row-label">${esc(t.title)}<small>Confidence ${t.confidence} of 5</small>${progressBar(t.progress)}</span><span class="row-value">${Math.round(t.progress)}%</span></div>`).join("")}</div>` : empty("No topics", "Add topics on your Mac."))}
    ${section("Active", taskList(rows.filter(taskActive), "Nothing active", "Linked To Dos appear here."), { count: rows.filter(taskActive).length })}
    ${section("Completed", taskList(rows.filter(t => t.isCompleted), "Nothing completed yet", "Finished To Dos collect here."), { count: rows.filter(t => t.isCompleted).length })}`;
}
function revisionView() {
  const subjects = sync.data.subjects.filter(s => !s.archived);
  return `${pageHead("Revision overview", "Your confidence and planned revision for each subject.")}${subjects.length ? `<div class="group">${subjects.map(s => `<button class="row" type="button" data-action="context" data-kind="subject" data-id="${esc(s.id)}"><span class="row-label">${esc(s.title)}<small>Confidence ${s.confidence} of 5, ${plural(sync.data.tasks.filter(t => taskActive(t) && sameID(t.subjectID, s.id)).length, "active To Do", "active To Dos")}</small></span>${icon("disclosure", "icon chevron")}</button>`).join("")}</div>` : empty("No subjects yet", "Subjects you create on your Mac appear here.")}`;
}
function syncCentreView() {
  return `${pageHead("Sync Centre", "Your local changes stay editable while you review conflicting versions.")}
    <div class="group"><div class="row"><span class="row-label">${esc(statusText(sync.status))}<small>${sync.durable ? "Saved on this device" : "Not yet saved on this device"}</small></span></div></div>
    <div class="button-stack"><button class="button secondary full" type="button" data-action="export-data">${icon("export")}<span>Export pending work or a recovery copy</span></button></div>
    ${sync.conflicts.length ? `<form id="conflict-form">${sync.conflicts.map((path, index) => `<section class="conflict"><h2>${esc(path)}</h2><div class="conflict-versions"><div><h3>This device</h3><pre>${esc(JSON.stringify(valueAtPath(sync.data, path), null, 2) || "Deleted")}</pre></div><div><h3>Other device</h3><pre>${esc(JSON.stringify(valueAtPath(sync.conflictRemote, path), null, 2) || "Deleted")}</pre></div></div><label class="field">Keep<select name="choice-${index}" aria-label="Keep" required><option value="">Choose a version</option><option value="local">This device</option><option value="remote">Other device</option></select></label></section>`).join("")}<button class="button primary full" type="submit">Resolve and sync safely</button></form>` : empty("No conflicts", "Independent changes merge automatically. Changes to the same field on two devices wait here for your choice.")}
    <div class="button-stack"><button class="button tinted full" type="button" data-action="sync-now">${icon("sync")}<span>Sync now</span></button></div>`;
}
function aboutView() {
  return `${pageHead("LifeBoard", "Mobile companion for LifeBoard on your Mac.")}
    ${section("Privacy", `<div class="group"><div class="row"><span class="row-label">Your Mac keeps the main copy. Sync sends your LifeBoard records and selected connected-calendar events to your private sync store. Automatic iCloud backup is separate and optional. There are no analytics or ads.</span></div></div>`)}`;
}
function gateView() {
  return `<div class="gate"><img class="brand-mark" src="/icon-192.png" alt="" width="64" height="64"><h1>Verify this connection</h1><p>Your cached work stays on this device until its private workspace is verified.</p>
    <div class="button-stack">${!sync.closed ? `<button class="button secondary full" type="button" data-action="export-data">Export cached work</button><button class="button primary full" type="button" data-action="sync-now">Retry connection</button>` : ""}<a class="button plain full" href="/connect.html">Reconnect</a></div></div>`;
}

/* Render */
function render() {
  if (!sync.scopeReady || sync.closed || (navigator.onLine && !sync.identityVerified)) {
    renderedState = null;
    if (sheet.open) sheet.close();
    screen.dataset.view = "gate";
    screen.innerHTML = gateView();
    navLeading.innerHTML = ""; navTitle.textContent = "";
    updateStatus(); return;
  }
  const state = JSON.stringify({ minute: view === "today" ? nowMinute() : 0, data: sync.data, view, filter, calendarDay, calendarMode, contextKind, contextID, searchText, captureText, previews, captureNotice, focusMinutes, focusCustom, focusTaskID, conflicts: sync.conflicts, done: [...recentlyDone.keys()], day: todayKey() });
  if (state === renderedState) { updateStatus(); return; }
  renderedState = state;
  const scroll = window.scrollY;
  const renderers = { today: todayView, todo: todoView, capture: captureView, calendar: calendarView, more: moreView, dates: datesView, projects: projectsView, subjects: subjectsView, focus: focusView, search: searchView, settings: settingsView, backups: backupsView, about: aboutView, completed: () => recoveryView(), trash: () => recoveryView(true), context: contextView, "sync-centre": syncCentreView, revision: revisionView };
  screen.dataset.view = view;
  screen.innerHTML = (renderers[view] || todayView)();
  tabbar.querySelectorAll("button").forEach(button => {
    const active = button.dataset.tab === view || (moreActive(view) && button.dataset.tab === "more");
    if (active) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
  });
  navLeading.innerHTML = moreActive(view) && view !== "more" ? `<button class="back-link" type="button" data-action="back-more" aria-label="Back to Browse">${icon("back")}<span>Browse</span></button>` : "";
  navTitle.textContent = document.getElementById("page-title")?.textContent || "";
  document.getElementById("add-button").hidden = !["today", "todo", "calendar", "search", "context"].includes(view);
  updateStatus();
  updateBadge();
  window.scrollTo(0, scroll);
  observeTitle();
}
// The navigation bar shows the inline title once the large title has scrolled
// under it, and turns to glass once anything has.
let titleObserver;
function observeTitle() {
  titleObserver?.disconnect();
  const title = document.getElementById("page-title");
  if (!title || !("IntersectionObserver" in window)) { topbar.classList.remove("show-title"); return; }
  titleObserver = new IntersectionObserver(([entry]) => topbar.classList.toggle("show-title", !entry.isIntersecting && entry.boundingClientRect.top < topbar.offsetHeight), { rootMargin: `-${topbar.offsetHeight}px 0px 0px 0px` });
  titleObserver.observe(title);
}
function updateStatus() { statusNode.textContent = statusText(sync.status); statusNode.dataset.tone = statusTone(sync.status); }
function applyCalendarScroll() {
  if (!pendingCalendarScroll || view !== "calendar") return false;
  pendingCalendarScroll = false;
  if (calendarMode !== "day") { window.scrollTo(0, 0); return true; }
  const grid = document.querySelector(".timeline");
  if (!grid) return false;
  const isToday = dayString(calendarDay) === todayKey();
  const first = scheduleFor(calendarDay).find(item => !item.allDay);
  const anchor = isToday ? nowMinute() - 90 : Math.min(8 * 60, first ? first.start : 8 * 60) - 30;
  const top = grid.getBoundingClientRect().top + window.scrollY + Math.max(0, anchor) * HOUR / 60 - topbar.getBoundingClientRect().height - 8;
  window.scrollTo(0, Math.max(0, top));
  return true;
}
function setView(next, push = true) {
  view = next;
  if (view === "calendar") pendingCalendarScroll = true;
  const hash = routeHash({ view, day: view === "calendar" ? dateParts(calendarDay) : null, kind: view === "context" ? contextKind : null, id: view === "context" ? contextID : null });
  if (push && location.hash !== hash) history.pushState(null, "", hash);
  render(); screen.focus({ preventScroll: true });
  if (!applyCalendarScroll()) window.scrollTo(0, 0);
}
function showToast(text, undo = false) {
  toast.hidden = false;
  toast.innerHTML = `<span class="toast-text">${esc(text)}</span>${undo ? '<button type="button" data-action="undo">Undo</button>' : ""}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.hidden = true, 5500);
}
function reversible(change, message, { deferRender = false } = {}) {
  const before = structuredClone(sync.data);
  try { sync.mutate(change); } catch (error) { showToast(error.message); return false; }
  undoOperation = inverseOperation(before, sync.data);
  if (deferRender) requestAnimationFrame(() => render()); else render();
  showToast(message, true);
  return true;
}

/* Factories (unchanged wire shapes) */
function taskFactory(draft) {
  const stamp = timestamp();
  const completionPercent = Math.min(100, Math.max(0, Number(draft.completionPercent) || 0));
  return { id: crypto.randomUUID(), title: draft.title.trim(), notes: draft.notes || "", createdAt: stamp, modifiedAt: stamp,
    isCompleted: completionPercent >= 100, completedAt: completionPercent >= 100 ? stamp : null, isArchived: false, estimatedMinutes: Number(draft.estimatedMinutes) || 30, priority: draft.priority || "none",
    sortOrder: 0, tags: [], completionPercent, ...(draft.recurrence ? { recurrence: draft.recurrence } : {}), ...(draft.subtasks?.length ? { subtasks: draft.subtasks } : {}), ...(draft.dueDay ? { dueDay: draft.dueDay } : {}), ...(draft.scheduledDay ? { scheduledDay: draft.scheduledDay } : {}),
    ...(draft.startMinutes != null && draft.scheduledDay ? { scheduledStartMinutes: draft.startMinutes, scheduledDurationMinutes: Number(draft.estimatedMinutes) || 30 } : {}),
    ...(draft.subjectID ? { subjectID: draft.subjectID } : {}), ...(draft.projectID ? { projectID: draft.projectID } : {}),
  };
}
function eventFactory(draft) {
  return { id: crypto.randomUUID(), title: draft.title.trim(), day: draft.scheduledDay || draft.dueDay || today(), startMinutes: draft.startMinutes ?? 18 * 60,
    endMinutes: (draft.startMinutes ?? 18 * 60) + (Number(draft.estimatedMinutes) || 30), notes: draft.notes || "", location: "", ...(draft.projectID ? { projectID: draft.projectID } : {}) };
}
function dateFactory(draft) {
  return { id: crypto.randomUUID(), title: draft.title.trim(), startDay: draft.dueDay, category: draft.category || "Important Date", notes: draft.notes || "", subjectID: draft.subjectID || null, colour: "orange" };
}

/* Sheets: grabber, swipe or Escape to dismiss, guarded when edited */
const formSnapshot = () => { const form = sheet.querySelector("form"); return form ? JSON.stringify([...new FormData(form).entries()]) : null; };
let sheetGeneration = 0; // each presentation gets a token so a stale close can never dismiss a newer sheet
function presentSheet(html) {
  sheetGeneration++;
  sheetReturnFocus = document.activeElement;
  sheet.classList.remove("closing", "settling"); sheet.style.transform = "";
  sheet.innerHTML = html;
  sheet.showModal();
  sheetBaseline = formSnapshot();
}
function openSheet(title, content, onSubmit, { confirm = "Save", footer = "", autofocus = false } = {}) {
  presentSheet(`<form id="sheet-form"><div class="sheet-grabber" aria-hidden="true"></div><div class="sheet-head"><button class="button plain" type="button" data-action="close-sheet">Cancel</button><h2 id="sheet-title">${esc(title)}</h2><button class="button plain confirm" type="submit">${esc(confirm)}</button></div><div class="sheet-body">${content}${footer}</div></form>`);
  // New items start typing at once; existing ones open to read without raising the keyboard.
  if (autofocus) sheet.querySelector(".sheet-body input:not([type=hidden]),.sheet-body textarea")?.focus({ preventScroll: true });
  else sheet.querySelector(".sheet-head h2")?.setAttribute("tabindex", "-1"), sheet.querySelector(".sheet-head h2")?.focus({ preventScroll: true });
  sheet.querySelector("form").addEventListener("submit", event => { event.preventDefault(); onSubmit(new FormData(event.currentTarget)); });
}
function actionSheet(title, rows) {
  presentSheet(`<div class="sheet-content"><div class="sheet-grabber" aria-hidden="true"></div><div class="sheet-head"><span></span><h2 id="sheet-title">${esc(title)}</h2><button class="button plain confirm" type="button" data-action="close-sheet">Done</button></div><div class="sheet-body"><div class="group group-with-icons">${rows}</div></div></div>`);
}
function closeSheet() {
  editingTaskID = null;
  if (!sheet.open || sheet.classList.contains("closing")) return;
  if (reducedMotion.matches) { sheet.close(); return; }
  sheet.classList.add("closing");
  const generation = sheetGeneration;
  let done = false;
  const finish = () => {
    if (done) return;
    done = true; sheet.removeEventListener("animationend", onEnd);
    // Only the presentation this close began for may be dismissed.
    if (generation !== sheetGeneration || !sheet.classList.contains("closing")) return;
    sheet.classList.remove("closing"); if (sheet.open) sheet.close();
  };
  const onEnd = event => { if (event.target === sheet && !event.pseudoElement && /^(sheet|dialog)-out$/.test(event.animationName)) finish(); };
  sheet.addEventListener("animationend", onEnd);
  setTimeout(finish, 220);
}
function requestCloseSheet() {
  const changed = sheetBaseline !== null && formSnapshot() !== sheetBaseline;
  if (changed && !window.confirm("Discard your changes?")) return false;
  closeSheet(); return true;
}
sheet.addEventListener("cancel", event => { event.preventDefault(); requestCloseSheet(); });
let pressStartedOnBackdrop = false;
sheet.addEventListener("pointerdown", event => { pressStartedOnBackdrop = event.target === sheet; }, true);
sheet.addEventListener("click", event => { if (event.target === sheet && pressStartedOnBackdrop) requestCloseSheet(); pressStartedOnBackdrop = false; });
sheet.addEventListener("close", () => { editingTaskID = null; sheetBaseline = null; sheet.classList.remove("closing", "settling", "is-dragging"); sheet.style.transform = ""; sheetReturnFocus?.focus?.({ preventScroll: true }); });
(() => {
  let startY = 0, startTime = 0, armed = false, dragging = false, offset = 0;
  sheet.addEventListener("pointerdown", event => {
    if (window.innerWidth > 700 || !event.target.closest(".sheet-grabber, .sheet-head") || event.target.closest("button, input, select, textarea")) return;
    armed = true; dragging = false; startY = event.clientY; startTime = event.timeStamp; offset = 0;
  });
  sheet.addEventListener("pointermove", event => {
    if (!armed) return;
    offset = Math.max(0, event.clientY - startY);
    if (!dragging && offset > 6) { dragging = true; sheet.classList.add("is-dragging"); sheet.setPointerCapture(event.pointerId); }
    if (dragging) sheet.style.transform = `translateY(${offset}px)`;
  });
  const end = event => {
    if (!armed) return;
    armed = false;
    if (!dragging) return;
    dragging = false; sheet.classList.remove("is-dragging"); pressStartedOnBackdrop = false;
    const velocity = offset / Math.max(1, event.timeStamp - startTime);
    if ((offset > 110 || velocity > 0.6) && requestCloseSheet()) return;
    sheet.classList.add("settling"); sheet.style.transform = "";
    setTimeout(() => sheet.classList.remove("settling"), 260);
  };
  sheet.addEventListener("pointerup", end);
  sheet.addEventListener("pointercancel", end);
})();

/* Task editing */
function subjectOptions(selected) { return `<option value="">None</option>${sync.data.subjects.filter(x => !x.archived).map(x => `<option value="${esc(x.id)}" ${sameID(x.id, selected) ? "selected" : ""}>${esc(x.title)}</option>`).join("")}`; }
function projectOptions(selected) { return `<option value="">None</option>${sync.data.projects.filter(x => x.status !== "archived").map(x => `<option value="${esc(x.id)}" ${sameID(x.id, selected) ? "selected" : ""}>${esc(x.title)}</option>`).join("")}`; }
// The To Do form follows iOS: grouped rows, label on the left, value on the
// right. New To Dos parse the title as you type (dates, times, durations,
// subjects and priorities, abbreviations included) and show what will be saved.
function taskFields(task = {}, { isNew = false } = {}) {
  const percent = Math.round(task.completionPercent ?? (task.isCompleted ? 100 : 0));
  const planned = dateParts(task.scheduledDay);
  const quick = [["", "None"], [todayKey(), "Today"], [dayString(tomorrow()), "Tomorrow"]];
  const checklist = task.id && task.subtasks?.length ? `<div class="group group-with-icons" aria-label="Checklist">${task.subtasks.map(subtask => `<button type="button" class="row checklist-row" data-action="subtask-toggle" data-id="${esc(task.id)}" data-subtask="${esc(subtask.id)}" aria-pressed="${subtask.isCompleted}">${icon(subtask.isCompleted ? "completed" : "circle")}<span class="row-label">${esc(subtask.title)}</span></button>`).join("")}</div>` : "";
  return `<div class="form-group">
      <label class="form-row stack"><span>Title</span><input class="form-input title" name="title" aria-label="Title" placeholder="${isNew ? "chem worksheet tmr 30m" : "Title"}" value="${esc(task.title || "")}" required maxlength="400" autocomplete="off" enterkeyhint="done" ${isNew ? 'data-parse-title="1"' : ""}></label>
      <label class="form-row stack"><span>Notes</span><textarea class="form-input" name="notes" aria-label="Notes" placeholder="Notes" rows="2">${esc(task.notes || "")}</textarea></label>
    </div>
    ${isNew ? `<p class="form-hint" id="parse-hint" aria-live="polite"></p>` : ""}
    <div class="form-group">
      <div class="quick-days" role="group" aria-label="Plan for">${quick.map(([value, label]) => `<button type="button" data-action="quick-day" data-value="${value}" aria-pressed="${value === planned}">${label}</button>`).join("")}</div>
      ${formRow("Planned date", `<input type="date" name="scheduledDay" value="${planned}">`)}
      ${formRow("Time", `<input type="time" name="startMinutes" value="${task.scheduledStartMinutes == null ? "" : timeLabel(task.scheduledStartMinutes)}">`)}
      ${formRow("Minutes", `<input type="number" inputmode="numeric" name="estimatedMinutes" min="5" max="480" value="${task.estimatedMinutes || 30}">`)}
      ${formRow("Due date", `<input type="date" name="dueDay" value="${dateParts(task.dueDay)}">`)}
    </div>
    <div class="form-group">
      ${formRow("Progress", `<input class="range" type="range" name="completionPercent" min="0" max="100" step="5" value="${percent}" style="--p:${percent}%">`, `<output id="form-progress-value">${percent}%</output>`)}
    </div>
    <div class="form-group">
      ${formRow("Subject", `<select name="subjectID">${subjectOptions(task.subjectID)}</select>`)}
      ${formRow("Project", `<select name="projectID">${projectOptions(task.projectID)}</select>`)}
      ${formRow("Priority", `<select name="priority">${priorityOptions(task.priority)}</select>`)}
      ${formRow("Repeat", `<select name="recurrence"><option value="">Never</option>${["daily", "weekly", "monthly"].map(value => `<option value="${value}" ${task.recurrence?.frequency === value ? "selected" : ""}>${value[0].toUpperCase() + value.slice(1)}</option>`).join("")}</select>`)}
    </div>
    ${checklist}
    <div class="form-group">
      <label class="form-row stack"><span>Checklist</span><textarea class="form-input" name="subtasks" aria-label="Checklist, one step per line" placeholder="Checklist, one step per line" rows="2">${esc((task.subtasks || []).map(subtask => subtask.title).join("\n"))}</textarea></label>
    </div>`;
}
// Live parsing for a new To Do: fills the rows the person hasn't changed and
// says exactly what will be saved. The title saved is the cleaned title.
let parsedTitle = null;
const parsedFields = ["dueDay", "scheduledDay", "startMinutes", "estimatedMinutes", "subjectID", "projectID", "priority"];
function applyTitleParse(input) {
  const form = input.form, hint = document.getElementById("parse-hint");
  // Untouched rows return to the values the sheet opened with, then take
  // whatever the current text says, so deleting a word undoes its effect.
  form.dataset.defaults ||= JSON.stringify(Object.fromEntries(parsedFields.map(name => [name, form.elements[name]?.value ?? ""])));
  const defaults = JSON.parse(form.dataset.defaults);
  const set = (name, value) => { const field = form.elements[name]; if (field && !field.dataset.touched) field.value = value ?? ""; };
  const [draft] = input.value.trim() ? interpretText(input.value.split("\n")[0], sync.data) : [];
  parsedTitle = null;
  const values = { ...defaults };
  if (draft) {
    // As on the Mac: a time plans the To Do on the typed day (or the day in
    // view, or today); a typed date alone is a due date; "anytime" leaves it undated.
    const typedDay = draft.scheduledDay || draft.dueDay;
    if (draft.startMinutes != null) { values.scheduledDay = dayString(typedDay) || defaults.scheduledDay || todayKey(); values.startMinutes = timeLabel(draft.startMinutes); }
    else if (typedDay) { values.dueDay = dayString(typedDay); values.scheduledDay = ""; }
    else if (draft.anytime) values.scheduledDay = "";
    if (/\d\s*(?:h|hr|hrs|hours?|m|mins?|minutes?)\b|half (?:an )?hour|an hour/i.test(input.value)) values.estimatedMinutes = String(draft.estimatedMinutes);
    if (draft.subjectID) values.subjectID = draft.subjectID;
    if (draft.projectID) values.projectID = draft.projectID;
    if (draft.priority && draft.priority !== "none") values.priority = draft.priority;
  }
  for (const name of parsedFields) set(name, values[name]);
  syncQuickDays(form);
  if (!draft) { if (hint) hint.textContent = ""; return; }
  const changed = draft.title !== input.value.trim();
  const facts = [
    form.elements.scheduledDay.value ? `planned ${inlineDay(fromDayString(form.elements.scheduledDay.value))}` : draft.anytime ? "anytime" : "",
    form.elements.startMinutes.value ? `at ${form.elements.startMinutes.value}` : "",
    form.elements.dueDay.value ? `due ${inlineDay(fromDayString(form.elements.dueDay.value))}` : "",
    draft.subjectID ? subjectName(draft.subjectID) : "",
    draft.priority === "high" ? "high priority" : "",
  ].filter(Boolean);
  if (changed && draft.title) parsedTitle = draft.title;
  if (hint) hint.innerHTML = changed || facts.length ? `Saves as <strong>${esc(parsedTitle || input.value.trim())}</strong>${facts.length ? `, ${esc(facts.join(", "))}` : ""}.` : "";
}
function syncQuickDays(form) {
  const value = form.elements.scheduledDay?.value || "";
  form.querySelectorAll("[data-action='quick-day']").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.value === value)));
}
function valuesFromForm(form) {
  const title = String(form.get("title") || "").trim();
  const time = String(form.get("startMinutes") || "");
  return { title, notes: String(form.get("notes") || ""), dueDay: fromDayString(String(form.get("dueDay") || "")), scheduledDay: fromDayString(String(form.get("scheduledDay") || "")),
    startMinutes: time ? Number(time.slice(0, 2)) * 60 + Number(time.slice(3, 5)) : null, estimatedMinutes: Math.min(480, Math.max(5, Number(form.get("estimatedMinutes")) || 30)),
    subjectID: String(form.get("subjectID") || "") || null, projectID: String(form.get("projectID") || "") || null, priority: String(form.get("priority") || "none"), completionPercent: Number(form.get("completionPercent") || 0), recurrence: form.get("recurrence") ? { frequency: String(form.get("recurrence")), interval: 1 } : null, subtaskTitles: String(form.get("subtasks") || "").split(/\n/).map(title => title.trim()).filter(Boolean) };
}
function scheduleClashes(draft, excludingID = null) {
  if (draft.startMinutes == null || !draft.scheduledDay) return false;
  const exclusions = excludingID ? [excludingID] : [];
  const end = draft.startMinutes + draft.estimatedMinutes;
  if (busyIntervals(sync.data, draft.scheduledDay, exclusions).some(span => draft.startMinutes < span.end && Math.min(1440, end) > span.start)) return true;
  return end > 1440 && busyIntervals(sync.data, shiftDay(draft.scheduledDay, 1), exclusions).some(span => span.start < end - 1440 && span.end > 0);
}
function manualAdd(prefill = {}) {
  parsedTitle = null;
  openSheet("New To Do", taskFields({ estimatedMinutes: sync.data.settings?.defaultTaskMinutes || 30, ...prefill }, { isNew: true }), form => {
    const draft = valuesFromForm(form); if (!draft.title) return;
    if (parsedTitle) draft.title = parsedTitle;
    draft.subtasks = draft.subtaskTitles.map(title => ({ id: crypto.randomUUID(), title, isCompleted: false }));
    if (draft.startMinutes != null && !draft.scheduledDay) { showToast("Choose a planned date for that time."); return; }
    if (scheduleClashes(draft)) { showToast("That time overlaps another item. Choose another time or remove the time."); return; }
    if (reversible(data => data.tasks.push(taskFactory(draft)), "To Do added")) closeSheet();
  }, { confirm: "Add", autofocus: true, footer: `<div class="button-stack"><button class="button plain full" type="button" data-action="view" data-value="capture">Capture several, or from a photo</button></div>` });
}
function editTask(id) {
  const found = sync.data.tasks.find(item => sameID(item.id, id)); if (!found || found.isArchived) return;
  const task = structuredClone(found); editingTaskID = id;
  openSheet("Edit To Do", taskFields(task), form => {
    const draft = valuesFromForm(form); if (!draft.title) return;
    if (draft.startMinutes != null && !draft.scheduledDay) { showToast("Choose a planned date for that time."); return; }
    if (scheduleClashes(draft, id)) { showToast("That time overlaps another item. Choose another time."); return; }
    const candidate = structuredClone(task);
    if (draft.recurrence) candidate.recurrence = { ...task.recurrence, ...draft.recurrence }; else delete candidate.recurrence;
    const remaining = [...(task.subtasks || [])]; candidate.subtasks = draft.subtaskTitles.map(title => { const index = remaining.findIndex(s => s.title === title); if (index >= 0) return remaining.splice(index, 1)[0]; return { id: crypto.randomUUID(), title, isCompleted: false }; });
    Object.assign(candidate, { title: draft.title, notes: draft.notes, priority: draft.priority, estimatedMinutes: draft.estimatedMinutes, completionPercent: draft.completionPercent, isCompleted: draft.completionPercent >= 100 });
    candidate.completedAt = candidate.isCompleted ? (candidate.completedAt || timestamp()) : null;
    for (const key of ["dueDay", "scheduledDay", "subjectID", "projectID"]) { if (draft[key]) candidate[key] = draft[key]; else delete candidate[key]; }
    if (draft.startMinutes != null && draft.scheduledDay) { candidate.scheduledStartMinutes = draft.startMinutes; candidate.scheduledDurationMinutes = draft.estimatedMinutes; }
    else { delete candidate.scheduledStartMinutes; delete candidate.scheduledDurationMinutes; }
    const current = sync.data.tasks.find(item => sameID(item.id, id));
    if (!current || current.isArchived) { showToast("This To Do was removed on another device."); closeSheet(); return; }
    const merged = patchDraft(task, candidate, current);
    if (merged.conflicts.length) { showToast(`${merged.conflicts.join(", ")} changed on another device. Reopen the To Do to review.`); return; }
    if (reversible(data => { const index = data.tasks.findIndex(item => sameID(item.id, id)); merged.data.modifiedAt = timestamp(); data.tasks[index] = merged.data; if (!current.isCompleted && merged.data.isCompleted) completeRecurringTask(data, merged.data, timestamp()); }, "To Do updated")) closeSheet();
  }, { footer: `<div class="button-stack"><button class="button destructive full" type="button" data-action="task-delete" data-id="${esc(id)}">${icon("trash")}<span>Delete To Do</span></button></div>` });
}
function dateFields(marker = {}) {
  return `<div class="form-group"><label class="form-row stack"><span>Title</span><input class="form-input title" name="title" aria-label="Title" placeholder="Title" value="${esc(marker.title || "")}" required maxlength="400" autocomplete="off"></label></div>
    <div class="form-group">
      ${formRow("Date", `<input type="date" name="day" value="${dateParts(marker.startDay || today())}" required>`)}
      ${formRow("Type", `<select name="category">${categoryOptions(marker.category || "Test")}</select>`)}
      ${formRow("Subject", `<select name="subjectID">${subjectOptions(marker.subjectID)}</select>`)}
    </div>
    <div class="form-group"><label class="form-row stack"><span>Revision notes</span><textarea class="form-input" name="notes" aria-label="Notes" placeholder="Revision notes" rows="3">${esc(marker.notes || "")}</textarea></label></div>`;
}
function editDate(id = null) {
  const marker = id ? sync.data.yearMarkers.find(item => sameID(item.id, id)) : null;
  openSheet(marker ? "Important Date" : "New Test or Date", dateFields(marker || {}), form => {
    const title = String(form.get("title") || "").trim();
    const day = fromDayString(String(form.get("day") || ""));
    if (!title || !day) return;
    const update = { title, startDay: day, category: String(form.get("category") || "Test"), notes: String(form.get("notes") || ""), subjectID: String(form.get("subjectID") || "") || null };
    const done = reversible(data => {
      if (marker) { const target = data.yearMarkers.find(item => item.id === marker.id); if (target) Object.assign(target, update); }
      else data.yearMarkers.push({ id: crypto.randomUUID(), ...update, colour: "orange" });
    }, marker ? "Important date updated" : "Important date added");
    if (done) closeSheet();
  }, { confirm: marker ? "Save" : "Add", autofocus: !marker, footer: marker ? `<div class="button-stack"><button class="button destructive full" type="button" data-action="delete-date" data-id="${esc(marker.id)}">${icon("trash")}<span>Delete important date</span></button></div>` : "" });
}
function taskMenu(id) {
  const task = sync.data.tasks.find(item => sameID(item.id, id)); if (!task) return;
  const row = (action, iconName, label, extra = "") => `<button class="row ${extra}" type="button" data-action="${action}" data-id="${esc(id)}">${icon(iconName)}<span class="row-label">${label}</span></button>`;
  actionSheet(task.title, [
    row("task-edit", "edit", "Edit details"),
    `<button class="row" type="button" data-action="task-move" data-id="${esc(id)}" data-value="today">${icon("today")}<span class="row-label">Move to Today</span></button>`,
    `<button class="row" type="button" data-action="task-move" data-id="${esc(id)}" data-value="tomorrow">${icon("move")}<span class="row-label">Move to Tomorrow</span></button>`,
    task.scheduledDay ? row("task-unschedule", "unschedule", "Remove from Calendar") : "",
    row("task-focus", "focus", "Start Focus"),
    row("task-delete", "trash", "Delete To Do", "destructive"),
  ].join(""));
}
function addPreviews() {
  const selected = previews.filter(item => item.included && item.title.trim());
  if (!selected.length) { showToast("Select at least one item."); return; }
  if (selected.some(item => item.kind === "date" && !item.dueDay)) { showToast("Add a date to each important date."); return; }
  const candidate = structuredClone(sync.data);
  for (const item of selected) {
    if (item.kind === "date") continue;
    const day = item.scheduledDay || (item.kind === "event" ? (item.dueDay || today()) : null);
    const start = item.startMinutes ?? (item.kind === "event" ? 1080 : null), duration = item.estimatedMinutes || 30;
    if (start != null) {
      if (!day) { showToast("Choose a planned date for each time."); return; }
      if (item.kind === "event" && start + duration > 1440) { showToast("That event crosses midnight. Split it into two reviewed events."); return; }
      const segment = { ...item, scheduledDay: day, startMinutes: start, estimatedMinutes: duration };
      const occupied = busyIntervals(candidate, day, item.existingID ? [item.existingID] : []);
      const following = start + duration > 1440 ? busyIntervals(candidate, shiftDay(day, 1), item.existingID ? [item.existingID] : []) : [];
      if (occupied.some(span => start < span.end && Math.min(1440, start + duration) > span.start) || following.some(span => span.start < start + duration - 1440)) { showToast("A preview time overlaps existing work or another preview. Adjust the time before adding."); return; }
      candidate.tasks.push(taskFactory(segment));
    }
  }
  const added = reversible(data => {
    for (const item of selected) {
      if (item.existingID && item.kind === "task") {
        const target = data.tasks.find(task => task.id === item.existingID);
        if (target) {
          target.title = item.title.trim(); target.modifiedAt = timestamp();
          if (item.dueDay) target.dueDay = item.dueDay;
          if (item.scheduledDay) target.scheduledDay = item.scheduledDay;
          target.estimatedMinutes = item.estimatedMinutes;
          continue;
        }
      }
      if (item.kind === "date") data.yearMarkers.push(dateFactory(item));
      else if (item.kind === "event") data.events.push(eventFactory(item));
      else data.tasks.push(taskFactory(item));
    }
  }, `${plural(selected.length, "item")} added`);
  if (!added) return;
  previews = []; captureText = ""; captureNotice = ""; safeWrite("lifeboard.capture.draft", null); setView(selected.every(item => item.kind === "date") ? "dates" : "todo");
}
function updateBadge() {
  if ("setAppBadge" in navigator && "Notification" in window && Notification.permission === "granted") {
    const count = sync.data.tasks.filter(taskActive).length;
    if (count) navigator.setAppBadge(count).catch(() => {}); else navigator.clearAppBadge?.().catch(() => {});
  }
}

/* Focus */
function startFocus() {
  const taskID = document.getElementById("focus-task")?.value || null;
  const task = sync.data.tasks.find(item => sameID(item.id, taskID));
  const active = { id: crypto.randomUUID(), kind: "focus", taskID, taskTitle: task?.title || "Focus session", plannedMinutes: Math.max(1, Math.min(240, focusMinutes)), startedAt: timestamp(), pausedSeconds: 0 };
  if (task?.subjectID) active.subjectID = task.subjectID; if (task?.projectID) active.projectID = task.projectID;
  try { sync.mutate(data => data.activeFocus = active); } catch (error) { showToast(error.message); return; }
  render();
}
function stopFocus(completed = false) {
  const active = sync.data.activeFocus; if (!active) return;
  const elapsed = Math.max(0, active.plannedMinutes * 60 - focusRemaining(active));
  sync.mutate(data => {
    if (elapsed > 0 && !data.focusSessions.some(row => sameID(row.id, active.id))) data.focusSessions.unshift({ id: active.id, kind: active.kind, taskID: active.taskID, taskTitle: active.taskTitle,
      ...(active.subjectID ? { subjectID: active.subjectID } : {}), ...(active.projectID ? { projectID: active.projectID } : {}), startedAt: active.startedAt, endedAt: timestamp(), focusedSeconds: Math.round(elapsed), completedTimer: completed });
    delete data.activeFocus;
  }); render(); showToast(completed ? "Focus complete" : "Focus session saved");
}
function tickFocus() {
  if (!sync.scopeReady || sync.closed || (navigator.onLine && !sync.identityVerified)) return;
  const active = sync.data.activeFocus; if (!active || active.pausedAt) return;
  const seconds = focusRemaining(active);
  const clock = document.getElementById("focus-clock");
  if (clock) clock.textContent = clockText(seconds);
  const ring = document.getElementById("focus-progress");
  if (ring) ring.setAttribute("stroke-dashoffset", ringOffset(active).toFixed(2));
  if (seconds <= 0) stopFocus(true);
}
function tickNow() {
  const minute = nowMinute();
  const line = document.getElementById("now-line"), stamp = document.getElementById("now-stamp");
  if (line) line.style.top = `${minute * HOUR / 60}px`;
  if (stamp) { stamp.style.top = `${minute * HOUR / 60}px`; stamp.textContent = timeLabel(minute); document.querySelectorAll(".hour-label").forEach(label => label.classList.toggle("is-covered", Math.abs(Number(label.dataset.minute) - minute) < 14)); }
}

/* Completion: the check fills before any work happens, so it never lags */
function toggleTask(button, id) {
  const task = sync.data.tasks.find(item => sameID(item.id, id)); if (!task) return;
  const key = String(id).toLowerCase();
  const completing = !task.isCompleted;
  // Visual state changes in this same frame; the durable mutation follows
  // synchronously, and only the list re-render waits for the next frame.
  button.classList.toggle("checked", completing);
  button.setAttribute("aria-label", `${completing ? "Mark incomplete" : "Complete"} ${task.title}`);
  clearTimeout(recentlyDone.get(key)); recentlyDone.delete(key);
  if (completing) recentlyDone.set(key, setTimeout(() => { recentlyDone.delete(key); if (!document.activeElement?.matches("input,textarea,select")) render(); }, 1400));
  const saved = reversible(data => {
      const target = data.tasks.find(item => sameID(item.id, id)); if (!target) return;
      target.isCompleted = !target.isCompleted; target.completedAt = target.isCompleted ? timestamp() : null; target.completionPercent = target.isCompleted ? 100 : 0; target.modifiedAt = timestamp();
      if (target.isCompleted) completeRecurringTask(data, target, timestamp());
      if (target.isCompleted) data.activity.unshift({ id: crypto.randomUUID(), date: timestamp(), kind: "taskCompleted", title: `Completed “${target.title}”`, ...(target.subjectID ? { subjectID: target.subjectID } : {}), ...(target.projectID ? { projectID: target.projectID } : {}) });
  }, completing ? "Completed" : "Marked as not done", { deferRender: true });
  if (!saved) { button.classList.toggle("checked", !completing); recentlyDone.delete(key); }
}

/* Events */
document.querySelectorAll("[data-icon]").forEach(element => { element.innerHTML = icon(element.dataset.icon); });
tabbar.addEventListener("click", event => { const button = event.target.closest("[data-tab]"); if (button) setView(button.dataset.tab); });
window.addEventListener("scroll", () => topbar.classList.toggle("scrolled", window.scrollY > 4), { passive: true });
document.addEventListener("click", event => {
  const grid = event.target.closest(".timeline-grid");
  if (grid && !event.target.closest(".block")) {
    const minute = Math.max(0, Math.min(1425, Math.round((event.clientY - grid.getBoundingClientRect().top) * 60 / HOUR / 15) * 15));
    manualAdd({ scheduledDay: fromDayString(grid.dataset.slotDay), scheduledStartMinutes: minute });
    return;
  }
  const button = event.target.closest("[data-action]"); if (!button) return;
  const action = button.dataset.action, id = button.dataset.id, value = button.dataset.value;
  if (action === "view") {
    // Moving from a new To Do to Capture carries what was typed.
    const typed = value === "capture" && sheet.open ? sheet.querySelector("[data-parse-title]")?.value.trim() : "";
    if (typed) { captureText = [captureText, typed].filter(Boolean).join("\n"); safeWrite("lifeboard.capture.draft", captureText); }
    if (sheet.open) closeSheet(); setView(value);
  }
  else if (action === "quick-day") { const field = button.form?.elements.scheduledDay; if (field) { field.value = value; field.dataset.touched = "1"; syncQuickDays(button.form); if (!value && button.form.elements.startMinutes) button.form.elements.startMinutes.value = ""; } }
  else if (action === "back-more") setView("more");
  else if (action === "context") { contextKind = button.dataset.kind; contextID = id; setView("context"); }
  else if (action === "calendar-mode") { calendarMode = value; pendingCalendarScroll = true; render(); if (!applyCalendarScroll()) window.scrollTo(0, 0); }
  else if (action === "calendar-today") { calendarDay = today(); setView("calendar"); }
  else if (action === "calendar-pick") { const day = fromDayString(value); if (day) { calendarDay = day; setView("calendar"); } }
  else if (action === "search-calendar") { const day = fromDayString(value); if (day) { calendarDay = day; calendarMode = "day"; setView("calendar"); } }
  else if (action === "calendar-step") { calendarDay = shiftDay(calendarDay, Number(value) * (calendarMode === "week" ? 7 : 1)); setView("calendar"); }
  else if (action === "subtask-toggle") {
    try { sync.mutate(data => { const task = data.tasks.find(t => sameID(t.id, id)), subtask = task?.subtasks?.find(s => s.id === button.dataset.subtask); if (subtask) { subtask.isCompleted = !subtask.isCompleted; task.modifiedAt = timestamp(); } }); } catch (error) { showToast(error.message); return; }
    const pressed = button.getAttribute("aria-pressed") !== "true";
    button.setAttribute("aria-pressed", String(pressed));
    button.querySelector("svg").outerHTML = icon(pressed ? "completed" : "circle");
  }
  else if (action === "restore-task") reversible(data => { const task = data.tasks.find(t => sameID(t.id, id)); if (task) { task.isArchived = false; task.isCompleted = false; task.completionPercent = 0; task.completedAt = null; task.modifiedAt = timestamp(); } }, "To Do restored");
  else if (action === "export-data") downloadJSON(sync.data, "LifeBoard-phone-recovery.json");
  else if (action === "sync-now") sync.sync();
  else if (action === "logout") { fetch("/api/logout", { method: "POST" }).then(async response => { if (!response.ok) throw new Error(); await sync.clearLocal(); captureText = ""; previews = []; location.href = "/connect.html"; }).catch(() => showToast("Couldn't sign out safely. Try again while online.")); }
  else if (["capture", "focus", "calendar"].includes(action)) setView(action);
  // As on the Mac, a To Do added from Today is planned for today and one added
  // from the calendar for the day shown; elsewhere it starts undated.
  else if (action === "manual-add") manualAdd(view === "calendar" ? { scheduledDay: calendarDay } : view === "today" ? { scheduledDay: today() } : {});
  else if (action === "filter") { filter = value; render(); }
  else if (action === "edit") editTask(id);
  else if (action === "task-edit") { closeSheet(); setTimeout(() => editTask(id), reducedMotion.matches ? 0 : 160); }
  else if (action === "task-focus") { focusTaskID = id; closeSheet(); setView("focus"); }
  else if (action === "add-date") editDate();
  else if (action === "edit-date") editDate(id);
  else if (action === "delete-date") { if (reversible(data => { data.yearMarkers = data.yearMarkers.filter(item => item.id !== id); }, "Important date deleted")) closeSheet(); }
  else if (action === "task-menu") taskMenu(id);
  else if (action === "close-sheet") closeSheet();
  else if (action === "toggle") toggleTask(button, id);
  else if (action === "task-move") { const day = value === "today" ? today() : tomorrow(); reversible(data => { const item = data.tasks.find(task => sameID(task.id, id)); if (!item) return; item.scheduledDay = day; item.modifiedAt = timestamp(); }, `Moved to ${value}`); closeSheet(); }
  else if (action === "task-unschedule") { reversible(data => { const item = data.tasks.find(task => sameID(task.id, id)); if (!item) return; delete item.scheduledDay; delete item.scheduledStartMinutes; delete item.scheduledDurationMinutes; item.modifiedAt = timestamp(); }, "Removed from Calendar"); closeSheet(); }
  else if (action === "task-delete") { editingTaskID = null; reversible(data => { const task = data.tasks.find(task => sameID(task.id, id)); if (task) { task.isArchived = true; task.modifiedAt = timestamp(); } }, "Moved to Trash"); closeSheet(); }
  else if (action === "undo" && undoOperation) { let conflicts = []; try { sync.mutate(data => { conflicts = applyInverse(data, undoOperation); }); } catch (error) { showToast(error.message); return; } undoOperation = null; render(); showToast(conflicts.length ? "Some fields changed elsewhere and were kept." : "Undone"); }
  else if (action === "interpret") { clearTimeout(captureTimer); captureText = document.getElementById("capture-text")?.value || captureText; previews = interpretText(captureText, sync.data); document.getElementById("capture-preview").innerHTML = capturePreview(); if (!previews.length) showToast("Type something to capture first."); }
  else if (action === "add-previews") addPreviews();
  else if (action === "focus-preset") { focusMinutes = Number(value); focusCustom = false; render(); }
  else if (action === "focus-custom") { focusCustom = true; render(); document.getElementById("focus-minutes")?.focus(); }
  else if (action === "focus-start") startFocus();
  else if (action === "focus-pause") sync.mutate(data => data.activeFocus.pausedAt = timestamp());
  else if (action === "focus-resume") sync.mutate(data => { const active = data.activeFocus; active.pausedSeconds += (Date.now() - new Date(active.pausedAt).getTime()) / 1000; delete active.pausedAt; });
  else if (action === "focus-stop") stopFocus();
  else if (action === "focus-reset") { sync.mutate(data => delete data.activeFocus); render(); }
  else if (action === "dismiss-install") { safeWrite("lifeboard.install.dismissed", "1"); render(); }
});
let parseTimer;
document.addEventListener("input", event => {
  if (event.target.classList?.contains("range")) event.target.style.setProperty("--p", `${event.target.value}%`);
  if (event.target.dataset.progressId) { const output = event.target.parentElement.querySelector("output"); if (output) output.textContent = `${event.target.value}%`; }
  if (event.target.name === "completionPercent") document.getElementById("form-progress-value").textContent = `${event.target.value}%`;
  if (event.target.dataset.parseTitle) { clearTimeout(parseTimer); const input = event.target; parseTimer = setTimeout(() => applyTitleParse(input), 180); }
  else if (event.target.form?.id === "sheet-form" && event.target.name) { event.target.dataset.touched = "1"; if (event.target.name === "scheduledDay") syncQuickDays(event.target.form); }
  if (event.target.id === "focus-minutes") { const minutes = Number(event.target.value); if (minutes >= 1 && minutes <= 240) focusMinutes = Math.round(minutes); }
  if (event.target.id === "capture-text") {
    captureText = event.target.value; safeWrite("lifeboard.capture.draft", captureText);
    captureNotice = ""; document.getElementById("capture-notice")?.remove();
    clearTimeout(captureTimer); captureTimer = setTimeout(() => { if (view !== "capture") return; previews = interpretText(captureText, sync.data); const target = document.getElementById("capture-preview"); if (target) target.innerHTML = capturePreview(); }, 450);
  }
  if (event.target.id === "search-input") { searchText = event.target.value; const cursor = event.target.selectionStart; render(); const input = document.getElementById("search-input"); input.focus(); input.setSelectionRange(cursor, cursor); }
  const field = event.target.dataset.previewField;
  const item = field && previews.find(entry => entry.id === event.target.closest("[data-preview-id]")?.dataset.previewId);
  if (item) {
    const raw = event.target.type === "checkbox" ? event.target.checked : event.target.value;
    item[field] = ["dueDay", "scheduledDay"].includes(field) ? fromDayString(raw) : field === "startMinutes" ? (raw ? Number(raw.slice(0, 2)) * 60 + Number(raw.slice(3, 5)) : null) : field === "estimatedMinutes" ? Number(raw) : raw;
    if (field === "included") { const button = document.querySelector("[data-action='add-previews']"); const count = previews.filter(entry => entry.included).length; if (button) button.textContent = `Add ${plural(count, "item")}`; }
  }
});
document.addEventListener("change", event => {
  if (event.target.id === "calendar-day") { const day = fromDayString(event.target.value); if (day) { calendarDay = day; setView("calendar"); } return; }
  if (event.target.id === "focus-task") { focusTaskID = event.target.value; return; }
  if (event.target.dataset.progressId) {
    const id = event.target.dataset.progressId, amount = Number(event.target.value);
    reversible(data => {
      const task = data.tasks.find(item => sameID(item.id, id)); if (!task) return;
      const wasDone = task.isCompleted;
      task.completionPercent = amount; task.isCompleted = amount >= 100; task.completedAt = task.isCompleted ? (task.completedAt || timestamp()) : null; task.modifiedAt = timestamp();
      if (!wasDone && task.isCompleted) { completeRecurringTask(data, task, timestamp()); data.activity.unshift({ id: crypto.randomUUID(), date: timestamp(), kind: "taskCompleted", title: `Completed “${task.title}”`, ...(task.subjectID ? { subjectID: task.subjectID } : {}), ...(task.projectID ? { projectID: task.projectID } : {}) }); }
    }, amount >= 100 ? "Completed" : `Progress ${amount}%`);
    return;
  }
  if (event.target.form?.id === "sheet-form" && event.target.name) { event.target.dataset.touched = "1"; if (event.target.name === "scheduledDay") syncQuickDays(event.target.form); }
  if (event.target.id === "project-progress-mode") { try { sync.mutate(data => { const project = data.projects.find(p => sameID(p.id, contextID)); if (project) project.progressMode = event.target.value; }); } catch (error) { showToast(error.message); } render(); return; }
  if (event.target.dataset.previewField === "kind") { const item = previews.find(entry => entry.id === event.target.closest("[data-preview-id]")?.dataset.previewId); if (item) item.kind = event.target.value; render(); return; }
  if (event.target.id === "capture-image") {
    const file = event.target.files?.[0]; if (file) {
      event.target.value = ""; showToast("Reading the photo on this phone"); import("/ocr.js").then(({ recognizeImage }) => recognizeImage(file)).then(result => {
        previews = previewPhotoWithTypedText(captureText, result.text, result.confidence, sync.data);
        captureText = [captureText, result.text].filter(Boolean).join("\n"); safeWrite("lifeboard.capture.draft", captureText);
        captureNotice = result.confidence < 72 ? "Check the photo text carefully before adding anything." : "Photo text added. Check the preview before adding anything.";
        render(); showToast("Photo read. Check the preview.");
      }).catch(() => { captureNotice = "This photo couldn't be read reliably. Your typed text is safe. Try a closer, brighter photo. For handwriting, open it in Photos, use Live Text to copy the words, then paste them here."; previews = interpretText(captureText, sync.data); render(); showToast("The photo text wasn't clear enough."); });
    }
  }
});
window.addEventListener("popstate", () => { route = readRoute(location.hash); calendarDay = fromDayString(route.day) || calendarDay; contextKind = route.kind; contextID = route.id; setView(route.view, false); });
document.addEventListener("submit", event => { if (event.target.id === "conflict-form") { event.preventDefault(); const fields = new FormData(event.target), choices = Object.fromEntries(sync.conflicts.map((path, index) => [path, fields.get(`choice-${index}`)])); downloadJSON({ local: sync.data, remote: sync.conflictRemote }, "LifeBoard-conflict-recovery.json"); try { sync.resolveConflicts(choices); sync.sync(); } catch (error) { showToast(error.message); } } });
sync.addEventListener("change", () => { updateStatus(); if (!sync.scopeReady || sync.closed || (!sync.identityVerified && navigator.onLine)) { render(); return; } if (editingTaskID && !sync.data.tasks.some(t => sameID(t.id, editingTaskID) && !t.isArchived)) { closeSheet(); showToast("This To Do was removed on another device."); } if (!document.activeElement?.matches("input,textarea,select")) render(); });
window.addEventListener("online", () => sync.sync());
window.addEventListener("offline", () => { sync.status = "Offline · changes waiting"; updateStatus(); });
document.addEventListener("visibilitychange", () => { if (!document.hidden) { tickFocus(); tickNow(); render(); sync.sync(); } });
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/service-worker.js").catch(() => {});
setInterval(() => { tickFocus(); if (!document.hidden) sync.sync(); }, 20000);
let lastMinute = nowMinute(), lastDayKey = todayKey();
setInterval(() => {
  tickFocus();
  if (document.hidden) return;
  tickNow();
  const minute = nowMinute(), dayKey = todayKey();
  if (dayKey !== lastDayKey) { if (dayString(calendarDay) === lastDayKey) calendarDay = today(); lastDayKey = dayKey; }
  if (minute !== lastMinute) { lastMinute = minute; if (["today", "calendar"].includes(view) && !sheet.open && !document.activeElement?.matches("input,textarea,select")) render(); }
}, 1000);
sync.ready.then(async () => {
  if (navigator.onLine) { try { await sync.verifyIdentity(); } catch { render(); return; } }
  render(); applyCalendarScroll(); if (route.task) editTask(route.task); sync.sync();
});

// A connection established in another tab must invalidate this tab immediately.
window.addEventListener("storage", event => {
  if (event.key === "lifeboard.connected.workspace" && event.newValue !== sync.storage.workspaceID) {
    sync.closed = true; sync.identityVerified = false; sync.epoch++; clearTimeout(sync.timer);
    sync.status = "Workspace connection changed · reconnect"; render();
  }
});
if ("BroadcastChannel" in window) { const channel = new BroadcastChannel("lifeboard-workspace"); channel.onmessage = event => { if (event.data.workspaceID !== sync.storage.workspaceID) { sync.closed = true; sync.identityVerified = false; sync.epoch++; clearTimeout(sync.timer); sync.status = "Workspace connection changed · reconnect"; render(); } }; }
