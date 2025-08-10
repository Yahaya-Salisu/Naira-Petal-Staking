// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";

// Inheritance
import "./interfaces/INairaPetalStaking.sol";
import "./interfaces/IChainlinkAggregator.sol";

/* ========== CUSTOM ERRORS ========== */

error CannotStakeZero();
error NotEnoughRewards(uint256 available, uint256 required);
error RewardsNotAvailableYet(uint256 currentTime, uint256 availableTime);
error CannotunstakeZero();
error CannotunstakeStakingToken(address attemptedToken);
error InvalidPriceFeed(uint256 updateTime, int256 currentRewardTokenRate);
error NotWhitelisted(address account);

contract NairaPetalStaking is INairaPetalStaking, ERC20Pausable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable rewardsToken;
    IERC20 public immutable stakingToken;
    IChainlinkAggregator public immutable rewardsTokenRateAggregator;
    uint256 public immutable rewardsTokenRateDecimals;
    uint256 public targetRewardApy = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public rewardsAvailableDate;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => bool) public whitelist;

    /* ========== CONSTRUCTOR ========== */

    constructor(address _owner, address _rewardsToken, address _stakingToken, address _rewardsTokenRateAggregator)
        ERC20("NairaPetalStaking", "NPS")
        Ownable(_owner)
    {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsTokenRateAggregator = IChainlinkAggregator(_rewardsTokenRateAggregator);
        rewardsTokenRateDecimals = rewardsTokenRateAggregator.decimals();
        rewardsAvailableDate = block.timestamp + 86400 * 365;
    }

    /* ========== VIEWS ========== */

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (block.timestamp - lastUpdateTime) * rewardRate;
    }

    function earned(address account) public view override returns (uint256) {
        return (balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    function getRewardForDuration() public view override returns (uint256) {
        return rewardRate * 14 days;
    }

    function isWhitelisted(address account) public view returns (bool) {
        return whitelist[account];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount)
        external
        override
        nonReentrant
        updateReward(msg.sender)
        onlyWhitelisted
        whenNotPaused
    {
        if (amount == 0) revert CannotStakeZero();

        _rebalance();

        uint256 requiredRewards = (totalSupply() + amount) * getRewardForDuration() / 1e18;
        if (requiredRewards > rewardsToken.balanceOf(address(this))) {
            revert NotEnoughRewards(rewardsToken.balanceOf(address(this)), requiredRewards);
        }

        _mint(msg.sender, amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount)
        public
        override
        nonReentrant
        updateReward(msg.sender)
        onlyWhitelisted
        whenNotPaused
    {
        if (block.timestamp < rewardsAvailableDate) {
            revert RewardsNotAvailableYet(block.timestamp, rewardsAvailableDate);
        }
        if (amount == 0) revert CannotunstakeZero();

        try NairaPetalStaking(address(this)).rebalance() {} catch {}

        _burn(msg.sender, amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function getReward() public override nonReentrant updateReward(msg.sender) onlyWhitelisted whenNotPaused {
        if (block.timestamp < rewardsAvailableDate) {
            revert RewardsNotAvailableYet(block.timestamp, rewardsAvailableDate);
        }
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external override onlyWhitelisted whenNotPaused {
        unstake(balanceOf(msg.sender));
        getReward();
    }

    function reclaim() external onlyOwner {
        // contract is effectively shut down
        rewardsAvailableDate = block.timestamp;
        targetRewardApy = 0;
        rewardRate = 0;
        rewardsToken.safeTransfer(owner(), rewardsToken.balanceOf(address(this)));
    }

    function rebalance() external updateReward(address(0)) {
        _rebalance();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function releaseRewards() external onlyOwner {
        rewardsAvailableDate = block.timestamp;
        emit RewardsMadeAvailable(block.timestamp);
    }

    function setRewardYieldForYear(uint256 rewardApy) external onlyOwner updateReward(address(0)) {
        targetRewardApy = rewardApy;
        _rebalance();
        emit RewardYieldSet(rewardApy);
    }

    function supplyRewards(uint256 reward) external onlyOwner updateReward(address(0)) {
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        if (tokenAddress == address(stakingToken)) revert CannotunstakeStakingToken(tokenAddress);
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function addToWhitelist(address account) external onlyOwner {
        whitelist[account] = true;
        emit WhitelistAdded(account);
    }

    function removeFromWhitelist(address account) external onlyOwner {
        whitelist[account] = false;
        emit WhitelistRemoved(account);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function _rebalance() internal {
        (, int256 currentRewardTokenRate,, uint256 updateTime,) = rewardsTokenRateAggregator.latestRoundData();
        if (currentRewardTokenRate == 0 || updateTime < block.timestamp - 1 days - 1 hours) {
            revert InvalidPriceFeed(updateTime, currentRewardTokenRate);
        }
        rewardRate = targetRewardApy * 1e18 / (uint256(currentRewardTokenRate) * 10 ** (18 - rewardsTokenRateDecimals))
            / 365 days;
    }

    function _update(address from, address to, uint256 value) internal override updateReward(from) updateReward(to) {
        super._update(from, to, value);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyWhitelisted() {
        if (!whitelist[msg.sender]) {
            revert NotWhitelisted(msg.sender);
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event Recovered(address token, uint256 amount);
    event RewardsMadeAvailable(uint256 timestampAvailable);
    event RewardYieldSet(uint256 apy);
    event WhitelistAdded(address indexed account);
    event WhitelistRemoved(address indexed account);
}
