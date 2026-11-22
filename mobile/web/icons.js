// One outline icon family (24px grid, 1.75 stroke, round joins) so every
// screen speaks the same visual language. Icons are decorative: the control
// that contains one always carries its own accessible name.
const paths = {
  today: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
  todo: '<path d="M9 6h11M9 12h11M9 18h11"/><path d="m3.5 6 1.2 1.2L7 5M3.5 12l1.2 1.2L7 11"/><circle cx="5" cy="18" r="1.3"/>',
  calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M8 3v4M16 3v4M3.5 10h17"/>',
  capture: '<path d="M14.5 4.5h-8a3 3 0 0 0-3 3v10a3 3 0 0 0 3 3h10a3 3 0 0 0 3-3v-8"/><path d="m18.6 3.4 2 2L13 13l-2.8.8.8-2.8 7.6-7.6Z"/>',
  more: '<circle cx="12" cy="12" r="9"/><circle cx="8" cy="12" r=".9" fill="currentColor"/><circle cx="12" cy="12" r=".9" fill="currentColor"/><circle cx="16" cy="12" r=".9" fill="currentColor"/>',
  browse: '<rect x="3.5" y="3.5" width="7" height="7" rx="2"/><rect x="13.5" y="3.5" width="7" height="7" rx="2"/><rect x="3.5" y="13.5" width="7" height="7" rx="2"/><rect x="13.5" y="13.5" width="7" height="7" rx="2"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 5 5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  back: '<path d="m14.5 5-7 7 7 7"/>',
  forward: '<path d="m9.5 5 7 7-7 7"/>',
  disclosure: '<path d="m10 7 5 5-5 5"/>',
  ellipsis: '<circle cx="6" cy="12" r="1.2" fill="currentColor"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/><circle cx="18" cy="12" r="1.2" fill="currentColor"/>',
  check: '<path d="m6.5 12.5 3.5 3.5 7.5-8"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  due: '<rect x="4" y="5.5" width="16" height="14.5" rx="2.5"/><path d="M8 3.5v3.5M16 3.5V7M4 10h16M9.5 15h5"/>',
  flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
  photo: '<rect x="3.5" y="4.5" width="17" height="15" rx="3"/><circle cx="9" cy="10" r="1.6"/><path d="m4 17 5-4.5 3.5 3 2.5-2 5 4"/>',
  focus: '<circle cx="12" cy="13" r="7.5"/><path d="M12 13V9.5M9.5 2.5h5M12 2.5v3M18.5 6l1.5-1.5"/>',
  trash: '<path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10 11v5.5M14 11v5.5"/>',
  restore: '<path d="M9 14 4.5 9.5 9 5"/><path d="M4.5 9.5H15a4.5 4.5 0 0 1 0 9h-3"/>',
  subjects: '<path d="M4.5 5.5A2 2 0 0 1 6.5 3.5H19v14H6.5a2 2 0 0 0-2 2Z"/><path d="M4.5 19.5a2 2 0 0 0 2 2H19v-4"/>',
  projects: '<path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2.5h7a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2Z"/>',
  dates: '<rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M8 3v4M16 3v4M3.5 10h17"/><path d="m12 12.5.9 1.9 2.1.3-1.5 1.4.4 2-1.9-1-1.9 1 .4-2-1.5-1.4 2.1-.3Z"/>',
  circle: '<circle cx="12" cy="12" r="8.5"/>',
  completed: '<circle cx="12" cy="12" r="8.5"/><path d="m8.3 12.3 2.5 2.5 5-5.3"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 13.5a7.6 7.6 0 0 0 0-3l2-1.6-2-3.4-2.4 1a7.5 7.5 0 0 0-2.6-1.5L14 2.5h-4l-.4 2.5A7.5 7.5 0 0 0 7 6.5l-2.4-1-2 3.4 2 1.6a7.6 7.6 0 0 0 0 3l-2 1.6 2 3.4 2.4-1a7.5 7.5 0 0 0 2.6 1.5l.4 2.5h4l.4-2.5a7.5 7.5 0 0 0 2.6-1.5l2.4 1 2-3.4Z"/>',
  about: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.6v.2"/>',
  sync: '<path d="M19.5 9A7.5 7.5 0 0 0 6 7.2L4.5 9M4.5 15A7.5 7.5 0 0 0 18 16.8l1.5-2.3"/><path d="M4.5 4.5V9H9M19.5 19.5V15H15"/>',
  backups: '<rect x="3.5" y="13" width="17" height="6.5" rx="2"/><path d="M6 13l2-7.5h8l2 7.5M7.5 16.3h.1"/>',
  revision: '<path d="M4.5 20V10M10 20V5M15.5 20v-7M20.5 20H3.5"/>',
  repeat: '<path d="M17 3.5 20 6.5l-3 3M4 11.5v-1a4 4 0 0 1 4-4h12M7 20.5l-3-3 3-3M20 12.5v1a4 4 0 0 1-4 4H4"/>',
  play: '<path d="M8 5.5v13l10.5-6.5Z"/>',
  pause: '<path d="M8.5 5.5v13M15.5 5.5v13"/>',
  stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="1.5"/>',
  close: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
  move: '<path d="M4.5 12h12M12.5 7l5 5-5 5"/><path d="M20 5v14"/>',
  unschedule: '<rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M8 3v4M16 3v4M3.5 10h17M9.5 13.5l5 5M14.5 13.5l-5 5"/>',
  edit: '<path d="m16.6 4.4 3 3L8.4 18.6 4.5 19.5l.9-3.9Z"/>',
  export: '<path d="M12 15V3.5M7.5 8 12 3.5 16.5 8"/><path d="M5 12.5V19a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 19 19v-6.5"/>',
  signout: '<path d="M14 4.5H7a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h7M10 12h10.5M17 8.5l3.5 3.5-3.5 3.5"/>',
  checklist: '<rect x="4" y="4" width="6" height="6" rx="1.5"/><path d="m5.6 7 1 1 1.8-1.8M13.5 7H20M13.5 17H20"/><rect x="4" y="14" width="6" height="6" rx="1.5"/>',
};

export function icon(name, className = 'icon') {
  const body = paths[name];
  if (!body) throw Error(`Unknown icon ${name}`);
  return `<svg class="${className}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${body}</svg>`;
}
export const iconNames = Object.keys(paths);
