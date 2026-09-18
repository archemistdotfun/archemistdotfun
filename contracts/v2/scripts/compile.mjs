#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import solc from 'solc';

const deploymentRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const artifactsDir = path.resolve(deploymentRoot, 'artifacts');
const sourceFiles = [
  'src/ArchemistProxy.sol',
  'src/ArchemistV2USDCLockerV3.sol',
  'src/ArchemistV2USDCFactoryV3.sol',
];
const compilerVersion = solc.version();

if (!compilerVersion.startsWith('0.8.26+')) {
  throw new Error(`Expected solc 0.8.26, received ${compilerVersion}`);
}

const sources = Object.fromEntries(sourceFiles.map((relativePath) => [
  relativePath,
  { content: fs.readFileSync(path.resolve(deploymentRoot, relativePath), 'utf8') },
]));
const settings = {
  optimizer: { enabled: true, runs: 200 },
  viaIR: true,
  // No metadata hash: the deployed bytecode is a pure function of the source, so explorer verification
  // matches from the source alone and never depends on comment text or file names.
  metadata: { bytecodeHash: 'none', appendCBOR: false },
  outputSelection: {
    '*': {
      // `storageLayout` feeds `check-storage-layout.mjs`. These two implementations sit behind UUPS
      // proxies with no way back, so their layout is a compatibility surface, not an internal detail.
      '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'storageLayout'],
    },
  },
};
const output = JSON.parse(solc.compile(JSON.stringify({ language: 'Solidity', sources, settings })));
const errors = (output.errors ?? []).filter((entry) => entry.severity === 'error');
if (errors.length !== 0) {
  throw new Error(errors.map((entry) => entry.formattedMessage).join('\n'));
}

fs.mkdirSync(artifactsDir, { recursive: true });
for (const name of fs.readdirSync(artifactsDir)) {
  if (/^src_.*_sol_/u.test(name)) {
    fs.unlinkSync(path.resolve(artifactsDir, name));
  }
}

const artifactHashes = {};
for (const [source, contracts] of Object.entries(output.contracts)) {
  for (const [contractName, artifact] of Object.entries(contracts)) {
    const prefix = source.replace(/[\/.]/gu, '_');
    const abiName = `${prefix}_${contractName}.abi`;
    const binName = `${prefix}_${contractName}.bin`;
    const abi = JSON.stringify(artifact.abi);
    const bin = artifact.evm.bytecode.object;
    fs.writeFileSync(path.resolve(artifactsDir, abiName), abi);
    fs.writeFileSync(path.resolve(artifactsDir, binName), bin);
    if (artifact.storageLayout) {
      fs.writeFileSync(
        path.resolve(artifactsDir, `${prefix}_${contractName}.storage-layout.json`),
        `${JSON.stringify(artifact.storageLayout, null, 2)}\n`,
      );
    }
    artifactHashes[contractName] = {
      abiSha256: crypto.createHash('sha256').update(abi).digest('hex'),
      creationBytecodeSha256: crypto.createHash('sha256').update(bin).digest('hex'),
      creationBytes: bin.length / 2,
      runtimeBytes: artifact.evm.deployedBytecode.object.length / 2,
    };
  }
}

const buildInfo = {
  compiler: compilerVersion,
  settings,
  sources: Object.fromEntries(Object.entries(sources).map(([name, source]) => [
    name,
    { sha256: crypto.createHash('sha256').update(source.content).digest('hex') },
  ])),
  artifacts: artifactHashes,
};
fs.writeFileSync(
  path.resolve(artifactsDir, 'archemist-v2-build-info.json'),
  `${JSON.stringify(buildInfo, null, 2)}\n`,
);

console.table(Object.entries(artifactHashes).map(([contract, details]) => ({
  contract,
  creationBytes: details.creationBytes,
  runtimeBytes: details.runtimeBytes,
})));
console.log(`Compiler: ${compilerVersion}`);
console.log(`Build info: ${path.resolve(artifactsDir, 'archemist-v2-build-info.json')}`);
console.log('Storage-layout gate: npm run check-storage-layout');
