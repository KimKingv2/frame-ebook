/* FRAME Reader one-time legacy browser-data cleanup.
 * The cloud-only app no longer reads from IndexedDB or browser storage.
 * Remove all storage keys owned by previous FRAME Reader releases.
 */
(function () {
  "use strict";

  const LEGACY_DATABASES = ["frame-reader-library"];
  const STORAGE_PREFIXES = ["frame-reader-"];

  function removeLegacyKeys(storage, label) {
    if (!storage) return;
    const keys = [];
    for (let index = 0; index < storage.length; index += 1) {
      const key = storage.key(index);
      if (key && STORAGE_PREFIXES.some(prefix => key.startsWith(prefix))) keys.push(key);
    }
    keys.forEach(key => {
      try { storage.removeItem(key); }
      catch (error) { console.warn("FRAME Reader could not remove legacy " + label + " key:", key, error); }
    });
  }

  try { removeLegacyKeys(window.localStorage, "localStorage"); }
  catch (error) { console.warn("FRAME Reader could not inspect legacy localStorage:", error); }

  try { removeLegacyKeys(window.sessionStorage, "sessionStorage"); }
  catch (error) { console.warn("FRAME Reader could not inspect legacy sessionStorage:", error); }

  if (!("indexedDB" in window)) return;

  LEGACY_DATABASES.forEach(name => {
    try {
      const request = window.indexedDB.deleteDatabase(name);
      request.onsuccess = () => console.info("FRAME Reader removed legacy IndexedDB database:", name);
      request.onerror = () => console.warn("FRAME Reader could not delete legacy IndexedDB database:", name, request.error);
      request.onblocked = () => console.warn(
        "FRAME Reader legacy IndexedDB deletion is blocked by an older open tab. Close old FRAME Reader tabs and revisit the site to retry."
      );
    } catch (error) {
      console.warn("FRAME Reader could not request legacy IndexedDB deletion:", name, error);
    }
  });
})();
