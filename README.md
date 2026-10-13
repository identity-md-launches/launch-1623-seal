# seal (SEAL)

A fixed-supply ERC-20 token for the IMD custom-token launch on Ethereum (chain id 1).

| Parameter        | Value                                                  |
| ---------------- | ------------------------------------------------------ |
| Solidity contract| `SealToken` (`src/SealToken.sol`)                      |
| `name()`         | `seal`                                                 |
| `symbol()`       | `SEAL`                                                 |
| `decimals()`     | `18`                                                   |
| `totalSupply()`  | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor args | none                                                   |
| Compiler         | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## Behaviour

- The constructor mints the entire supply once to `msg.sender`, the deployer. Under the IMD launch
  that is the ProjectFactory, which distributes the supply (swarm share, pool seed, remainder).
- There is no owner, no minter role, no `mint`, no `burnFrom`, no pause, no blacklist, no freeze and
  no upgrade path. The supply can never grow after deployment.
- Transfers and `transferFrom` move exactly the amount requested: no tax, no reflection, no burn on
  transfer. The factory, the pool manager, the MerkleDistributor and any trader are all treated the
  same, so the launch flows (distributor funding, claims, single-sided seed, swaps each way) arrive
  whole.
- The implementation is OpenZeppelin Contracts v5.4.0 `ERC20`, vendored as plain files under
  `lib/openzeppelin-contracts/` (only the files the token imports). It uses custom errors
  (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, `ERC20InvalidReceiver`,
  `ERC20InvalidSpender`) on failure. Holders can burn nothing except by sending to a dead address of
  their choosing; the token itself exposes no burn.

## Assumptions

- The brief asks for a plain token: name, symbol and a fixed supply minted once to the deployer.
  No transfer rules, taxes, vesting or governance were requested, so none are implemented.
- The deployer is whoever runs the creation code. The constructor takes no arguments, reads no other
  contract and makes no external call, so it deploys identically on an empty chain and through
  CREATE2 from the factory.
- The runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (checked by a test),
  and every library the contract uses is internal, so the bytecode has no link placeholders.

## Deployment parameters

The IMD launch deploys the token from the built bytecode; nothing here broadcasts a transaction.
Values the launch step fills into the manifest (not written by this repository):

- `token.contract`: `SealToken`
- `token.name` / `token.symbol` / `token.decimals`: `seal` / `SEAL` / `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee `12500`, tick spacing `60`,
  initial price `79228162514264337593543950336` (provenance only; the deployer derives the opening
  price from the economics).
- Economics (copied verbatim from the job): `poolBps` 8800, `initialMarketCapWei`
  `2500000000000000000000`, `remainderTo` `0x12A7aad083cef06FeF7c295514B52FC8bc81960d`.

For a local or manual deployment, `script/DeploySealToken.s.sol` deploys the token with
`new SealToken()`; the broadcasting account receives the whole supply. `run()` reads nothing from
the environment, and tests call `deploy()` directly.

```sh
forge script script/DeploySealToken.s.sol --rpc-url <RPC> --broadcast
```

## After launch

There is nothing to configure. The token has no owner-settable values, no roles and no external
dependencies.

## Operational responsibilities

- **Supply distribution.** The factory holds the whole supply right after deployment and pays it
  out: 10% to the launch's MerkleDistributor, 88% to seed the pool, 2% to `remainderTo`. The token
  cannot recover tokens sent to a wrong address; the address receiving the remainder must be one the
  requester controls.
- **No admin keys.** Because the contract has no privileged functions, there is nothing to rotate,
  pause or upgrade, and no key whose loss affects the token. Any future change in behaviour requires
  a new token.
- **Explorer verification** of the deployed source and the independent adversarial review are the
  launch's and its reviewers' responsibility, not this repository's. Passing tests are not an audit.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

Tests live in `test/SealToken.t.sol` and cover metadata, the single constructor mint (balance and
the one `Transfer` event), the absence of mint and privileged functions, exact transfer amounts,
approval and `transferFrom` success paths, every documented revert (insufficient balance, insufficient
allowance, zero receiver, zero spender), the launch-style flows (distributor funding, claim, remainder)
and fuzzed conservation of supply. Tests read no environment variables and do not depend on the
caller, so they run in any order and in parallel.

Dependencies are vendored as ordinary files, not submodules:

- `lib/forge-std` — foundry-rs/forge-std at commit `0258fe8` (MIT / Apache-2.0)
- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.4.0, ERC20 subset (MIT)
