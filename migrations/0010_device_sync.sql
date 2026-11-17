-- FRAME Ebook 0.3.0
-- Revocable native-device pairing. Only token hashes are stored in D1.
CREATE TABLE IF NOT EXISTS reader_device_pairings (
  pairing_hash TEXT PRIMARY KEY,
  user_code TEXT NOT NULL UNIQUE,
  device_name TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','claimed','expired')),
  user_id TEXT,
  device_id TEXT,
  token_hash TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  approved_at INTEGER,
  claimed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_reader_device_pairings_status_expiry
  ON reader_device_pairings(status, expires_at);

CREATE INDEX IF NOT EXISTS idx_reader_device_pairings_user_code
  ON reader_device_pairings(user_code, status, expires_at);

CREATE TABLE IF NOT EXISTS reader_devices (
  device_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  device_name TEXT NOT NULL DEFAULT '',
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_reader_devices_user
  ON reader_devices(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_reader_devices_token_active
  ON reader_devices(token_hash, revoked_at);
