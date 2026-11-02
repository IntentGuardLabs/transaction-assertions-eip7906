# Security model

Section links refer to [EIP-7906](eip-7906.md).

## What an assertion can see

ASSERT frames run after the body, as `STATICCALL` ([The `ASSERT` Frame Mode](eip-7906.md#the-assert-frame-mode)).
They see:

- **The net diff** ([State Difference Semantics](eip-7906.md#state-difference-semantics)): for every balance,
  storage slot and code hash that changed, the value at transaction start and now. Plus every event, in order.
- **Calls to other contracts**, which return the state *now*.

Nothing can be read as of transaction start except through a `before` value. An entry absent from the diff did
not change.

| Question | Answered from | Trust |
|---|---|---|
| ETH spent or received | Balance table, gas pre-charge added back for the payer | Protocol |
| ERC-20 balance change | The holder's balance slot in the storage table | Protocol + correct slot |
| ERC-20 balance change, slot unknown | `Transfer` events | Token emits honest events |
| Did slot X of contract Y change (Bybit) | Storage table | Protocol |
| Did anything else in contract Y change | Storage table against an allowlist | Protocol |
| Was contract Y touched at all | Storage, code and event tables | Protocol |
| Price or oracle value at start | Not available: pass it as a signed parameter | Signer |
| NFT owner or approvals now | `ownerOf`, `getApproved` (`ERC721Assertion`) | Collection |

## Rules the contracts follow

1. **Limits come from signed calldata.** Nothing is read from a contract the transaction could have changed
   ([Assertion Inputs Controlled by the Transaction](eip-7906.md#assertion-inputs-controlled-by-the-transaction)).
2. **Diff over calls.** A called contract may have been modified by the body, or may detect the ASSERT frame and
   answer differently. Trace-based assertions never call `balanceOf` or `allowance`. `ERC721Assertion` does and
   says so.
3. **Slots need stable code.** `*AtSlot` checks revert if the token's code or EIP-1967 implementation or beacon
   changed.
4. **Events are claims.** Event-derived checks are labelled and never mixed with storage-derived ones.
5. **Fail closed.** Any failed read, halt or out-of-gas fails the assertion and reverts the body
   ([Assertion Gas Exhaustion](eip-7906.md#assertion-gas-exhaustion)).
6. **Fixed reader.** The reader address is an immutable set at deployment; callers cannot supply their own
   trace. Wallets should check `traceReader()` against the canonical deployment.

## What the wallet must do

- **Commit to the assertion frames.** A full EIP-8141 signature covers them. Session keys and policies must
  require them in VERIFY ([Enforcing `ASSERT` Frame Inclusion](eip-7906.md#enforcing-assert-frame-inclusion));
  see `test/integration/emulator/EmulatedAccount.sol`.
- **Choose restrictive limits**
  ([Insufficiently Restrictive Assertions](eip-7906.md#insufficiently-restrictive-assertions)).
- **Expect gas to be charged on failure.** The validation prefix (nonce, gas payment) is not reverted.
- **Expect state at inclusion, not at signing**
  ([Changes outside of Transaction Assertion's control](eip-7906.md#changes-outside-of-transaction-assertions-control)).

## Gaps

- Net diff only: a slot written and restored within the transaction is invisible.
- Storage wipes are not reported ([State Difference Semantics](eip-7906.md#state-difference-semantics)).
- An allowance set without an `Approval` event is invisible to `noUnexpectedApprovals`. `untouched` catches it,
  but only by forbidding all changes to the token.
- `slotUnchanged(safe, 0)` stops an implementation swap, not a malicious delegatecall that only moves assets. Pair
  it with asset checks.
