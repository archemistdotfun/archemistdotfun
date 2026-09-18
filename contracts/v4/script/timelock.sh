#!/usr/bin/env bash
# Timelock operations for the Archemist system contracts.
#
# Every privileged action on this system - upgrades, registerHook, setHookEnabled, enableCreate,
# retire, addPair, acceptOwnership - goes through the TimelockController, because the timelock is the
# owner of every proxy. This is the CLI for doing that, and it is deliberately the SAME script for
# testnet and mainnet so the mainnet run is a repeat of something already rehearsed rather than a
# first attempt.
#
#   ./script/timelock.sh status   <TARGET> <CALLDATA> [SALT]
#   ./script/timelock.sh schedule <TARGET> <CALLDATA> [SALT]
#   ./script/timelock.sh execute  <TARGET> <CALLDATA> [SALT]
#   ./script/timelock.sh cancel   <TARGET> <CALLDATA> [SALT]
#
# Environment:
#   TIMELOCK     the TimelockController address                       (required)
#   RPC          RPC endpoint                                          (required)
#   PRIVATE_KEY  proposer/canceller key; not needed for `status`       (schedule/cancel only)
#   SALT         32-byte salt. Defaults to keccak(target+calldata), which makes the operation id
#                deterministic so `status` and `execute` can be re-derived without notes - and, when
#                that exact operation has been run before, to the next free variant of it. See below.
#
# Build CALLDATA with `cast calldata`, e.g.
#   cast calldata "registerHook(address)" 0xHOOK
#   cast calldata "upgradeToAndCall(address,bytes)" 0xNEWIMPL 0x
#   cast calldata "setHookEnabled(address,bool)" 0xHOOK false
#
# `execute` needs no key on a correctly configured timelock: the executor role is address(0), meaning
# anyone may execute once the delay has elapsed. Nobody can be locked out of executing a change that is
# already public.
set -euo pipefail

ACTION="${1:-}"; TARGET="${2:-}"; CALLDATA="${3:-}"; SALT_ARG="${4:-}"
: "${TIMELOCK:?set TIMELOCK}"; : "${RPC:?set RPC}"

if [[ -z "$ACTION" || -z "$TARGET" || -z "$CALLDATA" ]]; then
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

PREDECESSOR=0x0000000000000000000000000000000000000000000000000000000000000000
DELAY=$(cast call "$TIMELOCK" "getMinDelay()(uint256)" --rpc-url "$RPC" | cut -d' ' -f1)

_op_id() {
  cast call "$TIMELOCK" "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
    "$TARGET" 0 "$CALLDATA" "$PREDECESSOR" "$1" --rpc-url "$RPC"
}
_bool() { cast call "$TIMELOCK" "$1(bytes32)(bool)" "$2" --rpc-url "$RPC"; }

# ---------------------------------------------------------------------------------------------------
# Salt selection.
#
# A purely deterministic salt means an operation can only ever be scheduled ONCE: OpenZeppelin keeps an
# executed operation forever, with timestamp 1, and `schedule` refuses an id it has already seen. So
# `setHookEnabled(hook, false)` after `setHookEnabled(hook, true)`, or a second `updatePair` with the
# same arguments, or simply retrying something that was cancelled, failed with
# `TimelockUnexpectedOperationState` and no hint as to why. Before this, the operator
# had to know to pass SALT by hand, at exactly the moment they are least likely to be improvising.
#
# The base salt stays deterministic, so the common case still needs no notes. When that operation has
# already been used, the CLI walks a numbered series derived from it - and `status`/`execute`/`cancel`
# walk the same series, so they find the live one without being told which attempt it was.
# ---------------------------------------------------------------------------------------------------
_base_salt() {
  cast keccak "$(cast concat-hex "$(cast to-bytes32 "$TARGET" 2>/dev/null || echo "$TARGET")" "$CALLDATA")"
}
# `cast to-uint256`, NOT `cast to-bytes32`: to-bytes32 LEFT-aligns, so it renders 1 and 10 (and 2/20,
# 3/30) as the identical word, which silently collapsed the series to 29 usable salts out of 32 and made
# two different attempts share an operation id - reintroducing, in miniature, the exact collision this
# series exists to avoid. Verified with `cast to-bytes32 1` == `cast to-bytes32 10`.
_nth_salt() {
  if [[ "$1" == "0" ]]; then _base_salt; else cast keccak "$(cast concat-hex "$(_base_salt)" "$(cast to-uint256 "$1")")"; fi
}

if [[ -n "$SALT_ARG" || -n "${SALT:-}" ]]; then
  SALT="${SALT_ARG:-$SALT}"
  ID=$(_op_id "$SALT")
else
  SALT=""
  for n in $(seq 0 31); do
    CANDIDATE=$(_nth_salt "$n")
    CANDIDATE_ID=$(_op_id "$CANDIDATE")
    EXISTS=$(_bool isOperation "$CANDIDATE_ID")
    if [[ "$ACTION" == "schedule" ]]; then
      # The first id the timelock has never seen.
      if [[ "$EXISTS" == "false" ]]; then SALT="$CANDIDATE"; ID="$CANDIDATE_ID"; break; fi
    else
      # The live one: scheduled and not yet executed. Keep walking past finished attempts.
      if [[ "$EXISTS" == "true" && "$(_bool isOperationDone "$CANDIDATE_ID")" == "false" ]]; then
        SALT="$CANDIDATE"; ID="$CANDIDATE_ID"; break
      fi
      if [[ "$EXISTS" == "false" ]]; then break; fi
    fi
    [[ "$n" == "0" ]] || echo "note: salt #$n is taken, trying the next"
  done
  if [[ -z "$SALT" ]]; then
    # Nothing live to act on - fall back to the base salt so `status` still reports honestly rather
    # than the script dying with an empty variable.
    SALT=$(_base_salt)
    ID=$(_op_id "$SALT")
  fi
fi

echo "timelock   $TIMELOCK"
echo "target     $TARGET"
echo "calldata   $CALLDATA"
echo "salt       $SALT"
echo "op id      $ID"
if [[ "$SALT" != "$(_base_salt)" ]]; then
  echo "           ^ NOT the base salt: an identical operation ran before. Pass this same salt to"
  echo "             status/execute/cancel if you script them, or let this CLI re-derive it."
fi
echo "minDelay   ${DELAY}s"

case "$ACTION" in
  status)
    PENDING=$(cast call "$TIMELOCK" "isOperationPending(bytes32)(bool)" "$ID" --rpc-url "$RPC")
    READY=$(cast call "$TIMELOCK" "isOperationReady(bytes32)(bool)" "$ID" --rpc-url "$RPC")
    DONE=$(cast call "$TIMELOCK" "isOperationDone(bytes32)(bool)" "$ID" --rpc-url "$RPC")
    WHEN=$(cast call "$TIMELOCK" "getTimestamp(bytes32)(uint256)" "$ID" --rpc-url "$RPC" | cut -d' ' -f1)
    echo "pending    $PENDING"
    echo "ready      $READY"
    echo "done       $DONE"
    if [[ "$WHEN" != "0" && "$WHEN" != "1" ]]; then
      echo "ready at   $WHEN  ($(( WHEN - $(date +%s) ))s from now)"
    fi
    ;;
  schedule)
    : "${PRIVATE_KEY:?set PRIVATE_KEY}"
    echo ""
    echo ">>> scheduling. This is PUBLIC from this moment and executable in ${DELAY}s."
    cast send "$TIMELOCK" "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
      "$TARGET" 0 "$CALLDATA" "$PREDECESSOR" "$SALT" "$DELAY" \
      --rpc-url "$RPC" --private-key "$PRIVATE_KEY"
    ;;
  execute)
    # No key required in principle (executor is open), but cast needs one to send a transaction.
    : "${PRIVATE_KEY:?set PRIVATE_KEY (any funded account - the executor role is open to all)}"
    cast send "$TIMELOCK" "execute(address,uint256,bytes,bytes32,bytes32)" \
      "$TARGET" 0 "$CALLDATA" "$PREDECESSOR" "$SALT" \
      --rpc-url "$RPC" --private-key "$PRIVATE_KEY"
    ;;
  cancel)
    : "${PRIVATE_KEY:?set PRIVATE_KEY}"
    cast send "$TIMELOCK" "cancel(bytes32)" "$ID" --rpc-url "$RPC" --private-key "$PRIVATE_KEY"
    ;;
  *)
    echo "unknown action: $ACTION (expected status|schedule|execute|cancel)" >&2
    exit 1
    ;;
esac
