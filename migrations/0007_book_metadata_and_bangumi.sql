-- FRAME Reader: EPUB metadata refreshed from the source file during a full scan.
-- Manga records are linked to each volume Book ID so a whole folder can share one Bangumi subject.

ALTER TABLE cloud_catalog ADD COLUMN book_title TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_catalog ADD COLUMN book_creator TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_catalog ADD COLUMN book_language TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_catalog ADD COLUMN book_description TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_catalog ADD COLUMN book_publisher TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_catalog ADD COLUMN book_date TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_catalog ADD COLUMN book_identifier TEXT NOT NULL DEFAULT '';
ALTER TABLE cloud_catalog ADD COLUMN book_subjects_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE cloud_catalog ADD COLUMN book_metadata_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE cloud_catalog ADD COLUMN book_metadata_updated_at INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS reader_comic_metadata (
  user_id TEXT NOT NULL,
  book_id TEXT NOT NULL,
  subject_id INTEGER NOT NULL,
  metadata_json TEXT NOT NULL,
  source_url TEXT NOT NULL,
  fetched_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, book_id)
);

CREATE INDEX IF NOT EXISTS idx_reader_comic_metadata_subject
  ON reader_comic_metadata(user_id, subject_id);
