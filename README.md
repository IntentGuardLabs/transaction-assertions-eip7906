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

Each use case sends real, signed EIP-8141 frame transactions to a local go-ethereum `bogota-devnet-2` node: one
the user's assertions allow, and one they must revert. The script then checks each frame's status in the receipt
and the balances and storage on chain.

```shell
script/node.sh                                           # terminal 1: the Bogota node (builds geth on first run)

# Public test key: node.sh funds it on the local chain only. On a real network, use your own funded key.
KEY=<removed>
forge script script/DeployAssertions.s.sol --rpc-url local --broadcast --skip-simulation --private-key $KEY
forge script script/DeployDeFiMocks.s.sol  --rpc-url local --broadcast --skip-simulation --private-key $KEY
forge script script/UseCases.s.sol         --rpc-url local --ffi                              # all use cases
forge script script/UseCases.s.sol         --rpc-url local --ffi --sig "preventBybitHack()"  # one use case
forge script script/GasBenchmarks.s.sol    --rpc-url local --ffi
```

- `DeployAssertions` is the real deployment: the reader and the assertion contracts, the same on any chain.
- `DeployDeFiMocks` runs on local dev chains only. It deploys stand-ins for the protocols the use cases interact
  with (tokens, a Safe, DEX venues), which a fresh chain does not have. On a shared devnet the use cases would use
  the real ones.
- `--ffi` allows a Foundry script to run a shell command. The scripts use it for one thing: `cast rpc` to fetch the
  transaction receipt, because forge 1.5 cannot parse a JSON receipt itself. The receipt holds each frame's status.

| Use case | Transaction | Assertion (ASSERT frame) | Result on the node |
|---|---|---|---|
| `preventOverspending()` | send 0.4 ETH, then 0.6 ETH | `NativeETHAssertion.maxSpent(wallet, 0.5 ETH)` | 0.4 passes; 0.6 reverts, recipient gets nothing, gas is still charged |
| | transfer 150 USDC | `ERC20Assertion.maxSpentAtSlot(usdc, slot, 100)` | reverts, balances unchanged |
| `preventForbiddenTokenApproval()` | pay 100 USDC, then the same + a hidden approval of a forbidden token to a drainer | `StateAssertion.untouched([token])` | the payment passes; with the approval, the whole transaction reverts |
| `preventBybitHack()` | Safe transfer + delegatecall replacing the Safe's implementation, as in the Bybit hack | `StateAssertion.slotUnchanged(safe, 0)` | reverts, implementation unchanged, transfer undone |
| | Safe transfer + delegatecall adding an owner | `StateAssertion.onlySlotsChanged(safe, [nonce])` | slot 0 untouched, the allowlist reverts it |
| `preventMinSwapOutput()` | sell 2 × 50,000 USDC for WETH on two venues | `ERC20Assertion.minReceived(weth, wallet, 39)` + `maxSpent(usdc, wallet, 100,000)` | 18 + 23 = 41 WETH passes; 18 + 20 = 38 reverts both swaps |

forge cannot send frame transactions yet, so `script/utils/FrameTx.sol` encodes and signs them; see
[`docs/WORKAROUNDS.md`](docs/WORKAROUNDS.md) for this and the other gaps in today's tooling.

**The Bybit hack.** In February 2025 Bybit's signers approved a Safe transaction that looked like a transfer but
delegatecalled an attacker contract. Running in the Safe's storage, it overwrote slot 0, the Safe's implementation
address, and the attacker then drained the wallet. An assertion that slot 0 is unchanged reverts that transaction,
whatever the calldata or the signing UI showed.

**Why a global minimum.** Per-swap slippage limits judge each venue alone. The assertion adds up every WETH
`Transfer` to the wallet and every USDC `Transfer` from it, across all swaps, however the route was built. Events
trust the token to report its transfers honestly; for an exact check, `minReceivedAtSlot` / `maxSpentAtSlot` read
the wallet's balance slot instead.

**Why an allowlist for the Safe.** Slot 0 holds the implementation. Owners, modules and the guard live at hashed
slots the wallet cannot list, but `onlySlotsChanged` refuses anything not allowed, so it covers them without
knowing the layout. Neither check stops a delegatecall that only moves assets; asset assertions cover that.

## How a wallet uses it

```
frame 0  VERIFY   signature, approve execution and gas
frame 1  SENDER   swap USDC for WETH on venue A
frame 2  SENDER   swap USDC for WETH on venue B
frame 3  ASSERT   ERC20Assertion       maxSpent(USDC, wallet, 100_000e6)
frame 4  ASSERT   ERC20Assertion       minReceived(WETH, wallet, 39e18)
```

An ASSERT frame is mode 3, `value = 0`, `target` = the assertion, and `data` = the call:

```solidity
abi.encodeCall(IERC20Assertion.maxSpent, (USDC, wallet, 100_000e6));
abi.encodeCall(IERC20Assertion.minReceived, (WETH, wallet, 39e18));
abi.encodeCall(IStateAssertion.slotUnchanged, (safe, bytes32(0)));
```

The EIP-8141 signature covers every frame, so limits cannot be dropped or loosened. Accounts that accept session
keys must also require the frames in VERIFY ([`EmulatedAccount.sol`](test/integration/emulator/EmulatedAccount.sol)).
Complete signed frame transactions are built in [`script/UseCases.s.sol`](script/UseCases.s.sol).

## Contracts

```
contracts/
├── shared/
│   ├── TxTrace.sol            base contract: reads what the transaction changed and emitted (TXTRACE, EVENTDATACOPY)
│   ├── TxTraceReader.yul      calls the two opcodes for TxTrace, since solc cannot emit them yet
│   └── ITxTraceReader.sol     interface of the Yul reader
└── assertions/
    ├── interfaces/            one interface per assertion: functions, errors, docs
    ├── Assertion.sol          base: ERC-165 interface detection and version
    ├── NativeETHAssertion.sol ETH spent / received / unchanged, gas excluded
    ├── ERC20Assertion.sol     token spent / received / unchanged, no unexpected approvals
    ├── StateAssertion.sol     a slot unchanged, only listed slots changed, code unchanged, contract untouched
    └── ERC721Assertion.sol    NFT owner and approvals, asked from the collection (no trace)
```

**`TxTrace`** is the contract every assertion inherits. During an ASSERT frame, the client exposes the transaction's
net changes (ETH balances, storage slots, code) and its events through the `TXTRACE` (0xb6) and `EVENTDATACOPY`
(0xb7) opcodes. `TxTrace` turns those raw reads into functions:

| Function | Returns |
|---|---|
| `balanceChange(account)` | ETH balance at start and now (binary search) |
| `gasPayment()` | gas payer and pre-charge, to exclude gas from ETH checks |
| `storageChange(account, slot)` | one slot at start and now (binary search) |
| `storageChanges(account)` | every changed slot of a contract |
| `codeChanged(account)` | whether its code hash changed, including EIP-7702 delegations |
| `events(emitter)`, `events(emitter, topic0)` | every event of a contract, optionally of one type (scans all events) |

solc cannot emit these opcodes yet, so `TxTrace` calls a ~100-byte Yul contract that runs them and returns the
result. Its address is fixed when an assertion is deployed, so no caller can point it at a fake trace. Once solc
supports the opcodes, `TxTrace` calls them directly and the Yul reader goes away
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

- The state at the beginning of the transaction can only be derived from the end state: read the current balance
  and work back to the initial balance by replaying the transfers.
- Should a precompile handle extracting the changed slots and the events?

Findings for the EIP authors: [`docs/EIP-7906-implementation-feedback.md`](docs/EIP-7906-implementation-feedback.md).

Licensed under [MIT](LICENSE).
