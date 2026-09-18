/**
 * The pure half of the V2 storage-layout gate: normalising solc's output and deciding whether one
 * layout may replace another. Separated from `scripts/check-storage-layout.mjs` so it can be tested
 * against layouts that do not exist in the repo - a gate nobody has watched reject something is a
 * comment. See `test/storage-layout.test.mjs`.
 */

/**
 * solc's raw output carries an `astId` and a source path on every entry, and keys its type table on
 * strings like `t_struct(Launch)1234_storage` whose number moves when an unrelated line is added to an
 * unrelated file. Diffing that would fail constantly for no reason, and a gate that cries wolf gets
 * regenerated unread. So: drop the AST ids, resolve every type reference to its human label, and keep
 * exactly what an upgrade can get wrong - order, slot, offset, type.
 */
export function normalize(layout) {
  const label = (typeKey) => layout.types?.[typeKey]?.label ?? typeKey;
  const member = (entry) => `${entry.slot}:${entry.offset} ${entry.label} ${label(entry.type)}`;

  const variables = (layout.storage ?? []).map(member);

  // One line per reachable type, sorted so the list does not reshuffle when a field is appended. A
  // nested struct that gets reordered changes its own line here even though `variables` is untouched.
  const types = Object.entries(layout.types ?? {})
    .map(([key, type]) => {
      const head = `${label(key)} | ${type.encoding} | ${type.numberOfBytes} bytes`;
      return type.members ? `${head} | ${type.members.map(member).join(', ')}` : head;
    })
    .sort();

  return { variables, types };
}

/** `"14:0 __gap uint256[32]"` -> `{ slot: 14, length: 32 }`, or null if that is not a trailing gap. */
export function trailingGap(variables) {
  const last = variables[variables.length - 1];
  const match = /^(\d+):0 __gap uint256\[(\d+)\]$/u.exec(last ?? '');
  return match ? { slot: Number(match[1]), length: Number(match[2]) } : null;
}

/**
 * Append-only, honouring the storage gap. Returns a human explanation, or null.
 *
 * Without a gap: `committed` must be a prefix of `current`.
 * With one: everything before the gap must be untouched, and the gap must still end on the same slot,
 * so any field added in its place occupies space that was reserved and provably zero.
 */
export function prefixViolation(committed, current) {
  const gap = trailingGap(committed);
  const fixed = gap ? committed.slice(0, -1) : committed;

  for (let i = 0; i < fixed.length; i += 1) {
    if (fixed[i] !== current[i]) {
      return [
        `storage variable #${i} is no longer what the committed layout says it is.`,
        `    committed: ${fixed[i]}`,
        `    now:       ${current[i] ?? '(removed)'}`,
        '    Live state at that slot would be reinterpreted. Only appending at the end is safe.',
      ].join('\n');
    }
  }
  if (!gap) {
    return current.length < committed.length
      ? `the layout lost ${committed.length - current.length} trailing variable(s).`
      : null;
  }

  const gapEnd = gap.slot + gap.length;
  const now = trailingGap(current);
  if (!now) {
    return [
      'the trailing `__gap uint256[32]` is gone.',
      `    committed: ${committed[committed.length - 1]}`,
      `    now:       ${current[current.length - 1] ?? '(nothing)'}`,
      '    The gap is what makes adding a field safe here; removing it ends that.',
    ].join('\n');
  }
  if (now.slot + now.length !== gapEnd) {
    return [
      `the reserved region moved: it used to end at slot ${gapEnd}, now it ends at ${now.slot + now.length}.`,
      `    committed: ${committed[committed.length - 1]}`,
      `    now:       ${current[current.length - 1]}`,
      '    Shrink the gap by exactly as many slots as the new fields occupy.',
    ].join('\n');
  }
  // New fields may only appear inside the space the gap gave up.
  const added = current.slice(fixed.length, -1);
  const firstAdded = added.length === 0 ? null : Number(added[0].split(':')[0]);
  if (firstAdded !== null && firstAdded !== gap.slot) {
    return `a new field starts at slot ${firstAdded}, but the reserved region begins at ${gap.slot}.`;
  }
  return null;
}

/** Types are a set, because appending a field of a brand-new type legitimately adds entries. */
export function missingType(committed, current) {
  const have = new Set(current);
  const gone = committed.find((line) => !have.has(line));
  return gone
    ? [
      'a type its storage reaches has changed shape. A nested struct can move a field without the',
      'top-level variable list changing at all.',
      `    committed: ${gone}`,
    ].join('\n')
    : null;
}

