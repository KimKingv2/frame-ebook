-- FRAME Reader: cloud-only personal library state.
-- All persistent user-owned preferences, progress and reading events live in D1.
-- Original EPUB / CBZ files remain in the configured Alist / OpenList provider.

CREATE TABLE IF NOT EXISTS reader_preferences (
  user_id TEXT NOT NULL,
  setting_key TEXT NOT NULL,
  value_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, setting_key)
);

CREATE INDEX IF NOT EXISTS idx_reader_preferences_updated
  ON reader_preferences(user_id, updated_at);

CREATE TABLE IF NOT EXISTS reader_book_state (
  user_id TEXT NOT NULL,
  book_id TEXT NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('vps', 'worker', 'mobile')),
  library TEXT NOT NULL CHECK (library IN ('books', 'comics')),
  root_path TEXT NOT NULL,
  book_path TEXT NOT NULL,
  state_json TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, book_id)
);

CREATE INDEX IF NOT EXISTS idx_reader_book_state_user_updated
  ON reader_book_state(user_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS reader_reading_events (
  user_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  day_key TEXT NOT NULL,
  book_id TEXT NOT NULL,
  book_title TEXT NOT NULL DEFAULT '',
  format TEXT NOT NULL DEFAULT '',
  seconds INTEGER NOT NULL CHECK (seconds > 0 AND seconds <= 30),
  started_at INTEGER NOT NULL,
  ended_at INTEGER NOT NULL,
  local_hour INTEGER NOT NULL DEFAULT 0 CHECK (local_hour >= 0 AND local_hour <= 23),
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, event_id)
);

CREATE INDEX IF NOT EXISTS idx_reader_reading_events_user_day
  ON reader_reading_events(user_id, day_key);

CREATE INDEX IF NOT EXISTS idx_reader_reading_events_user_book
  ON reader_reading_events(user_id, book_id, day_key);

CREATE INDEX IF NOT EXISTS idx_reader_reading_events_user_recent
  ON reader_reading_events(user_id, ended_at DESC);
