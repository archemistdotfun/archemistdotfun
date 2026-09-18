#!/usr/bin/env node
/**
 * The V2 storage-layout gate.
 *
 * `ArchemistV2USDCV3` and `ArchemistV2USDCLockerV3` sit behind UUPS proxies whose only privileged
 * function is `upgradeToAndCall`. Everything they own - every launch's locked liquidity, every creator's
 * unclaimed fees - is addressed by slot number. A future implementation that reorders, retypes, removes
 * or mid-inserts a field does not fail: it silently reinterprets that state, and the first symptom is
 * money going to the wrong address.
 *
 * Unlike the V4 contracts, these use ordinary sequential storage rather than an ERC-7201 namespace, so
 * solc reports their layout directly and no canary contract is needed. What is needed is a **committed
 * reference to compare against**, because "the compiler emitted a layout" says nothing on its own.
 *
 *   npm run check-storage-layout          # the gate: fails if any committed layout is not a prefix
 *   npm run check-storage-layout -- --write   # regenerate after a deliberate change, then READ THE DIFF
 *
 * Append-only is the rule, with one deliberate exception. Both contracts end in `__gap uint256[32]`,
 * reserved space whose entire purpose is to be spent on new fields - the correct way to add one is to
 * shrink the gap and insert ahead of it, which a naive prefix check would reject. So the gate instead
 * requires that the fields before the gap are untouched and that the gap still **ends on the same
 * slot**: consume as much of it as you like, never move what follows it. A gate that rejects the one
 * correct way to add a field is a gate that gets worked around.
 *
 * Everything else fails, including a change inside a struct the layout reaches, which the top-level
 * variable list alone would not reveal.
 *
 * Run `npm run compile` first - this reads that build's artifacts, it does not compile.
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { missingType, normalize, prefixViolation } from '../lib/storage-layout.mjs';

const deploymentRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const artifactsDir = path.resolve(deploymentRoot, 'artifacts');
const referenceDir = path.resolve(deploymentRoot, 'storage-layout-reference');

/** The contracts whose layout is a compatibility surface: upgradeable, and holding real balances. */
const GATED = [
  {
    contract: 'ArchemistV2USDCFactoryV3',
    artifact: 'src_ArchemistV2USDCFactoryV3_sol_ArchemistV2USDCFactoryV3',
  },
  {
    contract: 'ArchemistV2USDCLockerV3',
    artifact: 'src_ArchemistV2USDCLockerV3_sol_ArchemistV2USDCLockerV3',
  },
];

const write = process.argv.includes('--write');

let failures = 0;
fs.mkdirSync(referenceDir, { recursive: true });

for (const { contract, artifact } of GATED) {
  const artifactPath = path.resolve(artifactsDir, `${artifact}.storage-layout.json`);
  if (!fs.existsSync(artifactPath)) {
    console.error(`${contract}: no layout artifact at ${artifactPath}. Run "npm run compile" first.`);
    failures += 1;
    continue;
  }
  const current = normalize(JSON.parse(fs.readFileSync(artifactPath, 'utf8')));
  const referencePath = path.resolve(referenceDir, `${contract}.layout.json`);

  if (write) {
    fs.writeFileSync(referencePath, `${JSON.stringify(current, null, 2)}\n`);
    console.log(`wrote ${path.relative(deploymentRoot, referencePath)} (${current.variables.length} variables)`);
    continue;
  }

  if (!fs.existsSync(referencePath)) {
    console.error(`${contract}: no committed layout at ${referencePath}. Generate it with --write.`);
    failures += 1;
    continue;
  }
  if (current.variables.length === 0) {
    console.error(`${contract}: the compiler reported no storage at all. The gate would pass vacuously.`);
    failures += 1;
    continue;
  }

  const committed = JSON.parse(fs.readFileSync(referencePath, 'utf8'));
  const problem = prefixViolation(committed.variables, current.variables)
    ?? missingType(committed.types, current.types);

  if (problem) {
    console.error(`FAIL ${contract}: ${problem}`);
    failures += 1;
  } else {
    console.log(`ok   ${contract}: ${current.variables.length} variables, ${current.types.length} types, append-only`);
  }
}

if (write) {
  console.log('\nRegenerated. Read `git diff storage-layout-reference/` before trusting it: appended');
  console.log('lines at the end are the only safe change.');
} else if (failures !== 0) {
  console.error(`\n${failures} layout check(s) failed. Do not upgrade either proxy until this is understood.`);
  process.exit(1);
}
