import { LifeBoardSync, valueAtPath, inverseOperation, applyInverse, patchDraft, sameID } from "/sync.js";
import { interpretText, previewPhotoWithTypedText, dayString, fromDayString, today, tomorrow } from "/capture.js";
import { completeRecurringTask } from "/task-features.js";
import { taskSegment, calendarSegments, busyIntervals } from "/scheduling.js";
import { groupTasks } from "/task-groups.js";
import { readRoute, routeHash, moreActive } from "/navigation.js";

const uiIcon = name => ({'capture':'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>','photo':'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 6-6 4 4 3-3 5 5"/></svg>','focus':'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="13" r="8"/><path d="M9 2h6m-3 3v-3m0 11V9m6-3 2-2"/></svg>'})[name];

const sync = new LifeBoardSync();
const timestamp = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const screen = document.getElementById("screen");
const statusNode = document.getElementById("sync-status");
const tabbar = document.getElementById("tabbar");
const sheet = document.getElementById("sheet");
const toast = document.getElementById("toast");
let route = readRoute(location.hash);
let view = route.view;
let calendarDay = fromDayString(route.day) || today();
let calendarMode = "day";
let contextKind = route.kind, contextID = route.id;
let editingTaskID = null;
let sheetReturnFocus = null;
let filter = "Today";
let captureText = safeRead("lifeboard.capture.draft") || "";
let previews = [];
let captureNotice = "";
let captureTimer;
let searchText = "";
let toastTimer;
let undoOperation = null;
let focusMinutes = 25;
let renderedState = null;

const esc = value => String(value ?? "").replace(/[&<>"']/g, character => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
const todayKey = () => dayString(today());
const dateLabel = day => day ? new Date(day.year, day.month - 1, day.day, 12).toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" }) : "Anytime";
const timeLabel = minutes => `${String(Math.floor(minutes / 60)).padStart(2,"0")}:${String(minutes % 60).padStart(2,"0")}`;
const taskActive = task => !task.isCompleted && !task.isArchived;
const subjectName = id => sync.data.subjects.find(item => sameID(item.id,id))?.title;
const projectName = id => sync.data.projects.find(item => sameID(item.id,id))?.title;
const unique = list => [...new Set(list.filter(Boolean))];
const dateParts = day => day ? `${day.year}-${String(day.month).padStart(2,"0")}-${String(day.day).padStart(2,"0")}` : "";

function safeRead(key) { try { return localStorage.getItem(key); } catch { return null; } }
function safeWrite(key,value) { try { if(value===null)localStorage.removeItem(key);else localStorage.setItem(key,value); } catch { showToast("Draft storage unavailable · keep this page open or export your work"); } }
function downloadJSON(value, name) {
  const link = document.createElement("a"); link.href = URL.createObjectURL(new Blob([JSON.stringify(value,null,2)],{type:"application/json"})); link.download = name; link.click(); setTimeout(()=>URL.revokeObjectURL(link.href),1000);
}
function pageHead(eyebrow, title, subtitle = "") {
  return `${moreActive(view) && view !== "more" ? '<button class="text-button" data-action="back-more">‹ More</button>' : ""}<div class="page-head"><p class="eyebrow">${esc(eyebrow)}</p><h1>${esc(title)}</h1>${subtitle ? `<p class="subhead">${esc(subtitle)}</p>` : ""}</div>`;
}
function section(title, body, count = "") {
  return `<section class="section"><div class="section-heading"><h2>${esc(title)}</h2>${count ? `<small>${esc(count)}</small>` : ""}</div>${body}</section>`;
}
function empty(title, detail) { return `<div class="empty"><strong>${esc(title)}</strong>${esc(detail)}</div>`; }
function taskRow(task) {
  const meta = unique([
    task.dueDay ? `Due ${dateLabel(task.dueDay)}` : "",
    task.scheduledDay ? `Planned ${dateLabel(task.scheduledDay)}${task.scheduledStartMinutes != null ? ` · ${timeLabel(task.scheduledStartMinutes)}` : ""}` : "",
    subjectName(task.subjectID), projectName(task.projectID), task.estimatedMinutes ? `${task.estimatedMinutes} min` : "",
  ]);
  return `<div class="task-row ${task.isCompleted ? "completed" : ""}">
    <button class="task-check ${task.isCompleted ? "checked" : ""}" type="button" data-action="toggle" data-id="${esc(task.id)}" aria-label="${task.isCompleted ? "Mark incomplete" : "Complete"} ${esc(task.title)}">${task.isCompleted ? "✓" : ""}</button>
    <button class="task-main" type="button" data-action="edit" data-id="${esc(task.id)}"><div class="task-title">${task.priority === "high" ? '<span class="priority-dot" title="High priority"></span>' : ""}${esc(task.title)}</div>${task.subtasks?.length?`<div class="task-meta">${task.subtasks.filter(s=>s.isCompleted).length}/${task.subtasks.length} subtasks complete</div>`:""}<div class="task-meta">${esc(meta.join(" · "))}</div></button>
    <button class="row-more" type="button" data-action="task-menu" data-id="${esc(task.id)}" aria-label="More options for ${esc(task.title)}">⋯</button>
    <label class="task-progress"><span>${Math.round(task.completionPercent ?? (task.isCompleted ? 100 : 0))}% done</span><input type="range" min="0" max="100" step="5" value="${Math.round(task.completionPercent ?? (task.isCompleted ? 100 : 0))}" data-progress-id="${esc(task.id)}" aria-label="Completion for ${esc(task.title)}"></label>
  </div>`;
}
const taskList = tasks => tasks.length ? `<div class="list">${tasks.map(taskRow).join("")}</div>` : empty("Nothing here yet", "Add a To Do whenever something is on your mind.");

function nextItem() {
  const minute = new Date().getHours() * 60 + new Date().getMinutes();
  const key = todayKey();
  const tasks = sync.data.tasks.filter(task => taskActive(task) && dayString(task.scheduledDay) === key && task.scheduledStartMinutes != null)
    .map(task => ({ id: task.id, title: task.title, start: task.scheduledStartMinutes, end: task.scheduledStartMinutes + (task.scheduledDurationMinutes || task.estimatedMinutes), type: "task" }));
  const events = [...sync.data.events, ...sync.data.externalEvents].filter(event => dayString(event.day) === key && !event.isAllDay)
    .map(event => ({ id: event.id, title: event.title, start: event.startMinutes, end: event.endMinutes, type: "event" }));
  return [...tasks, ...events].filter(item => item.end >= minute).sort((a,b) => a.start - b.start)[0];
}
function scheduleFor(day) {
  return [
    ...sync.data.tasks.map(task=>{const span=taskSegment(task,day);return span?{title:task.title,start:span.start,end:span.end,external:false,taskID:task.id}:null;}),
    ...sync.data.events.map(event=>{const span=calendarSegments(event,day);return span?{title:event.title,start:span.start,end:span.end,external:false}:null;}),
    ...sync.data.externalEvents.map(event=>{const span=calendarSegments(event,day);return span?{title:event.title,start:span.start,end:span.end,external:true,allDay:event.isAllDay}:null;}),
  ].filter(Boolean).sort((a,b)=>a.start-b.start);
}

function scheduleList(day) {
  const rows = scheduleFor(day);
  return rows.length ? `<div class="list">${rows.map(item => `<${item.taskID ? "button" : "div"} class="schedule-row" ${item.taskID ? `type="button" data-action="edit" data-id="${esc(item.taskID)}"` : ""}><span class="schedule-time">${item.allDay ? "All day" : timeLabel(item.start)}</span><div><h3>${esc(item.title)}</h3><p class="task-meta">${item.allDay ? "All day · busy" : `${timeLabel(item.start)}–${timeLabel(item.end)}`}${item.external ? " · Connected calendar" : ""}</p></div></${item.taskID ? "button" : "div"}>`).join("")}</div>` : empty("No time blocks", "To Dos can stay unscheduled until you choose a time.");
}

function todayView() {
  const day = today();
  const key = todayKey();
  const next = nextItem();
  const { carryOver, overdue, todayUntimed } = groupTasks(sync.data.tasks, key, dayString(tomorrow()));
  const important = sync.data.yearMarkers.filter(item => dayString(item.startDay) >= key).sort((a,b) => dayString(a.startDay).localeCompare(dayString(b.startDay))).slice(0,3);
  return `${pageHead(new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" }), "Today", "A clear view of what matters next.")}
    ${section("Next", next ? `<button class="next" type="button" data-action="${next.type === "task" ? "edit" : "calendar"}" data-id="${esc(next.id)}"><span class="eyebrow">NEXT UP</span><div class="next-title">${esc(next.title)}</div><div class="next-meta">${timeLabel(next.start)}–${timeLabel(next.end)}</div></button>` : `<div class="next empty-next"><span class="eyebrow">NEXT UP</span><div class="next-title">Your schedule is clear</div><div class="next-meta">Your To Dos are still here when you need them.</div></div>`)}
    ${section("Quick actions", `<div class="quick-actions"><button class="quick-action" data-action="manual-add"><b>${uiIcon("capture")}</b>Add To Do</button><button class="quick-action" data-action="capture"><b>${uiIcon("photo")}</b>Capture</button><button class="quick-action" data-action="focus"><b>${uiIcon("focus")}</b>Start Focus</button></div>`)}
    ${carryOver.length ? section("Carry over", `<p class="subhead">Missed plans. Move to a new day or remove the plan; deadlines stay the same.</p>${taskList(carryOver)}`, `${carryOver.length} items`) : ""}
    ${sync.conflicts.length ? '<button class="primary full" data-action="view" data-value="sync-centre">Review sync conflicts</button>' : ""}
    ${overdue.length ? section("Overdue", taskList(overdue), `${overdue.length} to do`) : ""}
    ${section("Unscheduled for today", taskList(todayUntimed), `${todayUntimed.length} items`)}
    ${important.length ? section("Important dates", `<div class="list">${important.map(item => `<button class="menu-row" data-action="edit-date" data-id="${esc(item.id)}"><span><strong>${esc(item.title)}</strong><small class="task-meta">${esc(item.category || "Important date")} · ${dateLabel(item.startDay)}${item.subjectID ? ` · ${esc(subjectName(item.subjectID) || "")}` : ""}</small></span><span>›</span></button>`).join("")}</div>`) : ""}
    ${section("Schedule", scheduleList(day), `${scheduleFor(day).length} items`)}`;
}

function todoView() {
  const current = todayKey();
  const next = dayString(tomorrow());
  const { filters: groups } = groupTasks(sync.data.tasks, current, next);
  const selected = groups[filter] || groups.Today;
  return `${pageHead("Your work", "To Do", "A task can live here without a calendar block.")}
    <button class="primary full" type="button" data-action="manual-add" style="margin-bottom:18px">＋ &nbsp; Add To Do</button>
    <div class="filter-strip" role="tablist" aria-label="To Do filters">${Object.keys(groups).map(name => `<button type="button" class="chip ${name === filter ? "selected" : ""}" role="tab" aria-selected="${name === filter}" data-action="filter" data-value="${name}">${name}${groups[name].length ? ` · ${groups[name].length}` : ""}</button>`).join("")}</div>
    ${taskList(selected.sort((a,b) => ({high:3,medium:2,low:1,none:0}[b.priority]||0)-({high:3,medium:2,low:1,none:0}[a.priority]||0)))}`;
}

function previewItem(item, index) {
  const isDate = item.kind === "date";
  return `<div class="preview-item" data-preview-id="${esc(item.id)}">
    <div class="preview-head"><input type="checkbox" aria-label="Include ${esc(item.title)}" data-preview-field="included" ${item.included ? "checked" : ""}><strong>${isDate ? "Important Date" : item.existingID ? "Update To Do" : "Proposed item"} ${index + 1}</strong></div>
    ${item.needsReview ? `<p class="review-note">${esc(item.reviewReason || "Check this item before adding. The existing task could not be matched confidently.")}</p>` : ""}
    <label class="field">Title<input data-preview-field="title" value="${esc(item.title)}"></label>
    <label class="field">Type<select data-preview-field="kind"><option value="task" ${item.kind === "task" ? "selected" : ""}>To Do</option><option value="date" ${isDate ? "selected" : ""}>Important Date</option><option value="event" ${item.kind === "event" ? "selected" : ""}>Timed event</option></select></label>
    ${isDate ? `<div class="field-inline"><label class="field">Date<input type="date" data-preview-field="dueDay" value="${dateParts(item.dueDay)}"></label><label class="field">Category<select data-preview-field="category">${[["Test","Test or exam"],["Deadline","Deadline"],["Important Date","Important date"]].map(([value,label])=>`<option value="${value}" ${value===(item.category||"Important Date")?"selected":""}>${label}</option>`).join("")}</select></label></div>` : `<div class="field-inline"><label class="field">Due date<input type="date" data-preview-field="dueDay" value="${dateParts(item.dueDay)}"></label><label class="field">Planned date<input type="date" data-preview-field="scheduledDay" value="${dateParts(item.scheduledDay)}"></label></div>
    <div class="field-inline"><label class="field">Time<input type="time" data-preview-field="startMinutes" value="${item.startMinutes == null ? "" : timeLabel(item.startMinutes)}"></label><label class="field">Minutes<input type="number" min="5" max="480" data-preview-field="estimatedMinutes" value="${item.estimatedMinutes}"></label></div>`}
    <div class="field-inline"><label class="field">Subject<select data-preview-field="subjectID"><option value="">None</option>${sync.data.subjects.filter(subject => !subject.archived).map(subject => `<option value="${esc(subject.id)}" ${subject.id === item.subjectID ? "selected" : ""}>${esc(subject.title)}</option>`).join("")}</select></label>${isDate ? "" : `<label class="field">Project<select data-preview-field="projectID"><option value="">None</option>${sync.data.projects.filter(project => project.status !== "archived").map(project => `<option value="${esc(project.id)}" ${project.id === item.projectID ? "selected" : ""}>${esc(project.title)}</option>`).join("")}</select></label>`}</div>
    ${isDate ? "" : `<label class="field">Priority<select data-preview-field="priority">${["none","low","medium","high"].map(value => `<option value="${value}" ${item.priority === value ? "selected" : ""}>${value[0].toUpperCase()+value.slice(1)}</option>`).join("")}</select></label>`}
  </div>`;
}
function capturePreview() {
  return previews.length ? section("Editable preview", `${previews.map(previewItem).join("")}<div class="sticky-action"><button class="primary full" data-action="add-previews">Add ${previews.filter(item=>item.included).length} item${previews.filter(item=>item.included).length===1?"":"s"}</button></div>`) : "";
}
function captureView() {
  return `${pageHead("Get it out of your head", "Capture", "Type one item per line. Review the suggestions below before adding anything.")}
    <label class="field">What needs doing?<textarea class="capture-input" id="capture-text" placeholder="Chemistry tomorrow 30 mins&#10;English essay Friday, don’t schedule">${esc(captureText)}</textarea></label>
    ${captureNotice ? `<p class="review-note" role="status" id="capture-notice">${esc(captureNotice)}</p>` : ""}
    <label class="upload"><span class="upload-icon">${uiIcon("photo")}</span><span><b>Try a planner photo or screenshot</b><br>Works best with clear printed text</span><input id="capture-image" type="file" accept="image/*"></label>
    <button class="secondary full" type="button" data-action="interpret" style="margin-bottom:22px">Review captured items</button>
    <div id="capture-preview">${capturePreview()}</div>`;
}

function calendarView() {
  const day = calendarDay;
  const untimed = sync.data.tasks.filter(task => taskActive(task) && dayString(task.scheduledDay) === dayString(day) && task.scheduledStartMinutes == null);
  const days = calendarMode === "week" ? Array.from({length:7},(_,i)=>fromDayString(dayString(new Date(day.year,day.month-1,day.day+i,12)))) : [day];
  return `${pageHead("When you intend to do it", "Calendar", "Scheduling is optional. Task blocks open their editable details.")}
    <div class="date-navigation"><button class="secondary" data-action="calendar-step" data-value="-1" aria-label="Previous ${calendarMode}">‹</button><label class="field">Date<input type="date" id="calendar-day" value="${dateParts(day)}"></label><button class="secondary" data-action="calendar-step" data-value="1" aria-label="Next ${calendarMode}">›</button></div>
    <div class="filter-strip"><button class="chip" data-action="calendar-today">Today</button>${["day","week"].map(mode=>`<button class="chip ${mode===calendarMode?"selected":""}" data-action="calendar-mode" data-value="${mode}" aria-pressed="${mode===calendarMode}">${mode==='day'?'Day':'7 days'}</button>`).join("")}</div>
    ${days.map(date=>section(dateLabel(date),scheduleList(date))).join("")}
    ${untimed.length ? section("Planned, without a time", taskList(untimed)) : ""}
    <button class="secondary full" type="button" data-action="manual-add">Add a To Do</button>`;
}

function moreView() {
  const rows = [["completed","Completed"],["trash","Trash"],["sync-centre","Sync Centre"],["revision","Revision overview"],["dates","Important Dates"],["projects","Projects"],["subjects","Subjects"],["focus","Focus"],["search","Search"],["backups","Backups"],["settings","Settings"],["about","About LifeBoard"]];
  return `${pageHead("Your workspace", "More", "Context and tools when you need them.")}
    <div class="list">${rows.map(([id,label]) => `<button type="button" class="menu-row" data-action="view" data-value="${id}"><span>${label}</span><span>›</span></button>`).join("")}</div>`;
}

function datesView() {
  const dates = [...sync.data.yearMarkers].sort((a,b) => dayString(a.startDay).localeCompare(dayString(b.startDay)));
  const upcoming = dates.filter(item => dayString(item.startDay) >= todayKey());
  const past = dates.filter(item => dayString(item.startDay) < todayKey()).reverse();
  const rows = items => `<div class="list">${items.map(item => `<button class="menu-row" data-action="edit-date" data-id="${esc(item.id)}"><span><strong>${esc(item.title)}</strong><small class="task-meta">${esc(item.category || "Important date")} · ${dateLabel(item.startDay)}${item.subjectID ? ` · ${esc(subjectName(item.subjectID) || "")}` : ""}</small>${item.notes ? `<small class="task-meta">${esc(item.notes)}</small>` : ""}</span><span>›</span></button>`).join("")}</div>`;
  return `${pageHead("Prepare ahead", "Important Dates", "Keep tests, exams and deadlines visible without adding a calendar block.")}
    <button class="primary full" type="button" data-action="add-date" style="margin-bottom:18px">＋ &nbsp; Add test or date</button>
    ${section("Coming up", upcoming.length ? rows(upcoming) : empty("Nothing coming up", "Add a test or date you need to prepare for."))}
    ${past.length ? section("Past dates", rows(past.slice(0,15))) : ""}`;
}

function projectsView() {
  const projects = sync.data.projects.filter(project => project.status !== "archived");
  return `${pageHead("Longer-term progress", "Projects")}${projects.length ? projects.map(project => {
    const active = sync.data.tasks.filter(task => taskActive(task) && task.projectID === project.id);
    const milestone = project.milestones?.filter(item => !item.isCompleted).sort((a,b) => dayString(a.targetDay).localeCompare(dayString(b.targetDay)))[0];
    return section(project.title, `<div class="list"><div class="context-row"><div><p class="subhead">${esc(project.summary || `${active.length} active To Dos`)}</p>${milestone ? `<p class="task-meta">Next milestone · ${esc(milestone.title)} · ${dateLabel(milestone.targetDay)}</p>` : ""}<div class="project-progress"><i style="width:${Math.max(0,Math.min(100,project.progress||0))}%"></i></div></div><span class="context-value">${project.progressMode === "tasks" ? taskCompletion(project.id) : project.progressMode === "milestones" ? milestoneCompletion(project) : Math.round(project.progress||0)}%<br>${esc(project.progressMode || "manual")} progress</span></div>${active.slice(0,5).map(taskRow).join("")}<button class="menu-row" data-action="context" data-kind="project" data-id="${esc(project.id)}">Show all ${active.length} active tasks and milestones <span>›</span></button></div>`);
  }).join("") : empty("No projects yet", "Projects created on your Mac will appear here.")}`;
}

function subjectsView() {
  const subjects = sync.data.subjects.filter(subject => !subject.archived);
  return `${pageHead("Learning context", "Subjects")}${subjects.length ? `<div class="list">${subjects.map(subject => {
    const active = sync.data.tasks.filter(task => taskActive(task) && task.subjectID === subject.id);
    const nextTest=sync.data.yearMarkers.filter(item=>item.subjectID===subject.id&&dayString(item.startDay)>=todayKey()).sort((a,b)=>dayString(a.startDay).localeCompare(dayString(b.startDay)))[0];
    return `<button class="context-row menu-row" data-action="context" data-kind="subject" data-id="${esc(subject.id)}"><div><h3>${esc(subject.title)}</h3><p class="subhead">${active.length} upcoming To Dos${subject.lastActivity ? ` · Worked ${new Date(subject.lastActivity).toLocaleDateString("en-GB")}` : ""}</p>${nextTest ? `<p class="task-meta">Next test · ${esc(nextTest.title)} · ${dateLabel(nextTest.startDay)}</p>` : ""}<div class="project-progress"><i style="width:${Math.max(0,Math.min(100,subject.progress||0))}%"></i></div></div><span class="context-value">${Math.round(subject.progress||0)}%<br>course (manual)</span></button>`;
  }).join("")}</div>` : empty("No subjects yet", "Subjects created on your Mac will appear here.")}`;
}

function focusRemaining(active) {
  if (!active) return focusMinutes*60;
  const end = active.pausedAt ? new Date(active.pausedAt).getTime() : Date.now();
  const elapsed = Math.max(0, (end - new Date(active.startedAt).getTime())/1000 - (active.pausedSeconds||0));
  return Math.max(0, Math.ceil(active.plannedMinutes*60 - elapsed));
}
function focusView() {
  const active = sync.data.activeFocus;
  const remaining = focusRemaining(active);
  const clock = `${String(Math.floor(remaining/60)).padStart(2,"0")}:${String(remaining%60).padStart(2,"0")}`;
  return `${pageHead("Do the work", "Focus", "Choose one thing, then give it your attention.")}
    ${!active ? `<div class="focus-presets">${[25,50].map(value=>`<button class="chip ${focusMinutes===value?"selected":""}" data-action="focus-preset" data-value="${value}">${value} min</button>`).join("")}<button class="chip ${![25,50].includes(focusMinutes)?"selected":""}" data-action="focus-custom">Custom</button></div>
      <label class="field">Work on (optional)<select id="focus-task"><option value="">General focus</option>${sync.data.tasks.filter(taskActive).map(task=>`<option value="${esc(task.id)}">${esc(task.title)}</option>`).join("")}</select></label>` : ""}
    <div class="focus-hero"><p class="eyebrow">${active?.kind === "shortBreak" ? "BREAK" : "FOCUS"}</p><div id="focus-clock" class="focus-clock">${clock}</div><p class="subhead">${esc(active?.taskTitle || "A little time to make progress")}</p>
    <div class="focus-controls">${active ? `<button class="secondary" data-action="${active.pausedAt ? "focus-resume":"focus-pause"}">${active.pausedAt ? "Resume":"Pause"}</button><button class="secondary" data-action="focus-stop">Stop</button>` : `<button class="primary" data-action="focus-start">Start Focus</button>`}</div></div>
    ${active ? `<button class="text-button" data-action="focus-reset" style="display:block;margin:14px auto">Reset timer</button>` : `<p class="subhead" style="text-align:center;margin-top:15px">Elapsed time is recovered when you reopen LifeBoard. This phone does not deliver a locked-screen alarm.</p>`}`;
}

function searchView() {
  const query = searchText.trim().toLowerCase();
  const matchingTasks = query ? sync.data.tasks.filter(task => task.title.toLowerCase().includes(query) || (task.notes||"").toLowerCase().includes(query)) : [];
  const matches = query ? [
    ...sync.data.events.filter(item => item.title.toLowerCase().includes(query)).map(item => ["Event", item.title]),
    ...sync.data.projects.filter(item => [item.title,item.notes,item.summary,...(item.milestones||[]).map(x=>x.title)].some(value=>(value||"").toLowerCase().includes(query))).map(item => ["Project", item.title]),
    ...sync.data.subjects.filter(item => [item.title,item.notes].some(value=>(value||"").toLowerCase().includes(query))).map(item => ["Subject", item.title]),
    ...sync.data.yearMarkers.filter(item => [item.title,item.notes,item.category].some(value=>(value||"").toLowerCase().includes(query))).map(item => ["Important Date", item.title]),
  ] : [];
  return `${pageHead("Find anything", "Search")}
    <label class="field"><span class="visually-hidden">Search LifeBoard</span><input id="search-input" type="search" placeholder="Search To Dos, projects, notes…" value="${esc(searchText)}" autocomplete="off"></label>
    ${query ? `${section("To Dos", taskList(matchingTasks))}${matches.length ? section("More results", `<div class="list">${matches.map(([type,title])=>`<div class="context-row"><div><h3>${esc(title)}</h3><p class="task-meta">${type}</p></div></div>`).join("")}</div>`) : ""}` : empty("Search your LifeBoard", "Find tasks, events, projects, milestones, subjects and notes.")}`;
}

function settingsView() {
  const installed = window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone;
  const dismissed = safeRead("lifeboard.install.dismissed");
  return `${pageHead("Make it yours", "Settings")}
    ${section("Sync", `<div class="list"><div class="context-row"><div><h3>LifeBoard Sync</h3><p class="subhead">${esc(sync.status)}</p></div><span class="context-value">${sync.revision ? "On" : "Waiting"}</span></div></div>`)}
    <button class="secondary full" data-action="view" data-value="sync-centre">Open Sync Centre</button><button class="secondary full" data-action="export-data">Export current phone data</button><button class="secondary full" data-action="logout">Sign out and clear this device</button>
    ${section("Notifications", `<div class="list"><div class="context-row"><div><h3>Phone notifications</h3><p class="subhead">${"Notification" in window ? "Reminders and locked-phone Focus alarms are not implemented. The timer catches up when you reopen LifeBoard." : "Reminders and locked-phone alarms are not implemented."}</p></div></div></div>`)}
    ${!installed && !dismissed ? `<div class="install-help"><strong>Put LifeBoard on your Home Screen</strong><p>Open this page in Safari, tap Share, then Add to Home Screen. It opens straight to Today.</p><button class="text-button" data-action="dismiss-install">Got it</button></div>` : ""}`;
}
function backupsView() { return `<button class="secondary full" data-action="export-data">Export phone recovery copy</button>${pageHead("Your data", "Backups", "Sync keeps devices aligned. Backups remain separate.")}${section("Mac backups", `<div class="list"><div class="context-row"><div><h3>Export and restore</h3><p class="subhead">Restore and automatic iCloud backup are desktop-only. You can export this phone’s current data below. Backups contain readable private records.</p></div></div></div>`)}`; }
function recoveryView(trash = false) {
  const rows = sync.data.tasks.filter(task => trash ? task.isArchived : task.isCompleted && !task.isArchived);
  return `${pageHead("Recover your work", trash ? "Trash" : "Completed", trash ? "Deleted tasks stay here until restored." : "Completed work can be made active again.")}${rows.length ? `<div class="list">${rows.map(task=>`<div class="context-row"><div><h3>${esc(task.title)}</h3><p class="task-meta">${task.completedAt?new Date(task.completedAt).toLocaleDateString('en-GB'):''}</p></div><button class="secondary" data-action="restore-task" data-id="${esc(task.id)}">Restore</button></div>`).join("")}</div>` : empty("Nothing to restore", "Your recovered tasks return to To Do.")}`;
}
function taskCompletion(id) { const rows=sync.data.tasks.filter(t=>t.projectID===id&&!t.isArchived); return rows.length?Math.round(rows.filter(t=>t.isCompleted).length*100/rows.length):0; }
function milestoneCompletion(project) { const rows=project.milestones||[];return rows.length?Math.round(rows.filter(m=>m.isCompleted).length*100/rows.length):0; }
function contextView() {
  const project=contextKind==='project', item=(project?sync.data.projects:sync.data.subjects).find(x=>x.id===contextID);
  if(!item)return `${pageHead('Context','Item unavailable')}${empty('Item removed','Return to More to choose another item.')}`;
  const rows=sync.data.tasks.filter(t=>!t.isArchived&&(project?t.projectID:t.subjectID)===item.id);
  return `${pageHead(project?'Project':'Subject',item.title,project?'Overall progress can be maintained manually or calculated from tasks or milestones.':'Course and topic progress are manually maintained. Confidence is your self-assessment on a scale from 1 to 5.')}
    ${project?`<label class="field">Overall progress calculation<select id="project-progress-mode"><option value="manual" ${!item.progressMode||item.progressMode==='manual'?'selected':''}>Manual overall progress</option><option value="tasks" ${item.progressMode==='tasks'?'selected':''}>Completed task count</option><option value="milestones" ${item.progressMode==='milestones'?'selected':''}>Completed milestone count</option></select></label><p class="subhead">${rows.filter(t=>t.isCompleted).length}/${rows.length} tasks completed. Full project editing and Kanban are desktop-only.</p>${section('Milestones',(item.milestones||[]).map(m=>`<p>${m.isCompleted?'✓':'○'} ${esc(m.title)} · ${dateLabel(m.targetDay)}</p>`).join('')||empty('No milestones','Add milestones on your Mac.'))}`:section('Topics',(item.topics||[]).map(t=>`<p>${esc(t.title)} · ${Math.round(t.progress)}% progress · confidence ${t.confidence}/5</p>`).join('')||empty('No topics','Add topics on your Mac.'))}
    ${section('Active tasks',taskList(rows.filter(taskActive)))}${section('Completed tasks',taskList(rows.filter(t=>t.isCompleted)))}`;
}
function revisionView() {
  return `${pageHead('Learning','Revision overview','Self-assessed confidence and planned revision for each subject.')}${sync.data.subjects.filter(s=>!s.archived).map(s=>section(s.title,`<p class="subhead">Confidence ${s.confidence}/5 · ${sync.data.tasks.filter(t=>taskActive(t)&&t.subjectID===s.id).length} active tasks</p><button class="secondary" data-action="context" data-kind="subject" data-id="${esc(s.id)}">Review topics and tasks</button>`)).join('')}`;
}
function conflictValue(document,path) { return valueAtPath(document,path); }
function syncCentreView() {
  return `${pageHead('Your devices','Sync Centre','Your local changes remain editable while you review conflicting versions.')}
    <p class="subhead">${esc(sync.status)} · ${sync.durable?'Saved on this device':'Not yet saved on this device'}</p>
    <button class="secondary full" data-action="export-data">Export pending work / recovery copy</button>
    ${sync.conflicts.length?`<form id="conflict-form">${sync.conflicts.map((path,index)=>`<section class="section"><h2>${esc(path)}</h2><div class="conflict-versions"><div><h3>This device</h3><pre>${esc(JSON.stringify(conflictValue(sync.data,path),null,2)||'Deleted')}</pre></div><div><h3>Other device</h3><pre>${esc(JSON.stringify(conflictValue(sync.conflictRemote,path),null,2)||'Deleted')}</pre></div></div><label class="field">Keep<select name="choice-${index}" aria-label="Keep" required><option value="">Choose a version</option><option value="local">This device</option><option value="remote">Other device</option></select></label></section>`).join('')}<button class="primary full" type="submit">Resolve and sync safely</button></form>`:empty('No conflicts','Independent fields merge automatically. Same-field changes need a choice.')}
    <button class="secondary full" data-action="sync-now">Sync now</button>`;
}
function aboutView() { return `${pageHead("A calm place to make progress", "LifeBoard", "Version 4.1 · Mobile companion")}${section("Privacy", `<div class="list"><div class="context-row"><p class="subhead">Your Mac keeps a local copy. Sync sends your LifeBoard records and selected connected-calendar events to your private sync store. Automatic iCloud backup is separate and optional. No analytics or ads.</p></div></div>`)}`; }

function render() {
  if(!sync.scopeReady||sync.closed||(navigator.onLine&&!sync.identityVerified)){
    renderedState=null;
    if(sheet.open)sheet.close();
    screen.innerHTML=empty("Verify this connection", "Your cached work stays on this device until its private workspace is verified.")+'<div style="display:grid;gap:10px">'+
      (!sync.closed ? '<button class="secondary full" data-action="export-data">Export cached work</button><button class="primary full" data-action="sync-now">Retry connection</button>' : '')+
      '<a class="secondary full" style="display:block;text-align:center" href="/connect.html">Reconnect</a></div>';
    updateStatus();return;
  }
  const state=JSON.stringify({data:sync.data,view,filter,calendarDay,calendarMode,contextKind,contextID,searchText,captureText,previews,captureNotice,focusMinutes,conflicts:sync.conflicts});
  if(state===renderedState){updateStatus();return;}
  renderedState=state;
  const scroll=window.scrollY;
  const renderers = {today:todayView,todo:todoView,capture:captureView,calendar:calendarView,more:moreView,dates:datesView,projects:projectsView,subjects:subjectsView,focus:focusView,search:searchView,settings:settingsView,backups:backupsView,about:aboutView,completed:()=>recoveryView(),trash:()=>recoveryView(true),context:contextView,"sync-centre":syncCentreView,revision:revisionView};
  screen.dataset.view = view;
  screen.innerHTML = (renderers[view] || todayView)();
  tabbar.querySelectorAll("button").forEach(button => {
    const active = button.dataset.tab === view || (moreActive(view) && button.dataset.tab === "more");
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current","page"); else button.removeAttribute("aria-current");
  });
  updateStatus();
  updateBadge();
  window.scrollTo(0,scroll);
}
function updateStatus() { statusNode.textContent = sync.status; }
function setView(next, push = true) { view = next; const hash=routeHash({view,day:view==='calendar'?dateParts(calendarDay):null,kind:view==='context'?contextKind:null,id:view==='context'?contextID:null});if(push&&location.hash!==hash)history.pushState(null,'',hash); render(); screen.focus({preventScroll:true}); window.scrollTo(0,0); }
function showToast(text, undo = false) {
  toast.hidden = false;
  toast.innerHTML = `${esc(text)}${undo ? ' <button type="button" data-action="undo">Undo</button>' : ""}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.hidden = true, 5500);
}
function reversible(change, message) {
  const before = structuredClone(sync.data);
  sync.mutate(change);
  undoOperation = inverseOperation(before,sync.data);
  render();
  showToast(`${message} · saving on this device`, true);
}
function taskFactory(draft) {
  const stamp = timestamp();
  const completionPercent=Math.min(100,Math.max(0,Number(draft.completionPercent)||0));
  return { id: crypto.randomUUID(), title: draft.title.trim(), notes: draft.notes || "", createdAt: stamp, modifiedAt: stamp,
    isCompleted: completionPercent>=100, completedAt: completionPercent>=100?stamp:null, isArchived: false, estimatedMinutes: Number(draft.estimatedMinutes)||30, priority: draft.priority||"none",
    sortOrder: 0, tags: [], completionPercent, ...(draft.recurrence ? {recurrence:draft.recurrence}:{}), ...(draft.subtasks?.length ? {subtasks:draft.subtasks}:{}), ...(draft.dueDay ? {dueDay:draft.dueDay} : {}), ...(draft.scheduledDay ? {scheduledDay:draft.scheduledDay} : {}),
    ...(draft.startMinutes != null && draft.scheduledDay ? {scheduledStartMinutes:draft.startMinutes,scheduledDurationMinutes:Number(draft.estimatedMinutes)||30} : {}),
    ...(draft.subjectID ? {subjectID:draft.subjectID} : {}), ...(draft.projectID ? {projectID:draft.projectID} : {}),
  };
}
function eventFactory(draft) {
  return {id:crypto.randomUUID(),title:draft.title.trim(),day:draft.scheduledDay||draft.dueDay||today(),startMinutes:draft.startMinutes??18*60,
    endMinutes:(draft.startMinutes??18*60)+(Number(draft.estimatedMinutes)||30),notes:draft.notes||"",location:"",...(draft.projectID?{projectID:draft.projectID}:{})};
}
function dateFactory(draft) {
  return {id:crypto.randomUUID(),title:draft.title.trim(),startDay:draft.dueDay,category:draft.category||"Important Date",notes:draft.notes||"",subjectID:draft.subjectID||null,colour:"orange"};
}
function openSheet(title, content, onSubmit) {
  sheet.innerHTML = `<div class="sheet-head"><h2 id="sheet-title">${esc(title)}</h2><button class="sheet-close" type="button" data-action="close-sheet" aria-label="Close">×</button></div><form id="sheet-form">${content}<div class="sheet-actions"><button class="secondary" type="button" data-action="close-sheet">Cancel</button><button class="primary" type="submit">Save</button></div></form>`;
  sheetReturnFocus = document.activeElement;
  sheet.showModal();
  sheet.querySelector("input,textarea,select")?.focus();
  sheet.querySelector("form").addEventListener("submit", event => { event.preventDefault(); onSubmit(new FormData(event.currentTarget)); });
}
function taskFields(task = {}) {
  return `<label class="field">Title<input name="title" value="${esc(task.title||"")}" required maxlength="400"></label><label class="field">Notes<textarea name="notes" aria-label="Notes">${esc(task.notes||"")}</textarea></label>
    <div class="field-inline"><label class="field">Due date<input type="date" name="dueDay" value="${dateParts(task.dueDay)}"></label><label class="field">Planned date<input type="date" name="scheduledDay" value="${dateParts(task.scheduledDay)}"></label></div>
    <div class="field-inline"><label class="field">Time<input type="time" name="startMinutes" value="${task.scheduledStartMinutes==null?"":timeLabel(task.scheduledStartMinutes)}"></label><label class="field">Minutes<input type="number" name="estimatedMinutes" min="5" max="480" value="${task.estimatedMinutes||30}"></label></div>
    <div class="field-inline"><label class="field">Subject<select name="subjectID"><option value="">None</option>${sync.data.subjects.filter(x=>!x.archived).map(x=>`<option value="${esc(x.id)}" ${x.id===task.subjectID?"selected":""}>${esc(x.title)}</option>`).join("")}</select></label><label class="field">Project<select name="projectID"><option value="">None</option>${sync.data.projects.filter(x=>x.status!=="archived").map(x=>`<option value="${esc(x.id)}" ${x.id===task.projectID?"selected":""}>${esc(x.title)}</option>`).join("")}</select></label></div>
    <label class="field">Priority<select name="priority">${["none","low","medium","high"].map(value=>`<option value="${value}" ${task.priority===value?"selected":""}>${value[0].toUpperCase()+value.slice(1)}</option>`).join("")}</select></label>
    ${task.subtasks?.length?`<div class="list">${task.subtasks.map(subtask=>`<button type="button" class="menu-row" data-action="subtask-toggle" data-id="${esc(task.id)}" data-subtask="${esc(subtask.id)}" aria-pressed="${subtask.isCompleted}">${subtask.isCompleted?'✓':'○'} ${esc(subtask.title)}</button>`).join('')}</div>`:''}
    <label class="field">Repeat<select name="recurrence"><option value="">Does not repeat</option>${['daily','weekly','monthly'].map(value=>`<option value="${value}" ${task.recurrence?.frequency===value?'selected':''}>${value[0].toUpperCase()+value.slice(1)}</option>`).join('')}</select></label>
    <label class="field">Subtasks · one per line<textarea name="subtasks">${esc((task.subtasks||[]).map(subtask=>subtask.title).join('\n'))}</textarea></label>
    <label class="field">Completion · <output id="form-progress-value">${Math.round(task.completionPercent ?? (task.isCompleted ? 100 : 0))}%</output><input type="range" name="completionPercent" min="0" max="100" step="5" value="${Math.round(task.completionPercent ?? (task.isCompleted ? 100 : 0))}"></label>`;
}
function valuesFromForm(form) {
  const title = String(form.get("title")||"").trim();
  const time = String(form.get("startMinutes")||"");
  return {title,notes:String(form.get("notes")||""),dueDay:fromDayString(String(form.get("dueDay")||"")),scheduledDay:fromDayString(String(form.get("scheduledDay")||"")),
    startMinutes:time?Number(time.slice(0,2))*60+Number(time.slice(3,5)):null,estimatedMinutes:Math.min(480,Math.max(5,Number(form.get("estimatedMinutes"))||30)),
    subjectID:String(form.get("subjectID")||"")||null,projectID:String(form.get("projectID")||"")||null,priority:String(form.get("priority")||"none"),completionPercent:Number(form.get("completionPercent")||0),recurrence:form.get("recurrence")?{frequency:String(form.get("recurrence")),interval:1}:null,subtaskTitles:String(form.get("subtasks")||"").split(/\n/).map(title=>title.trim()).filter(Boolean)};
}
function scheduleClashes(draft, excludingID=null) {
  if(draft.startMinutes==null||!draft.scheduledDay)return false;
  const exclusions=excludingID?[excludingID]:[];
  const end=draft.startMinutes+draft.estimatedMinutes;
  if(busyIntervals(sync.data,draft.scheduledDay,exclusions).some(span=>draft.startMinutes<span.end&&Math.min(1440,end)>span.start))return true;
  return end>1440&&busyIntervals(sync.data,addDays(draft.scheduledDay,1),exclusions).some(span=>span.start<end-1440&&span.end>0);
}
function manualAdd() {
  openSheet("Add a To Do", taskFields({estimatedMinutes:sync.data.settings?.defaultTaskMinutes||30}), form => {
    const draft = valuesFromForm(form); if (!draft.title) return;
    draft.subtasks=draft.subtaskTitles.map(title=>({id:crypto.randomUUID(),title,isCompleted:false}));
    if(draft.startMinutes!=null&&!draft.scheduledDay){showToast("Choose a planned date for that time");return;}
    if(scheduleClashes(draft)){showToast("That time overlaps another item · choose another time or remove the time");return;}
    reversible(data => data.tasks.push(taskFactory(draft)), "To Do added");
    sheet.close();
  });
}
function editTask(id) {
  const found = sync.data.tasks.find(item => sameID(item.id,id)); if (!found || found.isArchived) return;
  const task=structuredClone(found); editingTaskID=id;
  openSheet("Edit To Do", taskFields(task), form => {
    const draft = valuesFromForm(form); if (!draft.title) return;
    if(draft.startMinutes!=null&&!draft.scheduledDay){showToast("Choose a planned date for that time");return;}
    if(scheduleClashes(draft,id)){showToast("That time overlaps another item · choose another time");return;}
    const candidate=structuredClone(task);
    if(draft.recurrence)candidate.recurrence={...task.recurrence,...draft.recurrence};else delete candidate.recurrence;
    const remaining=[...(task.subtasks||[])];candidate.subtasks=draft.subtaskTitles.map(title=>{const index=remaining.findIndex(s=>s.title===title);if(index>=0)return remaining.splice(index,1)[0];return {id:crypto.randomUUID(),title,isCompleted:false};});
    Object.assign(candidate,{title:draft.title,notes:draft.notes,priority:draft.priority,estimatedMinutes:draft.estimatedMinutes,completionPercent:draft.completionPercent,isCompleted:draft.completionPercent>=100});
    candidate.completedAt=candidate.isCompleted?(candidate.completedAt||timestamp()):null;
    for(const key of ["dueDay","scheduledDay","subjectID","projectID"]) {if(draft[key])candidate[key]=draft[key];else delete candidate[key];}
    if(draft.startMinutes!=null&&draft.scheduledDay){candidate.scheduledStartMinutes=draft.startMinutes;candidate.scheduledDurationMinutes=draft.estimatedMinutes;}
    else{delete candidate.scheduledStartMinutes;delete candidate.scheduledDurationMinutes;}
    const current=sync.data.tasks.find(item=>sameID(item.id,id));
    if(!current||current.isArchived){showToast("This task was removed on another device");sheet.close();return;}
    const merged=patchDraft(task,candidate,current);
    if(merged.conflicts.length){showToast(`New changes to ${merged.conflicts.join(', ')} · reopen the task to review`);return;}
    reversible(data=>{const index=data.tasks.findIndex(item=>sameID(item.id,id));merged.data.modifiedAt=timestamp();data.tasks[index]=merged.data;if(!current.isCompleted&&merged.data.isCompleted)completeRecurringTask(data,merged.data,timestamp());},"To Do updated");sheet.close();
  });
}
function dateFields(marker = {}) {
  return `<label class="field">Title<input name="title" value="${esc(marker.title || "")}" required maxlength="400"></label>
    <label class="field">Date<input type="date" name="day" value="${dateParts(marker.startDay || today())}" required></label>
    <label class="field">Type<select name="category">${[["Test","Test or exam"],["Deadline","Deadline"],["Important Date","Important date"]].map(([value,label])=>`<option value="${value}" ${marker.category===value?"selected":""}>${label}</option>`).join("")}</select></label>
    <label class="field">Subject<select name="subjectID"><option value="">None</option>${sync.data.subjects.filter(item=>!item.archived).map(item=>`<option value="${esc(item.id)}" ${marker.subjectID===item.id?"selected":""}>${esc(item.title)}</option>`).join("")}</select></label>
    <label class="field">Revision notes<textarea name="notes" aria-label="Notes">${esc(marker.notes||"")}</textarea></label>`;
}
function editDate(id = null) {
  const marker = id ? sync.data.yearMarkers.find(item => sameID(item.id,id)) : null;
  openSheet(marker ? "Edit Important Date" : "Add Test or Date", dateFields(marker || {}), form => {
    const title = String(form.get("title")||"").trim();
    const day = fromDayString(String(form.get("day")||""));
    if(!title || !day)return;
    const update = {title,startDay:day,category:String(form.get("category")||"Test"),notes:String(form.get("notes")||""),subjectID:String(form.get("subjectID")||"")||null};
    reversible(data => {
      if(marker){const target=data.yearMarkers.find(item=>item.id===marker.id);if(target)Object.assign(target,update);}
      else data.yearMarkers.push({id:crypto.randomUUID(),...update,colour:"orange"});
    },marker ? "Important date updated" : "Important date added");
    sheet.close();
  });
  if(marker){
    sheet.querySelector(".sheet-actions").insertAdjacentHTML("afterend",`<button class="text-button" type="button" data-action="delete-date" data-id="${esc(marker.id)}" style="color:var(--danger);margin-top:12px">Delete important date</button>`);
  }
}
function taskMenu(id) {
  const task = sync.data.tasks.find(item => sameID(item.id,id)); if (!task) return;
  sheet.innerHTML = `<div class="sheet-head"><h2 id="sheet-title">${esc(task.title)}</h2><button class="sheet-close" data-action="close-sheet" aria-label="Close">×</button></div><div class="list">
    <button class="menu-row" data-action="task-move" data-id="${esc(id)}" data-value="today">Move to Today <span>›</span></button><button class="menu-row" data-action="task-move" data-id="${esc(id)}" data-value="tomorrow">Move to Tomorrow <span>›</span></button>
    <button class="menu-row" data-action="task-unschedule" data-id="${esc(id)}">Remove from Calendar <span>›</span></button><button class="menu-row" data-action="task-delete" data-id="${esc(id)}" style="color:var(--danger)">Delete To Do <span>›</span></button></div>`;
  sheet.showModal();
}
function addPreviews() {
  const selected = previews.filter(item => item.included && item.title.trim());
  if (!selected.length) { showToast("Select at least one item"); return; }
  if (selected.some(item => item.kind === "date" && !item.dueDay)) { showToast("Add a date to each Important Date"); return; }
  const candidate=structuredClone(sync.data);
  for(const item of selected){
    if(item.kind==="date")continue;
    const day=item.scheduledDay||(item.kind==="event"?(item.dueDay||today()):null);
    const start=item.startMinutes??(item.kind==="event"?1080:null),duration=item.estimatedMinutes||30;
    if(start!=null){
      if(!day){showToast("Choose a planned date for each time");return;}
      if(item.kind==="event"&&start+duration>1440){showToast("That event crosses midnight · split it into two reviewed events");return;}
      const segment={...item,scheduledDay:day,startMinutes:start,estimatedMinutes:duration};
      const occupied=busyIntervals(candidate,day,item.existingID?[item.existingID]:[]);
      const next=start+duration>1440?busyIntervals(candidate,addDays(day,1),item.existingID?[item.existingID]:[]):[];
      if(occupied.some(span=>start<span.end&&Math.min(1440,start+duration)>span.start)||next.some(span=>span.start<start+duration-1440)){showToast("A preview time overlaps existing work or another preview · adjust the time before adding");return;}
      candidate.tasks.push(taskFactory(segment));
    }
  }
  reversible(data => {
    for (const item of selected) {
      if (item.existingID && item.kind === "task") {
        const target = data.tasks.find(task => task.id === item.existingID);
        if (target) {
          target.title=item.title.trim(); target.modifiedAt=timestamp();
          if (item.dueDay) target.dueDay=item.dueDay;
          if (item.scheduledDay) target.scheduledDay=item.scheduledDay;
          target.estimatedMinutes=item.estimatedMinutes;
          continue;
        }
      }
      if (item.kind === "date") data.yearMarkers.push(dateFactory(item));
      else if (item.kind === "event") data.events.push(eventFactory(item));
      else data.tasks.push(taskFactory(item));
    }
  }, `${selected.length} item${selected.length===1?"":"s"} added`);
  previews=[];captureText="";captureNotice="";safeWrite("lifeboard.capture.draft",null);setView(selected.every(item=>item.kind==="date")?"dates":"todo");
}
function updateBadge() {
  if ("setAppBadge" in navigator && "Notification" in window && Notification.permission === "granted") {
    const count=sync.data.tasks.filter(taskActive).length;
    if (count) navigator.setAppBadge(count).catch(()=>{}); else navigator.clearAppBadge?.().catch(()=>{});
  }
}
function startFocus() {
  const taskID = document.getElementById("focus-task")?.value || null;
  const task = sync.data.tasks.find(item=>item.id===taskID);
  const active={id:crypto.randomUUID(),kind:"focus",taskID,taskTitle:task?.title||"Focus session",plannedMinutes:focusMinutes,startedAt:timestamp(),pausedSeconds:0};
  if(task?.subjectID)active.subjectID=task.subjectID;if(task?.projectID)active.projectID=task.projectID;
  sync.mutate(data=>data.activeFocus=active);render();
}
function stopFocus(completed=false) {
  const active=sync.data.activeFocus;if(!active)return;
  const elapsed=Math.max(0,active.plannedMinutes*60-focusRemaining(active));
  sync.mutate(data=>{
    if(elapsed>0&&!data.focusSessions.some(row=>sameID(row.id,active.id)))data.focusSessions.unshift({id:active.id,kind:active.kind,taskID:active.taskID,taskTitle:active.taskTitle,
      ...(active.subjectID?{subjectID:active.subjectID}:{}),...(active.projectID?{projectID:active.projectID}:{}),startedAt:active.startedAt,endedAt:timestamp(),focusedSeconds:Math.round(elapsed),completedTimer:completed});
    delete data.activeFocus;
  });render();showToast(completed?"Focus complete":"Focus session saved");
}
function tickFocus() {
  if(!sync.scopeReady||sync.closed||(navigator.onLine&&!sync.identityVerified))return;
  const active=sync.data.activeFocus;if(!active || active.pausedAt)return;
  const seconds=focusRemaining(active);
  const clock=document.getElementById("focus-clock");
  if(clock)clock.textContent=`${String(Math.floor(seconds/60)).padStart(2,"0")}:${String(seconds%60).padStart(2,"0")}`;
  if(seconds<=0)stopFocus(true);
}

tabbar.addEventListener("click", event => { const button=event.target.closest("[data-tab]");if(button)setView(button.dataset.tab); });
document.getElementById("search-button").addEventListener("click",()=>setView("search"));
document.addEventListener("click",event=>{
  const button=event.target.closest("[data-action]");if(!button)return;
  const action=button.dataset.action,id=button.dataset.id,value=button.dataset.value;
  if(action==="view")setView(value);
  else if(action==="back-more")setView("more");
  else if(action==="context"){contextKind=button.dataset.kind;contextID=id;setView("context");}
  else if(action==="calendar-mode"){calendarMode=value;render();}
  else if(action==="calendar-today"){calendarDay=today();setView("calendar");}
  else if(action==="calendar-step"){calendarDay=fromDayString(dayString(new Date(calendarDay.year,calendarDay.month-1,calendarDay.day+Number(value)*(calendarMode==='week'?7:1),12)));setView("calendar");}
  else if(action==="subtask-toggle"){sync.mutate(data=>{const task=data.tasks.find(t=>sameID(t.id,id)),subtask=task?.subtasks?.find(s=>s.id===button.dataset.subtask);if(subtask){subtask.isCompleted=!subtask.isCompleted;task.modifiedAt=timestamp();}});button.setAttribute('aria-pressed',button.getAttribute('aria-pressed')!=='true');button.textContent=button.textContent.startsWith('✓')?button.textContent.replace('✓','○'):button.textContent.replace('○','✓');}
  else if(action==="restore-task")reversible(data=>{const task=data.tasks.find(t=>sameID(t.id,id));if(task){task.isArchived=false;task.isCompleted=false;task.completionPercent=0;task.completedAt=null;task.modifiedAt=timestamp();}},"Task restored");
  else if(action==="export-data")downloadJSON(sync.data,"LifeBoard-phone-recovery.json");
  else if(action==="sync-now")sync.sync();
  else if(action==="logout"){fetch('/api/logout',{method:'POST'}).then(async response=>{if(!response.ok)throw new Error();await sync.clearLocal();captureText='';previews=[];location.href='/connect.html';}).catch(()=>showToast('Could not sign out safely · retry while online'));}
  else if(["capture","focus","calendar"].includes(action))setView(action);
  else if(action==="manual-add")manualAdd();
  else if(action==="filter"){filter=value;render();}
  else if(action==="edit")editTask(id);
  else if(action==="add-date")editDate();
  else if(action==="edit-date")editDate(id);
  else if(action==="delete-date"){reversible(data=>{data.yearMarkers=data.yearMarkers.filter(item=>item.id!==id);},"Important date deleted");sheet.close();}
  else if(action==="task-menu")taskMenu(id);
  else if(action==="close-sheet")sheet.close();
  else if(action==="toggle")reversible(data=>{
    const task=data.tasks.find(item=>sameID(item.id,id));if(!task)return;
    task.isCompleted=!task.isCompleted;task.completedAt=task.isCompleted?timestamp():null;task.completionPercent=task.isCompleted?100:0;task.modifiedAt=timestamp();
    if(task.isCompleted)completeRecurringTask(data,task,timestamp());
    if(task.isCompleted)data.activity.unshift({id:crypto.randomUUID(),date:timestamp(),kind:"taskCompleted",title:`Completed “${task.title}”`,...(task.subjectID?{subjectID:task.subjectID}:{}),...(task.projectID?{projectID:task.projectID}:{})});
  },"To Do updated");
  else if(action==="task-move"){const day=value==="today"?today():tomorrow();reversible(data=>{const item=data.tasks.find(task=>sameID(task.id,id));item.scheduledDay=day;item.modifiedAt=timestamp();},`Moved to ${value}`);sheet.close();}
  else if(action==="task-unschedule"){reversible(data=>{const item=data.tasks.find(task=>sameID(task.id,id));delete item.scheduledDay;delete item.scheduledStartMinutes;delete item.scheduledDurationMinutes;item.modifiedAt=timestamp();},"Removed from Calendar");sheet.close();}
  else if(action==="task-delete"){reversible(data=>{const task=data.tasks.find(task=>sameID(task.id,id));if(task){task.isArchived=true;task.modifiedAt=timestamp();}},"Moved to Trash");sheet.close();}
  else if(action==="undo"&&undoOperation){let conflicts=[];sync.mutate(data=>{conflicts=applyInverse(data,undoOperation);});undoOperation=null;render();showToast(conflicts.length?"Some fields changed elsewhere and were preserved":"Action undone");}
  else if(action==="interpret"){clearTimeout(captureTimer);captureText=document.getElementById("capture-text")?.value||captureText;previews=interpretText(captureText,sync.data);document.getElementById("capture-preview").innerHTML=capturePreview();if(!previews.length)showToast("Add some text to capture first");}
  else if(action==="add-previews")addPreviews();
  else if(action==="focus-preset"){focusMinutes=Number(value);render();}
  else if(action==="focus-custom"){const input=prompt("Focus minutes (1–240)",String(focusMinutes));if(input){focusMinutes=Math.max(1,Math.min(240,Number(input)||25));render();}}
  else if(action==="focus-start")startFocus();
  else if(action==="focus-pause")sync.mutate(data=>data.activeFocus.pausedAt=timestamp());
  else if(action==="focus-resume")sync.mutate(data=>{const active=data.activeFocus;active.pausedSeconds+=(Date.now()-new Date(active.pausedAt).getTime())/1000;delete active.pausedAt;});
  else if(action==="focus-stop")stopFocus();
  else if(action==="focus-reset"){sync.mutate(data=>delete data.activeFocus);render();}
  else if(action==="dismiss-install"){safeWrite("lifeboard.install.dismissed","1");render();}
});
document.addEventListener("input",event=>{
  if(event.target.name==="completionPercent")document.getElementById("form-progress-value").textContent=`${event.target.value}%`;
  if(event.target.dataset.progressId)event.target.closest(".task-progress").querySelector("span").textContent=`${event.target.value}% done`;
  if(event.target.id==="capture-text"){
    captureText=event.target.value;safeWrite("lifeboard.capture.draft",captureText);
    captureNotice="";document.getElementById("capture-notice")?.remove();
    clearTimeout(captureTimer);captureTimer=setTimeout(()=>{if(view!=="capture")return;previews=interpretText(captureText,sync.data);const target=document.getElementById("capture-preview");if(target)target.innerHTML=capturePreview();},450);
  }
  if(event.target.id==="search-input"){searchText=event.target.value;const cursor=event.target.selectionStart;render();const input=document.getElementById("search-input");input.focus();input.setSelectionRange(cursor,cursor);}
  const field=event.target.dataset.previewField;
  const item=field&&previews.find(entry=>entry.id===event.target.closest("[data-preview-id]")?.dataset.previewId);
  if(item){const raw=event.target.type==="checkbox"?event.target.checked:event.target.value;
    item[field]=["dueDay","scheduledDay"].includes(field)?fromDayString(raw):field==="startMinutes"?(raw?Number(raw.slice(0,2))*60+Number(raw.slice(3,5)):null):field==="estimatedMinutes"?Number(raw):raw;
  }
});
document.addEventListener("change",event=>{
  if(event.target.id==="calendar-day"){const day=fromDayString(event.target.value);if(day){calendarDay=day;setView('calendar');}return;}
  if(event.target.id==="project-progress-mode"){sync.mutate(data=>{const project=data.projects.find(p=>p.id===contextID);if(project)project.progressMode=event.target.value;});render();return;}
  if(event.target.dataset.previewField==="kind") {const item=previews.find(entry=>entry.id===event.target.closest("[data-preview-id]")?.dataset.previewId);if(item)item.kind=event.target.value;render();return;}
  if(event.target.dataset.progressId){
    const id=event.target.dataset.progressId, amount=Number(event.target.value);
    reversible(data=>{const task=data.tasks.find(item=>sameID(item.id,id));if(!task)return;const wasDone=task.isCompleted;task.completionPercent=amount;task.isCompleted=amount>=100;task.completedAt=task.isCompleted?(task.completedAt||timestamp()):null;task.modifiedAt=timestamp();if(!wasDone&&task.isCompleted)completeRecurringTask(data,task,timestamp());if(!wasDone&&task.isCompleted)data.activity.unshift({id:crypto.randomUUID(),date:timestamp(),kind:"taskCompleted",title:`Completed “${task.title}”`});},"Progress updated");
  }
  if(event.target.id==="capture-image"){
    const file=event.target.files?.[0];if(file){event.target.value="";showToast("Reading photo on this phone…");import("/ocr.js").then(({recognizeImage})=>recognizeImage(file)).then(result=>{
      previews=previewPhotoWithTypedText(captureText,result.text,result.confidence,sync.data);
      captureText=[captureText,result.text].filter(Boolean).join("\n");safeWrite("lifeboard.capture.draft",captureText);
      captureNotice=result.confidence<72?"Check the photo text carefully before adding anything.":"Photo text added. Check the preview before adding anything.";
      render();showToast("Photo read · check the preview");
    }).catch(()=>{captureNotice="I couldn't read this photo reliably. Your typed text is safe. Try a closer, brighter photo. For handwriting, open it in iPhone Photos, use Live Text to copy the words, then paste them here.";previews=interpretText(captureText,sync.data);render();showToast("Photo text wasn't clear enough");});
    }
  }
});
sheet.addEventListener('close',()=>{editingTaskID=null;sheetReturnFocus?.focus?.();});
window.addEventListener('popstate',()=>{route=readRoute(location.hash);calendarDay=fromDayString(route.day)||calendarDay;contextKind=route.kind;contextID=route.id;setView(route.view,false);});
document.addEventListener('submit',event=>{if(event.target.id==='conflict-form'){event.preventDefault();const fields=new FormData(event.target), choices=Object.fromEntries(sync.conflicts.map((path,index)=>[path,fields.get(`choice-${index}`)]));downloadJSON({local:sync.data,remote:sync.conflictRemote},'LifeBoard-conflict-recovery.json');try{sync.resolveConflicts(choices);sync.sync();}catch(error){showToast(error.message);} }});
sync.addEventListener("change",()=>{updateStatus();if(!sync.scopeReady||sync.closed||(!sync.identityVerified&&navigator.onLine)){render();return;}if(editingTaskID&&!sync.data.tasks.some(t=>sameID(t.id,editingTaskID)&&!t.isArchived)){sheet.close();showToast('Task removed on another device');}if(!document.activeElement?.matches("input,textarea,select"))render();});
window.addEventListener("online",()=>sync.sync());
window.addEventListener("offline",()=>{sync.status="Offline · changes waiting";updateStatus();});
document.addEventListener("visibilitychange",()=>{if(!document.hidden){tickFocus();sync.sync();}});
if("serviceWorker" in navigator)navigator.serviceWorker.register("/service-worker.js").catch(()=>{});
setInterval(()=>{tickFocus();if(!document.hidden)sync.sync();},20000);
setInterval(tickFocus,1000);
sync.ready.then(async()=>{
  if(navigator.onLine){try{await sync.verifyIdentity();}catch{render();return;}}
  render();if(route.task)editTask(route.task);sync.sync();
});

// A connection established in another tab must invalidate this tab immediately.
window.addEventListener('storage',event=>{
  if(event.key==='lifeboard.connected.workspace'&&event.newValue!==sync.storage.workspaceID){
    sync.closed=true;sync.identityVerified=false;sync.epoch++;clearTimeout(sync.timer);
    sync.status='Workspace connection changed · reconnect';render();
  }
});
if('BroadcastChannel' in window){const channel=new BroadcastChannel('lifeboard-workspace');channel.onmessage=event=>{if(event.data.workspaceID!==sync.storage.workspaceID){sync.closed=true;sync.identityVerified=false;sync.epoch++;clearTimeout(sync.timer);sync.status='Workspace connection changed · reconnect';render();}};}
