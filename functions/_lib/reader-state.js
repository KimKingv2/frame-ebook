function isRecord(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function defineOwn(target, key, value) {
  Object.defineProperty(target, key, {
    configurable: true,
    enumerable: true,
    writable: true,
    value
  });
}

/**
 * Applies JSON Merge Patch semantics to reader state.
 *
 * Nested progress and appearance updates preserve sibling fields, which keeps
 * concurrent device changes from replacing unrelated sub-fields.
 */
export function mergeReaderBookState(previous, patch) {
  const merge = (target, source) => {
    const output = {};
    if (isRecord(target)) {
      for (const [key, value] of Object.entries(target)) {
        if (key === "__proto__" || key === "prototype" || key === "constructor") {
          continue;
        }
        defineOwn(output, key, value);
      }
    }

    if (!isRecord(source)) return output;
    for (const [key, value] of Object.entries(source)) {
      if (key === "__proto__" || key === "prototype" || key === "constructor") {
        continue;
      }
      if (value === null) {
        delete output[key];
      } else if (isRecord(value)) {
        defineOwn(output, key, merge(output[key], value));
      } else {
        defineOwn(output, key, value);
      }
    }
    return output;
  };

  return merge(previous, patch);
}
