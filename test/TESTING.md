# TEST token test coverage

Run `forge build` and then:

```sh
FOUNDRY_FUZZ_SEED=0x71f587eee2e9aaa7db704251be18f514c97868b604b88ae66c816645fd979b43 forge test
```

All submitted tests are local, use the existing vendored dependencies, and require no RPC,
environment setup, downloaded fixtures, or signing keys. Test actors are generated with
`makeAddr`; they are not deployment configuration. Fuzz counts and sequence depth are set inline
in the new test contracts. No project configuration changes are needed.

Verified with Foundry 1.8.3: `forge build` succeeded and the full seeded `forge test` run passed
79 tests across six suites, with zero failures or skips. The two invariant campaigns completed
160,768 actions in total with zero handler reverts. A separate coverage run over the 65 unit/fuzz
tests reported 100% of the token's lines (29/29), statements (46/46), branches (7/7) and functions
(5/5). Wallet-gas tests were checked against the normal optimized build, not coverage instrumentation.

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
actions with zero handler reverts and exercised all ten selectors.

## Reported defects and limits

Two failing proofs are preserved in the root `.imd-findings.json`, rather than included as passing
assertions or weakened tests:

- A deterministic expensive distributor lookup causes different results at minimum-success gas:
  a distributor's 100 TEST claim delivers 99 TEST and burns 1 TEST, while ample gas delivers all
  100. The ordinary mapping getter passes the wallet-gas checks. The finding explicitly requires
  an expensive dependency and makes no claim about a deployed factory.
- `burnOn(uint256.max)` panics before division even though its result fits. This is limited to
  the public quote helper; transferable amounts cannot reach the overflow boundary.

Both proofs import only the production token and forge-std and were executed to confirm failure.
The proofs used during investigation live in disposable scratch space; the report embeds their
full source. The submitted passing suite does not assert either defective behavior as correct.

The supplied protected checks require framework contracts that are not part of this repository.
The local tests exercise the token's launch transfer semantics with the existing mock factory and
pool/distributor actors; they do not claim to execute a live Uniswap v4 swap or the external
protected harness. No fork block was assigned.
