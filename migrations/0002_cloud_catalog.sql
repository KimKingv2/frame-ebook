-- FRAME Reader V0.8
-- Persistent metadata-only index for OpenList cloud libraries.
-- Original EPUB / CBZ files remain in their configured OpenList sources.

CREATE TABLE IF NOT EXISTS cloud_catalog (
  provider TEXT NOT NULL CHECK (provider IN ('vps', 'worker', 'mobile', 'local')),
  library TEXT NOT NULL CHECK (library IN ('books', 'comics')),
  root_path TEXT NOT NULL,
  path TEXT NOT NULL,
  parent_path TEXT NOT NULL,
  name TEXT NOT NULL,
  is_dir INTEGER NOT NULL CHECK (is_dir IN (0, 1)),
  format TEXT NOT NULL DEFAULT '',
  size_bytes INTEGER NOT NULL DEFAULT 0 CHECK (size_bytes >= 0),
  modified_at TEXT,
  scan_id TEXT NOT NULL,
  indexed_at TEXT NOT NULL,
  PRIMARY KEY (provider, library, root_path, path)
);

CREATE INDEX IF NOT EXISTS idx_cloud_catalog_parent
  ON cloud_catalog(provider, library, root_path, parent_path, is_dir, name);

CREATE INDEX IF NOT EXISTS idx_cloud_catalog_path
  ON cloud_catalog(provider, library, root_path, path);

CREATE TABLE IF NOT EXISTS cloud_scan_state (
  scan_key TEXT NOT NULL PRIMARY KEY,
  provider TEXT NOT NULL,
  library TEXT NOT NULL,
  root_path TEXT NOT NULL,
  state_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cloud_scan_state_scope
  ON cloud_scan_state(provider, library, root_path);
