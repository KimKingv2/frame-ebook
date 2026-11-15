-- FRAME Reader V1.0
-- Cloud-origin book annotations are stored in D1 and partitioned by the
-- verified Cloudflare Access subject. Local-import annotations stay in
-- browser IndexedDB and never use this table.

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
