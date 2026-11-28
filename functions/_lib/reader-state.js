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

export function cleanReaderProgressPatch(input) {
  if (!isRecord(input)) throw new Error("閱讀進度格式無效。");
  if (!Object.prototype.hasOwnProperty.call(input, "percent")) {
    throw new Error("閱讀進度百分比缺失。");
  }

  const percent = Number(input.percent);
  if (!Number.isFinite(percent) || percent < 0 || percent > 100) {
    throw new Error("閱讀進度數值無效。");
  }

  const output = { percent: Math.round(percent) };
  if (Object.prototype.hasOwnProperty.call(input, "label")) {
    output.label = String(input.label || "").slice(0, 160);
  }
  if (Object.prototype.hasOwnProperty.call(input, "cfi")) {
    output.cfi = String(input.cfi || "").slice(0, 4000);
  }
  if (Object.prototype.hasOwnProperty.call(input, "index")) {
    const index = input.index == null ? null : Number(input.index);
    if (index !== null && (!Number.isSafeInteger(index) || index < 0)) {
      throw new Error("閱讀進度索引無效。");
    }
    output.index = index;
  }
  return output;
}

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
