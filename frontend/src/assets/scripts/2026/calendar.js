/**
 * FullCalendar wiring for the 2026 design system.
 *
 * A page declares the calendar mount as <div data-fc></div>; this module
 * initializes FullCalendar with the seed events below, themes it via the
 * 2026 toolbar (we hide FC's built-in toolbar and let our own buttons drive
 * .next() / .prev() / .today() / .changeView()), and re-renders on theme
 * change so colors stay in sync.
 */

import { Calendar } from '@fullcalendar/core';
import dayGridPlugin from '@fullcalendar/daygrid';
import timeGridPlugin from '@fullcalendar/timegrid';
import listPlugin from '@fullcalendar/list';
import interactionPlugin from '@fullcalendar/interaction';

const SEED_EVENTS = [
  { title: 'Q2 kickoff',         start: '2026-04-01T09:00', classNames: ['fc-cat-work'] },
  { title: 'Design review',      start: '2026-04-02T11:00', classNames: ['fc-cat-team'] },
  { title: 'Lunch w/ Marcus',    start: '2026-04-03T13:00', classNames: ['fc-cat-personal'] },
  { title: '🎂 Sara birthday',    start: '2026-04-05',      allDay: true, classNames: ['fc-cat-birthday'] },
  { title: 'Standup',            start: '2026-04-07T10:00', classNames: ['fc-cat-work'] },
  { title: 'Brand workshop',     start: '2026-04-07T14:00', classNames: ['fc-cat-team'] },
  { title: 'All-hands',          start: '2026-04-08T15:00', classNames: ['fc-cat-work'] },
  { title: '✈ Lisbon trip',       start: '2026-04-09',      end: '2026-04-13', allDay: true, classNames: ['fc-cat-travel'] },
  { title: 'Investor sync',      start: '2026-04-14T16:00', classNames: ['fc-cat-work'] },
  { title: '📑 Tax deadline',     start: '2026-04-15',      allDay: true, classNames: ['fc-cat-finance'] },
  { title: 'Invoice approval',   start: '2026-04-17T12:00', classNames: ['fc-cat-finance'] },
  { title: 'Run with Mira',      start: '2026-04-20T07:00', classNames: ['fc-cat-personal'] },
  { title: 'Earth day talk',     start: '2026-04-22T14:00', classNames: ['fc-cat-team'] },
  { title: '✓ Dependency merge', start: '2026-04-23',      allDay: true, classNames: ['fc-cat-work'] },
  { title: 'Coffee w/ Rita',     start: '2026-04-24T10:00', classNames: ['fc-cat-personal'] },
  { title: 'PR reviews',         start: '2026-04-24T15:00', classNames: ['fc-cat-work'] },
  { title: 'Run · 5K',           start: '2026-04-25T07:00', classNames: ['fc-cat-personal'] },
  { title: "Dinner @ Carla's",   start: '2026-04-25T20:00', classNames: ['fc-cat-personal'] },
  { title: 'Sprint planning',    start: '2026-04-27T10:00', classNames: ['fc-cat-work'] },
  { title: 'Board review',       start: '2026-04-28T14:00', classNames: ['fc-cat-work'] },
  { title: 'Eng review',         start: '2026-04-28T17:00', classNames: ['fc-cat-team'] },
  { title: 'Anya 1:1',           start: '2026-04-29T11:30', classNames: ['fc-cat-team'] },
  { title: 'Newsletter goes out',start: '2026-04-30T09:00', classNames: ['fc-cat-team'] },
  { title: 'Yoga',               start: '2026-04-30T19:00', classNames: ['fc-cat-personal'] },
];

const VIEW_MAP = { Day: 'timeGridDay', Week: 'timeGridWeek', Month: 'dayGridMonth', Agenda: 'listWeek' };

let calendar = null;

function bindToolbar(host) {
  // Wire the page's existing toolbar buttons to the FC instance.
  const root = host.closest('.cal-main') || document;
  const monthEl = root.querySelector('.cal-month');

  const updateTitle = () => {
    if (!monthEl || !calendar) return;
    const d = calendar.getDate();
    const month = d.toLocaleString('en-US', { month: 'long' });
    const year  = d.getFullYear();
    monthEl.innerHTML = `${month} <span class="yr">${year}</span>`;
  };

  root.querySelectorAll('.cal-nav-btn').forEach((btn, idx) => {
    btn.addEventListener('click', () => {
      if (!calendar) return;
      if (idx === 0) calendar.prev();
      if (idx === 1) calendar.next();
      updateTitle();
    });
  });

  const today = root.querySelector('.cal-today-btn');
  if (today) today.addEventListener('click', () => { calendar.today(); updateTitle(); });

  root.querySelectorAll('.cal-view-tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      const label = tab.textContent.trim();
      const view = VIEW_MAP[label] || 'dayGridMonth';
      root.querySelectorAll('.cal-view-tab').forEach((t) => t.classList.toggle('is-active', t === tab));
      calendar.changeView(view);
      updateTitle();
    });
  });

  // Title isn't filled in until the calendar is rendered.
  setTimeout(updateTitle, 0);
}

function build(host) {
  if (calendar) {
    try { calendar.destroy(); } catch { /* re-build below */ }
  }
  calendar = new Calendar(host, {
    plugins: [dayGridPlugin, timeGridPlugin, listPlugin, interactionPlugin],
    initialView: 'dayGridMonth',
    initialDate: '2026-04-25',
    headerToolbar: false,
    height: '100%',
    expandRows: true,
    dayMaxEvents: 3,
    fixedWeekCount: false,
    firstDay: 0,
    nowIndicator: true,
    selectable: true,
    editable: true,
    events: SEED_EVENTS,
    dayHeaderFormat: { weekday: 'short' },
  });
  calendar.render();
  bindToolbar(host);
}

export function initCalendarPage() {
  const host = document.querySelector('[data-fc]');
  if (!host) return;
  build(host);
  // Re-render on theme change so any token-driven colors update.
  const observer = new MutationObserver((records) => {
    if (records.some((r) => r.attributeName === 'data-theme')) {
      // Just trigger a redraw — colors come from CSS, not from JS.
      if (calendar) calendar.render();
    }
  });
  observer.observe(document.documentElement, { attributes: true });
}
