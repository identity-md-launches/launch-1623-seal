// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SealToken} from "src/SealToken.sol";
import {SealTokenHandler} from "./handlers/SealTokenHandler.sol";

/// @notice Supply, exact per-holder accounting, and spending authority after random call sequences.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract SealTokenInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    SealTokenHandler private handler;
    SealToken private token;

    function setUp() public {
        handler = new SealTokenHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transferTokens.selector;
        selectors[1] = handler.approveTokens.selector;
        selectors[2] = handler.spendAllowance.selector;
        selectors[3] = handler.transferTooMuch.selector;
        selectors[4] = handler.spendTooMuchAllowance.selector;
        selectors[5] = handler.spendTooMuchBalance.selector;
        selectors[6] = handler.transferToZero.selector;
        selectors[7] = handler.approveZeroSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyAndMetadataStayFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "issuance must never grow or burn");
        assertEq(token.name(), "seal");
        assertEq(token.symbol(), "SEAL");
        assertEq(token.decimals(), 18);
        assertEq(token.balanceOf(address(0)), 0, "zero address cannot receive tokens");

        uint256 totalHeld;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            totalHeld += token.balanceOf(handler.actors(i));
        }
        assertEq(totalHeld, SUPPLY, "all issued tokens must remain accounted for");
    }

    function invariant_balancesMatchSuccessfulTransferHistory() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder gained or lost unaccounted value");
        }
    }

    function invariant_allowancesMatchApprovalAndSpendingHistory() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < handler.ACTOR_COUNT(); ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "approval isolation, spending budget, or failure rollback violated"
                );
            }
        }
    }

    /// @dev A deterministic regression drives every handler and ensures the model sees real
    /// value movement, finite exhaustion, infinite spending, revocation, and expected failures.
    function test_handlerSequenceExercisesAccountingAndFailures() public {
        handler.transferTokens(0, 1, 1);
        handler.approveTokens(1, 2, 17, 3);
        handler.spendAllowance(1, 2, 3, 2); // Entire finite allowance: 17.
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), 0);
        assertEq(token.balanceOf(handler.actors(3)), SUPPLY / 4 + 17);

        handler.approveTokens(1, 2, 0, 1); // Infinite allowance.
        handler.spendAllowance(1, 2, 1, 1); // Self-transfer consumes no infinite allowance.
        handler.spendAllowance(1, 2, 3, 1);
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), type(uint256).max);
        handler.approveTokens(1, 2, 0, 0); // Revoke.
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), 0);

        handler.transferTooMuch(0, 1, type(uint256).max);
        handler.spendTooMuchAllowance(0, 1, 2, 1);
        handler.spendTooMuchBalance(0, 1, 2, type(uint256).max - 1, false);
        handler.spendTooMuchBalance(0, 1, 2, type(uint256).max, true);
        handler.transferToZero(0, 1, 1, true);
        handler.transferToZero(0, 1, 0, false);
        handler.approveZeroSpender(0, type(uint256).max);

        invariant_supplyAndMetadataStayFixed();
        invariant_balancesMatchSuccessfulTransferHistory();
        invariant_allowancesMatchApprovalAndSpendingHistory();
    }
}
