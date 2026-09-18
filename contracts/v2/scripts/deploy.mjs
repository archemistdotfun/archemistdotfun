#!/usr/bin/env node

/**
 * Deploys Archemist V2 **implementation version 3** - the trustless redeploy.
 *
 * What is different from `deploy-usdc-launch-factory.mjs`, and why:
 *
 *   - Both contracts go behind `ArchemistProxy` (the repo's own EIP-1967 UUPS proxy, byte-identical to
 *     the fee router's, which has been upgraded in place on Arc twice). Their addresses therefore never
 *     change again, and the six-full-redeploys era ends here.
 *   - The locker has no `setLaunchFactory`, so the link cannot be made in a second transaction. Instead
 *     the locker proxy is initialized with the factory proxy's address PREDICTED from this deployer's
 *     nonce, and the factory's own `initialize` refuses to run unless `locker.launchFactory()` really is
 *     the address it ended up at. A wrong prediction fails loudly at deploy time, before any creator can
 *     depend on it.
 *   - Neither contract has any administrative function other than upgrade. The only
 *     privileged function on either is `upgradeToAndCall`, and ownership is handed to a
 *     `TimelockController` at the end (two-step: this script transfers, the timelock accepts through a
 *     scheduled operation after its delay).
 *
 * Usage:
 *   NETWORK=arc-mainnet npm run deploy-usdc-launch-factory-v3
 *
 * Environment (read from .env in this directory):
 *   PRIVATE_KEY_MAINNET or PRIVATE_KEY_DEV   the deployer
 *   TIMELOCK                                 the TimelockController that will own both proxies.
 *                                            Omit for a testnet candidate you intend to keep owning.
 *   TREASURY                                 defaults to the deployer
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPublicClient, createWalletClient, encodeFunctionData, getAddress, getContractAddress, keccak256, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { loadDotEnv, privateKeyFromEnv } from '../lib/config.mjs';
import { createSerializedRpcTransport } from '../lib/rpc.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const artifacts = path.resolve(root, 'artifacts');

const NETWORK = process.env.NETWORK ?? 'arc-testnet';
const MANIFESTS = {
  'arc-mainnet': 'deployments/arc-mainnet.json',
  'arc-testnet': 'deployments/arc-testnet.json',
};
// Creator 80% / treasury 20%. NOT passed to the contract - it is a constant in
// ArchemistV2USDCLockerV3, so a wrong deploy argument cannot produce a wrong split. Read back and
// asserted below, which is what makes this a check rather than a comment.
const EXPECTED_PROTOCOL_FEE_BPS = 2_000n;

/// Just the four entry points the handover needs. OpenZeppelin's TimelockController.
const TIMELOCK_ABI = [
  { type: 'function', name: 'PROPOSER_ROLE', stateMutability: 'view', inputs: [], outputs: [{ type: 'bytes32' }] },
  { type: 'function', name: 'getMinDelay', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  {
    type: 'function', name: 'hasRole', stateMutability: 'view',
    inputs: [{ type: 'bytes32' }, { type: 'address' }], outputs: [{ type: 'bool' }],
  },
  {
    type: 'function', name: 'schedule', stateMutability: 'nonpayable',
    inputs: [
      { name: 'target', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'data', type: 'bytes' },
      { name: 'predecessor', type: 'bytes32' }, { name: 'salt', type: 'bytes32' }, { name: 'delay', type: 'uint256' },
    ],
    outputs: [],
  },
];

function artifactPath(file, contract) {
  return {
    abi: path.resolve(artifacts, `src_${file}_sol_${contract}.abi`),
    bin: path.resolve(artifacts, `src_${file}_sol_${contract}.bin`),
  };
}

function loadArtifact({ abi, bin }) {
  const parsed = JSON.parse(fs.readFileSync(abi, 'utf8'));
  const raw = fs.readFileSync(bin, 'utf8').trim();
  return { abi: parsed, bytecode: raw.startsWith('0x') ? raw : `0x${raw}` };
}

async function deployAndWait(label, ctx, artifact, args) {
  const hash = await ctx.wallet.deployContract({ account: ctx.account, ...artifact, args });
  const receipt = await ctx.publicClient.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 240_000 });
  if (receipt.status !== 'success' || !receipt.contractAddress) {
    throw new Error(`${label} deployment reverted: ${hash}`);
  }
  console.log(`  ${label.padEnd(24)} ${getAddress(receipt.contractAddress)}  (${hash})`);
  return { address: getAddress(receipt.contractAddress), transaction: hash, blockNumber: receipt.blockNumber };
}

const manifestRelative = MANIFESTS[NETWORK];
if (!manifestRelative) throw new Error(`Unknown NETWORK "${NETWORK}" (expected one of ${Object.keys(MANIFESTS)})`);
loadDotEnv(path.resolve(root, '.env'));

const manifest = JSON.parse(fs.readFileSync(path.resolve(root, manifestRelative), 'utf8'));
const proxy = loadArtifact(artifactPath('ArchemistProxy', 'ArchemistProxy'));
const lockerImpl = loadArtifact(artifactPath('ArchemistV2USDCLockerV3', 'ArchemistV2USDCLockerV3'));
const factoryImpl = loadArtifact(artifactPath('ArchemistV2USDCFactoryV3', 'ArchemistV2USDCFactoryV3'));

const rpcUrls = [...new Set([
  process.env.RPC_URL,
  NETWORK === 'arc-mainnet' ? process.env.ARC_MAINNET_RPC_URL : process.env.ARC_TESTNET_RPC_URL,
  NETWORK === 'arc-mainnet' ? 'https://rpc.arc-scan.org' : 'https://rpc.testnet.arc.network',
].filter((value) => typeof value === 'string' && /^https?:\/\//u.test(value)))];
const chain = {
  id: Number(manifest.chainId),
  name: manifest.network,
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: [rpcUrls[0]] } },
  testnet: NETWORK !== 'arc-mainnet',
};
const transport = createSerializedRpcTransport(rpcUrls, { minIntervalMs: 200, maxRetries: 8 });
const publicClient = createPublicClient({ chain, transport });
const account = privateKeyToAccount(
  privateKeyFromEnv(NETWORK === 'arc-mainnet' ? 'PRIVATE_KEY_MAINNET' : 'PRIVATE_KEY_DEV'),
);
const wallet = createWalletClient({ account, chain, transport });
const ctx = { account, wallet, publicClient };

const treasury = getAddress(process.env.TREASURY ?? account.address);
const timelock = process.env.TIMELOCK ? getAddress(process.env.TIMELOCK) : null;
const { pairedToken, uniswapV3Factory, nonfungiblePositionManager, swapRouter02 } = manifest.contracts;

console.log(`Network        ${NETWORK} (chain ${manifest.chainId})`);
console.log(`Deployer       ${account.address}`);
console.log(`Treasury       ${treasury}`);
console.log(`Timelock       ${timelock ?? '(none - deployer keeps ownership)'}`);
console.log('');

// --- 1. implementations ------------------------------------------------------------------------
const lockerImplDeployment = await deployAndWait('locker impl v3', ctx, lockerImpl, [BigInt(manifest.chainId)]);
const factoryImplDeployment = await deployAndWait('factory impl v3', ctx, factoryImpl, [BigInt(manifest.chainId)]);

// --- 2. predict the factory proxy's address --------------------------------------------------------
// The locker's `initialize` takes the factory proxy's address, and the factory proxy does not exist
// yet. CREATE is deterministic in the deployer's nonce, so the next-but-one contract this account
// deploys is knowable: locker proxy at `nonce`, factory proxy at `nonce + 1`. The factory's own
// `initialize` verifies the prediction was right, so a mistake here cannot go unnoticed.
const nonceAfterImpls = await publicClient.getTransactionCount({ address: account.address });
const predictedLockerProxy = getContractAddress({ from: account.address, nonce: BigInt(nonceAfterImpls) });
const predictedFactoryProxy = getContractAddress({ from: account.address, nonce: BigInt(nonceAfterImpls + 1) });
console.log(`  predicted locker proxy   ${predictedLockerProxy}`);
console.log(`  predicted factory proxy  ${predictedFactoryProxy}`);

// --- 3. proxies, initialized inside their own constructors -----------------------------------------
const lockerInit = encodeFunctionData({
  abi: lockerImpl.abi,
  functionName: 'initialize',
  args: [
    account.address,
    treasury,
    pairedToken,
    nonfungiblePositionManager,
    predictedFactoryProxy,
  ],
});
const lockerProxy = await deployAndWait('locker proxy', ctx, proxy, [lockerImplDeployment.address, lockerInit]);
if (lockerProxy.address !== predictedLockerProxy) {
  throw new Error(`Locker proxy landed at ${lockerProxy.address}, predicted ${predictedLockerProxy}`);
}

const factoryInit = encodeFunctionData({
  abi: factoryImpl.abi,
  functionName: 'initialize',
  args: [
    account.address,
    treasury,
    pairedToken,
    uniswapV3Factory,
    nonfungiblePositionManager,
    swapRouter02,
    lockerProxy.address,
  ],
});
const factoryProxy = await deployAndWait('factory proxy', ctx, proxy, [factoryImplDeployment.address, factoryInit]);
if (factoryProxy.address !== predictedFactoryProxy) {
  throw new Error(`Factory proxy landed at ${factoryProxy.address}, predicted ${predictedFactoryProxy}`);
}

// --- 3b. write down what exists BEFORE anything can go wrong ----------------------------------------
//
// Everything past this point is reads and owner calls, and any of them can fail for reasons that have
// nothing to do with the deployment - an RPC that refuses `eth_call` is enough. When that happened on
// the Arc mainnet run, the script died mid-verification and the four addresses it had just created were
// only recoverable out of a crash dump. Four contracts are on chain by now; losing track of them is a
// far worse outcome than any of the checks below failing.
//
// So the manifest is written here, marked incomplete, and rewritten at the end with the full record.
const addressesSoFar = {
  network: NETWORK,
  chainId: Number(manifest.chainId),
  implementationVersion: 3,
  proxy: true,
  status: 'INCOMPLETE - deploy succeeded, later steps not yet confirmed',
  contracts: {
    pairedToken,
    uniswapV3Factory,
    nonfungiblePositionManager,
    swapRouter02,
    lockerImplementation: lockerImplDeployment.address,
    lockerProxy: lockerProxy.address,
    factoryImplementation: factoryImplDeployment.address,
    factoryProxy: factoryProxy.address,
    timelock,
  },
  transactions: {
    lockerImplementation: lockerImplDeployment.transaction,
    lockerProxy: lockerProxy.transaction,
    factoryImplementation: factoryImplDeployment.transaction,
    factoryProxy: factoryProxy.transaction,
  },
};
fs.writeFileSync(path.resolve(root, manifestRelative.replace('.json', '.partial.json')),
  `${JSON.stringify(addressesSoFar, null, 2)}\n`);
console.log('');
console.log(`  addresses recorded in ${manifestRelative.replace('.json', '.partial.json')} before verification`);

// --- 4. assert every link on chain, while a mistake is still cheap to fix ---------------------------
//
// A read that throws is NOT the same as a link that is wrong, and conflating them is how a healthy
// deployment gets re-run. `eth_call` being refused by the RPC says nothing about the contracts.
const read = async (address, abi, functionName) => {
  try {
    return await publicClient.readContract({ address, abi, functionName });
  } catch (error) {
    console.error('');
    console.error(`  !! could not READ ${functionName}() from ${address}.`);
    console.error('     The contracts above are deployed and their addresses are recorded. This is an RPC');
    console.error('     problem, not a deployment problem - do NOT re-run this script, which would deploy');
    console.error('     a second set. Re-point RPC_URL at a node that serves eth_call and verify by hand,');
    console.error('     then finish the handover (transferOwnership + timelock schedule).');
    console.error(`     underlying: ${error.shortMessage ?? error.message}`);
    throw error;
  }
};
const [
  lockerLaunchFactory, lockerPairedToken, lockerTreasury, lockerProtocolBps, lockerOwner, lockerVersion,
  factoryLocker, factoryPairedToken, factoryTreasury, factoryOwner, factoryVersion,
] = await Promise.all([
  read(lockerProxy.address, lockerImpl.abi, 'launchFactory'),
  read(lockerProxy.address, lockerImpl.abi, 'pairedToken'),
  read(lockerProxy.address, lockerImpl.abi, 'treasury'),
  read(lockerProxy.address, lockerImpl.abi, 'protocolFeeBps'),
  read(lockerProxy.address, lockerImpl.abi, 'owner'),
  read(lockerProxy.address, lockerImpl.abi, 'PROXY_VERSION'),
  read(factoryProxy.address, factoryImpl.abi, 'LOCKER'),
  read(factoryProxy.address, factoryImpl.abi, 'PAIRED_TOKEN'),
  read(factoryProxy.address, factoryImpl.abi, 'TREASURY'),
  read(factoryProxy.address, factoryImpl.abi, 'owner'),
  read(factoryProxy.address, factoryImpl.abi, 'PROXY_VERSION'),
]);

const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const failures = [];
if (!same(lockerLaunchFactory, factoryProxy.address)) failures.push('locker.launchFactory');
if (!same(factoryLocker, lockerProxy.address)) failures.push('factory.LOCKER');
if (!same(lockerPairedToken, pairedToken)) failures.push('locker.pairedToken');
if (!same(factoryPairedToken, pairedToken)) failures.push('factory.PAIRED_TOKEN');
if (!same(lockerTreasury, treasury)) failures.push('locker.treasury');
if (!same(factoryTreasury, treasury)) failures.push('factory.TREASURY');
if (lockerProtocolBps !== EXPECTED_PROTOCOL_FEE_BPS) failures.push('locker.protocolFeeBps');
if (!same(lockerOwner, account.address)) failures.push('locker.owner');
if (!same(factoryOwner, account.address)) failures.push('factory.owner');
if (lockerVersion !== 3n || factoryVersion !== 3n) failures.push('PROXY_VERSION');
if (failures.length !== 0) throw new Error(`Deployment verification failed: ${failures.join(', ')}`);

// --- 5. the two implementations must be distinguishable from each other -------------------------
// `PROXY_VERSION() != 0` and
// the chain id are satisfied by BOTH, so without a distinct `ARCHEMIST_KIND` a copy-pasted
// `upgradeToAndCall` could point either proxy at the other's implementation and it would be accepted:
// the proxy comes back speaking the wrong ABI over the right storage. These two are deployed seconds
// apart by this very script, which is exactly what makes that the likely mistake.
const [lockerKind, factoryKind] = await Promise.all([
  read(lockerProxy.address, lockerImpl.abi, 'ARCHEMIST_KIND'),
  read(factoryProxy.address, factoryImpl.abi, 'ARCHEMIST_KIND'),
]);
if (lockerKind === factoryKind) throw new Error('locker and factory share an ARCHEMIST_KIND');
console.log(`  locker kind   ${lockerKind}`);
console.log(`  factory kind  ${factoryKind}`);

// --- 6. hand over ----------------------------------------------------------------------------------
// Two steps, both in this run.
//
// Step one offers ownership; step two SCHEDULES the `acceptOwnership()` calls on the timelock so the
// handover cannot be forgotten. The V4 script does the same; leaving it out here meant
// the V2 proxies would sit owned by a single EOA, able to upgrade either contract instantly, with
// nothing anywhere recording that the handover was still owed. That is the gap this closes, and
// it is worse on this side because nothing else in the V2 pipeline would ever notice.
//
// It is still only step two of three: the operations cannot execute for the timelock's delay, they are
// public that whole time, and the proposer can cancel them. If the timelock address were wrong, the
// deployer is still the owner and can point ownership somewhere else before they mature.
const HANDOVER_SALT = keccak256(toHex('archemist.v2.v3.handover'));
const ACCEPT_OWNERSHIP = encodeFunctionData({ abi: lockerImpl.abi, functionName: 'acceptOwnership', args: [] });
const PREDECESSOR = '0x0000000000000000000000000000000000000000000000000000000000000000';

if (timelock) {
  for (const [label, address, abi] of [
    ['locker', lockerProxy.address, lockerImpl.abi],
    ['factory', factoryProxy.address, factoryImpl.abi],
  ]) {
    const hash = await wallet.writeContract({
      account, address, abi, functionName: 'transferOwnership', args: [timelock],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 240_000 });
    if (receipt.status !== 'success') throw new Error(`${label} transferOwnership reverted: ${hash}`);
    console.log(`  ${label} ownership offered to the timelock  (${hash})`);
  }

  // Only the proposer may schedule. When the deployer is not it, say so loudly rather than reverting
  // the whole deploy over the last step.
  const proposerRole = await publicClient.readContract({
    address: timelock, abi: TIMELOCK_ABI, functionName: 'PROPOSER_ROLE',
  });
  const canPropose = await publicClient.readContract({
    address: timelock, abi: TIMELOCK_ABI, functionName: 'hasRole', args: [proposerRole, account.address],
  });
  const minDelay = await publicClient.readContract({
    address: timelock, abi: TIMELOCK_ABI, functionName: 'getMinDelay',
  });

  if (!canPropose) {
    console.log('');
    console.log(`  !! ${account.address} is NOT a proposer on ${timelock}.`);
    console.log('     acceptOwnership() was NOT scheduled - whoever holds PROPOSER_ROLE must do it, or');
    console.log('     these proxies stay owned by this EOA indefinitely.');
  } else {
    for (const [label, address] of [['locker', lockerProxy.address], ['factory', factoryProxy.address]]) {
      const hash = await wallet.writeContract({
        account,
        address: timelock,
        abi: TIMELOCK_ABI,
        functionName: 'schedule',
        args: [address, 0n, ACCEPT_OWNERSHIP, PREDECESSOR, HANDOVER_SALT, minDelay],
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 240_000 });
      if (receipt.status !== 'success') throw new Error(`${label} handover schedule reverted: ${hash}`);
      console.log(`  ${label} acceptOwnership() scheduled        (${hash})`);
    }
    console.log(`  handover salt   ${HANDOVER_SALT}`);
    console.log(`  executable in   ${minDelay}s (anyone may execute once it matures)`);
  }
}

console.log('');
// The completed record. Written to a FILE as well as printed: the run that matters happens once, on
// mainnet, and "it was in the terminal" is not a deployment record. Replaces the `.partial.json`
// written before verification.
const finalManifest = {
  network: NETWORK,
  chainId: Number(manifest.chainId),
  implementationVersion: 3,
  proxy: true,
  predecessor: manifestRelative.includes('mainnet') ? 'arc-mainnet-usdc-v2' : 'arc-testnet-usdc',
  contracts: {
    pairedToken,
    uniswapV3Factory,
    nonfungiblePositionManager,
    swapRouter02,
    lockerImplementation: lockerImplDeployment.address,
    lockerProxy: lockerProxy.address,
    factoryImplementation: factoryImplDeployment.address,
    factoryProxy: factoryProxy.address,
    timelock,
  },
  configuration: {
    treasury,
    protocolFeeBps: Number(lockerProtocolBps),
    creatorFeeBps: 10_000 - Number(lockerProtocolBps),
    feeSplitSource: 'constant in ArchemistV2USDCLockerV3 - not a deploy argument, not settable',
  },
  transactions: {
    lockerImplementation: lockerImplDeployment.transaction,
    lockerProxy: lockerProxy.transaction,
    factoryImplementation: factoryImplDeployment.transaction,
    factoryProxy: factoryProxy.transaction,
  },
  handoverSalt: timelock ? HANDOVER_SALT : null,
  nextSteps: timelock
    ? [
      'acceptOwnership() is already SCHEDULED on both proxies by this script - it does not need proposing.',
      'After the timelock delay, EXECUTE both (anyone may; the executor role is open):',
      "  ./script/timelock.sh execute <PROXY> \"$(cast calldata 'acceptOwnership()')\" <handoverSalt>",
      'Until they execute, the deployer still owns both proxies and can upgrade either one instantly.',
    ]
    : ['ownership left with the deployer - set TIMELOCK and re-run, or transfer manually'],
};

const serialized = JSON.stringify(finalManifest, (_, value) => (typeof value === 'bigint' ? value.toString() : value), 2);
const outPath = path.resolve(root, `deployments/${NETWORK}-usdc-v3.addresses.json`);
fs.writeFileSync(outPath, `${serialized}\n`);
fs.rmSync(path.resolve(root, manifestRelative.replace('.json', '.partial.json')), { force: true });
console.log(serialized);
console.log('');
console.log(`Written to deployments/${NETWORK}-usdc-v3.addresses.json`);
