const keyFor = day => day ? `${day.year}-${String(day.month).padStart(2, "0")}-${String(day.day).padStart(2, "0")}` : "";

export function groupTasks(tasks, current, next) {
  const active = tasks.filter(task => !task.isCompleted && !task.isArchived);
  const plannedBefore = task => Boolean(task.scheduledDay) && keyFor(task.scheduledDay) < current;
  const dueBefore = task => Boolean(task.dueDay) && keyFor(task.dueDay) < current;
  const plannedToday = task => keyFor(task.scheduledDay) === current;
  const dueToday = task => keyFor(task.dueDay) === current;
  const carryOver = active.filter(plannedBefore);
  const overdue = active.filter(task => dueBefore(task) && !plannedBefore(task));
  const todayUntimed = active.filter(task => !plannedBefore(task) && !dueBefore(task)
    && (plannedToday(task) || dueToday(task)) && task.scheduledStartMinutes == null);

  const todayWorkload = active.filter(task => plannedBefore(task) || dueBefore(task) || plannedToday(task) || dueToday(task));
  const tomorrowWorkload = active.filter(task => !todayWorkload.includes(task) && (keyFor(task.dueDay) === next || keyFor(task.scheduledDay) === next));
  return {
    todayWorkload,
    carryOver,
    overdue,
    todayUntimed,
    filters: {
      Overdue: active.filter(dueBefore),
      "Carry over": carryOver,
      Today: todayWorkload,
      Tomorrow: tomorrowWorkload,
      Upcoming: active.filter(task => !todayWorkload.includes(task) && !tomorrowWorkload.includes(task) && [task.dueDay, task.scheduledDay].some(day => day && keyFor(day) > next)),
      Anytime: active.filter(task => !task.dueDay && !task.scheduledDay),
    },
  };
}
