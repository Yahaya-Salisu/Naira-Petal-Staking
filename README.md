# FixedStakingRewards

A modernized version of the Synthetix StakingRewards contract with fixed reward rates and additional security features.

## Overview

FixedStakingRewards is a staking contract that allows users to stake tokens and earn rewards at a fixed rate. It's based on the Synthetix StakingRewards contract but has been significantly modernized and modified to account for new requirements.

## Key Features & Changes

### Modernized Solidity Standards

- **Solidity ^0.8.29**: Uses the latest Solidity version with built-in overflow protection
- **Custom Errors**: Replaced `require` statements with gas-efficient custom errors
- **Modern OpenZeppelin Contracts**: Uses latest versions of OpenZeppelin libraries

### Updated Reward Rate System

- **Fixed APY**: Uses a fixed Annual Percentage Yield instead of a floating rate based on the number of deposited tokens
- **Owner-Controlled**: Only owner can set reward rates via `setRewardYieldForYear()`
- **2-Week Minimum**: Contract ensures there are enough rewards for at least 2 weeks before allowing deposit

### Delayed Reward Access

- **Rewards Available Date**: Withdrawals and reward claims blocked until `rewardsAvailableDate`
- **Early Release**: Owner can call `releaseRewards()` to enable withdrawals early
- **Default Lock**: Initially set to 1 year from deployment (`block.timestamp + 86400 * 365`)

### Owner Functions

- **No Reward Distributor**: Removed the rewardDistributor role, owner handles all admin functions
- **Direct Control**: Owner has direct access to all administrative functions
- **Reclaim Function**: Owner can recover previously supplied and unclaimed rewards with `reclaim()`

## Usage

### Development Setup

This project uses Foundry for development and testing.

```shell
# Install dependencies
forge install

# Build the project
forge build

# Run tests
forge test

# Format code
forge fmt
```

### Deployment

This project uses [Cannon](https://usecannon.com) for deployments.

```shell

```

## Security Considerations

- **Minimum Reward Guarantee**: The contract ensures there are always enough rewards for at least 2 weeks of staking upon supply (after 2 weeks more would need to be deposited)
- **Pausable**: Can be paused in emergency situations

## License

MIT
