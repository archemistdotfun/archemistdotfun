import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { missingType, normalize, prefixViolation, trailingGap } from '../lib/storage-layout.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const reference = (name) =>
  JSON.parse(fs.readFileSync(path.resolve(root, 'storage-layout-reference', `${name}.layout.json`), 'utf8'));

const LOCKER = 'ArchemistV2USDCLockerV3';
const FACTORY = 'ArchemistV2USDCFactoryV3';

// A gate that has never been watched reject something is a comment, not a gate. Every case below is a
// change that compiles cleanly, that no reviewer reliably catches by eye, and that would silently
// reinterpret live state behind a proxy whose only privileged function is `upgradeToAndCall`.

test('the committed layouts accept themselves', () => {
  for (const name of [LOCKER, FACTORY]) {
    const { variables, types } = reference(name);
    assert.equal(prefixViolation(variables, variables), null, name);
    assert.equal(missingType(types, types), null, name);
  }
});

test('a reordered field is rejected, and named', () => {
  const { variables } = reference(LOCKER);
  const swapped = [...variables];
  // `treasury` and `pairedToken`: both addresses, so nothing about the sizes gives it away. An upgrade
  // shipping this would start paying protocol fees to the paired token's own address.
  [swapped[2], swapped[3]] = [swapped[3].replace(/^3:/u, '2:'), swapped[2].replace(/^2:/u, '3:')];

  const problem = prefixViolation(variables, swapped);
  assert.match(problem, /storage variable #2/u);
  assert.match(problem, /treasury/u);
});

test('a retyped field is rejected even at the same slot and width', () => {
  const { variables } = reference(FACTORY);
  const retyped = variables.map((line) => line.replace('8:0 _lock uint256', '8:0 _lock bytes32'));
  assert.notDeepEqual(retyped, variables);
  assert.match(prefixViolation(variables, retyped), /storage variable #8/u);
});

test('a removed field is rejected', () => {
  const { variables } = reference(LOCKER);
  assert.match(prefixViolation(variables, variables.slice(0, -2)), /storage variable #13/u);
});

test('a field inserted in the middle is rejected', () => {
  const { variables } = reference(FACTORY);
  const inserted = [...variables.slice(0, 6), '6:0 sneakyNewField address', ...variables.slice(6)];
  assert.match(prefixViolation(variables, inserted), /storage variable #6/u);
});

// --- the storage gap -------------------------------------------------------------------------------
// Consuming reserved space is the one change that must stay allowed, or the gate makes the contracts
// un-upgradeable and gets bypassed the first time someone needs a field.

test('consuming the gap correctly is allowed', () => {
  const { variables } = reference(LOCKER);
  const gap = trailingGap(variables);
  assert.deepEqual(gap, { slot: 14, length: 32 });

  const grown = [
    ...variables.slice(0, -1),
    `${gap.slot}:0 newlyAddedField uint256`,
    `${gap.slot + 1}:0 __gap uint256[${gap.length - 1}]`,
  ];
  assert.equal(prefixViolation(variables, grown), null);
});

test('shrinking the gap by the wrong amount is rejected', () => {
  const { variables } = reference(LOCKER);
  // One field added, but the gap gave up two slots: everything after the reserved region moves up.
  const wrong = [...variables.slice(0, -1), '14:0 newlyAddedField uint256', '15:0 __gap uint256[30]'];
  assert.match(prefixViolation(variables, wrong), /reserved region moved/u);
});

test('deleting the gap outright is rejected', () => {
  const { variables } = reference(FACTORY);
  assert.match(prefixViolation(variables, variables.slice(0, -1)), /is gone/u);
});

test('a field added after the gap instead of inside it is rejected', () => {
  const { variables } = reference(FACTORY);
  const gap = trailingGap(variables);
  const after = [...variables.slice(0, -1), variables[variables.length - 1], `${gap.slot + gap.length}:0 tail uint256`];
  // `trailingGap` no longer matches, because the gap is not last any more.
  assert.notEqual(prefixViolation(variables, after), null);
});

// --- nested structs --------------------------------------------------------------------------------

test('a reordered nested struct is rejected, though the variable list is untouched', () => {
  const { variables, types } = reference(LOCKER);
  const key = types.find((line) => line.startsWith('struct ArchemistV2USDCLockerV3.PositionInfo'));
  assert.ok(key, 'the locker must reach PositionInfo');

  const mutated = types.map((line) =>
    line === key
      ? line.replace(
        '0:0 positionId uint256, 1:0 creatorFeeAdmin address',
        '0:0 creatorFeeAdmin address, 1:0 positionId uint256',
      )
      : line);

  // This is the case the top-level list cannot see: it is completely unchanged.
  assert.equal(prefixViolation(variables, variables), null);
  assert.match(missingType(types, mutated), /PositionInfo/u);
});

test('a type appearing for the first time is allowed', () => {
  const { types } = reference(FACTORY);
  assert.equal(missingType(types, [...types, 'struct Whatever.New | inplace | 32 bytes']), null);
});

// --- normalisation ---------------------------------------------------------------------------------

test('normalisation drops AST ids, which move for unrelated reasons', () => {
  const layout = {
    storage: [
      { astId: 1234, contract: 'a.sol:A', label: 'owner', offset: 0, slot: '0', type: 't_address' },
      { astId: 1240, contract: 'a.sol:A', label: 'info', offset: 0, slot: '1', type: 't_struct(Info)77_storage' },
    ],
    types: {
      t_address: { encoding: 'inplace', label: 'address', numberOfBytes: '20' },
      't_struct(Info)77_storage': {
        encoding: 'inplace',
        label: 'struct A.Info',
        numberOfBytes: '32',
        members: [{ astId: 9, contract: 'a.sol:A', label: 'n', offset: 0, slot: '0', type: 't_address' }],
      },
    },
  };
  const first = normalize(layout);

  // Same contract, recompiled after an unrelated edit somewhere else in the import graph.
  const shifted = JSON.parse(
    JSON.stringify(layout).replaceAll('77_storage', '9001_storage').replaceAll('"astId": 12', '"astId": 88'),
  );
  assert.deepEqual(normalize(shifted), first, 'an AST-id shift must not read as a layout change');
  assert.deepEqual(first.variables, ['0:0 owner address', '1:0 info struct A.Info']);
});

test('an empty layout is not silently treated as compatible', () => {
  // The V4 gate had exactly this bug: solc reports nothing for a namespaced struct, and the check
  // concluded "no problems". Here it must be the caller's job to refuse, so prove the shape it sees.
  assert.deepEqual(normalize({}), { variables: [], types: [] });
  assert.match(prefixViolation(['0:0 owner address'], []), /storage variable #0/u);
});
