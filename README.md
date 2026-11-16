# Test (TEST)

A fixed-supply ERC-20 with a 1% burn on every ordinary transfer, built for an IdentityMD custom
token launch on Sepolia (chain id 11155111).

| Property | Value |
| --- | --- |
| Solidity contract | `TestToken` (`src/TestToken.sol`) |
| Token name | Test |
| Symbol | TEST |
| Decimals | 18 |
| Total supply | 1,000,000,000 TEST = `1000000000000000000000000000` minor units |
| Minting | once, in the constructor, to `msg.sender` (the launch factory) |
| Burn on ordinary transfers | 1% (`BURN_BPS = 100` of `BPS_DENOMINATOR = 10_000`) |
| Owner / admin | none |

## What it does

Every transfer that is not one of the launch's own flows burns 1% of the amount and delivers the
remaining 99%:

- The sender is debited the full amount. The recipient receives `amount - amount / 100`. The
  difference is burned (a `Transfer(from, 0x0, burned)` event) and leaves `totalSupply`.
- `transferFrom` behaves the same way and spends the allowance by the full amount.
- The burn rounds down, so an amount below 100 minor units burns nothing.
- A transfer to yourself still pays the burn. A zero-amount transfer burns nothing.
- `burnOn(amount)` returns what a given amount would burn. `isBurnExempt(from, to)` tells whether
  a transfer skips the burn. `TransferBurned(from, to, amount, burned)` is emitted next to the
  ERC-20 events whenever a burn happens.

### Launch flows that skip the burn

The launch has to move exactly what it says, so these transfers are never burned:

| Transfer | Why |
| --- | --- |
| sent by the factory (`FACTORY`) | the swarm share to the MerkleDistributor, the seed to the pool, the remainder to the requester |
| sent by this launch's MerkleDistributor | contributor claims arrive whole |
| sent by or to the Uniswap v4 PoolManager (`POOL_MANAGER`) | buys and sells against the launch pool settle exactly |

The distributor is not a constructor argument because its address depends on the token's. The
token asks the factory for it at transfer time through `distributorOf(LAUNCH_NUMBER)` with a
static call. If the factory has not recorded one yet, has no code, reverts, or answers with less
than a word, the token treats that as "no distributor" and keeps working; ordinary transfers are
never blocked by the lookup. Only the distributor of this launch number is exempt. An address that
received tokens through an exempt flow (a claimant, a trader) pays the burn on its own transfers.

## What it cannot do

- No function mints. The supply can only shrink.
- No owner, pauser, minter or blacklist. No `pause`, `freeze`, `burnFrom`, `seize`, upgrade or
  initializer entry points exist, so no privileged hand can move or freeze a holder's balance.
- No `delegatecall`, `callcode` or `selfdestruct` in the runtime code.
- The burn rate and the exempt addresses are constants and immutables. Nobody can change them
  after deployment.

## Deployment parameters

The IdentityMD factory deploys the token through `ProjectFactory.launchCustom`. It is not deployed
by a script in this repository, and nothing here signs or broadcasts.

Constructor: `constructor(address factory_, address poolManager_, uint64 launchNumber_)`

| Argument | Manifest value | Meaning |
| --- | --- | --- |
| `factory_` | `$factory` | the launch factory, the constructor's caller, which receives the whole supply |
| `poolManager_` | `$poolManager` | Sepolia's Uniswap v4 PoolManager |
| `launchNumber_` | `$launchNumber` | this launch's number, used to look up its MerkleDistributor |

The constructor reverts on a zero factory or a zero pool manager (`FactoryIsZero`,
`PoolManagerIsZero`). It calls no other contract, so it deploys on an empty chain.

Values for the manifest step (not written here, per the launch rules):

- `token.contract`: `TestToken`
- `token.name`: `Test`, `token.symbol`: `TEST`, `token.decimals`: `18`
- `token.totalSupply`: `1000000000000000000000000000`
- `contracts`: none. This launch deploys only the token.
- Pool and economics as the launch decided: native ETH pair, fee 12500, tick spacing 60,
  `{"poolBps":9000,"initialMarketCapWei":"25000000000000000000"}`.

Build settings are in `foundry.toml`: solc 0.8.26, optimizer on with 200 runs, EVM version
cancun, `bytecode_hash = "none"`.

## After launch

Nothing to configure. The token has no owner and no settable values.

## Assumptions

- The factory mints to itself by being the constructor's caller and then pays out the swarm's 10%,
  the pool seed and the remainder. The token does not reserve, allocate or hold any of the supply.
- The factory records this launch's distributor under `distributorOf(uint64)` before claims start.
  Until then the distributor's transfers are burned like anyone else's.
- The factory and PoolManager addresses are the real Sepolia launch addresses, filled by the
  manifest. They are never zero and never guessed.
- Ordinary wallets and integrators understand that the recipient gets 99% of what was sent. Contracts
  that require exact receipt (some bridges, vaults and DEX routers that check balances) may not
  support fee-on-transfer tokens; that is inherent to the requested behavior.
- Liquidity flows other than the launch pool's PoolManager (for example a later Uniswap v2 or v3
  pool) pay the burn on both legs, which such venues tolerate only with fee-on-transfer aware
  routers.

## Operational responsibilities

- There are no admin keys to hold or rotate and no parameters to maintain.
- The requester should state the 1% burn in listing and documentation so holders and venues expect
  it.
- Anyone integrating the token should test against `burnOn` and `isBurnExempt` rather than assume
  one-to-one receipt.
- Tests passing is not a security audit. A separate adversarial review by an independent
  contributor is the launch's final step.

## Tests

`test/TestToken.t.sol` covers metadata and the one-time mint, constructor rejections, the burn
math including rounding and dust, ordinary `transfer` and `transferFrom` burns with their events
and allowance accounting, every exempt flow (factory, registered distributor, pool manager both
ways, a seed and round-trip swap), the non-exempt cases (unregistered distributor, another launch's
distributor, onward transfers by claimants), lookup robustness against a codeless, reverting or
short-answering factory, and the failure paths (insufficient balance including the burn,
insufficient allowance, zero recipient, no mint or admin entry points).

`test/TestToken.invariant.t.sol` drives random transfers among the launch addresses and ordinary
holders and checks that the supply never grows, that it equals the initial supply minus every
expected burn, and that balances always sum to the supply.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x71f587eee2e9aaa7db704251be18f514c97868b604b88ae66c816645fd979b43 forge test
forge fmt --check
```

Checks run here: `forge build`, `forge test` with the seed above (35 tests, all passing), and
`forge fmt --check`. Slither was not available on this machine; the code avoids its blocking
detectors (no `selfdestruct`, no arbitrary-from `transferFrom`, no initializer or upgrade path, no
storage pointers, no shifts, no packed encoding of dynamic values).

## Dependencies

Vendored as plain files under `lib/` (no submodules):

- forge-std v1.11.0
- OpenZeppelin Contracts v5.4.0 (`ERC20` only)
