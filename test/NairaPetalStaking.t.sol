// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {NairaPetalStaking} from "../src/NairaPetalStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20, IERC20Errors} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {console} from "forge-std/console.sol";

// Import custom errors
import {
    CannotStakeZero,
    NotEnoughRewards,
    RewardsNotAvailableYet,
    CannotunstakeZero,
    CannotunstakeStakingToken,
    InvalidPriceFeed,
    NotWhitelisted
} from "../src/NairaPetalStaking.sol";

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract MockChainlinkAggregator is IChainlinkAggregator {
    uint80 public roundId = 0;
    uint8 public keyDecimals = 0;

    struct Entry {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    mapping(uint256 => Entry) public entries;

    bool public allRoundDataShouldRevert;
    bool public latestRoundDataShouldRevert;

    // Mock setup function
    function setLatestAnswer(int256 answer, uint256 timestamp) external {
        roundId++;
        entries[roundId] = Entry({
            roundId: roundId,
            answer: answer,
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: roundId
        });
    }

    function setLatestAnswerWithRound(int256 answer, uint256 timestamp, uint80 _roundId) external {
        roundId = _roundId;
        entries[roundId] = Entry({
            roundId: roundId,
            answer: answer,
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: roundId
        });
    }

    function setAllRoundDataShouldRevert(bool _shouldRevert) external {
        allRoundDataShouldRevert = _shouldRevert;
    }

    function setLatestRoundDataShouldRevert(bool _shouldRevert) external {
        latestRoundDataShouldRevert = _shouldRevert;
    }

    function setDecimals(uint8 _decimals) external {
        keyDecimals = _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (latestRoundDataShouldRevert) {
            revert("latestRoundData reverted");
        }
        return getRoundData(uint80(latestRound()));
    }

    function latestRound() public view returns (uint256) {
        return roundId;
    }

    function decimals() external view returns (uint8) {
        return keyDecimals;
    }

    function getAnswer(uint256 _roundId) external view returns (int256) {
        Entry memory entry = entries[_roundId];
        return entry.answer;
    }

    function getTimestamp(uint256 _roundId) external view returns (uint256) {
        Entry memory entry = entries[_roundId];
        return entry.updatedAt;
    }

    function getRoundData(uint80 _roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        if (allRoundDataShouldRevert) {
            revert("getRoundData reverted");
        }

        Entry memory entry = entries[_roundId];
        // Emulate a Chainlink aggregator
        return (entry.roundId, entry.answer, entry.startedAt, entry.updatedAt, entry.answeredInRound);
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}

contract NairaPetalStakingTest is Test {
    NairaPetalStaking public nairaPetalStaking;
    MockERC20 public rewardsToken;
    MockERC20 public stakingToken;
    MockERC20 public otherToken;
    MockChainlinkAggregator public mockAggregator;

    address public owner;
    address public user1;
    address public user2;

    uint256 public constant INITIAL_REWARDS_SUPPLY = 10000e18;
    uint256 public constant INITIAL_STAKING_SUPPLY = 10000e18;
    uint256 public constant REWARDS_DURATION = 86400 * 14; // 14 days

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        vm.warp(1000000000);

        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy tokens
        rewardsToken = new MockERC20("RewardsToken", "RT", INITIAL_REWARDS_SUPPLY);
        stakingToken = new MockERC20("StakingToken", "ST", INITIAL_STAKING_SUPPLY);
        otherToken = new MockERC20("OtherToken", "OT", 1000e18);

        // Deploy mock aggregator
        mockAggregator = new MockChainlinkAggregator();

        // assuming a 50c reward token rate
        mockAggregator.setDecimals(8);
        mockAggregator.setLatestAnswer(1e8 / 2, block.timestamp);

        // Deploy staking contract
        nairaPetalStaking =
            new NairaPetalStaking(owner, address(rewardsToken), address(stakingToken), address(mockAggregator));

        // setup token allowances so we dont have to do it later
        stakingToken.approve(address(nairaPetalStaking), type(uint256).max);
        rewardsToken.approve(address(nairaPetalStaking), type(uint256).max);

        // Setup initial token distributions
        stakingToken.transfer(user1, 1000e18);
        stakingToken.transfer(user2, 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor_InitializesCorrectly() public view {
        assertEq(address(nairaPetalStaking.rewardsToken()), address(rewardsToken));
        assertEq(address(nairaPetalStaking.stakingToken()), address(stakingToken));
        assertEq(nairaPetalStaking.owner(), owner);
        assertEq(nairaPetalStaking.rewardRate(), 0);
        assertEq(nairaPetalStaking.name(), "NairaPetalStaking");
        assertEq(nairaPetalStaking.symbol(), "NPS");

        // Check rewardsAvailableDate is set to 1 year from deployment
        assertEq(nairaPetalStaking.rewardsAvailableDate(), block.timestamp + 86400 * 365);
    }

    function test_Constructor_WithDifferentOwner() public {
        address newOwner = makeAddr("newOwner");
        NairaPetalStaking newStaking =
            new NairaPetalStaking(newOwner, address(rewardsToken), address(stakingToken), address(mockAggregator));

        assertEq(newStaking.owner(), newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RewardPerToken_WithZeroTotalSupply() public view {
        uint256 result = nairaPetalStaking.rewardPerToken();
        assertEq(result, 0);
    }

    function test_RewardPerToken_WithNonZeroTotalSupply() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600); // 1 hour

        uint256 result = nairaPetalStaking.rewardPerToken();
        uint256 expected = 100 * 3600 * (1e18 * 2 / uint256(365 days)) * 1e18 / 100e18; // timeElapsed * rewardRate * 1e18 / totalSupply
        assertEq(result, expected);
    }

    function test_Earned_WithoutStaking() public view {
        uint256 result = nairaPetalStaking.earned(user1);
        assertEq(result, 0);
    }

    function test_Earned_WithStaking() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600); // 1 hour

        uint256 result = nairaPetalStaking.earned(user1);
        uint256 expected = 100 * 3600 * (1e18 * 2 / uint256(365 days)); // 100 tokens * 1 hour * 1 token per second / 0.5 token rate
        assertEq(result, expected);
    }

    function test_GetRewardForDuration_ReturnsCorrectValue() public {
        nairaPetalStaking.setRewardYieldForYear(1e18);
        uint256 result = nairaPetalStaking.getRewardForDuration();
        uint256 expected = (1e18 * 2 / uint256(365 days)) * (86400 * 14); // Should use rewardsDuration instead
        assertEq(result, expected);
    }

    /*//////////////////////////////////////////////////////////////
                             STAKING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Stake_Success() public {
        uint256 amount = 100e18;

        // Set up rewards so staking is allowed
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), amount);

        vm.expectEmit(true, true, false, true);
        emit Staked(user1, amount);

        nairaPetalStaking.stake(amount);

        assertEq(nairaPetalStaking.balanceOf(user1), amount);
        assertEq(nairaPetalStaking.totalSupply(), amount);
        assertEq(stakingToken.balanceOf(address(nairaPetalStaking)), amount);
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_AmountIsZero() public {
        // Add user to whitelist first
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 0);

        vm.expectRevert(abi.encodeWithSelector(CannotStakeZero.selector));
        nairaPetalStaking.stake(0);
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_InsufficientRewards() public {
        // Add user to whitelist first
        nairaPetalStaking.addToWhitelist(user1);

        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1e18);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);

        uint256 available = 1e18;
        // rounding makes it hard so just put the value directly
        uint256 required = 7671232876648320000;

        vm.expectRevert(abi.encodeWithSelector(NotEnoughRewards.selector, available, required));
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();
    }

    function test_Stake_UpdatesRewards() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // First stake
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        // Second stake should update rewards
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);

        uint256 rewards = nairaPetalStaking.rewards(user1);
        assertGt(rewards, 0);
        vm.stopPrank();
    }

    function test_Stake_TransferShareTokens_UpdatesRewards() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        uint256 rewardsPerHour = 2 * 100e18 * 3600 / uint256(365 days);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        uint256 user1Rewards = nairaPetalStaking.earned(user1);
        assertApproxEqAbs(user1Rewards, rewardsPerHour, 1000000, "first hour rewards");

        // User transfers share tokens to user2
        vm.startPrank(user1);
        nairaPetalStaking.transfer(user2, 50e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        // Both user1 and user2 should be able to receive their corresponding rewards
        user1Rewards = nairaPetalStaking.earned(user1);
        uint256 user2Rewards = nairaPetalStaking.earned(user2);
        assertApproxEqAbs(user1Rewards, rewardsPerHour + rewardsPerHour / 2, 1000000, "second hour rewards user1");
        // half of the rewards because user2 only has half the shares for half of the time
        assertApproxEqAbs(user2Rewards, rewardsPerHour / 2, 1000000, "second hour rewards user2");
    }

    /*//////////////////////////////////////////////////////////////
                             unstakeAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_unstake_RevertWhen_BeforeRewardsAvailableDate() public {
        // Set up staking first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(2000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsNotAvailableYet.selector, block.timestamp, nairaPetalStaking.rewardsAvailableDate()
            )
        );
        nairaPetalStaking.unstake(50e18);
        vm.stopPrank();
    }

    function test_unstake_RevertWhen_AmountIsZero() public {
        // Release rewards and add user to whitelist first
        nairaPetalStaking.releaseRewards();
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(CannotunstakeZero.selector));
        nairaPetalStaking.unstake(0);
        vm.stopPrank();
    }

    function test_unstake_Success() public {
        // Set up staking first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(2000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Release rewards
        nairaPetalStaking.releaseRewards();

        uint256 unstakeAmount = 50e18;
        uint256 initialBalance = stakingToken.balanceOf(user1);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Unstaked(user1, unstakeAmount);

        nairaPetalStaking.unstake(unstakeAmount);

        assertEq(nairaPetalStaking.balanceOf(user1), 50e18);
        assertEq(nairaPetalStaking.totalSupply(), 50e18);
        assertEq(stakingToken.balanceOf(user1), initialBalance + unstakeAmount);
        vm.stopPrank();
    }

    function test_unstake_SuccessWhenRebalanceFails() public {
        // Set up staking first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(2000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Release rewards
        nairaPetalStaking.releaseRewards();

        uint256 unstakeAmount = 50e18;

        mockAggregator.setLatestRoundDataShouldRevert(true);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Unstaked(user1, unstakeAmount);

        nairaPetalStaking.unstake(unstakeAmount);

        vm.expectRevert("latestRoundData reverted");
        nairaPetalStaking.rebalance();
    }

    function test_unstake_RevertWhen_InsufficientBalance() public {
        // Set up staking first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(2000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Release rewards
        nairaPetalStaking.releaseRewards();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 100e18, 200e18));
        nairaPetalStaking.unstake(200e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             REWARD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetReward_RevertWhen_BeforeRewardsAvailableDate() public {
        // Add user to whitelist first
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardsNotAvailableYet.selector, block.timestamp, nairaPetalStaking.rewardsAvailableDate()
            )
        );
        nairaPetalStaking.getReward();
        vm.stopPrank();
    }

    function test_GetReward_WithNoRewards() public {
        // Release rewards and add user to whitelist
        nairaPetalStaking.releaseRewards();
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        nairaPetalStaking.getReward(); // Should not revert, just do nothing
        vm.stopPrank();
    }

    function test_GetReward_Success() public {
        // Set up staking and rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward to accumulate rewards
        skip(3600);

        // Release rewards
        nairaPetalStaking.releaseRewards();

        uint256 expectedReward = nairaPetalStaking.earned(user1);
        uint256 initialBalance = rewardsToken.balanceOf(user1);

        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit RewardPaid(user1, expectedReward);

        nairaPetalStaking.getReward();

        assertEq(nairaPetalStaking.rewards(user1), 0);
        assertEq(rewardsToken.balanceOf(user1), initialBalance + expectedReward);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             EXIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Exit_Success() public {
        // Set up staking and rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward to accumulate rewards
        skip(3600);

        // Release rewards
        nairaPetalStaking.releaseRewards();

        uint256 expectedReward = nairaPetalStaking.earned(user1);
        uint256 stakedAmount = nairaPetalStaking.balanceOf(user1);
        uint256 initialStakingBalance = stakingToken.balanceOf(user1);
        uint256 initialRewardsBalance = rewardsToken.balanceOf(user1);

        vm.startPrank(user1);
        nairaPetalStaking.exit();

        assertEq(nairaPetalStaking.balanceOf(user1), 0);
        assertEq(nairaPetalStaking.rewards(user1), 0);
        assertEq(stakingToken.balanceOf(user1), initialStakingBalance + stakedAmount);
        assertEq(rewardsToken.balanceOf(user1), initialRewardsBalance + expectedReward);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReleaseRewards_Success() public {
        uint256 oldDate = nairaPetalStaking.rewardsAvailableDate();

        nairaPetalStaking.releaseRewards();

        assertEq(nairaPetalStaking.rewardsAvailableDate(), block.timestamp);
        assertLt(nairaPetalStaking.rewardsAvailableDate(), oldDate);
    }

    function test_ReleaseRewards_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.releaseRewards();
        vm.stopPrank();
    }

    function test_SetRewardRate_Success() public {
        uint256 newRate = 5e18;

        nairaPetalStaking.setRewardYieldForYear(newRate);

        assertEq(nairaPetalStaking.rewardRate(), newRate * 2 / 365 days);
    }

    function test_SetRewardRate_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.setRewardYieldForYear(5e18);
        vm.stopPrank();
    }

    function test_SetRewardYieldForYear_ChangeAfterUserDeposit() public {
        // Set initial reward rate and supply rewards
        nairaPetalStaking.setRewardYieldForYear(1e18); // 1 token per year
        nairaPetalStaking.supplyRewards(5000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 300e18);
        nairaPetalStaking.stake(300e18);
        vm.stopPrank();

        // Move time forward by 1 hour (should earn at 1e18/year rate)
        skip(3600); // 1 hour

        // Calculate expected rewards at old rate
        uint256 expectedRewardsOldRate = 300 * 3600 * (1e18 * 2 / uint256(365 days));
        uint256 earnedAfterFirstHour = nairaPetalStaking.earned(user1);
        assertEq(earnedAfterFirstHour, expectedRewardsOldRate);

        // Change reward rate to 2 tokens per year
        nairaPetalStaking.setRewardYieldForYear(2e18);

        // Verify rate changed
        assertEq(nairaPetalStaking.rewardRate(), 2e18 * 2 / uint256(365 days));

        // Move time forward by another hour (should earn at 2e18/year rate)
        skip(3600); // Another hour

        // Calculate total expected rewards: 1 hour at old rate + 1 hour at new rate
        uint256 expectedRewardsNewRate = 300 * 3600 * (2e18 * 2 / uint256(365 days));
        uint256 totalExpectedRewards = expectedRewardsOldRate + expectedRewardsNewRate;

        uint256 earnedAfterRateChange = nairaPetalStaking.earned(user1);
        assertEq(earnedAfterRateChange, totalExpectedRewards);

        // stake again to make sure rewards are preserved
        mockAggregator.setLatestAnswer(1e8 / 2, block.timestamp);
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 200e18);
        nairaPetalStaking.stake(200e18);
        vm.stopPrank();

        assertEq(nairaPetalStaking.balanceOf(user1), 500e18);

        // Verify rewards are preserved when rate changes by checking stored rewards
        // The updateReward modifier should have stored the accumulated rewards
        uint256 storedRewards = nairaPetalStaking.rewards(user1);
        assertEq(storedRewards, totalExpectedRewards);
        uint256 earnedAfterFirstStake = nairaPetalStaking.earned(user1);
        assertEq(earnedAfterFirstStake, totalExpectedRewards);

        // move time forward to make sure rewards are still preserved
        skip(3600);

        // verify rewards are still preserved
        expectedRewardsNewRate = 500 * 3600 * (2e18 * 2 / uint256(365 days));
        totalExpectedRewards += expectedRewardsNewRate;

        uint256 earnedAfterSecondStake = nairaPetalStaking.earned(user1);
        assertEq(earnedAfterSecondStake, totalExpectedRewards);
    }

    function test_SupplyRewards_Success() public {
        nairaPetalStaking.setRewardYieldForYear(1e18);

        vm.expectEmit(true, false, false, true);
        emit RewardAdded(1000e18);

        nairaPetalStaking.supplyRewards(1000e18);

        assertEq(nairaPetalStaking.lastUpdateTime(), block.timestamp);
    }

    function test_SupplyRewards_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.supplyRewards(1000e18);
        vm.stopPrank();
    }

    function test_RecoverERC20_Success() public {
        uint256 amount = 100e18;
        otherToken.transfer(address(nairaPetalStaking), amount);

        uint256 initialBalance = otherToken.balanceOf(owner);

        vm.expectEmit(true, false, false, true);
        emit Recovered(address(otherToken), amount);

        nairaPetalStaking.recoverERC20(address(otherToken), amount);

        assertEq(otherToken.balanceOf(owner), initialBalance + amount);
    }

    function test_RecoverERC20_RevertWhen_StakingToken() public {
        vm.expectRevert(abi.encodeWithSelector(CannotunstakeStakingToken.selector, address(stakingToken)));
        nairaPetalStaking.recoverERC20(address(stakingToken), 100e18);
    }

    function test_RecoverERC20_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.recoverERC20(address(otherToken), 100e18);
        vm.stopPrank();
    }

    function test_Reclaim_Success() public {
        uint256 amount = 1000e18;
        nairaPetalStaking.supplyRewards(amount);
        uint256 initialBalance = rewardsToken.balanceOf(owner);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        mockAggregator.setLatestAnswer(1e8, block.timestamp);
        nairaPetalStaking.reclaim();

        assertEq(rewardsToken.balanceOf(owner), initialBalance + amount);
        assertEq(rewardsToken.balanceOf(address(nairaPetalStaking)), 0);

        // deposited users can still pull their original staked tokens
        vm.startPrank(user1);
        nairaPetalStaking.exit();
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        assertEq(stakingToken.balanceOf(user1), 1000e18);
        assertEq(rewardsToken.balanceOf(user1), 0);
    }

    function test_Reclaim_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.reclaim();
        vm.stopPrank();
    }

    function test_Rebalance_Success() public {
        // Set target APY to 1 token per year
        uint256 targetApy = 1e18;
        nairaPetalStaking.setRewardYieldForYear(targetApy);

        // Verify initial state - aggregator is set to 0.5 (1e18 / 2) in setUp
        int256 initialRate = 1e18 / 2; // 0.5 tokens per USD
        uint256 expectedRewardRate = targetApy * 1e18 / uint256(initialRate) / 365 days;
        assertEq(nairaPetalStaking.rewardRate(), expectedRewardRate);

        // Change aggregator rate to 0.25 (token price doubled)
        mockAggregator.setLatestAnswer(1e8 / 4, block.timestamp);

        // Call rebalance
        nairaPetalStaking.rebalance();

        // Verify reward rate updated correctly
        uint256 newExpectedRewardRate = targetApy * 1e18 / uint256(1e18 / 4) / 365 days;
        assertEq(nairaPetalStaking.rewardRate(), newExpectedRewardRate);

        // New rate should be double the original (since token price halved)
        assertApproxEqAbs(nairaPetalStaking.rewardRate(), expectedRewardRate * 2, 10);
    }

    function test_Rebalance_UpdatesRewards() public {
        // Set up staking scenario
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward to accumulate rewards
        skip(3600); // 1 hour

        uint256 earnedBefore = nairaPetalStaking.earned(user1);
        assertGt(earnedBefore, 0);

        // Change the aggregator rate and rebalance
        mockAggregator.setLatestAnswer(1e8, block.timestamp); // Rate changes from 0.5 to 1.0
        nairaPetalStaking.rebalance();

        // Rewards should be preserved due to updateReward modifier
        uint256 earnedAfter = nairaPetalStaking.earned(user1);
        assertEq(earnedAfter, earnedBefore);
    }

    function test_Rebalance_WithZeroTargetApy() public {
        // Set target APY to 0
        nairaPetalStaking.setRewardYieldForYear(0);

        // Change aggregator rate
        mockAggregator.setLatestAnswer(1e8, block.timestamp);

        // Rebalance should result in 0 reward rate
        nairaPetalStaking.rebalance();
        assertEq(nairaPetalStaking.rewardRate(), 0);
    }

    function test_Rebalance_RevertWhen_PriceFeedReturnsZero() public {
        // Set target APY
        nairaPetalStaking.setRewardYieldForYear(1e18);

        // Set aggregator to return zero rate
        mockAggregator.setLatestAnswer(0, block.timestamp);

        // Rebalance should revert with InvalidPriceFeed
        vm.expectRevert(abi.encodeWithSelector(InvalidPriceFeed.selector, block.timestamp, int256(0)));
        nairaPetalStaking.rebalance();
    }

    function test_Rebalance_RevertWhen_PriceFeedIsStale() public {
        // Set target APY
        nairaPetalStaking.setRewardYieldForYear(1e18);

        // Set aggregator with stale data (2 days old)
        uint256 staleTimestamp = block.timestamp - 2 days;
        mockAggregator.setLatestAnswer(1e8 / 2, staleTimestamp);

        // Rebalance should revert with InvalidPriceFeed
        vm.expectRevert(abi.encodeWithSelector(InvalidPriceFeed.selector, staleTimestamp, int256(1e8 / 2)));
        nairaPetalStaking.rebalance();
    }

    function test_Rebalance_RevertWhen_PriceFeedIsStaleExactly1Day1Hour() public {
        // Set target APY
        nairaPetalStaking.setRewardYieldForYear(1e18);

        // Set aggregator with data exactly 1 day + 1 hour old (should still revert)
        uint256 staleTimestamp = block.timestamp - 1 days - 1 hours - 1;
        mockAggregator.setLatestAnswer(1e8 / 2, staleTimestamp);

        // Rebalance should revert with InvalidPriceFeed
        vm.expectRevert(abi.encodeWithSelector(InvalidPriceFeed.selector, staleTimestamp, int256(1e8 / 2)));
        nairaPetalStaking.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                             MODIFIER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateReward_WithZeroAddress() public {
        nairaPetalStaking.setRewardYieldForYear(1e18);

        // This should work without reverting
        nairaPetalStaking.supplyRewards(1000e18);
    }

    function test_UpdateReward_WithValidAddress() public {
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        rewardsToken.transfer(address(nairaPetalStaking), 2000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward
        skip(3600);

        // Another action should update rewards
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);

        assertGt(nairaPetalStaking.rewards(user1), 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Stake_ValidAmounts(uint96 amount) public {
        // Bound to reasonable values
        amount = uint96(bound(amount, 1, 1000e18));

        // Setup rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        rewardsToken.transfer(address(nairaPetalStaking), 10000e18);

        // Give user enough tokens
        stakingToken.mint(user1, amount);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), amount);
        nairaPetalStaking.stake(amount);

        assertEq(nairaPetalStaking.balanceOf(user1), amount);
        vm.stopPrank();
    }

    function testFuzz_unstake_ValidAmounts(uint96 stakeAmount, uint96 unstakeAmount) public {
        // Bound to reasonable values
        stakeAmount = uint96(bound(stakeAmount, 1, 1000e18));
        unstakeAmount = uint96(bound(unstakeAmount, 1, stakeAmount));

        // Setup rewards and staking
        nairaPetalStaking.setRewardYieldForYear(1e18);
        rewardsToken.transfer(address(nairaPetalStaking), 10000e18);
        stakingToken.mint(user1, stakeAmount);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), stakeAmount);
        nairaPetalStaking.stake(stakeAmount);
        vm.stopPrank();

        // Release rewards
        nairaPetalStaking.releaseRewards();

        vm.startPrank(user1);
        nairaPetalStaking.unstake(unstakeAmount);

        assertEq(nairaPetalStaking.balanceOf(user1), stakeAmount - unstakeAmount);
        vm.stopPrank();
    }

    function testFuzz_RewardRate_ValidRates(uint96 rate) public {
        // Bound to reasonable values (not too high to avoid overflow)
        rate = uint96(bound(rate, 1, 1000e18));

        nairaPetalStaking.setRewardYieldForYear(rate);

        assertEq(nairaPetalStaking.rewardRate(), rate * 2 / 365 days);
    }

    /*//////////////////////////////////////////////////////////////
                             INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_CompleteFlow() public {
        // 1. Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        rewardsToken.transfer(address(nairaPetalStaking), 5000e18);

        // 2. Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // 3. User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // 4. Time passes
        skip(3600);

        // 5. Check earned rewards
        uint256 earned = nairaPetalStaking.earned(user1);
        assertEq(earned, 100 * 3600 * (1e18 * 2 / uint256(365 days)));

        // 6. Release rewards
        nairaPetalStaking.releaseRewards();

        // 7. User exits
        vm.startPrank(user1);
        nairaPetalStaking.exit();
        vm.stopPrank();

        // 8. Verify final state
        assertEq(nairaPetalStaking.balanceOf(user1), 0);
        assertEq(nairaPetalStaking.rewards(user1), 0);
        assertEq(rewardsToken.balanceOf(user1), earned);
    }

    function test_Integration_MultipleUsers() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(2e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add users to whitelist
        nairaPetalStaking.addToWhitelist(user1);
        nairaPetalStaking.addToWhitelist(user2);

        // User1 stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Time passes
        skip(1800); // 30 minutes

        // User2 stakes
        vm.startPrank(user2);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // More time passes
        skip(1800); // Another 30 minutes

        // Check rewards
        uint256 user1Earned = nairaPetalStaking.earned(user1);
        uint256 user2Earned = nairaPetalStaking.earned(user2);

        // User1 should have more rewards (staked earlier)
        assertGt(user1Earned, user2Earned);

        // Total rewards should be reasonable
        assertApproxEqAbs(user1Earned + user2Earned, 100 * 3600 * 2e18 / uint256(365 days), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                             WHITELIST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Whitelist_InitialState() public view {
        // Initially no addresses should be whitelisted
        assertFalse(nairaPetalStaking.isWhitelisted(user1));
        assertFalse(nairaPetalStaking.isWhitelisted(user2));
        assertFalse(nairaPetalStaking.isWhitelisted(owner));
    }

    function test_AddToWhitelist_Success() public {
        vm.expectEmit(true, false, false, true);
        emit WhitelistAdded(user1);

        nairaPetalStaking.addToWhitelist(user1);

        assertTrue(nairaPetalStaking.isWhitelisted(user1));
        assertFalse(nairaPetalStaking.isWhitelisted(user2));
    }

    function test_AddToWhitelist_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.addToWhitelist(user2);
        vm.stopPrank();
    }

    function test_RemoveFromWhitelist_Success() public {
        // First add to whitelist
        nairaPetalStaking.addToWhitelist(user1);
        assertTrue(nairaPetalStaking.isWhitelisted(user1));

        vm.expectEmit(true, false, false, true);
        emit WhitelistRemoved(user1);

        nairaPetalStaking.removeFromWhitelist(user1);

        assertFalse(nairaPetalStaking.isWhitelisted(user1));
    }

    function test_RemoveFromWhitelist_RevertWhen_NotOwner() public {
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.removeFromWhitelist(user1);
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_NotWhitelisted() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);

        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();
    }

    function test_Stake_SuccessWhen_Whitelisted() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);

        vm.expectEmit(true, true, false, true);
        emit Staked(user1, 100e18);

        nairaPetalStaking.stake(100e18);

        assertEq(nairaPetalStaking.balanceOf(user1), 100e18);
        vm.stopPrank();
    }

    function test_Stake_OnlyWhitelistedUsersCanStake() public {
        // Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // Add only user1 to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // user1 can stake
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // user2 cannot stake
        vm.startPrank(user2);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user2));
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        assertEq(nairaPetalStaking.balanceOf(user1), 100e18);
        assertEq(nairaPetalStaking.balanceOf(user2), 0);
    }

    function test_unstakeAndGetReward_WorkAfterWhitelistRemoval() public {
        // Set up rewards and whitelist user
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        nairaPetalStaking.addToWhitelist(user1);

        // User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward and release rewards
        skip(3600);
        nairaPetalStaking.releaseRewards();

        // User should be able to unstake and get rewards while still whitelisted
        vm.startPrank(user1);
        nairaPetalStaking.unstake(50e18);
        nairaPetalStaking.getReward();
        vm.stopPrank();

        assertEq(nairaPetalStaking.balanceOf(user1), 50e18);
        assertGt(rewardsToken.balanceOf(user1), 0);
    }

    function test_unstake_RevertWhen_NotWhitelisted() public {
        // Set up staking first (user needs to be whitelisted to stake)
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(2000e18);
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Remove user from whitelist and release rewards
        nairaPetalStaking.removeFromWhitelist(user1);
        nairaPetalStaking.releaseRewards();

        // User should not be able to unstake after being removed from whitelist
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        nairaPetalStaking.unstake(50e18);
        vm.stopPrank();
    }

    function test_GetReward_RevertWhen_NotWhitelisted() public {
        // Set up staking and rewards first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward and release rewards
        skip(3600);
        nairaPetalStaking.releaseRewards();

        // Remove user from whitelist
        nairaPetalStaking.removeFromWhitelist(user1);

        // User should not be able to get rewards after being removed from whitelist
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        nairaPetalStaking.getReward();
        vm.stopPrank();
    }

    function test_Exit_RevertWhen_NotWhitelisted() public {
        // Set up staking first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Release rewards and remove from whitelist
        nairaPetalStaking.releaseRewards();
        nairaPetalStaking.removeFromWhitelist(user1);

        // User should not be able to exit after being removed from whitelist
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        nairaPetalStaking.exit();
        vm.stopPrank();
    }

    function test_Integration_WhitelistFlow() public {
        // 1. Set up rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);

        // 2. Add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // 3. User stakes
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // 4. Remove user from whitelist
        nairaPetalStaking.removeFromWhitelist(user1);

        // 5. User cannot stake more
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // 6. Re-add user to whitelist
        nairaPetalStaking.addToWhitelist(user1);

        // 7. User can stake again
        vm.startPrank(user1);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        assertEq(nairaPetalStaking.balanceOf(user1), 200e18);
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_InitialState() public view {
        // Contract should not be paused initially
        assertFalse(nairaPetalStaking.paused());
    }

    function test_Pause_Success() public {
        vm.expectEmit(true, false, false, true);
        emit Paused(owner);

        nairaPetalStaking.pause();

        assertTrue(nairaPetalStaking.paused());
    }

    function test_Pause_RevertWhen_NotOwner() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.pause();
        vm.stopPrank();
    }

    function test_Unpause_Success() public {
        // First pause
        nairaPetalStaking.pause();
        assertTrue(nairaPetalStaking.paused());

        vm.expectEmit(true, false, false, true);
        emit Unpaused(owner);

        nairaPetalStaking.unpause();

        assertFalse(nairaPetalStaking.paused());
    }

    function test_Unpause_RevertWhen_NotOwner() public {
        nairaPetalStaking.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        nairaPetalStaking.unpause();
        vm.stopPrank();
    }

    function test_Stake_RevertWhen_Paused() public {
        // Set up rewards and whitelist
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        nairaPetalStaking.addToWhitelist(user1);

        // Pause the contract
        nairaPetalStaking.pause();

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);

        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();
    }

    function test_unstake_RevertWhen_Paused() public {
        // Set up staking first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(2000e18);
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Release rewards and pause
        nairaPetalStaking.releaseRewards();
        nairaPetalStaking.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        nairaPetalStaking.unstake(50e18);
        vm.stopPrank();
    }

    function test_GetReward_RevertWhen_Paused() public {
        // Set up staking and rewards
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Move time forward and release rewards
        skip(3600);
        nairaPetalStaking.releaseRewards();

        // Pause the contract
        nairaPetalStaking.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        nairaPetalStaking.getReward();
        vm.stopPrank();
    }

    function test_Exit_RevertWhen_Paused() public {
        // Set up staking first
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        nairaPetalStaking.addToWhitelist(user1);

        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // Release rewards and pause
        nairaPetalStaking.releaseRewards();
        nairaPetalStaking.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        nairaPetalStaking.exit();
        vm.stopPrank();
    }

    function test_OwnerFunctions_WorkWhen_Paused() public {
        // Owner functions should still work when paused
        nairaPetalStaking.pause();

        // These should all work
        nairaPetalStaking.addToWhitelist(user1);
        nairaPetalStaking.removeFromWhitelist(user1);
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(100e18);
        nairaPetalStaking.releaseRewards();

        assertTrue(nairaPetalStaking.paused());
    }

    function test_Integration_PauseUnpauseFlow() public {
        // 1. Set up rewards and whitelist
        nairaPetalStaking.setRewardYieldForYear(1e18);
        nairaPetalStaking.supplyRewards(1000e18);
        nairaPetalStaking.addToWhitelist(user1);

        // 2. User stakes successfully
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // 3. Pause contract
        nairaPetalStaking.pause();

        // 4. User cannot stake more
        vm.startPrank(user1);
        stakingToken.approve(address(nairaPetalStaking), 100e18);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        // 5. Unpause contract
        nairaPetalStaking.unpause();

        // 6. User can stake again
        vm.startPrank(user1);
        nairaPetalStaking.stake(100e18);
        vm.stopPrank();

        assertEq(nairaPetalStaking.balanceOf(user1), 200e18);
        assertFalse(nairaPetalStaking.paused());
    }
}
