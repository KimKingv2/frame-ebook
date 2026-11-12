import {
  recordReadingEvent, getPendingReadingEvents, markReadingEventsSynced, localDayKey
} from "/assets/library-store.js";

const HEARTBEAT_MS = 15000;
const IDLE_LIMIT_MS = 5 * 60 * 1000;
let activeBook = null;
let timer = null;
let lastTickAt = 0;
let lastActivityAt = 0;
let tickWasActive = false;
let syncing = false;
let cloudBackoffUntil = 0;

function isForegroundActive(now = Date.now()) {
  return !!activeBook &&
    document.visibilityState === "visible" &&
    (!document.hasFocus || document.hasFocus()) &&
    now - lastActivityAt <= IDLE_LIMIT_MS;
}

function makeId() {
  if (crypto && typeof crypto.randomUUID === "function") return crypto.randomUUID();
  return "evt-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 12);
}

async function persistInterval(startAt, endAt) {
  let cursor = startAt;
  while (cursor < endAt) {
    const date = new Date(cursor);
    const midnight = new Date(date.getFullYear(), date.getMonth(), date.getDate() + 1).getTime();
    const segmentEnd = Math.min(endAt, midnight);
    const seconds = Math.floor((segmentEnd - cursor) / 1000);
    if (seconds > 0) {
      const event = {
        id: makeId(),
        dayKey: localDayKey(cursor),
        bookId: activeBook.id,
        bookTitle: activeBook.title,
        format: activeBook.format,
        seconds: Math.min(30, seconds),
        startedAt: cursor,
        endedAt: Math.min(segmentEnd, cursor + 30000)
      };
      try {
        await recordReadingEvent(event);
      } catch (error) {
        console.warn("FRAME Reader could not save a reading-time segment:", error);
      }
    }
    cursor = segmentEnd;
  }
  syncPending();
}

async function syncPending(force = false) {
  if (syncing || (!force && Date.now() < cloudBackoffUntil)) return;
  syncing = true;
  try {
    const pending = await getPendingReadingEvents(100);
    if (!pending.length) return;
    const response = await fetch("/api/reading/events", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ events: pending.map(({ id, dayKey, bookId, bookTitle, format, seconds, startedAt, endedAt }) => ({
        id, dayKey, bookId, bookTitle, format, seconds, startedAt, endedAt
      })) })
    });
    if (response.status === 401 || response.status === 404 || response.status === 503) {
      cloudBackoffUntil = Date.now() + 5 * 60 * 1000;
      return;
    }
    if (!response.ok) return;
    await markReadingEventsSynced(pending.map(item => item.id));
  } catch (_) {
    cloudBackoffUntil = Date.now() + 60 * 1000;
  } finally {
    syncing = false;
  }
}

function tick(now = Date.now()) {
  if (!activeBook) return;
  if (tickWasActive && lastTickAt > 0) {
    const elapsed = Math.min(now - lastTickAt, HEARTBEAT_MS * 2);
    if (elapsed > 0) persistInterval(lastTickAt, now);
  }
  lastTickAt = now;
  tickWasActive = isForegroundActive(now);
}

function activity() {
  if (!activeBook) return;
  lastActivityAt = Date.now();
  if (!tickWasActive) {
    lastTickAt = lastActivityAt;
    tickWasActive = isForegroundActive(lastActivityAt);
  }
}

function onVisibilityChange() {
  if (document.visibilityState === "hidden") {
    tick(Date.now());
    tickWasActive = false;
  } else {
    lastTickAt = Date.now();
    lastActivityAt = lastTickAt;
    tickWasActive = isForegroundActive(lastTickAt);
  }
}

function onWindowBlur() {
  tick(Date.now());
  tickWasActive = false;
}

function onWindowFocus() {
  lastTickAt = Date.now();
  lastActivityAt = lastTickAt;
  tickWasActive = isForegroundActive(lastTickAt);
}

function attachListeners() {
  ["pointerdown", "keydown", "wheel", "touchstart"].forEach(name => {
    window.addEventListener(name, activity, { passive: true });
  });
  document.addEventListener("visibilitychange", onVisibilityChange);
  window.addEventListener("blur", onWindowBlur);
  window.addEventListener("focus", onWindowFocus);
  const viewport = document.getElementById("reader-viewport");
  if (viewport) viewport.addEventListener("scroll", activity, { passive: true });
}

function detachListeners() {
  ["pointerdown", "keydown", "wheel", "touchstart"].forEach(name => {
    window.removeEventListener(name, activity);
  });
  document.removeEventListener("visibilitychange", onVisibilityChange);
  window.removeEventListener("blur", onWindowBlur);
  window.removeEventListener("focus", onWindowFocus);
  const viewport = document.getElementById("reader-viewport");
  if (viewport) viewport.removeEventListener("scroll", activity);
}

async function start(book) {
  await stop();
  activeBook = {
    id: String(book && book.id || "standalone:" + (book && book.title || "untitled")),
    title: String(book && book.title || "未命名書籍").slice(0, 240),
    format: String(book && book.format || "EPUB").toUpperCase()
  };
  const now = Date.now();
  lastTickAt = now;
  lastActivityAt = now;
  tickWasActive = isForegroundActive(now);
  attachListeners();
  timer = window.setInterval(() => tick(Date.now()), HEARTBEAT_MS);
  syncPending();
  return true;
}

async function stop() {
  if (activeBook && tickWasActive) tick(Date.now());
  if (timer) window.clearInterval(timer);
  timer = null;
  tickWasActive = false;
  detachListeners();
  activeBook = null;
  lastTickAt = 0;
  await syncPending();
}

export { start, stop, activity, syncPending, isForegroundActive };
