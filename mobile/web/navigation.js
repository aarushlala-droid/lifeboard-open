// Tabs: Today, To Do, Calendar and Browse, with Search apart. Every other view
// is reached from Browse (or a link) and shows a Browse back button.
export const primaryViews = ['today','todo','calendar','more','search'];
export const childViews = ['capture','dates','projects','subjects','focus','backups','settings','about','completed','trash','sync-centre','context','revision'];
export const moreActive = view => !primaryViews.includes(view) || view === 'more';
export function readRoute(hash) {
  const values = new URLSearchParams(String(hash).replace(/^#/,''));
  const view = values.get('view') || 'today';
  return { view: [...primaryViews,...childViews].includes(view) ? view : 'today', day: /^\d{4}-\d{2}-\d{2}$/.test(values.get('day') || '') ? values.get('day') : null, kind: values.get('kind'), id: values.get('id'), task: values.get('task') };
}
export function routeHash(route) {
  const values = new URLSearchParams();
  for (const [key,value] of Object.entries(route)) if (value) values.set(key,String(value));
  return `#${values}`;
}
