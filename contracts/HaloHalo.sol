// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.6.12;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeMath} from '@openzeppelin/contracts/math/SafeMath.sol';

contract HaloHalo is ERC20('HaloHalo', 'HALOHALO') {
  using SafeMath for uint256;
  IERC20 public halo;
  uint256 public constant DECIMALS = 10**18;
  uint256 public APY;
  HaloHaloPrice public latestHaloHaloPrice;

  // Define the Halo token contract
  constructor(IERC20 _halo) public {
    halo = _halo;
  }

  struct HaloHaloPrice {
    uint256 lastHaloHaloUpdateTimestamp;
    uint256 lastHaloHaloPrice;
  }

  event HaloHaloPriceUpdated(
    uint256 lastHaloHaloUpdateTimestamp,
    uint256 lastHaloHaloPrice
  );

  // Stake HALOs for HALOHALOs.
  // Locks Halo and mints HALOHALO
  function enter(uint256 _amount) public {
    // Gets the amount of Halo locked in the contract
    uint256 totalHalo = halo.balanceOf(address(this));
    // Gets the amount of HALOHALO in existence
    uint256 totalShares = totalSupply();
    // If no HALOHALO exists, mint it 1:1 to the amount put in
    if (totalShares == 0 || totalHalo == 0) {
      _mint(msg.sender, _amount);
    } else {
      // Calculate and mint the amount of HALOHALO the Halo is worth. The ratio will change overtime, as HALOHALO is burned/minted and Halo deposited from LP rewards.
      uint256 haloHaloAmount = _amount.mul(totalShares).div(totalHalo);
      _mint(msg.sender, haloHaloAmount);
    }

    // Lock the Halo in the contract
    halo.transferFrom(msg.sender, address(this), _amount);
  }

  // Claim HALOs from HALOHALOs.
  // Unlocks the staked + gained Halo and burns HALOHALO
  function leave(uint256 _share) public {
    // Gets the amount of HALOHALO in existence
    uint256 totalShares = totalSupply();
    // Calculates the amount of Halo the HALOHALO is worth
    uint256 haloHaloAmount =
      _share.mul(halo.balanceOf(address(this))).div(totalShares);
    _burn(msg.sender, _share);
    halo.transfer(msg.sender, haloHaloAmount);
  }

  function updateHaloHaloPrice() public {
    uint256 totalShares = totalSupply();
    require(totalShares > 0, 'No HALOHALO supply');
    uint256 haloHaloPrice = halo.balanceOf(address(this)).div(totalShares);
    // unixtimestamp
    latestHaloHaloPrice.lastHaloHaloUpdateTimestamp = now;
    // ratio in wei
    latestHaloHaloPrice.lastHaloHaloPrice = haloHaloPrice.mul(DECIMALS);

    // using the newly set values to avoid timestamp differences
    emit HaloHaloPriceUpdated(
      latestHaloHaloPrice.lastHaloHaloUpdateTimestamp,
      latestHaloHaloPrice.lastHaloHaloPrice
    );
  }

  function estimateHaloHaloAPY() public returns (uint256) {
    // get old halohalo values
    uint256 oldHaloHaloPrice = latestHaloHaloPrice.lastHaloHaloPrice;
    uint256 oldHaloHaloLastUpdateTimestamp =
      latestHaloHaloPrice.lastHaloHaloUpdateTimestamp;

    // update price
    updateHaloHaloPrice();

    // calculate interval changes
    uint256 haloHaloPriceChange =
      latestHaloHaloPrice.lastHaloHaloPrice.sub(oldHaloHaloPrice);

    uint256 updateIntervalDuration = now.sub(oldHaloHaloLastUpdateTimestamp);

    // calculate ratio by dividing it to number of seconds in a year, pad decimal zeroes to support decimal values
    uint256 APYDurationRatio =
      updateIntervalDuration.mul(DECIMALS).div(31536000);
    uint256 APYProjection = haloHaloPriceChange.mul(APYDurationRatio);
    // remove padding
    APY = APYProjection.div(DECIMALS);
  }
}