# transaction-assertions

Assertion contracts for [EIP-7906](docs/eip-7906.md) (transaction assertions) on EIP-8141 frame transactions,
tested on a real go-ethereum node.

A wallet appends ASSERT frames to a frame transaction. Each one calls an assertion contract with limits the user
signed. The frames run after the body and read the transaction's net state diff and events. If one reverts,
go-ethereum reverts the whole body: every state change is undone. The transaction stays in the block and gas is
charged.

> Reference implementation, not audited. EIP-7906 and EIP-8141 are drafts. Do not deploy to mainnet.

Assertions check the outcome of the whole transaction, not its calldata or a simulation made before inclusion.
They cover two goals:

1. **Expected outcome:** the user receives or keeps what they authorized.
2. **No unexpected effects:** the transaction does not touch protected assets, permissions or wallet state.

## Use cases on Bogota

Each use case runs on a local go-ethereum `bogota-devnet-2` node as real, signed EIP-8141 frame transactions: one
that stays within the user's limits and one that breaks them. The script reads each frame's status from the receipt
and the chain state afterwards.

```shell
script/node.sh                                           # terminal 1: the Bogota node (builds geth on first run)

# Public test key: node.sh funds it on the local chain only. On a real network, use your own funded key.
KEY=<removed>
forge script script/DeployAssertions.s.sol --rpc-url local --broadcast --skip-simulation --private-key $KEY
forge script script/DeployDeFiMocks.s.sol  --rpc-url local --broadcast --skip-simulation --private-key $KEY
forge script script/UseCases.s.sol         --rpc-url local --ffi                          # all use cases
forge script script/UseCases.s.sol         --rpc-url local --ffi --sig "proxyUpgrade()"  # one
forge script script/GasBenchmarks.s.sol    --rpc-url local --ffi
```

- `DeployAssertions` is the real deployment: the reader and the assertion contracts, the same on any chain.
- `DeployDeFiMocks` runs on local dev chains only. It deploys stand-ins for the protocols the use cases interact
  with (tokens, a Safe, DEX venues), which a fresh chain does not have. On a shared devnet the use cases would use
  the real ones.

| Use case | Transaction | Assertion (ASSERT frame) | Result on the node |
|---|---|---|---|
| `spendLimit()` | send 0.4 ETH, then 0.6 ETH | `NativeETHAssertion.maxSpent(wallet, 0.5 ETH)` | 0.4 passes; 0.6 reverts, recipient gets nothing, gas is still charged |
| | transfer 150 USDC | `ERC20Assertion.maxSpentAtSlot(usdc, slot, 100)` | reverts, balances unchanged |
| `forbiddenToken()` | pay 100 USDC, then the same + a silent approval of a forbidden token | `StateAssertion.untouched([token])` | the payment passes; with the approval, the whole transaction reverts |
| `proxyUpgrade()` | Safe transfer + delegatecall swapping the implementation (Bybit) | `StateAssertion.slotUnchanged(safe, 0)` | reverts, implementation unchanged, transfer undone |
| | Safe transfer + delegatecall adding an owner | `StateAssertion.onlySlotsChanged(safe, [nonce])` | slot 0 untouched, the allowlist reverts it |
| `globalSwap()` | sell 2 × 50,000 USDC on two venues | `NativeETHAssertion.minReceived(wallet, 39 ETH)` + `maxSpentAtSlot(usdc, 100,000)` | 18 + 23 = 41 passes; 18 + 20 = 38 reverts both swaps |

forge cannot send frame transactions yet, so `script/utils/FrameTx.sol` encodes and signs them; see
[`docs/WORKAROUNDS.md`](docs/WORKAROUNDS.md) for this and the other gaps in today's tooling.

**Why a global minimum.** Per-swap slippage limits judge each venue alone. An assertion checks the wallet's net
change after every swap, however the route was built. Reading it from the balance table and the token's balance
slot, not from events, also makes it correct for fee-on-transfer tokens.

**Why an allowlist for the Safe.** Slot 0 holds the implementation. Owners, modules and the guard live at hashed
slots the wallet cannot list, but `onlySlotsChanged` refuses anything not allowed, so it covers them without
knowing the layout. Neither check stops a delegatecall that only moves assets; asset assertions cover that.

## How a wallet uses it

```
frame 0  VERIFY   signature, approve execution and gas
frame 1  SENDER   swap on venue A
frame 2  SENDER   swap on venue B
frame 3  ASSERT   NativeETHAssertion   minReceived(wallet, 39 ether)
frame 4  ASSERT   ERC20Assertion       maxSpentAtSlot(USDC, slot, 100_000e6)
```

An ASSERT frame is mode 3, `value = 0`, `target` = the assertion, and `data` = the call:

```solidity
abi.encodeCall(INativeETHAssertion.minReceived, (wallet, 39 ether));
abi.encodeCall(IERC20Assertion.maxSpentAtSlot, (USDC, keccak256(abi.encode(wallet, uint256(0))), 100_000e6));
abi.encodeCall(IStateAssertion.slotUnchanged, (safe, bytes32(0)));
```

The EIP-8141 signature covers every frame, so limits cannot be dropped or loosened. Accounts that accept session
keys must also require the frames in VERIFY ([`EmulatedAccount.sol`](test/integration/emulator/EmulatedAccount.sol)).
Complete signed frame transactions are built in [`script/UseCases.s.sol`](script/UseCases.s.sol).

## Contracts

```
contracts/
├── shared/
│   ├── TxTrace.sol            typed trace reads; base contract of every trace-based assertion
│   ├── TxTraceReader.yul      the only code using the opcodes, at a fixed CREATE2 address
│   └── ITxTraceReader.sol
└── assertions/
    ├── interfaces/            IAssertion and one interface per assertion
    ├── Assertion.sol          ERC-165 + version
    ├── NativeETHAssertion.sol
    ├── ERC20Assertion.sol
    ├── StateAssertion.sol     protected slots, slot allowlist, code, untouched contracts
    └── ERC721Assertion.sol    reads the collection, not the trace
```

**`TxTrace`** reads what the client exposes to an ASSERT frame:

| Function | Returns |
|---|---|
| `balanceChange(account)` | ETH balance at start and now (binary search) |
| `gasPayment()` | gas payer and pre-charge, to exclude gas from ETH checks |
| `storageChange(account, slot)` | one slot at start and now (binary search) |
| `storageChanges(account)` | every changed slot of a contract |
| `codeChanged(account)` | whether its code hash changed, including EIP-7702 delegations |
| `events(emitter)`, `events(emitter, topic0)` | every event of a contract, optionally of one type (scans all events) |

It is an abstract contract holding the reader address as an immutable, so no caller can supply a fake trace.
solc cannot emit `TXTRACE` (0xb6) or `EVENTDATACOPY` (0xb7), so a ~100-byte Yul contract forwards to them. Once
solc supports them, `TxTrace` can call them directly and the reader goes away
([`docs/WORKAROUNDS.md`](docs/WORKAROUNDS.md)).

**Assertions and what they trust:**

| Check | Source | Trust |
|---|---|---|
| `NativeETHAssertion.*` | balance table + gas pre-charge | protocol |
| `ERC20Assertion.*AtSlot` | the holder's balance slot | protocol + the wallet's slot is right; reverts if the token's code or proxy implementation changed |
| `ERC20Assertion.minReceived / maxSpent / balanceUnchanged / noUnexpectedApprovals` | `Transfer` / `Approval` events | the token emits honest events |
| `StateAssertion.*` | storage, code and event tables | protocol |
| `ERC721Assertion.*` | `ownerOf`, `getApproved`, `isApprovedForAll` | the collection |

Every check returns if it holds and reverts with the observed values otherwise. See
[`docs/SECURITY.md`](docs/SECURITY.md).

## Using the contracts

```shell
forge install intentguard/transaction-assertions
```

```solidity
import {IStateAssertion} from "transaction-assertions/contracts/assertions/interfaces/IStateAssertion.sol";
```

`script/DeployAssertions.s.sol` deploys the reader (same address on every chain) and the assertions. The assertions are
stateless, so one deployment serves every wallet.

## Running

```shell
git submodule update --init   # forge-std
forge test                    # unit tests, against a mock reader that reproduces the spec's halts
```

Unit tests check the logic. Client behaviour is checked on the node, with the scripts in
[Use cases on Bogota](#use-cases-on-bogota) (needs git, Go and Foundry).

## Limits and open questions

- **Event scans are linear in all events.** Events are not sorted, so `events(token)` reads every event: an
  event-based ERC-20 check costs ~10,700 gas alone and ~811,000 with 1,000 padding events. A client-side
  per-emitter index or precompile would fix it (feedback F3, F12).
- **No generic ERC-20 balance.** Exact token checks need the balance slot; events can lie (F5).
- **Net diff only.** Slots written and restored, and storage wipes, are invisible.
- **Tested on go-ethereum only**, on a local node. Other clients and the public devnet are not covered.

Findings for the EIP authors: [`docs/EIP-7906-implementation-feedback.md`](docs/EIP-7906-implementation-feedback.md).

Licensed under [MIT](LICENSE).
