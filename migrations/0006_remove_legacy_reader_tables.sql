-- FRAME Reader: remove tables from the retired local-first / password-session architecture.
-- New per-user reading history is stored in reader_reading_events (migration 0005).
-- Cloudflare Access now owns website authentication; auth_attempts is no longer used.
-- The D1 cloud catalog and reader_annotations are intentionally preserved.

DROP TABLE IF EXISTS reading_events;
DROP TABLE IF EXISTS auth_attempts;
