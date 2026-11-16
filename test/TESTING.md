# TEST token test coverage

Run `forge build` and then:

```sh
FOUNDRY_FUZZ_SEED=0x71f587eee2e9aaa7db704251be18f514c97868b604b88ae66c816645fd979b43 forge test
```

All submitted tests are local, use the existing vendored dependencies, and require no RPC,
environment setup, downloaded fixtures, or signing keys. Test actors are generated with
`makeAddr`; they are not deployment configuration. Fuzz counts and sequence depth are set inline
in the new test contracts. No project configuration changes are needed.

Verified for this revision with Foundry 1.9.0: `forge build` succeeded and the full seeded
`forge test` run passed every test in all six suites, with zero failures or skips. The accounting
invariant campaign (256 runs of 128 actions over eleven selectors) recorded zero handler reverts.

## Revision: transfers out of the PoolManager now burn

The token was revised (`src/TestToken.sol:125-126`): only transfers *into* the PoolManager are
exempt now, because a holder could otherwise use the manager's flash accounting to pay in and take
straight back out and skip the burn. The suite was updated to match, with no change to any other
expectation:

- Both invariant oracles (`TestToken.invariant.t.sol`, `TestTokenAccounting.invariant.t.sol`) no
  longer exempt `from == pool`.
- The accounting campaign's pool is now the `FlashAccountingManager` mock, and a new
  `relayThroughPoolManager` action has holders route value through it with `PoolManagerRelay`. The
  ledger expects the burn to be paid exactly once, on the way out, or not at all when the relay
  sends back into the manager. The relay must also use up its allowance.
- `TestTokenEdges.t.sol` checks that a transfer out of the manager emits the burn events, that
  the manager sending to itself is still whole, and that a holder's allowance spent into the manager
  arrives whole. `TestTokenLookup.t.sol` checks that the manager's outflow burns whether or not the
  distributor lookup answers.
- `TestTokenWalletGas.t.sol` runs a relay, where the lookup sits two calls deep, through the wallet-gas helper.

## Coverage added to the accepted suite

| File | Properties |
| --- | --- |
| `TestTokenEdges.t.sol` | Exact transfer/burn/approval events; zero, dust, rounding thresholds and full-supply amounts; finite/infinite/revoked approvals; self transfers; independent caller/from/to roles; dynamic distributor replacement; exact custom errors; atomic rollback of failed delegated transfers; round trips; split-transfer rounding; equivalent direct/delegated economics. Each fuzz property runs 1,000 cases. |
| `TestTokenLookup.t.sol` | Exact launch-number query; all response lengths below 32 bytes; arbitrary canonical address responses; ABI-shaped revert data; unavailable/recovered lookups; factory/pool flows during a lookup failure. Each fuzz property runs 1,000 cases. |
| `TestTokenWalletGas.t.sol` | The supplied `helpers/WalletGas.sol` compares minimum-success and ample-gas returns/events for transfers, delegated transfers, self/zero/dust transfers, launch flows, distributor lookup/exemption views, and codeless/reverting/short-answer factories. |
| `TestTokenAccounting.invariant.t.sol` | Independent balances, allowances, burns, distributor identity and monotonic supply across 256 sequences of 128 actions. Includes a deterministic sequence that exercises every handler selector and confirms real burns, successful transfers and rejected calls occur. |
| `TestToken.invariant.t.sol` | The original invariant campaign is retained. Its burn oracle now uses the specified one-percent rule and the mock registry, rather than the token's own burn/exemption helpers. |

## Property discovery and model design

The five discovery passes from the supplied Pashov fizz guide were applied to this ERC-20,
with the supplied Trail of Bits guide used to review boundaries, independent oracles and
nonvacuous assertions. The following are specification-backed properties; self transfers are
adapted for this token's burn rather than assuming an ordinary ERC-20 no-op.

| Pass | Property and source basis | Implementation |
| --- | --- | --- |
| Conservation | Constructor supply is fixed; balances sum to supply; initial supply equals current supply plus cumulative burns (`src/TestToken.sol:61`, `:102`). | Independent balance ledger and burn counter, compared after every handler action. |
| State transitions | Only approvals change spending authority; successful finite spends consume the gross amount; failed calls preserve balances, supply and allowance (inherited ERC20 `_spendAllowance` / `_transfer`). Distributor replacement changes subsequent exemption status (`src/TestToken.sol:87`). | Separate approve, revoke, spend and registry actions; all actor-pair allowances checked against history. |
| Round trips and rounding | Each ordinary leg loses its own rounded-down one-percent burn (`src/TestToken.sol:64`). Splitting into two transfers can save at most one minor unit through rounding. | Full-balance/self-transfer actions; explicit dust thresholds; round-trip, split-transfer and quote-period fuzz properties. |
| Adversarial behavior | No spender, including an exempt role, may debit an unapproved holder; sending the maximum uint256 must fail without changing state; recipients cannot execute callbacks; unavailable lookups must not unexpectedly alter ordinary accounting. | Invalid and valid inputs interleaved in the handler; exact errors and rollback fuzz tests; lookup tests and wallet-gas checks. |
| Token-specific rules | Zero transfers emit `Transfer` without moving value; burns never credit address zero; infinite allowances stay infinite until overwritten; launch exemptions depend on source/destination rather than spender (`src/TestToken.sol:85`). | Event assertions, allowance matrix, zero-balance invariant and role tests. |

The new handler seeds seven roles through genuine exempt transfers. It bounds generated amounts
using its **expected** balances and allowances, never the implementation's balance/exemption/quote
functions. Explicit modes also generate 0, 1, 99, 100, full balance, one above the available amount,
and `uint256.max`. The tracked actor set is closed: every possible recipient is tracked, or is
the invalid zero address. Approvals and spending are separate actions, so repeated spending,
revocation, and stale allowances can be tested across calls.

Expected reverts are caught and checked against the full custom error. Unexpected successes,
reverts or return data set a persistent failure flag checked by an invariant. This avoids losing
failures when the runner permits handler reverts. The fixed-seed campaign completed all 32,768
actions with zero handler reverts and exercised all its selectors (eleven since this revision added the relay).

## Reported defects and limits

The two defects reported in the previous round have been fixed in the implementation, and its own
suite now covers them (`test/TestToken.t.sol`):

- The distributor lookup forwards a fixed `LOOKUP_GAS` and reverts with `LookupOutOfGas` instead of
  burning a claim at a wallet's gas (`test_distributorClaimAtWalletGasArrivesWholeWithAnExpensiveLookup`,
  `test_transferShortOfLookupGasRevertsInsteadOfBurningTheClaim`).
- `burnOn` is defined for every `uint256`, including the maximum (`test_burnOnIsDefinedForEveryAmount`).

No new defect was found in this revision, so there is no findings file. One design point is
deliberate rather than a defect: since the manager's outflow is not exempt, a buy delivers 99% of
what the pool pays out. The manager is still debited exactly what `take` names, so its accounting
settles and the protected seed-and-swap flow holds.

The supplied protected checks need framework contracts (v4-core, LaunchLiquidity) that are not in
this repository. The local tests run the token's launch semantics against the mock factory and the
flash-accounting manager mock; they do not claim to run a live Uniswap v4 swap or the external
protected harness. No fork block was assigned.
