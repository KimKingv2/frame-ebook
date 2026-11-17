-- FRAME Reader: ensure cloud annotation storage exists in Production D1.
-- Idempotent repair migration. Safe to apply even when migration 0004 was
-- applied previously; existing annotations and indexes are preserved.

CREATE TABLE IF NOT EXISTS reader_annotations (
  user_id TEXT NOT NULL,
  book_id TEXT NOT NULL,
  annotation_id TEXT NOT NULL,
  provider TEXT NOT NULL CHECK (provider IN ('vps', 'worker', 'mobile', 'local')),
  library TEXT NOT NULL CHECK (library IN ('books', 'comics')),
  root_path TEXT NOT NULL,
  book_path TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('highlight', 'note', 'bookmark')),
  cfi TEXT NOT NULL,
  quote TEXT NOT NULL DEFAULT '',
  note_text TEXT NOT NULL DEFAULT '',
  color TEXT NOT NULL DEFAULT 'yellow',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, book_id, annotation_id)
);

CREATE INDEX IF NOT EXISTS idx_reader_annotations_user_book
  ON reader_annotations(user_id, book_id, created_at, annotation_id);

CREATE INDEX IF NOT EXISTS idx_reader_annotations_user_updated
  ON reader_annotations(user_id, updated_at);
