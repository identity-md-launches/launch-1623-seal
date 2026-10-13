// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title seal (SEAL)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 SEAL (18 decimals) is minted once,
///         in the constructor, to the deployer. There is no owner, no further minting, no pause, no
///         blacklist and no transfer tax: every transfer moves exactly the amount requested.
/// @dev The constructor takes no arguments, reads no other contract and performs no external call, so
///      the creation code deploys identically on an empty chain. `msg.sender` at construction is the
///      deployer (the launch factory), which then distributes the supply.
contract SealToken is ERC20 {
    /// @notice Human-readable token name, as `name()` returns it.
    string private constant TOKEN_NAME = "seal";

    /// @notice Ticker, as `symbol()` returns it.
    string private constant TOKEN_SYMBOL = "SEAL";

    /// @notice Number of decimals; `decimals()` is inherited and returns 18.
    uint8 public constant DECIMALS = 18;

    /// @notice Whole-token supply before scaling by decimals.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice Total supply in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** uint256(DECIMALS);

    /// @notice Mints the entire supply to the deployer. Nothing can mint afterwards.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
