.PHONY: install build test sizes test-fork-mainnet test-fork-mainnet-v2 layout-references

install:
	forge install --no-git \
		Uniswap/v4-core@46c6834698c48bc4a463a86d8420f4eb1d7f3b75 \
		Uniswap/v4-periphery@dce236d4e2057422d0791d9a973a58765eb46f65 \
		foundry-rs/forge-std@v1.9.7

build:
	forge build

test:
	forge test -vvv

sizes:
	forge build --sizes

# Runs the suite against a FORK of Arc mainnet: the real PoolManager, the real ARCH, the real Uniswap v3
# ARCH/USDC pool and its actual liquidity, and the real linked USDC with its Circle precompiles. Reads
# only - it spends nothing and broadcasts nothing. Needs RPC_URL_MAINNET in .env.
#
# Pin a block (FORK_BLOCK=...) to make reruns cheap and results reproducible; without one it takes the
# chain tip, so the numbers move with the market.
test-fork-mainnet:
	set -a; . ./.env; set +a; \
	forge test --match-path 'test/ArcMainnetFork.t.sol' -vv \
		--fork-url "$$RPC_URL_MAINNET" \
		$(if $(FORK_BLOCK),--fork-block-number $(FORK_BLOCK),)

# The same, for the V2 launchpad's implementation v3, against Arc mainnet's real Uniswap v3 periphery -
# the real NonfungiblePositionManager, the real SwapRouter02, the real v3 factory.
test-fork-mainnet-v2:
	set -a; . ./.env; set +a; \
	forge test --match-path 'test/ArcMainnetForkV2.t.sol' -vv \
		--fork-url "$$RPC_URL_MAINNET" \
		$(if $(FORK_BLOCK),--fork-block-number $(FORK_BLOCK),)

# Regenerates the committed storage-layout references the upgrade gate enforces. READ THE DIFF:
# appended lines at the end are the only safe change.
layout-references:
	forge build && forge script script/WriteLayoutReferences.s.sol && git diff test/layout/reference/


# --- Verified Token Information escrow -------------------------------------
# Price and fee are NATIVE amounts. On Arc the native currency is USDC at 18-decimal
# scale, so $150 is 150 ether and Blockscout's $99 wholesale fee is 99 ether.
# Pilot pricing: 0.0015 USDC total, 0.00099 to Blockscout, 0.00051 to Archemist - the
# agreed $150/$99 ratio scaled right down, since Blockscout does not bill verifications
# until Archemist mainnet launch. Do not go lower: Arc USDC is 18 decimals natively but 6
# in its ERC-20 view, so anything under 1e12 wei displays as 0 there.
# Commercial values: 150000000000000000000 / 99000000000000000000.
VERIFICATION_PRICE ?= 1500000000000000
VERIFICATION_FEE   ?= 990000000000000
ARC_MAINNET_RPC    ?= https://rpc.arc-scan.org
ARC_TESTNET_RPC    ?= https://rpc.testnet.arc.network

# Treasury: ArchemistFeeRouterV3's treasury, where protocol revenue already lands.
# Blockscout's Arc address, given 2026-09-12; they move to a Safe later (setBlockscoutRecipient).
VERIFICATION_TREASURY  ?= 0x10B1E155E7164b720d120618ab5709bED33959d3
BLOCKSCOUT_RECIPIENT   ?= 0xF3e177A4034cF6e57cCBe80108cAe6f3729C6649

deploy-verification-payments-mainnet:
	SYSTEM_OWNER=$$(cast wallet address --private-key $$DEPLOYER_PRIVATE_KEY) \
	TREASURY=$(VERIFICATION_TREASURY) \
	SETTLER=$$(cast wallet address --private-key $$DEPLOYER_PRIVATE_KEY) \
	BLOCKSCOUT_RECIPIENT=$(BLOCKSCOUT_RECIPIENT) \
	PRICE=$(VERIFICATION_PRICE) \
	BLOCKSCOUT_FEE=$(VERIFICATION_FEE) \
	forge script script/DeployVerificationPayments.s.sol \
		--rpc-url $(ARC_MAINNET_RPC) --broadcast --slow

deploy-verification-payments-testnet:
	SYSTEM_OWNER=$$(cast wallet address --private-key $$DEPLOYER_PRIVATE_KEY) \
	TREASURY=$(VERIFICATION_TREASURY) \
	SETTLER=$$(cast wallet address --private-key $$DEPLOYER_PRIVATE_KEY) \
	BLOCKSCOUT_RECIPIENT=$(BLOCKSCOUT_RECIPIENT) \
	PRICE=$(VERIFICATION_PRICE) \
	BLOCKSCOUT_FEE=$(VERIFICATION_FEE) \
	forge script script/DeployVerificationPayments.s.sol \
		--rpc-url $(ARC_TESTNET_RPC) --broadcast --slow


# --- ARCH fee redistributor -------------------------------------------------
# Redistributes the ARCH side of ARCH's own LP fees to ARCH holders, pro rata,
# one Merkle epoch at a time. The USDC side is swept to USDC_SINK untouched.
#
# Deploying changes nothing on its own: fees only start arriving once
# creatorFeeAdmin (0x10B1E155…) points the locker's creator recipient at it, with
# redirect-arch-fees-mainnet below. Do that only after checking the address.
ARCH_TOKEN         ?= 0x5042419b1F2498959787Bc23Be1F484Ed1306650
ARCH_V2_LOCKER     ?= 0x7Dd53C388F650c0DaB535eFb03d8bd80F0A6bD07
ARCH_USDC_SINK     ?= 0x4C85e3847c549f4823cf9bBD5Dfc7E1724559AEf

deploy-arch-redistributor-mainnet:
	SYSTEM_OWNER=$${SYSTEM_OWNER:-$$(cast wallet address --private-key $$DEPLOYER_PRIVATE_KEY)} \
	PUBLISHER=$${PUBLISHER:-$$(cast wallet address --private-key $$DEPLOYER_PRIVATE_KEY)} \
	ARCH=$(ARCH_TOKEN) \
	LOCKER=$(ARCH_V2_LOCKER) \
	USDC_SINK=$(ARCH_USDC_SINK) \
	forge script script/DeployArchRedistributor.s.sol \
		--rpc-url $(ARC_MAINNET_RPC) --broadcast --slow

# Dry run first - prints the same wiring report without deploying anything.
simulate-arch-redistributor-mainnet:
	ARCH=$(ARCH_TOKEN) LOCKER=$(ARCH_V2_LOCKER) USDC_SINK=$(ARCH_USDC_SINK) \
	forge script script/DeployArchRedistributor.s.sol --rpc-url $(ARC_MAINNET_RPC)

# The one irreversible-feeling step: live revenue starts flowing to REDISTRIBUTOR.
# Must be sent by creatorFeeAdmin's key. Fees credited before this stay with the
# old recipient and are claimed there - the switch is not retroactive.
redirect-arch-fees-mainnet:
	@test -n "$(REDISTRIBUTOR)" || (echo "REDISTRIBUTOR=0x… is required" && exit 1)
	cast send $(ARCH_V2_LOCKER) "updateCreatorFeeRecipient(address,address)" \
		$(ARCH_TOKEN) $(REDISTRIBUTOR) \
		--rpc-url $(ARC_MAINNET_RPC) --private-key $$CREATOR_FEE_ADMIN_KEY
