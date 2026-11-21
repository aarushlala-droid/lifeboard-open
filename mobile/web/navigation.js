export const primaryViews = ['today','todo','capture','calendar','more'];
export const childViews = ['dates','projects','subjects','focus','search','backups','settings','about','completed','trash','sync-centre','context','revision'];
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
