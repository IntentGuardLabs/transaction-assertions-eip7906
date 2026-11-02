#!/usr/bin/env bash
# Starts a local Bogota node: go-ethereum bogota-devnet-2 (EIP-7906 + EIP-8141) on http://127.0.0.1:8545.
# Builds geth once (cached in .node/), starts a fresh dev chain, deploys the standard CREATE2 factory and funds two
# well-known test keys (anvil's accounts 0 and 1). Ctrl-C stops the node.
#
# Needs git, Go and Foundry.
set -euo pipefail

COMMIT=f71f4be8027bc0828148ae03424231092ed7ab66 # ethpandaops/geth:bogota-devnet-2
RPC=http://127.0.0.1:8545
# Local test keys, public: never use them on a real network.
DEPLOYER_KEY=<removed>
WALLET_KEY=<removed>
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
WALLET=$(cast wallet address --private-key "$WALLET_KEY")
FACTORY_SIGNER=0x3fab184622dc19b6109349b94811493bf2a45362
FACTORY_TX=0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.node/go-ethereum"
GETH="$ROOT/.node/geth"
export GOTOOLCHAIN=auto

if [ ! -x "$GETH" ]; then
  echo "Building go-ethereum bogota-devnet-2 @ ${COMMIT:0:8} (first run only)"
  rm -rf "$SRC" && git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 https://github.com/ethereum/go-ethereum "$COMMIT"
  git -C "$SRC" checkout -q FETCH_HEAD
  (cd "$SRC" && go build -o "$GETH" ./cmd/geth)
fi

DATADIR="$(mktemp -d)"
"$GETH" --dev --dev.period 0 --dev.gaslimit 60000000 --datadir "$DATADIR" \
  --http --http.addr 127.0.0.1 --http.port 8545 --http.api eth,net,web3,debug,txpool \
  --rpc.allow-unprotected-txs --nodiscover --maxpeers 0 --nat none --verbosity 2 &
NODE=$!
trap 'kill $NODE 2>/dev/null; rm -rf "$DATADIR"' EXIT
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do sleep 0.2; done

# Fund the test keys and deploy the CREATE2 factory. Receipts are not readable until geth finishes indexing, so
# send without waiting and then wait for the factory's receipt.
DEV=$(cast rpc eth_accounts --rpc-url "$RPC" | tr -d '[]"')
for account in "$DEPLOYER" "$WALLET"; do
  cast send --async --rpc-url "$RPC" --unlocked --from "$DEV" "$account" --value 1000ether >/dev/null
done
cast send --async --rpc-url "$RPC" --unlocked --from "$DEV" "$FACTORY_SIGNER" --value 0.1ether >/dev/null
FACTORY_HASH=$(cast publish --async --rpc-url "$RPC" "$FACTORY_TX")
until cast receipt --rpc-url "$RPC" "$FACTORY_HASH" status >/dev/null 2>&1; do sleep 0.2; done

echo "Bogota node running on $RPC (chain $(cast chain-id --rpc-url "$RPC"))"
echo "  deployer $DEPLOYER  key $DEPLOYER_KEY"
echo "  wallet   $WALLET  key $WALLET_KEY"
wait $NODE
