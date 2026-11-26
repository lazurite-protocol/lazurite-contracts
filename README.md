# Lazurite Protocol

Lazurite is a universal, multichain DeFi protocol for EVM-compatible ecosystems. It provides an ERC-20 Token Factory, a V2/ERC-20 Liquidity Locker, Token Vesting, and a V3/Algebra NFT Liquidity Locker.

- Website: [https://lazurite.one](https://lazurite.one)
- X: [@lazurite_one](https://x.com/lazurite_one)
- Contracts: [lazurite-protocol/lazurite-contracts](https://github.com/lazurite-protocol/lazurite-contracts)

## Security model

**Non-upgradeable • Zero Admin Withdraw • Immutable**

- No proxies and no upgrade authority.
- No owner, admin, rescue, or privileged withdrawal path.
- Assets remain non-custodial and can only be withdrawn by the recorded owner or beneficiary.
- V3 swap fees are collected by the position owner without unlocking the NFT.
- OpenZeppelin SafeERC20 is used for token transfers and fee-on-transfer accounting.
- Every deployment is immutable and independently verifiable on-chain.

## Architecture

| Contract | Responsibility |
| --- | --- |
| TokenFactory | Deploys fixed-supply OpenZeppelin ERC-20 tokens with a public on-chain registry |
| LiquidityAndTokenLocker | Locks ERC-20 and ERC-20 LP balances until a timestamp; owner-only withdrawal |
| TokenVesting | Linear vesting with an optional cliff; beneficiary-only release |
| V3LiquidityLocker | Supports Uniswap V3, Algebra V3, and any ERC-721 NonfungiblePositionManager DEXs; owner-only swap fee collection and post-unlock withdrawal |

The V3 locker accepts standard ERC-721 NonfungiblePositionManager positions and uses a narrow collect interface. It does not custody private keys, upgrade positions, or expose an administrative withdrawal path.

## Deployments

### DogeOS Chikyū Testnet — first active test network

Chain ID: **6281971**

| Contract | Address | Purpose |
| --- | --- | --- |
| TokenFactory | 0x553A3e2bcad83eEbDB8B860ef7169d9C8D52a8f9 | ERC-20 token deployment and registry |
| LiquidityAndTokenLocker | 0xC74F9aFAcD95d74A170a3275F14c38f9273824E2 | ERC-20 / V2 LP locking |
| TokenVesting | 0x8d0Fe34995e20FD5C2abB773639Ed6f37c148558 | Linear token vesting |
| V3LiquidityLocker | 0x112C276062FB38B40398AE403651C57c7f9934B6 | V3 / Algebra NFT locking |

Explorer: [DogeOS Chikyū Testnet](https://blockscout.testnet.dogeos.com)

Additional EVM deployments can be added without changing the protocol architecture.

## Repository layout

~~~
src/
  StandardERC20.sol
  TokenFactory.sol
  LiquidityAndTokenLocker.sol
  TokenVesting.sol
  V3LiquidityLocker.sol
  interfaces/
test/
  *.t.sol
script/
  Deploy.s.sol
  DeployV3.s.sol
~~~

## Build and test

Requirements: [Foundry](https://book.getfoundry.sh/).

~~~bash
cd contracts
forge build
forge test -vvv
~~~

The suite covers factory deployment, vesting with fee-on-transfer tokens, locker accounting, ownership, V3 NFT custody, fee collection, early-withdrawal protection, and lock extension rules.

## Deploy

Use a dedicated deployer key. Never commit a private key or seed phrase.

~~~bash
export RPC_URL=<RPC_URL>
export CHAIN_ID=<CHAIN_ID>
export PRIVATE_KEY=0x...

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --broadcast \
  -vvv

forge script script/DeployV3.s.sol:DeployV3 \
  --rpc-url "$RPC_URL" \
  --broadcast \
  -vvv
~~~

The deploy scripts use the configured deployment chain and write metadata under the deployments directory. Delete Foundry cache after deploying a real key.

## Verification

Verify against the Blockscout-compatible API of the target network:

~~~bash
forge verify-contract <ADDRESS> <SOURCE_PATH>:<CONTRACT_NAME> \
  --chain-id <CHAIN_ID> \
  --verifier blockscout \
  --verifier-url <EXPLORER_VERIFIER_URL> \
  --constructor-args <ABI_ENCODED_ARGS>
~~~
