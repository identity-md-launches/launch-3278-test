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
- `burnOn(amount)` returns what a given amount would burn, for every `uint256` (it never overflows).
  `isBurnExempt(from, to)` tells whether a transfer skips the burn.
  `TransferBurned(from, to, amount, burned)` is emitted next to the ERC-20 events whenever a burn
  happens.

### Launch flows that skip the burn

The launch has to move exactly what it says, so these transfers are never burned:

| Transfer | Why |
| --- | --- |
| sent by the factory (`FACTORY`) | the swarm share to the MerkleDistributor, the seed to the pool, the remainder to the requester |
| sent by this launch's MerkleDistributor | contributor claims arrive whole |
| sent **to** the Uniswap v4 PoolManager (`POOL_MANAGER`) | the seed and sells into the launch pool arrive whole, which the manager's `settle()` needs |

Transfers **out of** the PoolManager are not exempt. The v4 PoolManager is a permissionless
singleton with flash accounting: anyone can `unlock` it, pay TEST in with `sync`/`settle`, and
`take` it straight out to any recipient without touching a pool. If the manager's outgoing leg were
exempt, that relay (or an ERC-6909 claim redemption) would move tokens burn-free and the 1% burn
would be optional for every holder. So the burn is paid once, when tokens leave the manager:

- A buy delivers 99% of what the pool pays out. The manager is debited the full amount, so v4's
  delta accounting is unaffected; only the trader's receipt is 1% short, as on any transfer.
- A sell arrives whole and settles exactly. A trader who sells the balance they hold ends at zero.
- A relay through the manager, or minting and redeeming ERC-6909 claims, pays the same 1% as a
  direct transfer.

The distributor is not a constructor argument because its address depends on the token's. The
token asks the factory for it at transfer time through `distributorOf(LAUNCH_NUMBER)` with a
static call that forwards a fixed `LOOKUP_GAS` (50,000 gas) and copies at most one word of the
answer. If the factory has not recorded one yet, has no code, reverts, does not finish within the
stipend, or answers with less than a word, the token treats that as "no distributor" and keeps
working; a misbehaving factory can neither block ordinary transfers nor cost them more than the
stipend. Because the stipend is fixed, the lookup answers the same at every gas limit the caller
might send: a distributor claim sent at the wallet's estimate arrives whole, exactly as with gas to
spare. If a call does not have enough gas left to forward the whole stipend, it reverts with
`LookupOutOfGas` rather than treating the unfinished lookup as "no distributor" and burning a
transfer the full lookup would have exempted. Only the distributor of this launch number is exempt.
An address that received tokens through an exempt flow (a claimant, a trader) pays the burn on its
own transfers.

## What it cannot do

- No function mints. The supply can only shrink.
- No owner, pauser, minter or blacklist. No `pause`, `freeze`, `burnFrom`, `seize`, upgrade or
  initializer entry points exist, so no privileged hand can move or freeze a holder's balance.
- No `delegatecall`, `callcode` or `selfdestruct` in the runtime code.
- The burn rate, the lookup gas stipend and the exempt addresses are constants and immutables.
  Nobody can change them after deployment.
- No transfer is exempt on the strength of its recipient alone except one into the PoolManager, and
  nothing that leaves the PoolManager is exempt, so no holder can route around the burn.

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

Chosen constants (the brief leaves them open; they are named constants in `src/TestToken.sol`):

| Constant | Value | Why |
| --- | --- | --- |
| `LOOKUP_GAS` | 50,000 gas | the stipend the distributor lookup forwards to the factory: a mapping getter, also behind a proxy, needs a few thousand; the rest is headroom |

A transfer that is not sent by the factory needs roughly 56,000 gas left when it reaches the lookup
(the stipend, its 1/64 EIP-150 margin and the call overhead), so `eth_estimateGas` for an ordinary
transfer lands a little above what the transfer itself consumes. Gas that the lookup does not use is
refunded as usual.

## After launch

Nothing to configure. The token has no owner and no settable values.

## Assumptions

- The factory mints to itself by being the constructor's caller and then pays out the swarm's 10%,
  the pool seed and the remainder. The token does not reserve, allocate or hold any of the supply.
- The factory records this launch's distributor under `distributorOf(uint64)` before claims start.
  Until then the distributor's transfers are burned like anyone else's.
- The factory's `distributorOf` answers within 50,000 gas (a mapping getter, also behind a proxy,
  does). A lookup that needs more is treated as "no distributor" and claims are burned.
- The factory and PoolManager addresses are the real Sepolia launch addresses, filled by the
  manifest. They are never zero and never guessed.
- Ordinary wallets and integrators understand that the recipient gets 99% of what was sent. Contracts
  that require exact receipt (some bridges, vaults and DEX routers that check balances) may not
  support fee-on-transfer tokens; that is inherent to the requested behavior.
- Buyers from the launch pool receive 99% of what the pool pays out, like any other recipient; sells
  into the pool settle exactly. Front ends should quote buys net of the burn. This is the price of
  a burn that nobody can route around through the manager's flash accounting; the alternative
  (exempting the manager as a sender) would let any holder move tokens burn-free.
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
math including rounding, dust and the whole `uint256` domain, ordinary `transfer` and
`transferFrom` burns with their events and allowance accounting, every exempt flow (factory,
registered distributor, transfers into the pool manager, a seed and round-trip swap), the
non-exempt cases (unregistered distributor, another launch's distributor, onward transfers by
claimants, transfers out of the pool manager, a pay-in/take-out relay through a flash-accounting
stand-in for the manager), lookup robustness against a codeless, reverting, short-answering,
return-bombing or gas-guzzling factory, the lookup's independence from the caller's gas limit (a
claim at the wallet's minimum passing gas behaves exactly as with gas to spare, and a call short of
the stipend reverts with `LookupOutOfGas` instead of burning), and the failure paths (insufficient
balance including the burn, insufficient allowance, zero recipient, no mint or admin entry points).

`test/TestToken.invariant.t.sol` drives random transfers among the launch addresses and ordinary
holders and checks that the supply never grows, that it equals the initial supply minus every
expected burn, and that balances always sum to the supply.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x71f587eee2e9aaa7db704251be18f514c97868b604b88ae66c816645fd979b43 forge test
forge fmt --check
```

Checks run here: `forge build`, `forge test` with the seed above (47 tests, all passing), and
`forge fmt --check`. Slither was not available on this machine; the code avoids its blocking
detectors (no `selfdestruct`, no arbitrary-from `transferFrom`, no initializer or upgrade path, no
storage pointers, no shifts, no packed encoding of dynamic values). The build's one lint note
(`reentrancy-events`, an event after the lookup) is about a bounded static call, which cannot
change state.

## Dependencies

Vendored as plain files under `lib/` (no submodules):

- forge-std v1.11.0
- OpenZeppelin Contracts v5.4.0 (`ERC20` only)
