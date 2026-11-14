-- FRAME Reader V0.9
-- Private, content-addressed cover metadata for the D1 cloud catalogue.
-- Cover image bytes live in the private R2 bucket bound as FRAME_READER_COVERS.

ALTER TABLE cloud_catalog ADD COLUMN cover_hash TEXT;
ALTER TABLE cloud_catalog ADD COLUMN cover_type TEXT;
ALTER TABLE cloud_catalog ADD COLUMN cover_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE cloud_catalog ADD COLUMN cover_error TEXT;
ALTER TABLE cloud_catalog ADD COLUMN cover_updated_at TEXT;

UPDATE cloud_catalog SET cover_status='none' WHERE is_dir=1;

CREATE INDEX IF NOT EXISTS idx_cloud_catalog_cover_queue
  ON cloud_catalog(provider, library, root_path, cover_status, is_dir, path);

CREATE INDEX IF NOT EXISTS idx_cloud_catalog_cover_hash
  ON cloud_catalog(cover_hash);
