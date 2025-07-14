// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";

// Inheritance
import "./interfaces/IStakingRewards.sol";
import {console} from "forge-std/console.sol";

/* ========== CUSTOM ERRORS ========== */

error CannotStakeZero();
error NotEnoughRewards(uint256 available, uint256 required);
error RewardsNotAvailableYet(uint256 currentTime, uint256 availableTime);
error CannotWithdrawZero();
error CannotWithdrawStakingToken(address attemptedToken);
error PreviousRewardsPeriodNotComplete(uint256 currentTime, uint256 periodFinish);
error ContractIsPaused();

contract FixedStakingRewards is IStakingRewards, ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    
    /* ========== STATE VARIABLES ========== */

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public rewardsAvailableDate;
    uint256 public periodFinish = 0;
    uint256 public rewardsDuration = 86400 * 14; // 14 days

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsToken,
        address _stakingToken
    ) ERC20("FixedStakingRewards", "FSR") Ownable(_owner) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsAvailableDate = block.timestamp + 86400 * 365;
    }

    /* ========== VIEWS ========== */

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored +
                (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
    }

    function earned(address account) public override view returns (uint256) {
        return (balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    function getRewardForDuration() public override view returns (uint256) {
        return rewardRate * 14 days;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert CannotStakeZero();

        uint256 requiredRewards = (totalSupply() + amount) * getRewardForDuration() / 1e18;
        if (requiredRewards > rewardsToken.balanceOf(address(this))) {
            revert NotEnoughRewards(
                rewardsToken.balanceOf(address(this)),
                requiredRewards
            );
        }

        _mint(msg.sender, amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        if (block.timestamp < rewardsAvailableDate) revert RewardsNotAvailableYet(block.timestamp, rewardsAvailableDate);
        if (amount == 0) revert CannotWithdrawZero();
        _burn(msg.sender, amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        if (block.timestamp < rewardsAvailableDate) revert RewardsNotAvailableYet(block.timestamp, rewardsAvailableDate);
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external override {
        withdraw(balanceOf(msg.sender));
        getReward();
    }

    function reclaim() external onlyOwner {
        // contract is effectively shut down
        rewardsAvailableDate = block.timestamp;
        rewardRate = 0;
        rewardPerTokenStored = 0;
        rewardsToken.safeTransfer(owner(), rewardsToken.balanceOf(address(this)));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function releaseRewards() external onlyOwner {
        rewardsAvailableDate = block.timestamp;
    }

    function setRewardYieldForYear(uint256 rewardApy) external onlyOwner updateReward(address(0)) {
        rewardRate = rewardApy / 365 days;
    }

    function supplyRewards(uint256 reward) external onlyOwner updateReward(address(0)) {
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        if (tokenAddress == address(stakingToken)) revert CannotWithdrawStakingToken(tokenAddress);
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        if (block.timestamp <= periodFinish) {
            revert PreviousRewardsPeriodNotComplete(block.timestamp, periodFinish);
        }
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}