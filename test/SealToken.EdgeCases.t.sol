// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SealToken} from "src/SealToken.sol";

contract SealCreate2Deployer {
    function deploy(bytes32 salt) external returns (SealToken) {
        return new SealToken{salt: salt}();
    }
}

/// @notice Boundary and failure-atomicity tests supplementing the original token suite.
/// forge-config: default.fuzz.runs = 1000
contract SealTokenEdgeCasesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 1e18;
    SealToken private token;
    address private alice;
    address private bob;
    address private carol;

    function setUp() public {
        token = new SealToken();
        alice = makeAddr("seal edge alice");
        bob = makeAddr("seal edge bob");
        carol = makeAddr("seal edge carol");
    }

    function testFuzz_constructorMintsToItsImmediateDeployer(address creator) public {
        creator = address(uint160(bound(uint256(uint160(creator)), 1, type(uint160).max)));
        vm.prank(creator);
        SealToken fresh = new SealToken();

        assertEq(fresh.name(), "seal");
        assertEq(fresh.symbol(), "SEAL");
        assertEq(fresh.decimals(), 18);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(creator), SUPPLY);
        assertEq(fresh.balanceOf(address(0)), 0);
    }

    function test_create2MintsToFactoryNotOriginOrCaller() public {
        SealCreate2Deployer factory = new SealCreate2Deployer();
        bytes32 salt = keccak256("seal constructor ownership");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(SealToken).creationCode))
                    )
                )
            )
        );

        vm.prank(alice, bob);
        SealToken fresh = factory.deploy(salt);

        assertEq(address(fresh), predicted);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(factory)), SUPPLY);
        assertEq(fresh.balanceOf(alice), 0);
        assertEq(fresh.balanceOf(bob), 0);
        assertEq(fresh.balanceOf(address(this)), 0);
    }

    function test_transferBoundaryAmountsAndRoundTrips() public {
        uint256[4] memory amounts = [uint256(0), 1, SUPPLY - 1, SUPPLY];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            vm.expectEmit(true, true, false, true, address(token));
            emit IERC20.Transfer(address(this), alice, amount);
            assertTrue(token.transfer(alice, amount));
            assertEq(token.balanceOf(address(this)), SUPPLY - amount);
            assertEq(token.balanceOf(alice), amount);
            assertEq(token.totalSupply(), SUPPLY);

            vm.prank(alice);
            assertTrue(token.transfer(address(this), amount));
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.balanceOf(address(this)), SUPPLY);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    function test_transferMaximumUintRevertsWithoutChangingBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        assertTrue(token.transfer(alice, 1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        token.transfer(alice, 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromNeedsNoAllowanceAndEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, carol, 0);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 0));

        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(carol), 0);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_zeroTransferToZeroAddressStillReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 0);
        assertEq(token.allowance(alice, bob), 0);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_zeroTransferFromZeroOwnerIsRejected() public {
        // No allowance is needed for zero, but zero is still not a valid token owner.
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(address(0), alice, 0);
        assertEq(token.allowance(address(0), bob), 0);
        _assertOnlyDeployerHoldsSupply();
    }

    function testFuzz_transferToZeroIsAtomic(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        _assertOnlyDeployerHoldsSupply();
    }

    function testFuzz_transferFromToZeroRestoresAllowance(uint256 amount, bool infiniteApproval) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 approved = infiniteApproval ? type(uint256).max : amount;
        assertTrue(token.approve(bob, approved));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), amount);

        assertEq(token.allowance(address(this), bob), approved);
        _assertOnlyDeployerHoldsSupply();
    }

    function testFuzz_failedTransferFromRestoresFiniteAllowance(uint256 held, uint256 attempted, uint256 approved)
        public
    {
        held = bound(held, 0, SUPPLY);
        attempted = bound(attempted, held + 1, type(uint256).max - 1);
        approved = bound(approved, attempted, type(uint256).max - 1);
        assertTrue(token.transfer(alice, held));
        vm.prank(alice);
        assertTrue(token.approve(bob, approved));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempted));
        token.transferFrom(alice, carol, attempted);

        // Spending allowance occurs before the balance check, so rollback matters here.
        assertEq(token.allowance(alice, bob), approved);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumDelegatedTransferRevertsAndKeepsInfiniteAllowance() public {
        assertTrue(token.approve(bob, type(uint256).max));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transferFrom(address(this), alice, type(uint256).max);

        assertEq(token.allowance(address(this), bob), type(uint256).max);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_largestFiniteAllowanceDecrements() public {
        assertTrue(token.approve(bob, type(uint256).max - 1));
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, 1));

        assertEq(token.allowance(address(this), bob), type(uint256).max - 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_finiteAllowanceCannotBeReused() public {
        assertTrue(token.approve(bob, 1));
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), bob), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(this), carol, 1);

        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_finiteAllowanceLimitsCumulativeSpending(uint256 approved, uint256 first, uint256 second) public {
        approved = bound(approved, 1, SUPPLY);
        first = bound(first, 0, approved);
        second = bound(second, 0, approved - first);
        assertTrue(token.approve(bob, approved));

        vm.startPrank(bob);
        assertTrue(token.transferFrom(address(this), alice, first));
        assertTrue(token.transferFrom(address(this), carol, second));
        vm.stopPrank();
        uint256 remaining = approved - first - second;

        assertEq(token.allowance(address(this), bob), remaining);
        assertEq(token.balanceOf(alice), first);
        assertEq(token.balanceOf(carol), second);
        assertEq(token.balanceOf(address(this)), SUPPLY - first - second);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, remaining, remaining + 1)
        );
        token.transferFrom(address(this), alice, remaining + 1);
        assertEq(token.allowance(address(this), bob), remaining);
        assertEq(token.balanceOf(alice), first);
        assertEq(token.balanceOf(carol), second);
        assertEq(token.balanceOf(address(this)), SUPPLY - first - second);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_revocationStopsPreviouslyApprovedSpender(uint256 approved, uint256 attempted) public {
        approved = bound(approved, 1, type(uint256).max);
        attempted = bound(attempted, 1, SUPPLY);
        assertTrue(token.approve(bob, approved));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), bob, 0);
        assertTrue(token.approve(bob, 0));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, attempted));
        token.transferFrom(address(this), alice, attempted);
        assertEq(token.allowance(address(this), bob), 0);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_infiniteAllowanceCanBeRevokedAfterUse() public {
        assertTrue(token.approve(bob, type(uint256).max));
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), bob), type(uint256).max);
        assertTrue(token.approve(bob, 0));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_approvalBelongsToOneOwnerAndOneSpender() public {
        assertTrue(token.transfer(alice, 10));
        assertTrue(token.approve(bob, 10));

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1));
        token.transferFrom(address(this), carol, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, carol, 1);

        assertEq(token.allowance(address(this), bob), 10);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.allowance(address(this), carol), 0);
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10);
    }

    function test_ownerUsingTransferFromStillNeedsApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
        _assertOnlyDeployerHoldsSupply();

        assertTrue(token.approve(address(this), 1));
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_delegatedSelfTransferConsumesAllowanceButPreservesBalance() public {
        assertTrue(token.approve(bob, SUPPLY));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), address(this), SUPPLY);
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY));

        assertEq(token.allowance(address(this), bob), 0);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_spenderCanBeTheRecipient() public {
        assertTrue(token.approve(bob, SUPPLY));
        vm.prank(bob);
        assertTrue(token.transferFrom(address(this), bob, SUPPLY));
        assertEq(token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.allowance(address(this), bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approvalOverwritesAndIsIdempotent(uint256 first, uint256 replacement) public {
        // An unfunded owner may approve the full uint256 range; allowance is not a balance.
        vm.startPrank(alice);
        assertTrue(token.approve(bob, first));
        assertTrue(token.approve(bob, replacement));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(alice, bob, replacement);
        assertTrue(token.approve(bob, replacement));
        vm.stopPrank();

        assertEq(token.allowance(alice, bob), replacement);
        assertEq(token.allowance(bob, alice), 0);
        _assertOnlyDeployerHoldsSupply();
    }

    function testFuzz_approvalOfZeroSpenderIsAtomic(uint256 amount) public {
        assertTrue(token.approve(bob, 123));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.allowance(address(this), bob), 123);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_zeroApprovalOfZeroSpenderStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.allowance(address(this), address(0)), 0);
        _assertOnlyDeployerHoldsSupply();
    }

    function test_directTransfersLeaveApprovalsUntouched() public {
        assertTrue(token.approve(bob, type(uint256).max - 1));
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.allowance(address(this), bob), type(uint256).max - 1);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), bob), type(uint256).max - 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _assertOnlyDeployerHoldsSupply() private view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
