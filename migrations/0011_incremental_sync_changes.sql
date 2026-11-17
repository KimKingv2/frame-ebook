-- FRAME Ebook 0.3.0
-- Per-user incremental change journal. Rows are appended only when a user-owned
-- reading record changes; clients pull by indexed change_id cursor.
CREATE TABLE IF NOT EXISTS reader_sync_changes (
  change_id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('state','annotation','event','preference')),
  entity_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (operation IN ('upsert','delete')),
  payload_json TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_reader_sync_changes_user_cursor
  ON reader_sync_changes(user_id, change_id);

CREATE INDEX IF NOT EXISTS idx_reader_sync_changes_user_entity
  ON reader_sync_changes(user_id, entity_type, entity_id, change_id);
