import json
import sqlite3
import unittest


UPSERT_STATE = """
INSERT INTO reader_book_state
(user_id,book_id,provider,library,root_path,book_path,state_json,created_at,updated_at)
VALUES (?,?,?,?,?,?,?,?,?)
ON CONFLICT(user_id,book_id) DO UPDATE SET
  provider=excluded.provider,
  library=excluded.library,
  root_path=excluded.root_path,
  book_path=excluded.book_path,
  state_json=json_patch(
    CASE
      WHEN json_valid(reader_book_state.state_json)
      THEN reader_book_state.state_json
      ELSE '{}'
    END,
    excluded.state_json
  ),
  updated_at=excluded.updated_at
"""

JOURNAL_STATE = """
INSERT INTO reader_sync_changes
(user_id,entity_type,entity_id,operation,payload_json,created_at)
SELECT ?,'state',?,'upsert',
  json_object('book',json(?),'state',json(state_json)),?
FROM reader_book_state
WHERE user_id=? AND book_id=?
"""


class ReaderStateSqlTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.execute("""
          CREATE TABLE reader_book_state (
            user_id TEXT NOT NULL,
            book_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            library TEXT NOT NULL,
            root_path TEXT NOT NULL,
            book_path TEXT NOT NULL,
            state_json TEXT NOT NULL DEFAULT '{}',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(user_id, book_id)
          )
        """)
        self.db.execute("""
          CREATE TABLE reader_sync_changes (
            change_id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        """)
        self.book = {
            "id": "cloud:book-1",
            "sourceId": "webdav:source-1",
            "library": "books",
            "rootPath": "/books",
            "path": "/books/example.epub",
        }

    def tearDown(self):
        self.db.close()

    def write_patch(self, patch, updated_at):
        patch_json = json.dumps(patch, ensure_ascii=False, separators=(",", ":"))
        book_json = json.dumps(self.book, ensure_ascii=False, separators=(",", ":"))
        self.db.execute(UPSERT_STATE, (
            "user-1", "cloud:book-1", "vps", "books", "/books",
            "/books/example.epub", patch_json, updated_at, updated_at,
        ))
        self.db.execute(JOURNAL_STATE, (
            "user-1", "cloud:book-1", book_json, updated_at,
            "user-1", "cloud:book-1",
        ))
        self.db.commit()

    def test_partial_progress_and_appearance_updates_preserve_siblings(self):
        self.write_patch({
            "progress": {"percent": 12, "index": 3, "cfi": "cfi-1", "label": "Chapter 1"},
            "appearance": {"theme": "dark", "fontScale": 1.0, "lineHeight": 1.6},
        }, 1)
        self.write_patch({
            "progress": {"percent": 20},
            "appearance": {"fontScale": 1.2},
        }, 2)

        raw = self.db.execute(
            "SELECT state_json FROM reader_book_state WHERE user_id=? AND book_id=?",
            ("user-1", "cloud:book-1"),
        ).fetchone()[0]
        state = json.loads(raw)
        self.assertEqual(state, {
            "progress": {"percent": 20, "index": 3, "cfi": "cfi-1", "label": "Chapter 1"},
            "appearance": {"theme": "dark", "fontScale": 1.2, "lineHeight": 1.6},
        })

    def test_every_journal_entry_contains_the_post_merge_snapshot(self):
        self.write_patch({"progress": {"percent": 10, "cfi": "cfi-1"}}, 1)
        self.write_patch({"progress": {"percent": 25}}, 2)

        rows = self.db.execute(
            "SELECT payload_json FROM reader_sync_changes ORDER BY change_id"
        ).fetchall()
        first = json.loads(rows[0][0])
        second = json.loads(rows[1][0])
        self.assertEqual(first["state"]["progress"]["percent"], 10)
        self.assertEqual(second["state"]["progress"], {
            "percent": 25, "cfi": "cfi-1"
        })
        self.assertEqual(second["book"], self.book)

    def test_invalid_legacy_json_is_recovered_as_an_empty_object(self):
        self.write_patch({"progress": {"percent": 10}}, 1)
        self.db.execute(
            "UPDATE reader_book_state SET state_json='not-json' WHERE user_id=? AND book_id=?",
            ("user-1", "cloud:book-1"),
        )
        self.db.commit()

        self.write_patch({"appearance": {"theme": "dark"}}, 2)
        raw = self.db.execute(
            "SELECT state_json FROM reader_book_state WHERE user_id=? AND book_id=?",
            ("user-1", "cloud:book-1"),
        ).fetchone()[0]
        self.assertEqual(json.loads(raw), {"appearance": {"theme": "dark"}})


if __name__ == "__main__":
    unittest.main(verbosity=2)
