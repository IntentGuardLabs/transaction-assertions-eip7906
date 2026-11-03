# Tooling gaps and workarounds

EIP-7906 and EIP-8141 run on the Bogota devnets, but the standard tools do not support them yet. Each gap below
has one small workaround, kept in one place, so it can be deleted when the tool catches up.

| Gap | Workaround | File | Remove when |
|---|---|---|---|
| solc cannot emit `TXTRACE` / `EVENTDATACOPY` | A Yul contract forwards to the opcodes | `contracts/shared/TxTraceReader.yul` | solc has builtins for them |
| forge and cast cannot build or send frame transactions (type `0x06`) | Encode and sign them in Solidity, send with `vm.rpc("eth_sendRawTransaction")` | `script/utils/FrameTx.sol` | forge/cast support EIP-8141 |
| forge 1.5 has no `vm.rpcJson`; `vm.rpc` ABI-encodes JSON objects | Read receipts with `cast rpc` through `vm.ffi` (hence `--ffi`) | `script/utils/FrameTxScript.sol` (`_receipt`) | forge has `vm.rpcJson` |
| forge's EVM does not know EIP-7906 or Bogota gas rules | Unit tests use a mock reader; broadcasts use `--skip-simulation` so the node estimates gas | `test/mocks/MockTxTraceReader.sol`, the commands in the README | revm implements Bogota |
| No pinned geth release for the devnet | Build geth from source at the devnet commit | `script/node.sh` (`COMMIT`) | a release or image is the reference |
| A fresh local chain has no tokens, Safe or DEX | Mocks with the same storage layout where it matters | `test/mocks/`, `script/DeployDeFiMocks.s.sol` | running against a devnet with real deployments |

## Moving to a new Bogota version

1. Set `COMMIT` in `script/node.sh` to the new go-ethereum commit, delete `.node/`, and start the node.
2. If the frame transaction format changed, update `script/utils/FrameTx.sol`. It follows
   `core/types/tx_frame.go` field by field.
3. If the `TXTRACE` parameters changed, update the constants in `contracts/shared/TxTrace.sol` and the mock reader.
4. Run `forge test`, then the deploy and use-case scripts. A rejected transaction or an unexpected frame status
   points at what changed.

## The reader contract (`TxTraceReader.yul`)

`TxTrace` should read the trace with the opcodes directly. solc 0.8.35 has no builtin for `TXTRACE` (0xb6) or
`EVENTDATACOPY` (0xb7), and `verbatim`, the only way to emit an unknown opcode, works only in standalone Yul. In
Solidity inline assembly it fails with `Function "verbatim_2i_1o" not found`.

So the opcodes live in a ~100-byte Yul contract that forwards its arguments and returns the result; assertions call
it with `STATICCALL`. The spec allows this: the opcodes work anywhere in an ASSERT frame's call subtree
([Per-contract Usage](eip-7906.md#per-contract-usage)).

Cost: 638 gas per query through the reader on go-ethereum, against 100 for `TXTRACE` itself (feedback F1), and an
extra trusted contract. The reader is deployed with CREATE2, so its address is fixed by its bytecode, and each
assertion stores it as an immutable at deployment so no caller can supply a fake trace.

When solc supports the opcodes, only `TxTrace._read` changes:

```solidity
// today
return traceReader.txtrace(param, in2);
// with compiler support (builtin name to be defined by solc)
assembly { value := txtrace(param, in2) }
```

`TxTraceReader.yul`, `ITxTraceReader.sol`, the reader deployment and the constructor argument then go away. The
functions the assertions call keep their signatures.

## Frame transactions from Foundry (`FrameTx.sol`)

forge broadcasts only the transaction types it knows, and this geth's `eth_sendTransaction` has no frame fields, so a
frame transaction can only reach the node as raw signed bytes. `FrameTx.sol` builds them:

- `0x06 || rlp([chainId, nonceKeys, nonce, sender, frames, signatures, fees, blobHashes])`, with each frame as
  `[mode, flags, target, [executionGas, stateGas], value, data]` (an empty target means the sender).
- The signature hash is the same encoding with the signature replaced by its length (65). It is signed with
  `vm.sign`, and the signature is stored as `v || r || s`.
- Gas defaults that work on this client: VERIFY gets 50,000 (the mempool caps the validation prefix at 100,000,
  signature check included), body frames get a state-gas budget because a fresh storage slot costs ~98,000 state
  gas (EIP-8037).

The scripts then read the receipt: `frameReceipts[i].status` is 1 (succeeded), 0 (failed) or 2 (skipped after an
earlier ASSERT frame failed).

## The local node (`script/node.sh`)

Builds go-ethereum at the pinned bogota-devnet-2 commit once, then starts a fresh `--dev` chain with Bogota active
from genesis. It also deploys the standard CREATE2 factory (so the reader gets its usual address) and funds two
public test keys. Right after startup geth answers receipt queries with "transaction indexing is in progress", so
the script waits for a receipt before reporting the node ready.

## Mocks

`DeployDeFiMocks.s.sol` deploys what a fresh chain lacks: tokens (`MockERC20`, and `MisleadingERC20`, which changes
allowances without events), a Safe stand-in, DEX venues paying a fixed WETH amount per swap, and the gas-benchmark helpers.
`MockSafe` copies Safe's storage layout for slots 0 to 5 (singleton, modules, owners, owner count, threshold,
nonce) so the slot checks mean the same thing as on a real Safe. It is not the audited Safe code.
