# SEAL tests

The original `SealToken.t.sol` remains intact. The additional suites use only the
repository's vendored dependencies and require no network, fork, environment
variables, or configuration changes.

- `SealToken.EdgeCases.t.sol` checks constructor ownership through direct creation
  and CREATE2, exact transfer events and boundary amounts, cumulative allowance
  spending, revocation, owner/spender isolation, self-transfers, and failure
  atomicity. Each new parameterized test runs 1,000 cases.
- `SealToken.Invariant.t.sol` drives the real token through
  `handlers/SealTokenHandler.sol` for 256 sequences of 128 calls. Explicit selector
  targeting restricts the runner to eight token actions. Unexpected handler
  reverts fail the campaign; expected token errors are checked inside the handler.

The handler uses four actors, including the constructor's deployer. All actors
receive real transfers from constructor issuance; token storage and supply are
never modified with cheatcodes. Random actions include transfers, finite and
infinite approvals, replacements and revocations, delegated spending, insufficient
balances and allowances, and invalid zero recipients/spenders. Amount generation
includes zero, one minor unit, full balances/budgets, and the uint256 boundary.

After each handler action the invariants check:

1. The supply remains exactly `1_000_000_000 * 10**18`, metadata stays fixed, and
   the sum of all reachable holders' balances equals that supply.
2. Each holder's balance equals its constructor issuance plus cumulative receipts
   minus cumulative sends, recorded independently from requested successful calls.
3. Every owner/spender pair retains its approval budget minus successful spending,
   including infinite approvals and unchanged state after failed calls.

The closed actor set makes the balance sum exhaustive within these sequences.
The original address-fuzzing test separately exercises arbitrary recipients.
A deterministic handler regression ensures finite exhaustion, infinite spending,
revocation, actual value movement, and every failure action are also pinned cases.

Run `forge build` and `forge test`. To keep local generated artifacts in the
assignment's disposable area, append
`--out test/scratch/out --cache-path test/scratch/cache` to either command.
