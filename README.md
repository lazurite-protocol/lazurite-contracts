# Lazurite Contracts

Lazurite is a non-custodial launch protocol for DogeOS. It combines a fixed-supply ERC-20 factory, an ownerless liquidity/vault locker, linear token vesting, and a V3/Algebra NFT liquidity locker. Every contract is immutable and has no owner, admin withdrawal, upgrade proxy, or rescue path.

> Testnet software. Tokens, LP positions, and fees on DogeOS Chikyū have no monetary value.

## Security model

**Non-upgradeable • Zero Admin Withdraw**

- No proxy contracts and no upgrade authority.
- No `owner`, `admin`, `rescue`, or privileged withdrawal function.
- All fees are immutable constructor parameters.
- Vaults hold user assets; only the recorded owner/beneficiary can withdraw them.
- V3/Algebra collect fees go directly to the original position owner while the NFT remains locked.
- OpenZeppelin SafeERC20 is used for streaming/fee-on-transfer token safety.

## Contracts

All addresses are deployed on **DogeOS Chikyū Testnet**, chain ID **6281971**.

| Contract | Address | Purpose | Fee |
| --- | --- | --- | --- |
| TokenFactory | [`0x553A3e2bcad83eEbDB8B860ef7169d9C8D52a8f9`](https://blockscout.testnet.dogeos.com/address/0x553a3e2bcad83eebdb8b860ef7169d9c8d52a8f9) | Creates immutable fixed-supply OpenZeppelin ERC-20 tokens | 0.001 DOGE |
| LiquidityAndTokenLocker | [`0xC74F9aFAcD95d74A170a3275F14c38f9273824E2`](https://blockscout.testnet.dogeos.com/address/0xc74f9afacd95d74a170a3275f14c38f9273824e2) | Locks ERC-20 and ERC-20 LP balances until a timestamp | 0.0005 DOGE |
| TokenVesting | [`0x8d0Fe34995e20FD5C2abB773639Ed6f37c148558`](https://blockscout.testnet.dogeos.com/address/0x8d0fe349e20fd5c2abb773639ed6f37c148558) | Linear vesting with an optional cliff | 0.0005 DOGE |
| V3LiquidityLocker | [`0x112C276062FB38B40398AE403651C57c7f9934B6`](https://blockscout.testnet.dogeos.com/address/0x112c276062fb38b40398ae403651c57c7f9934b6) | Locks BarkSwap/Algebra V3 NFT positions; collects swap fees without unlocking | 0.0005 DOGE |

Fee receiver: [`0x8d836630E6FA80B353D4C7B4D50C9f6B3D68cB57`](https://blockscout.testnet.dogeos.com/address/0x8d836630e6fa80b353d4c7b4d50c9f6b3d68cb57)

The V3 locker uses the narrow BarkSwap/Algebra `IBarkSwapNonfungiblePositionManager` interface for `collect(CollectParams)` and standard ERC-721 ownership. It does not implement ve(3,3) governance, gauges, emissions, or voting escrow.

## Repository layout

```
src/
  StandardERC20.sol
  TokenFactory.sol
  LiquidityAndTokenLocker.sol
  TokenVesting.sol
  V3LiquidityLocker.sol
  interfaces/
    IBarkSwapNonfungiblePositionManager.sol
test/
  *.t.sol
script/
  Deploy.s.sol
  DeployV3.s.sol
```

## Build and test

Requirements: [Foundry](https://book.getfoundry.sh/) and Node.js only for the ABI export helper.

```bash
cd contracts
forge build
forge test -vvv
```

The suite covers the factory, fee-on-transfer vesting, locker accounting, V3 NFT custody, fee collection, owner-only access, early-withdraw protection, and lock extension rules.

## Deploy

Use a dedicated testnet deployer. Never commit a private key or a seed phrase.

```bash
export RPC_URL=https://rpc.testnet.dogeos.com
export PRIVATE_KEY=0x...
export FEE_RECEIVER=0x8d836630e6fa80b353d4c7b4d50c9f6b3d68cb57

# Core factory, ERC-20 locker and vesting
export FLAT_FEE_WEI=1000000000000000
export LOCK_FEE_WEI=500000000000000
export VESTING_FEE_WEI=500000000000000
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast -vvv

# V3 / BarkSwap NFT locker
export LOCK_FEE_WEI=500000000000000
forge script script/DeployV3.s.sol:DeployV3 --rpc-url "$RPC_URL" --broadcast -vvv
```

The deploy scripts enforce chain ID `6281971` and write deployment metadata under `deployments/`. Delete local Foundry cache after deploying a real key; the script may cache sensitive broadcast data under `cache/`.

## Verify

Blockscout verification for the V3 locker:

```bash
ARGS=$(cast abi-encode "constructor(address,uint256)" \
  0x8d836630e6fa80b353d4c7b4d50c9f6b3d68cb57 \
  500000000000000)

forge verify-contract \
  0x112C276062FB38B40398AE403651C57c7f9934B6 \
  src/V3LiquidityLocker.sol:V3LiquidityLocker \
  --chain-id 6281971 \
  --verifier blockscout \
  --verifier-url https://blockscout.testnet.dogeos.com/api/ \
  --constructor-args "$ARGS"
```

Verification is not an audit. A production/mainnet deployment requires an independent security review.

## Notes

- DogeOS Chikyū Testnet is the only deployment target in this repository.
- V3 locks are designed for BarkSwap/Algebra `NonfungiblePositionManager` ERC-721 positions.
- `collectFees` never transfers the NFT; `withdrawNFT` is the only path that returns it, and only after `unlockTime`.
- `extendLock` only moves the unlock time forward.
