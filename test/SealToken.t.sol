// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SealToken} from "../src/SealToken.sol";
import {DeploySealToken} from "../script/DeploySealToken.s.sol";

/// @notice Deploys the token the way the launch factory will: from a contract whose `msg.sender` at
///         construction is this deployer, which then holds the whole supply.
contract Deployer {
    SealToken public immutable token;

    constructor() {
        token = new SealToken();
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        return token.approve(spender, amount);
    }
}

contract SealTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    Deployer internal deployer;
    SealToken internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    function setUp() public {
        deployer = new Deployer();
        token = deployer.token();
    }

    // ---------------------------------------------------------------- metadata

    function test_nameSymbolDecimals() public view {
        assertEq(token.name(), "seal");
        assertEq(token.symbol(), "SEAL");
        assertEq(token.decimals(), 18);
        assertEq(token.DECIMALS(), 18);
    }

    // ------------------------------------------------------------------ supply

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.balanceOf(address(deployer)), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.recordLogs();
        Deployer fresh = new Deployer();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one Transfer event");
        assertEq(logs[0].emitter, address(fresh.token()));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(fresh));
        assertEq(abi.decode(logs[0].data, (uint256)), EXPECTED_SUPPLY);
    }

    function test_deployScriptMintsToCaller() public {
        DeploySealToken script = new DeploySealToken();
        SealToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
    }

    function test_noMintFunctionExists() public {
        string[5] memory signatures =
            ["mint(address,uint256)", "mint(uint256)", "mint()", "issue(uint256)", "setMinter(address)"];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            vm.prank(address(deployer));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(ALICE);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_noPrivilegedControlsExist() public {
        deployer.send(ALICE, 1000e18);
        string[10] memory signatures = [
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "transferOwnership(address)",
            "owner()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            vm.prank(address(deployer));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(ALICE), 1000e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 400e18));
        assertEq(token.balanceOf(BOB), 400e18);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // --------------------------------------------------------------- transfers

    function test_transferMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(deployer), ALICE, 123e18);
        assertTrue(deployer.send(ALICE, 123e18));
        assertEq(token.balanceOf(ALICE), 123e18);
        assertEq(token.balanceOf(address(deployer)), EXPECTED_SUPPLY - 123e18);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        deployer.send(ALICE, 50e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 50e18));
        assertEq(token.balanceOf(ALICE), 50e18);
    }

    function test_transferWholeBalanceLeavesZero() public {
        deployer.send(ALICE, 7e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 7e18));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 7e18);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        deployer.send(ALICE, 10e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10e18, 11e18));
        token.transfer(BOB, 11e18);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, CAROL, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        deployer.send(ALICE, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    // --------------------------------------------------------------- approvals

    function test_approveAndTransferFrom() public {
        deployer.send(ALICE, 100e18);
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(ALICE, BOB, 60e18);
        assertTrue(token.approve(BOB, 60e18));
        assertEq(token.allowance(ALICE, BOB), 60e18);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, 40e18));
        assertEq(token.balanceOf(ALICE), 60e18);
        assertEq(token.balanceOf(CAROL), 40e18);
        assertEq(token.allowance(ALICE, BOB), 20e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        deployer.send(ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 100e18);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(ALICE);
        token.approve(BOB, 5e18);
        token.approve(BOB, 2e18);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), 2e18);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        deployer.send(ALICE, 100e18);
        vm.prank(ALICE);
        token.approve(BOB, 10e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 10e18, 11e18));
        token.transferFrom(ALICE, CAROL, 11e18);
    }

    function test_RevertWhen_transferFromWithoutApproval() public {
        deployer.send(ALICE, 100e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_RevertWhen_transferFromExceedsBalanceDespiteAllowance() public {
        deployer.send(ALICE, 5e18);
        vm.prank(ALICE);
        token.approve(BOB, 10e18);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 5e18, 6e18));
        token.transferFrom(ALICE, CAROL, 6e18);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_deployerCannotPullFromHolderWithoutApproval() public {
        deployer.send(ALICE, 10e18);
        vm.prank(address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(deployer), 0, 1)
        );
        token.transferFrom(ALICE, address(deployer), 1);
        assertEq(token.balanceOf(ALICE), 10e18);
    }

    // ---------------------------------------------------------------- launch flows

    /// @dev The flows the launch performs: the swarm's tenth leaves the deployer whole, is claimed whole,
    ///      and the supply never changes.
    function test_launchStyleFlowsMoveExactAmounts() public {
        address distributor = address(0xD157);
        address claimant = address(0xC1A1);
        address remainderTo = address(0x12A7aad083cef06FeF7c295514B52FC8bc81960d);
        uint256 swarm = EXPECTED_SUPPLY / 10;
        uint256 pool = (EXPECTED_SUPPLY * 8800) / 10_000;
        uint256 remainder = EXPECTED_SUPPLY - swarm - pool;

        assertTrue(deployer.send(distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm);
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);

        assertTrue(deployer.send(remainderTo, remainder));
        assertEq(token.balanceOf(remainderTo), remainder);
        assertEq(token.balanceOf(address(deployer)), pool);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // -------------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(deployer));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        assertTrue(deployer.send(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(deployer)) + token.balanceOf(to), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowanceAmount, uint256 spend) public {
        allowanceAmount = bound(allowanceAmount, 0, EXPECTED_SUPPLY);
        spend = bound(spend, 0, EXPECTED_SUPPLY);
        deployer.approve(BOB, allowanceAmount);
        vm.prank(BOB);
        if (spend > allowanceAmount) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowanceAmount, spend)
            );
            token.transferFrom(address(deployer), CAROL, spend);
        } else {
            assertTrue(token.transferFrom(address(deployer), CAROL, spend));
            assertEq(token.balanceOf(CAROL), spend);
            assertEq(token.allowance(address(deployer), BOB), allowanceAmount - spend);
        }
    }

    function testFuzz_cannotTransferMoreThanHeld(uint256 held, uint256 attempt) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        attempt = bound(attempt, held + 1, type(uint256).max);
        vm.assume(held < type(uint256).max);
        deployer.send(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, attempt));
        token.transfer(BOB, attempt);
    }
}
