// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SealToken} from "src/SealToken.sol";

/// @notice Drives the actual token using four actors, including its original deployer.
/// @dev The closed actor set includes every successful sender and recipient. Ghost accounting
/// records requested amounts after successful calls; it never copies balances from the token.
contract SealTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant ACTOR_COUNT = 4;
    SealToken public immutable token;
    address[4] public actors;

    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;
    mapping(address => mapping(address => uint256)) public approved;
    mapping(address => mapping(address => uint256)) public spentSinceApproval;

    constructor() {
        actors[0] = address(this);
        actors[1] = makeAddr("seal invariant alice");
        actors[2] = makeAddr("seal invariant bob");
        actors[3] = makeAddr("seal invariant carol");
        token = new SealToken();

        // Only genuine constructor issuance and ERC-20 transfers fund the actors.
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            _transfer(actors[0], actors[i], SUPPLY / 4);
        }
        // Both finite and infinite approvals are reachable from the first fuzzed call.
        _approve(actors[0], actors[1], SUPPLY / 8);
        _approve(actors[1], actors[2], SUPPLY / 8);
        _approve(actors[2], actors[3], type(uint256).max);
        _approve(actors[3], actors[0], type(uint256).max);
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _amount(amountSeed, expectedBalance(from)));
    }

    function approveTokens(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint8 mode) external {
        uint256 amount;
        if (mode % 4 == 0) amount = 0;
        else if (mode % 4 == 1) amount = type(uint256).max;
        else if (mode % 4 == 2) amount = bound(value, 0, SUPPLY);
        else amount = value;
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function spendAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 limit = expectedBalance(owner);
        uint256 allowanceRemaining = expectedAllowance(owner, spender);
        if (allowanceRemaining < limit) limit = allowanceRemaining;
        uint256 amount = _amount(amountSeed, limit);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "valid delegated transfer must succeed");
        sent[owner] += amount;
        received[to] += amount;
        if (approved[owner][spender] != type(uint256).max) {
            spentSinceApproval[owner][spender] += amount;
        }
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 held = expectedBalance(from);
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(_actor(toSeed), amount);
        // Ghosts stay unchanged. Invariants check all balances and approvals after the revert.
    }

    function spendTooMuchAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 value) external {
        address owner = _fundedActor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowanceAmount = bound(value, 0, expectedBalance(owner) - 1);
        _approve(owner, spender, allowanceAmount);
        uint256 attempted = allowanceAmount + 1;

        // The owner can afford this transfer; allowance must independently prevent it.
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowanceAmount, attempted
            )
        );
        token.transferFrom(owner, _actor(toSeed), attempted);
    }

    function spendTooMuchBalance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 value,
        bool infiniteApproval
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 held = expectedBalance(owner);
        uint256 attempted = bound(value, held + 1, type(uint256).max);
        _approve(owner, spender, infiniteApproval ? type(uint256).max : attempted);

        // There is enough allowance. If the balance check fails, its earlier expenditure
        // must be rolled back along with the transfer.
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, attempted));
        token.transferFrom(owner, _actor(toSeed), attempted);
    }

    function transferToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 value, bool delegated) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(value, expectedBalance(owner));
        if (delegated) {
            address spender = _actor(spenderSeed);
            _approve(owner, spender, amount);
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), amount);
        }
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.prank(_actor(ownerSeed));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
    }

    function expectedBalance(address account) public view returns (uint256) {
        uint256 issuance = account == actors[0] ? SUPPLY : 0;
        return issuance + received[account] - sent[account];
    }

    function expectedAllowance(address owner, address spender) public view returns (uint256) {
        uint256 ceiling = approved[owner][spender];
        return ceiling == type(uint256).max ? ceiling : ceiling - spentSinceApproval[owner][spender];
    }

    function _transfer(address from, address to, uint256 amount) private {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer must succeed");
        sent[from] += amount;
        received[to] += amount;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "valid approval must succeed");
        approved[owner][spender] = amount;
        spentSinceApproval[owner][spender] = 0;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    function _fundedActor(uint256 seed) private view returns (address) {
        uint256 start = bound(seed, 0, ACTOR_COUNT - 1);
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address candidate = actors[(start + i) % ACTOR_COUNT];
            if (expectedBalance(candidate) > 0) return candidate;
        }
        revert("ghost ledger lost the fixed supply");
    }

    function _amount(uint256 seed, uint256 limit) private pure returns (uint256) {
        // Frequently exercise zero, one minor unit, and the entire available balance/budget.
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return limit == 0 ? 0 : 1;
        if (seed % 4 == 2) return limit;
        return bound(seed, 0, limit);
    }
}
