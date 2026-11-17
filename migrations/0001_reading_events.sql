-- FRAME Reader V0.6
-- D1 stores reading-time events and login rate-limit counters only.
-- Original EPUB / CBZ book files remain in OpenList or the user's local browser.

CREATE TABLE IF NOT EXISTS reading_events (
  event_id TEXT PRIMARY KEY,
  day_key TEXT NOT NULL,
  book_id TEXT NOT NULL,
  book_title TEXT NOT NULL DEFAULT '',
  format TEXT NOT NULL DEFAULT '',
  seconds INTEGER NOT NULL CHECK (seconds > 0 AND seconds <= 30),
  started_at INTEGER NOT NULL,
  ended_at INTEGER NOT NULL,
  local_hour INTEGER NOT NULL DEFAULT 0 CHECK (local_hour >= 0 AND local_hour <= 23),
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_reading_events_day
  ON reading_events(day_key);

CREATE INDEX IF NOT EXISTS idx_reading_events_book
  ON reading_events(book_id, day_key);

CREATE INDEX IF NOT EXISTS idx_reading_events_recent
  ON reading_events(ended_at DESC);

CREATE TABLE IF NOT EXISTS auth_attempts (
  ip_hash TEXT PRIMARY KEY,
  window_start_ms INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_attempt_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_auth_attempts_last
  ON auth_attempts(last_attempt_ms);
