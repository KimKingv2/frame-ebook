import assert from "node:assert/strict";
import test from "node:test";

import { mergeReaderBookState } from "../_lib/reader-state.js";

test("merges partial progress and appearance updates without losing sibling fields", () => {
  const previous = {
    progress: { percent: 12, index: 3, cfi: "epubcfi(/6/4)", label: "Chapter 2" },
    appearance: { theme: "dark", fontScale: 1, lineHeight: 1.6 },
    metadata: { title: "A Book", author: "Author" }
  };

  const merged = mergeReaderBookState(previous, {
    progress: { percent: 18, index: 5 },
    appearance: { fontScale: 1.15 }
  });

  assert.deepEqual(merged, {
    progress: { percent: 18, index: 5, cfi: "epubcfi(/6/4)", label: "Chapter 2" },
    appearance: { theme: "dark", fontScale: 1.15, lineHeight: 1.6 },
    metadata: { title: "A Book", author: "Author" }
  });
  assert.deepEqual(previous.progress, {
    percent: 12, index: 3, cfi: "epubcfi(/6/4)", label: "Chapter 2"
  });
});

test("replaces arrays and primitive values instead of merging them by index", () => {
  const previous = { toc: ["intro", "chapter-1"], appearance: { fontScale: 1 } };
  const merged = mergeReaderBookState(previous, {
    toc: ["preface", "chapter-2"],
    appearance: { fontScale: 1.2 }
  });

  assert.deepEqual(merged, {
    toc: ["preface", "chapter-2"],
    appearance: { fontScale: 1.2 }
  });
});

test("null removes a nested field while leaving its siblings intact", () => {
  const merged = mergeReaderBookState(
    { appearance: { theme: "dark", fontFamily: "serif" } },
    { appearance: { fontFamily: null } }
  );

  assert.deepEqual(merged, { appearance: { theme: "dark" } });
});

test("does not allow prototype-pollution keys into persisted state", () => {
  const patch = JSON.parse('{"appearance":{"__proto__":{"polluted":true},"fontScale":1.1}}');
  const merged = mergeReaderBookState({}, patch);

  assert.deepEqual(merged, { appearance: { fontScale: 1.1 } });
  assert.equal(Object.prototype.polluted, undefined);
});

test("treats malformed previous state as an empty object", () => {
  assert.deepEqual(mergeReaderBookState(null, { progress: { percent: 1 } }), {
    progress: { percent: 1 }
  });
});
