-- FRAME Reader: one shared library catalog for every configured OpenList provider.
-- The existing provider column is retained for schema compatibility. "vps" is now
-- the canonical D1 storage namespace only; the active provider is still selected
-- independently for directory and file requests.
--
-- Copy rows from every previous provider namespace into the canonical namespace.
-- Keep legacy rows untouched so this migration is reversible and never destroys
-- the original per-provider catalogue records.

INSERT INTO cloud_catalog (
  provider,library,root_path,path,parent_path,name,is_dir,format,size_bytes,
  modified_at,scan_id,indexed_at,cover_hash,cover_type,cover_status,cover_error,
  cover_updated_at,book_title,book_creator,book_language,book_description,
  book_publisher,book_date,book_identifier,book_subjects_json,
  book_metadata_status,book_metadata_updated_at
)
SELECT
  'vps',library,root_path,path,parent_path,name,is_dir,format,size_bytes,
  modified_at,scan_id,indexed_at,cover_hash,cover_type,cover_status,cover_error,
  cover_updated_at,book_title,book_creator,book_language,book_description,
  book_publisher,book_date,book_identifier,book_subjects_json,
  book_metadata_status,book_metadata_updated_at
FROM cloud_catalog
WHERE provider <> 'vps'
ORDER BY indexed_at ASC,provider ASC
ON CONFLICT(provider,library,root_path,path) DO UPDATE SET
  parent_path=excluded.parent_path,
  name=excluded.name,
  is_dir=excluded.is_dir,
  format=excluded.format,
  size_bytes=excluded.size_bytes,
  modified_at=excluded.modified_at,
  scan_id=CASE
    WHEN excluded.indexed_at >= cloud_catalog.indexed_at THEN excluded.scan_id
    ELSE cloud_catalog.scan_id
  END,
  indexed_at=MAX(cloud_catalog.indexed_at,excluded.indexed_at),
  cover_hash=CASE
    WHEN cloud_catalog.cover_status='ready' THEN cloud_catalog.cover_hash
    ELSE COALESCE(excluded.cover_hash,cloud_catalog.cover_hash)
  END,
  cover_type=CASE
    WHEN cloud_catalog.cover_status='ready' THEN cloud_catalog.cover_type
    ELSE COALESCE(excluded.cover_type,cloud_catalog.cover_type)
  END,
  cover_status=CASE
    WHEN cloud_catalog.cover_status='ready' OR excluded.cover_status='ready' THEN 'ready'
    WHEN cloud_catalog.cover_status='pending' OR excluded.cover_status='pending' THEN 'pending'
    WHEN cloud_catalog.cover_status='error' OR excluded.cover_status='error' THEN 'error'
    ELSE COALESCE(excluded.cover_status,cloud_catalog.cover_status)
  END,
  cover_error=CASE
    WHEN cloud_catalog.cover_status='ready' THEN cloud_catalog.cover_error
    ELSE COALESCE(excluded.cover_error,cloud_catalog.cover_error)
  END,
  cover_updated_at=COALESCE(cloud_catalog.cover_updated_at,excluded.cover_updated_at),
  book_title=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_title ELSE cloud_catalog.book_title END,
  book_creator=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_creator ELSE cloud_catalog.book_creator END,
  book_language=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_language ELSE cloud_catalog.book_language END,
  book_description=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_description ELSE cloud_catalog.book_description END,
  book_publisher=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_publisher ELSE cloud_catalog.book_publisher END,
  book_date=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_date ELSE cloud_catalog.book_date END,
  book_identifier=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_identifier ELSE cloud_catalog.book_identifier END,
  book_subjects_json=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_subjects_json ELSE cloud_catalog.book_subjects_json END,
  book_metadata_status=CASE
    WHEN excluded.book_metadata_status='ready' AND
      (cloud_catalog.book_metadata_status<>'ready' OR excluded.book_metadata_updated_at>=cloud_catalog.book_metadata_updated_at)
    THEN excluded.book_metadata_status ELSE cloud_catalog.book_metadata_status END,
  book_metadata_updated_at=MAX(cloud_catalog.book_metadata_updated_at,excluded.book_metadata_updated_at);
