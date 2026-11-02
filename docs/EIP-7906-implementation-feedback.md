# EIP-7906: implementation feedback

Findings from building a shared `TXTRACE` library and the `NativeETHAssertion` / `ERC20Assertion` reference
contracts against EIP-7906 as published on ethereum/EIPs master (`9099f41`, 2026-10-27; copy:
[`eip-7906.md`](eip-7906.md)): `ASSERT` frames, `TXTRACE` (0xb6), `EVENTDATACOPY` (0xb7). This is what
bogota-devnet-2 runs. Contracts: [`contracts/`](../contracts).

**Evidence levels.** Each finding says which of these backs it:

- **Real client:** frame transactions executed with real opcodes on go-ethereum built from `bogota-devnet-2` @
  `f71f4be8`, local `--dev` node (`script/node.sh`). Receipts and state are checked by
  `script/UseCases.s.sol`; gas figures come from `script/GasBenchmarks.s.sol`, each one a frame's
  `executionGasUsed` in the receipt.
- **Mock / emulator:** Foundry unit tests against spec-faithful mock readers, the Foundry frame-transaction
  emulator, or bytecode patching. These show logic and estimates, never client behaviour.

"Native" figures (no reader contract) are always estimates: real measurement minus the measured reader-call
overhead.

Classes: **Blocking**, **Security**, **Efficiency**, **Developer experience (DX)**, **Standardization**.
**Status**: *Demonstrated* (reproduced by a test or measurement in this repository) or *Hypothesis* (reasoned,
not tested).

## Summary

| # | Finding | Applies to | Class | Evidence |
|---|---|---|---|---|
| F1 | Solidity cannot emit the opcodes; the reader workaround costs 638 gas per query vs 100 | Tooling | DX, Efficiency | Real client |
| F2 | One word per `TXTRACE` call is not the bottleneck; batching over the ABI is *more* expensive | Tooling | Efficiency | Mock (Foundry) |
| F3 | Event scans are linear in *all* events: 800 gas per padding event per assertion; padding costs the body 422 | EIP | Security, Efficiency | Real client |
| F4 | Gas-payer sentence is sign-ambiguous; the natural reading counts gas twice | EIP | DX | Mock + real client (formula validated) |
| F5 | No sound generic ERC-20 balance invariant from the available primitives | EIP | Blocking (generic ERC-20) | Real client + emulator |
| F6 | Unexpected-approval detection can only use events | EIP | Security | Emulator |
| F7 | Storage-based checks need the token's code to stay fixed; cheap to enforce | EIP | Security | Mock (unit) |
| F8 | Sorted tables and binary search work; cost grows with log(table size) | EIP | Efficiency | Real client |
| F9 | Fixed-size event data needs a length query plus a memory copy | EIP | DX | Mock + real client |
| F10 | Unspecified details implementers must assume | EIP | DX, Security | Partly real client |
| F11 | Interfaces worth standardizing above the protocol | EIP | Standardization | — |
| F12 | "All events of contract X" should be a client query, not a Solidity loop | EIP | Efficiency, Security | Real client |

---

## F1. No compiler support; the workaround costs 638 gas per query instead of 100

- **Spec:** opcodes `0xb6`, `0xb7`; "Per-contract Usage".
- **Problem:** solc 0.8.35 (the latest available here) has no builtin for either opcode, and `verbatim` is
  rejected in Solidity inline assembly (`Function "verbatim_2i_1o" not found`). It works only in standalone Yul.
  Solidity assertion contracts therefore cannot use the opcodes directly. The repository puts both opcodes in a
  ~100-byte Yul contract (`contracts/shared/TxTraceReader.yul`) at a fixed CREATE2 address and calls it with `STATICCALL`. This
  is spec-compliant: "Per-contract Usage" confirms the opcodes work anywhere in an ASSERT frame's call subtree.
- **Applies to:** Solidity/Yul tooling (solc 0.8.35 has no builtin for `TXTRACE` or `EVENTDATACOPY`).
- **Evidence (real client):** a `TraceBench.queries(100)` assertion frame minus a warm `nop` frame gives **638
  gas per query** on go-ethereum. 100 of it is `TXTRACE`; the rest is the `STATICCALL` and ABI round
  trip to the reader. The earlier Foundry estimate (607, from the production bytecode with `TXTRACE` patched to
  `SUB`) was in the right range. Scenario C1 shows the real opcode halting outside an assertion frame ("invalid
  transaction assertion parameter or context"), so a reader call there fails closed. `TxTraceReaderTest` verifies
  operand order.
- **Impact:** every assertion pays about 6× the intended trace-read cost. A trusted bytecode dependency is added
  (mitigated by the CREATE2 address being bound to the bytecode).
- **Proposal:** add Yul/Solidity builtins for both opcodes, mirroring how other recent opcodes reached solc.
  Until then, standardize one deterministic reader deployment and its ABI (see F11) so assertion providers share
  one audited trust root.
- **Belongs in:** compiler (solc). No EIP change.

## F2. One word per call is not the bottleneck

- **Spec:** "A single call returns one 256-bit value", and the rationale for reading one field per call.
- **Applies to:** tooling. With native opcodes the question disappears.
- **Problem investigated:** whether reading the three fields of an entry with three calls is wasteful.
- **Evidence:** a development version of the reader added `txtraceBatch(uint256[])`. Reading three fields cost
  **4,922 gas batched vs 1,732 gas with three single calls** in a loop, and 4,680 vs 2,001 in a fresh call frame.
  The opcodes' share is 300 gas in both. Encoding and decoding the dynamic ABI arrays costs more than the calls
  it saves. The batch path was removed. The numbers come from that version (restoring the Yul case and
  `QueryLoop.oneBatchOfThree` reproduces them). Single-call figures are reproduced by
  `test_gas_perQueryWithProductionReader`.
- **Impact:** none on the EIP. With native opcodes, a field read is `PUSH`, `PUSH`, `TXTRACE`, about 106 gas,
  and the one-word design is cheap and simple.
- **Proposal:** keep the one-word, selector-and-index interface. The overhead found here comes from F1.
- **Belongs in:** no change.

## F3. Event scans are linear in all events, so padding is cheap relative to the scans it forces

- **Spec:** "Assertion Gas Exhaustion"; "Events are in emission order and require a linear scan".
- **Problem:** an event-based assertion must read at least `TXTRACE_EVENT_ADDRESS` for every event, relevant or
  not. The execution body chooses how many events exist. Independent ASSERT frames cannot share work: transient
  storage is discarded between frames and `TSTORE` is forbidden inside the `STATICCALL`. So *k* event-scanning
  assertions scan *k* times.
- **Evidence (real client, `script/GasBenchmarks.s.sol`):** the same body with 0, 200 and 1,000 empty
  `LOG0` padding events.

  | | 0 padding | 200 | 1,000 | Per padding event |
  |---|---|---|---|---|
  | Body (`TraceNoise.run`) | 114,311 | 198,711 | 536,311 | **422** |
  | One `ERC20Assertion.maxSpent` frame | 10,689 | 169,465 | 810,822 | **800** |
  | Three independent `maxSpent` frames (first pays a cold access) | 34,967 | 511,295 | 2,435,366 | 2,400 |

  Through today's reader, a single scanning assertion already pays 1.9× what the padding cost. With native
  opcodes, subtracting the measured 538 gas of call overhead per query, it is an estimated ≈ 262 gas per padding
  event. The body then pays ~1.6× more than one assertion, but padding becomes cheaper than verification at two
  or more independent event assertions. At the EIP's ~42,600-event bound, one native scan costs ≈ 11.2M gas, and
  34M through the reader. Out-of-gas always fails closed (`testFuzz_outOfGasNeverPasses`), so this is
  **griefing, not bypass**.
- **Proposal (EIP-7906):** an emitter-sorted view of the event table that fits the two-input model. For example,
  `TXTRACE_EVENT_BY_EMITTER(i)` would return the log index of the *i*-th event in `(emitter, log index)` order, so
  assertions can binary-search to one emitter's events in O(log n). *Hypothesis:* the client cost of the extra index is small, since clients already build
  one on first read.
- **Proposal (library):** aggregate several event constraints into one frame so the events are scanned once (not
  yet implemented).
- **Belongs in:** EIP-7906 (index or pricing), shared library (aggregation).

## F4. The gas-payer sentence is sign-ambiguous

- **Spec:** "State Difference Semantics": "*look up the gas payer via `gas_payer_address` … and subtract
  `gas_pre_charge` from that address's balance delta.*"
- **Problem:** the sentence is only correct if "balance delta" means the *decrease* `balance_before −
  balance_after`. With the more common signed definition `balance_after − balance_before`, the pre-charge
  already makes the payer's delta more negative, and subtracting it again **counts gas twice**. The correct
  operation is then `delta + gas_pre_charge`, i.e. add it back to `balance_after`. An implementer who reads it
  that way rejects legitimate transactions from the payer. That error is fail-closed, but it makes ETH limits
  unusable for the common self-paying wallet.
- **Evidence:** `NativeETHAssertionTest.test_gasPayerOnlyPaysGas` (mock). A payer that pays
  gas and moves no value must be "unchanged". **Real client:** in scenario A1 the sender is the payer and
  `maxSpent(sender, 0.5 ETH)` passes for a 0.4 ETH transfer, while the chain charged the sender 0.4 ETH plus
  `gasUsed × effectiveGasPrice` (checked to the wei). In A2 a 0.6 ETH transfer fails. Adding the pre-charge back
  is the reading that matches the clients. The EIP authors' workshop example (`EthSpendLimitAssertion`) reads the
  sentence the same way, subtracting the pre-charge from the *decrease*.
- **Proposal:** reword to "*add `gas_pre_charge` to the gas payer's `balance_after` (equivalently, subtract it from
  the payer's balance decrease)*". Also state that a payer whose transfers exactly offset the pre-charge has
  no `balances_changed` entry.
- **Belongs in:** EIP-7906 (wording).

## F5. No sound generic ERC-20 balance invariant

- **Spec:** "Events: a contract's event shows only that its code emitted it"; "Assertion Inputs Controlled by the
  Transaction".
- **Problem:** the trace exposes storage, not token balances. Each available route has a gap:

  | Route | Gap | Demonstrated by |
  |---|---|---|
  | `Transfer` events | Fee-on-transfer reporting gross amounts, silent rebases, and events without balance changes are all accepted | **Real client B4**: a silent rebase passes the event-only check and the wiped balance commits on chain. Emulator: `test_feeOnTransfer`, `test_rebaseWithoutEvents`, `test_misleadingEvent` |
  | Storage diff | Needs the holder's balance slot, which depends on layout (Solidity/Vyper mapping hashing, ERC-7201 namespaces, packed flags such as blacklist bits) and must be supplied off-chain | **Real client B2/B3**: the slot check reverts an over-limit transfer and the silent rebase; balances verified unchanged |
  | `balanceOf` in the ASSERT frame | Absolute rather than a delta; can be steered by the body (proxy upgrade, ASSERT-subtree detection) | EIP-7906 Security Considerations |

- **Impact:** a wallet cannot protect an arbitrary ERC-20 with guaranteed semantics. `ERC20Assertion` therefore
  exposes two explicitly separate variants with stated trust requirements and does not combine them silently.
- **Proposal:** an application-level ERC by which a token declares where a holder's balance lives (for example
  `balanceSlot(address holder) → bytes32` plus a declared encoding), or an equivalent registry, would make the
  storage route fully generic. This cannot be fixed in the protocol without making it token-aware, which the
  EIP rightly avoids.
- **Belongs in:** separate ERC. Shared library for the layout helpers.

## F6. Unexpected approvals can only be detected through events

- **Problem:** an allowance is stored at `keccak256(spender, keccak256(owner, slot))`. For an *unknown* spender
  the key cannot be predicted, and a changed slot in the token's storage cannot be attributed to an allowance.
  So "no unexpected approval" can only be checked through `Approval` events. ERC-20 requires `Approval` on
  `approve`, but not on every allowance-changing path.
- **Evidence:** `test_limitation_silentApproval`: an allowance set without an event passes
  `noUnexpectedApprovals`.
- **Proposal:** no protocol fix (it would need hash preimages). Document the limitation. Where the spender set is
  known, wallets can add exact slot checks for those spenders. A token-declared allowance-slot function (F5)
  would cover known spenders but not unknown ones.
- **Belongs in:** accepted limitation; optional ERC.

## F7. Storage-based checks need the token's code to stay fixed; the trace makes that cheap

- **Problem:** a balance slot only means "balance" under the code that defines it. A body that upgrades a proxy
  token could change what the slot holds.
- **Evidence:** `ERC20Assertion` rejects storage-based checks when the token's code hash changed
  (`codes_changed`) or its EIP-1967 implementation or beacon slot changed (`test_slotRejectsTokenCodeChange`,
  `test_slotRejectsProxyUpgrade`). Three O(log n) lookups make this cheap. This is a good use of the code table.
- **Gap:** proxies with non-standard implementation slots are not covered.
- **Belongs in:** library (implemented). Possibly part of the ERC in F5 (declared implementation slot).

## F8. Sorted tables and binary search work; cost grows with log(table size)

- **Evidence (real client, ~16-entry diff):**

  | Lookup | Gas |
  |---|---|
  | One ETH balance change, gas excluded | 6,166 |
  | One storage slot | 8,084 |
  | Enumerate all balance and storage entries | 33,929 |

  Search cost grows with log(table size) (Foundry synthetic benchmark: 7.4k → 23.4k from 1 to 10,000 entries).
  Most of it is reader call overhead per probe (F1), so native opcodes will lower it. Padding the state
  tables costs the body real state writes, unlike events.
- **Note:** targeted protections (one account, one slot) should search, not enumerate. That makes their cost
  independent of transaction size.

## F9. Fixed-size event data requires a length query plus a memory copy

- **Spec:** `EVENTDATACOPY` halts if `dataOffset + length` exceeds the data length, even for `length == 0`.
- **Problem:** a halt consumes all gas forwarded to the halting frame (`test_readsFailWithoutEip7906` shows the
  whole stipend consumed). A safe decoder must therefore query `TXTRACE_EVENT_DATA_LEN` before every copy.
  Decoding an ERC-20 `Transfer` takes about seven reads: emitter, topic count, topic 0, data length, topic 1,
  topic 2, then a copy.
- **Impact:** small. A matching ERC-20 `Transfer` is about 7 queries, ≈ 700 gas natively. The strict halt is the
  right default.
- **Proposal (optional):** none required. If revisited, a `TXTRACE` param returning one 32-byte data word would
  remove the memory round trip for the common case. It would need a second index (event, word), which the
  two-input model cannot express.
- **Belongs in:** EIP-7906 (optional), or no change.

## F10. Details implementers have to assume

The library had to pick an answer for each of these. Each one should be stated in the EIP:

1. **Address encoding** of address-valued params. The library assumes right-aligned with zero upper bits and
   rejects anything else (`NonCanonicalAddress`). *Real client:* geth pushes addresses this way, and the
   assertions ran without rejection. *Proposal:* state "left-padded with zeros to 32 bytes".
2. **Logs from reverted sub-calls inside an executed frame.** Matching "global log index" suggests receipt
   semantics (excluded). *Not yet tested on a client* (hypothesis). *Proposal:* "the event table contains exactly
   the logs the receipt would contain if execution ended at this call".
3. **Signedness.** All values are read as unsigned 256-bit words. *Proposal:* say so.
4. **Payer deductions.** The library assumes `gas_pre_charge` is the only protocol deduction from the payer before
   the ASSERT frames, and that the refund and priority fee are applied after them. *Proposal:* state it, with the
   corrected formula from F4.
5. **Resolved by the text and confirmed on the client:** the opcodes work at any call depth in an
   assertion frame ("Per-contract Usage"). Every real assertion here reaches them through a `STATICCALL` to the
   reader.

## F11. Interfaces worth standardizing above the protocol

These are application-level conventions, deliberately kept separate from the opcodes:

1. **Trace access.** One deterministic reader deployment and its ABI (`txtrace`, `eventDataCopy`) until compilers
   support the opcodes (F1), and a small typed API on top (`balanceChange`, `gasPayment`, `storageChange`,
   `storageChanges`, `codeChanged`, `events`).
2. **Assertion calling convention.** An ASSERT frame's data is a plain ABI call to an immutable, stateless
   contract that *returns on success and reverts with a custom error carrying the observed values*. Limits are
   parameters, so the EIP-8141 signature hash commits to them.
3. **Delta representation.** `(gain, loss)` pairs of `uint256` instead of `int256` avoid range checks and
   overflow at extreme balances (`test_largeValues`, `test_slotLargeValues`).
4. **Source labelling.** Every ERC-specific assertion should declare whether it is protocol-enforced,
   layout-dependent or event-dependent, as this repository's README does.
5. **Coverage policies** (not implemented): "every changed balance, slot, code hash and nonce is in an expected
   or permitted set". The sorted, complete state tables make allowlist-style assertions feasible. This is the
   most promising direction for closing the "insufficiently restrictive assertion" risk the EIP highlights.
6. **Balance and allowance slot declaration** for tokens (F5, F6).

## F12. "All events of contract X" should be a client query, not a Solidity loop

- **Spec:** [Results Ordering](eip-7906.md#results-ordering), [Enumeration](eip-7906.md#enumeration).
- **What we built:** `TxTrace.storageChanges(account)`, `TxTrace.events(emitter)`,
  `TxTrace.events(emitter, topic0)`, and on top of them `ERC20Assertion.transfers(token)` / `approvals(token)`.
- **Storage is fine.** The slot table is sorted by address, so one contract's slots are contiguous: one binary
  search, then four reads per slot.
- **Events are not.** They are in emission order, so "all `Transfer`s of token X" reads the emitter of *every*
  event in the transaction. Measured on geth: 800 gas per unrelated event per assertion (F3). The client already
  has the logs in memory and could answer this directly.
- **Proposal:** let the client return the events of one emitter, optionally of one event type. Two shapes:
  - a `TXTRACE` param over an emitter-sorted view of the event table (fits the two-input model; F3);
  - or a precompile callable only from ASSERT frames, `eventsOf(emitter, topic0) → indexes`.

  Either way the per-contract filter moves from O(all events) in EVM to a lookup in the client, and the padding
  griefing in F3 goes away.
- **Belongs in:** EIP-7906.
