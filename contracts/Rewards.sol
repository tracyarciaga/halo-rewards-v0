// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeMath} from '@openzeppelin/contracts/math/SafeMath.sol';
import {IMinter} from './interfaces/IMinter.sol';
import 'hardhat/console.sol';

///
/// User flow:
/// ========For AMM LPs=========
/// - User provides liquidity on AMMs like uniswap
/// - User takes the LP tokens received from uniswap and deposits in this rewards contract to earn rewards in HALO tokens
/// - User earns rewards per second based on the decay function and the amount of total LP tokens locked in this contract
/// - User can deposit and withdraw LP tokens any number of times. Each time they do that, the unclaimed HALO rewarsd are
/// automatically transferred to their account.
/// - User can then stake these HALO tokens inside the HaloChest contract to earn bonus rewards in HALO tokens.
/// ============================
///
/// =======For Minter LPs=======
/// - User mints synthetic stablecoins using the minter Dapp
/// - The minter contract calls the depositMinter function and the user starts earning HALO rewards based on the amount
///  of collateral they locked inside the minter contract.
/// - User earns rewards per second based on the decay function and the amount of total collateral locked by all users in the minter contract.
/// - User can mint and redeem collateral any number of times. Each time they do that, the unclaimed HALO rewarsd are
/// automatically transferred to their account.
/// - User can then stake these HALO tokens inside the HaloChest contract to earn bonus rewards in HALO tokens.
/// ============================
///
/// @title Rewards
/// @notice Rewards for participation in the halo ecosystem.
/// @dev Rewards for participation in the halo ecosystem.
contract Rewards is Ownable {
  /// @notice utility constant
  uint256 public constant DECIMALS = 10**18;
  /// @notice utility constant
  uint256 public constant BPS = 10**4;

  using SafeMath for uint256;

  /****************************************
   *                EVENTS                *
   ****************************************/

  event DepositAMMLPTokensEvent(
    address indexed user,
    address indexed lpAddress,
    uint256 amount
  );
  event WithdrawAMMLPTokensEvent(
    address indexed user,
    address indexed lpAddress,
    uint256 amount
  );
  event DepositMinterCollateralByAddress(
    address indexed user,
    address indexed collateralAddress,
    uint256 amount
  );
  event WithdrawMinterCollateralByAddress(
    address indexed user,
    address indexed collateralAddress,
    uint256 amount
  );
  event MinterRewardPoolRatioUpdatedEvent(
    address collateralAddress,
    uint256 accHaloPerShare,
    uint256 lastRewardTs
  );
  event AmmLPRewardUpdatedEvent(
    address lpAddress,
    uint256 accHaloPerShare,
    uint256 lastRewardTs
  );
  event VestedRewardsReleasedEvent(uint256 amount, uint256 timestamp);

  /****************************************
   *                VARIABLES              *
   ****************************************/

  struct UserInfo {
    uint256 amount; // How many collateral or LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
  }

  struct Pool {
    address poolAddress;
    uint256 allocPoint;
  }

  struct PoolInfo {
    bool whitelisted; // Address of LP token contract.
    uint256 allocPoint; // How many allocation points assigned to this pool. Used to calculate ratio of rewards for this amm pool out of total
    uint256 lastRewardTs; // Last block number that HALO distribution occured.
    uint256 accHaloPerShare; // Accumulated HALO per share, times 10^18.
  }

  /// @notice address of the halo erc20 token
  address public haloTokenAddress;
  /// @notice timestamp of rewards genesis
  uint256 public genesisTs;
  /// @notice rewards allocated for the first month
  uint256 public startingRewards;
  /// @notice decay base
  uint256 public decayBase; //multiply fraction by 10^18, keeps decimals consistent and gives enough entropy for more precision
  /// @notice length of a month = 30*24*60*60
  uint256 public epochLength;
  /// @notice percentage of rewards allocated to minter Lps
  uint256 private minterLpRewardsRatio;
  /// @notice percentage of rewards allocated to minter Amm Lps
  uint256 public ammLpRewardsRatio; //in bps, multiply fraction by 10^4
  /// @notice percentage of rewards allocated to stakers
  uint256 public vestingRewardsRatio; //in bps, multiply fraction by 10^4
  /// @notice total alloc points for amm lps
  uint256 public totalAmmLpAllocs; //total allocation points for all amm lps (the ratio defines percentage of rewards to a particular amm lp)
  /// @notice total alloc points for minter lps
  uint256 public totalMinterLpAllocs; //total allocation points for all minter lps (the ratio defines percentage of rewards to a particular minter lp)

  /// @notice reward for stakers already paid
  uint256 public vestingRewardsDebt;

  /// @notice address of the minter contract
  address private minterContract;

  /// @notice address of the staking contract
  address public haloChestContract;

  /// @notice timestamp of last allocation of rewards to stakers
  uint256 public lastHaloVestRewardTs;

  /// @notice info of whitelisted AMM Lp pools
  mapping(address => PoolInfo) public ammLpPools;
  /// @notice info of whitelisted minter Lp pools
  mapping(address => PoolInfo) public minterLpPools;
  /// @notice info of amm Lps
  mapping(address => mapping(address => UserInfo)) public ammLpUserInfo;
  /// @notice info of minter Lps
  mapping(address => mapping(address => UserInfo)) public minterLpUserInfo;

  mapping(address => uint256) public claimedHalo;

  /****************************************
   *          PRIVATE VARIABLES            *
   ****************************************/

  // @notice stores the AMM LP pool addresses internally
  address[] internal ammLpPoolsAddresses;

  /****************************************
   *           PUBLIC FUNCTIONS           *
   ****************************************/

  /// @notice initiates the contract with predefined params
  /// @dev initiates the contract with predefined params
  /// @param _haloTokenAddress address of the halo erc20 token
  /// @param _startingRewards rewards allocated for the first month
  /// @param _decayBase decay base
  /// @param _epochLength length of a month = 30*24*60*60
  /// @param _ammLpRewardsRatio percentage of rewards allocated to minter Amm Lps in bps
  /// @param _vestingRewardsRatio percentage of rewards allocated to stakers in bps
  /// @param _genesisTs timestamp of rewards genesis
  /// @param _minterLpPools info of whitelisted minter Lp pools at genesis
  /// @param _ammLpPools info of whitelisted amm Lp pools at genesis
  constructor(
    address _haloTokenAddress,
    uint256 _startingRewards,
    uint256 _decayBase, //multiplied by 10^18
    uint256 _epochLength,
    uint256 _ammLpRewardsRatio, //in bps, multiplied by 10^4
    uint256 _vestingRewardsRatio, //in bps, multiplied by 10^4
    uint256 _genesisTs,
    Pool[] memory _minterLpPools,
    Pool[] memory _ammLpPools
  ) public {
    haloTokenAddress = _haloTokenAddress;
    startingRewards = _startingRewards;
    decayBase = _decayBase;
    epochLength = _epochLength;
    minterLpRewardsRatio = 0;
    ammLpRewardsRatio = _ammLpRewardsRatio;
    vestingRewardsRatio = _vestingRewardsRatio;

    genesisTs = _genesisTs;
    lastHaloVestRewardTs = genesisTs;
    for (uint8 i = 0; i < _minterLpPools.length; i++) {
      addMinterCollateralType(
        _minterLpPools[i].poolAddress,
        _minterLpPools[i].allocPoint
      );
    }
    for (uint8 i = 0; i < _ammLpPools.length; i++) {
      addAmmLp(_ammLpPools[i].poolAddress, _ammLpPools[i].allocPoint);
    }
  }

  ///
  /// Updates accHaloPerShare and last reward update timestamp.
  /// Calculation:
  /// For each second, the total amount of rewards is fixed among all the current users who have staked LP tokens in the contract
  /// So, your share of the per second reward is proportionate to the amount of LP tokens you have staked in the pool.
  /// Hence, reward per second per collateral unit = reward per second / total collateral
  /// Since the total collateral remains the same between period when someone deposits or withdraws collateral,
  /// the per second reward per collateral unit also remains the same.
  /// So we just keep adding reward per share and keep a rewardDebt variable for each user to keep track of how much
  /// out of the accumulated reward they have already been paid or are not owed because of when they entered.
  ///
  ///
  /// @notice updates amm reward pool state
  /// @dev keeps track of accHaloPerShare as the number of stakers change
  /// @param _lpAddress address of the amm lp token
  function updateAmmRewardPool(address _lpAddress) public {
    PoolInfo storage pool = ammLpPools[_lpAddress];
    if (now <= pool.lastRewardTs) {
      return;
    }
    uint256 lpSupply = IERC20(_lpAddress).balanceOf(address(this));
    if (lpSupply == 0) {
      pool.lastRewardTs = now;
      return;
    }

    uint256 totalRewards = calcReward(pool.lastRewardTs);
    uint256 haloReward =
      totalRewards
        .mul(ammLpRewardsRatio)
        .mul(pool.allocPoint)
        .div(totalAmmLpAllocs)
        .div(BPS);

    pool.accHaloPerShare = pool.accHaloPerShare.add(
      haloReward.mul(DECIMALS).div(lpSupply)
    );

    pool.lastRewardTs = now;

    emit AmmLPRewardUpdatedEvent(
      _lpAddress,
      pool.accHaloPerShare,
      pool.lastRewardTs
    );
  }

  ///
  /// Updates accHaloPerShare and last reward update timestamp.
  /// Calculation:
  /// For each second, the amount of rewards is fixed among all the current users who have staked collateral in the contract
  /// So, your share of the per second reward is proportionate to your collateral in the pool.
  /// Hence, reward per second per collateral unit = reward per second / total collateral
  /// Since the total collateral remains the same between period when someone deposits or withdraws collateral,
  /// the per second reward per collateral unit also remains the same.
  /// So we just keep adding reward per share and keep a rewardDebt variable for each user to keep track of how much
  /// out of the accumulated reward they have already been paid.
  ///
  ///
  /// @notice updates minter reward pool state
  /// @dev keeps track of accHaloPerShare as the number of stakers change
  /// @param _collateralAddress address of the minter lp token
  function updateMinterRewardPool(address _collateralAddress) public {
    PoolInfo storage pool = minterLpPools[_collateralAddress];
    if (now <= pool.lastRewardTs) {
      return;
    }

    uint256 minterCollateralSupply =
      IMinter(minterContract).getTotalCollateralByCollateralAddress(
        _collateralAddress
      );
    if (minterCollateralSupply == 0) {
      pool.lastRewardTs = now;
      return;
    }

    uint256 totalRewards = calcReward(pool.lastRewardTs);
    uint256 haloReward =
      totalRewards
        .mul(minterLpRewardsRatio)
        .mul(pool.allocPoint)
        .div(totalMinterLpAllocs)
        .div(BPS);

    pool.accHaloPerShare = pool.accHaloPerShare.add(
      haloReward.mul(DECIMALS).div(minterCollateralSupply)
    );

    pool.lastRewardTs = now;

    emit MinterRewardPoolRatioUpdatedEvent(
      _collateralAddress,
      pool.accHaloPerShare,
      pool.lastRewardTs
    );
  }

  ///
  /// Deposit LP tokens and update reward debt for user and automatically sends accumulated rewards to the user.
  /// Reward debt keeps track of how much rewards have already been paid to the user + how much
  /// reward they are not entitled to that was earned before they entered the pool.
  ///
  ///
  /// @notice deposit amm lp tokens to earn rewards
  /// @dev deposit amm lp tokens to earn rewards
  /// @param _lpAddress address of the amm lp token
  /// @param _amount amount of lp tokens
  function depositPoolTokens(address _lpAddress, uint256 _amount) public {
    require(
      ammLpPools[_lpAddress].whitelisted == true,
      'Error: AMM Pool Address not allowed'
    );

    PoolInfo storage pool = ammLpPools[_lpAddress];
    UserInfo storage user = ammLpUserInfo[_lpAddress][msg.sender];

    updateAmmRewardPool(_lpAddress);

    if (user.amount > 0) {
      withdrawUnclaimedRewards(user, pool, msg.sender);
    }

    IERC20(_lpAddress).transferFrom(
      address(msg.sender),
      address(this),
      _amount
    );

    addAmountUpdateRewardDebtForUserForPoolTokens(
      _lpAddress,
      msg.sender,
      _amount
    );

    emit DepositAMMLPTokensEvent(msg.sender, _lpAddress, _amount);
  }

  /// @notice withdraw amm lp tokens to earn rewards
  /// @dev withdraw amm lp tokens to earn rewards
  /// @param _lpAddress address of the amm lp token
  /// @param _amount amount of lp tokens
  function withdrawPoolTokens(address _lpAddress, uint256 _amount) public {
    //require(lpPools[_lpAddress].whitelisted == true, "Error: Amm Lp not allowed"); //#DISCUSS: Allow withdraw from later blacklisted lp

    PoolInfo storage pool = ammLpPools[_lpAddress];
    UserInfo storage user = ammLpUserInfo[_lpAddress][msg.sender];

    require(user.amount >= _amount, 'Error: Not enough balance');

    updateAmmRewardPool(_lpAddress);

    withdrawUnclaimedRewards(user, pool, msg.sender);

    subtractAmountUpdateRewardDebtForUserForPoolTokens(
      _lpAddress,
      msg.sender,
      _amount
    );

    IERC20(_lpAddress).transfer(address(msg.sender), _amount);

    emit WithdrawAMMLPTokensEvent(msg.sender, _lpAddress, _amount);
  }

  /// @notice deposit collateral to minter to earn rewards, called by minter contract
  /// @dev deposit collateral to minter to earn rewards, called by minter contract
  /// @param _collateralAddress address of the minter collateral token
  /// @param _account address of the user
  /// @param _amount amount of collateral tokens
  function depositMinter(
    address _collateralAddress,
    address _account,
    uint256 _amount
  ) public onlyMinter {
    require(
      minterLpPools[_collateralAddress].whitelisted == true,
      'Error: Collateral type not allowed'
    );

    PoolInfo storage pool = minterLpPools[_collateralAddress];
    UserInfo storage user = minterLpUserInfo[_collateralAddress][_account];

    updateMinterRewardPool(_collateralAddress);

    if (user.amount > 0) {
      withdrawUnclaimedRewards(user, pool, _account);
    }

    addAmountUpdateRewardDebtAndForMinter(
      _collateralAddress,
      _account,
      _amount
    );

    emit DepositMinterCollateralByAddress(
      _account,
      _collateralAddress,
      _amount
    );
  }

  /// @notice withdraw collateral from minter, called by minter contract
  /// @dev withdraw collateral from minter, called by minter contract
  /// @param _collateralAddress address of the minter collateral token
  /// @param _account address of the user
  /// @param _amount amount of collateral tokens
  function withdrawMinter(
    address _collateralAddress,
    address _account,
    uint256 _amount
  ) public onlyMinter {
    //require(lpPools[_lpAddress].whitelisted == true, "Error: Amm Lp not allowed"); //#DISCUSS: Allow withdraw from later blacklisted lps

    PoolInfo storage pool = minterLpPools[_collateralAddress];
    UserInfo storage user = minterLpUserInfo[_collateralAddress][_account];

    require(user.amount >= _amount, 'Error: Not enough balance');

    updateMinterRewardPool(_collateralAddress);

    withdrawUnclaimedRewards(user, pool, _account);

    subtractAmountUpdateRewardDebtAndForMinter(
      _collateralAddress,
      _account,
      _amount
    );

    emit WithdrawMinterCollateralByAddress(
      _account,
      _collateralAddress,
      _amount
    );
  }

  /// @notice withdraw unclaimed amm lp rewards
  /// @dev withdraw unclaimed amm lp rewards, checks unclaimed rewards, updates rewardDebt
  /// @param _lpAddress address of the amm lp token
  function withdrawUnclaimedPoolRewards(address _lpAddress) external {
    PoolInfo storage pool = ammLpPools[_lpAddress];
    UserInfo storage user = ammLpUserInfo[_lpAddress][msg.sender];

    updateAmmRewardPool(_lpAddress);
    withdrawUnclaimedRewards(user, pool, msg.sender);
    user.rewardDebt = user.amount.mul(pool.accHaloPerShare).div(DECIMALS);
  }

  /// @notice withdraw unclaimed minter lp rewards
  /// @dev withdraw unclaimed minter lp rewards, checks unclaimed rewards, updates rewardDebt
  /// @param _collateralAddress address of the collateral token
  /// @param _account address of the user
  function withdrawUnclaimedMinterLpRewards(
    address _collateralAddress,
    address _account
  ) public onlyMinter {
    PoolInfo storage pool = minterLpPools[_collateralAddress];
    UserInfo storage user = minterLpUserInfo[_collateralAddress][_account];

    updateMinterRewardPool(_collateralAddress);
    withdrawUnclaimedRewards(user, pool, _account);
    user.rewardDebt = user.amount.mul(pool.accHaloPerShare).div(DECIMALS);
  }

  /****************************************
   *             VIEW FUNCTIONS            *
   ****************************************/

  /// @notice total pool  alloc points
  /// @dev total pool alloc points
  /// @return total pool alloc points
  function getTotalPoolAllocationPoints() public view returns (uint256) {
    return totalAmmLpAllocs;
  }

  /// @notice total minter lp alloc points
  /// @dev total minter lp alloc points
  /// @return total minter lp alloc points
  function getTotalMinterLpAllocationPoints() public view returns (uint256) {
    return totalMinterLpAllocs;
  }

  /// @notice unclaimed pool rewards
  /// @dev view function to check unclaimed pool rewards for an account
  /// @param _lpAddress address of the pool token
  /// @param _account address of the user
  /// @return unclaimed pool rewards for the user
  function getUnclaimedPoolRewardsByUserByPool(
    address _lpAddress,
    address _account
  ) public view returns (uint256) {
    PoolInfo storage pool = ammLpPools[_lpAddress];
    UserInfo storage user = ammLpUserInfo[_lpAddress][_account];
    return
      (user.amount.mul(pool.accHaloPerShare).div(DECIMALS)).sub(
        user.rewardDebt
      );
  }

  /// @notice lp tokens deposited by user
  /// @dev view function to check the amount of lp tokens deposited by user
  /// @param _lpAddress address of the amm lp token
  /// @param _account address of the user
  /// @return lp tokens deposited by user
  function getDepositedPoolTokenBalanceByUser(
    address _lpAddress,
    address _account
  ) public view returns (uint256) {
    UserInfo storage user = ammLpUserInfo[_lpAddress][_account];
    return user.amount;
  }

  /// @notice unclaimed minter lp rewards
  /// @dev view function to check unclaimed minter lp rewards for an account
  /// @param _collateralAddress address of the collateral token
  /// @param _account address of the user
  /// @return unclaimed minter lp rewards for the user
  function getUnclaimedMinterLpRewardsByUser(
    address _collateralAddress,
    address _account
  ) public view returns (uint256) {
    PoolInfo storage pool = minterLpPools[_collateralAddress];
    UserInfo storage user = minterLpUserInfo[_collateralAddress][_account];
    return
      (user.amount.mul(pool.accHaloPerShare).div(DECIMALS)).sub(
        user.rewardDebt
      );
  }

  /// @notice unclaimed rewards for stakers
  /// @dev view function to check unclaimed rewards for stakers since last withdrawal to vesting contract
  /// @return unclaimed rewards for stakers
  function getUnclaimedVestingRewards() public view returns (uint256) {
    uint256 nMonths = (now.sub(genesisTs)).div(epochLength);
    uint256 accMonthlyHalo =
      startingRewards.mul(sumExp(decayBase, nMonths)).div(DECIMALS);
    uint256 diffTime =
      ((now.sub(genesisTs.add(epochLength.mul(nMonths)))).mul(DECIMALS)).div(
        epochLength
      );
    uint256 thisMonthsReward =
      startingRewards.mul(exp(decayBase, nMonths + 1)).div(DECIMALS);
    uint256 accHalo =
      (diffTime.mul(thisMonthsReward).div(DECIMALS)).add(accMonthlyHalo);
    uint256 unclaimed =
      (accHalo.mul(vestingRewardsRatio).div(BPS)).sub(vestingRewardsDebt);
    return unclaimed;
  }

  /// @notice checks if an amm lp address is whitelisted
  /// @dev checks if an amm lp address is whitelisted
  /// @param _lpAddress address of the lp token
  /// @return true if valid amm lp
  function isValidAmmLp(address _lpAddress) public view returns (bool) {
    return ammLpPools[_lpAddress].whitelisted;
  }

  /// @notice checks if a collateral address is whitelisted
  /// @dev checks if a collateral address is whitelisted
  /// @param _collateralAddress address of the collateral
  /// @return true if valid minter lp
  function isValidMinterLp(address _collateralAddress)
    public
    view
    returns (bool)
  {
    return minterLpPools[_collateralAddress].whitelisted;
  }

  /// @notice view amm lp pool info
  /// @dev view amm lp pool info
  /// @param _lpAddress address of the lp token
  /// @return poolinfo
  function getAmmLpPoolInfo(address _lpAddress)
    public
    view
    returns (PoolInfo memory)
  {
    return ammLpPools[_lpAddress];
  }

  /// @notice view minter lp pool info
  /// @dev view minter lp pool info
  /// @param _collateralAddress address of the collateral
  /// @return view minter lp pool info
  function getMinterLpPoolInfo(address _collateralAddress)
    public
    view
    returns (PoolInfo memory)
  {
    return minterLpPools[_collateralAddress];
  }

  /// @notice get total claimed halo by user
  /// @dev get total claimed halo by user
  /// @param _account address of the user
  /// @return total claimed halo by user
  function getTotalRewardsClaimedByUser(address _account)
    public
    view
    returns (uint256)
  {
    return claimedHalo[_account];
  }

  /// @notice get all whitelisted AMM LM pool addresses
  /// @dev get all whitelisted AMM LM pool addresses
  /// @return AMM LP addresses as array
  function getWhitelistedAMMPoolAddresses()
    public
    view
    returns (address[] memory)
  {
    return ammLpPoolsAddresses;
  }

  function getMinterContractAddress() public view returns (address) {
    return minterContract;
  }

  function setMinterLpRewardsRatio(uint256 _minterLpRewardsRatio)
    public
    onlyOwner
  {
    minterLpRewardsRatio = _minterLpRewardsRatio;
  }

  function getMinterLpRewardsRatio() public view returns (uint256) {
    return minterLpRewardsRatio;
  }

  /****************************************
   *            ADMIN FUNCTIONS            *
   ****************************************/

  /// @notice set alloc points for amm lp
  /// @dev set alloc points for amm lp
  /// @param _lpAddress address of the lp token
  /// @param _allocPoint alloc points
  function setAmmLpAllocationPoints(address _lpAddress, uint256 _allocPoint)
    public
    onlyOwner
  {
    require(
      ammLpPools[_lpAddress].whitelisted == true,
      'AMM LP Pool not whitelisted'
    );
    totalAmmLpAllocs = totalAmmLpAllocs
      .sub(ammLpPools[_lpAddress].allocPoint)
      .add(_allocPoint);
    ammLpPools[_lpAddress].allocPoint = _allocPoint;
  }

  /// @notice set alloc points for minter lp
  /// @dev set alloc points for minter lp
  /// @param _collateralAddress address of the collateral
  /// @param _allocPoint alloc points
  function setMinterLpAllocationPoints(
    address _collateralAddress,
    uint256 _allocPoint
  ) public onlyOwner {
    require(
      minterLpPools[_collateralAddress].whitelisted == true,
      'Collateral type not whitelisted'
    );
    totalMinterLpAllocs = totalMinterLpAllocs
      .sub(minterLpPools[_collateralAddress].allocPoint)
      .add(_allocPoint);
    minterLpPools[_collateralAddress].allocPoint = _allocPoint;
  }

  /// @notice add an amm lp pool
  /// @dev add an amm lp pool
  /// @param _lpAddress address of the amm lp token
  /// @param _allocPoint alloc points
  function addAmmLp(address _lpAddress, uint256 _allocPoint) public onlyOwner {
    require(
      ammLpPools[_lpAddress].whitelisted == false,
      'AMM LP Pool already added'
    );
    uint256 lastRewardTs = now > genesisTs ? now : genesisTs;
    totalAmmLpAllocs = totalAmmLpAllocs.add(_allocPoint);

    //add lp to ammLpPools
    ammLpPools[_lpAddress].whitelisted = true;
    ammLpPools[_lpAddress].allocPoint = _allocPoint;
    ammLpPools[_lpAddress].lastRewardTs = lastRewardTs;
    ammLpPools[_lpAddress].accHaloPerShare = 0;

    // track the lp pool addresses addition internally
    addToAmmLpPoolsAddresses(_lpAddress);
  }

  /// @notice add a minter lp pool
  /// @dev add a minter lp pool
  /// @param _collateralAddress address of the collateral
  /// @param _allocPoint alloc points
  function addMinterCollateralType(
    address _collateralAddress,
    uint256 _allocPoint
  ) public onlyOwner {
    require(
      minterLpPools[_collateralAddress].whitelisted == false,
      'Collateral type already added'
    );
    uint256 lastRewardTs = now > genesisTs ? now : genesisTs;
    totalMinterLpAllocs = totalMinterLpAllocs.add(_allocPoint);

    //add lp to ammLpPools
    minterLpPools[_collateralAddress].whitelisted = true;
    minterLpPools[_collateralAddress].allocPoint = _allocPoint;
    minterLpPools[_collateralAddress].lastRewardTs = lastRewardTs;
    minterLpPools[_collateralAddress].accHaloPerShare = 0;
  }

  /// @notice remove an amm lp pool
  /// @dev remove an amm lp pool
  /// @param _lpAddress address of the amm lp token
  function removeAmmLp(address _lpAddress) public onlyOwner {
    require(
      ammLpPools[_lpAddress].whitelisted == true,
      'AMM LP Pool not whitelisted'
    );
    totalAmmLpAllocs = totalAmmLpAllocs.sub(ammLpPools[_lpAddress].allocPoint);
    ammLpPools[_lpAddress].whitelisted = false;

    // track the lp pool addresses removal internally
    removeFromAmmLpPoolsAddresses(_lpAddress);
  }

  /// @notice remove a minter lp pool
  /// @dev remove a minter lp pool
  /// @param _collateralAddress address of the collateral
  function removeMinterCollateralType(address _collateralAddress)
    public
    onlyOwner
  {
    require(
      minterLpPools[_collateralAddress].whitelisted == true,
      'Collateral type not whitelisted'
    );
    updateMinterRewardPool(_collateralAddress);
    totalMinterLpAllocs = totalMinterLpAllocs.sub(
      minterLpPools[_collateralAddress].allocPoint
    );
    minterLpPools[_collateralAddress].whitelisted = false;
  }

  /// @notice releases unclaimed vested rewards for stakers for extra bonus
  /// @dev releases unclaimed vested rewards for stakers for extra bonus
  function releaseVestedRewards() public onlyOwner {
    require(now > lastHaloVestRewardTs, 'now<lastHaloVestRewardTs');
    uint256 nMonths = (now.sub(genesisTs)).div(epochLength);
    uint256 accMonthlyHalo =
      startingRewards.mul(sumExp(decayBase, nMonths)).div(DECIMALS);
    uint256 diffTime =
      ((now.sub(genesisTs.add(epochLength.mul(nMonths)))).mul(DECIMALS)).div(
        epochLength
      );
    require(
      diffTime < epochLength.mul(DECIMALS),
      'diffTime > epochLength.mul(DECIMALS)'
    );
    uint256 thisMonthsReward =
      startingRewards.mul(exp(decayBase, nMonths + 1)).div(DECIMALS);
    uint256 accHalo =
      (diffTime.mul(thisMonthsReward).div(DECIMALS)).add(accMonthlyHalo);
    uint256 unclaimed =
      (accHalo.mul(vestingRewardsRatio).div(BPS)).sub(vestingRewardsDebt);
    vestingRewardsDebt = accHalo.mul(vestingRewardsRatio).div(BPS);
    safeHaloTransfer(haloChestContract, unclaimed);
    emit VestedRewardsReleasedEvent(unclaimed, now);
  }

  /// @notice sets the address of the minter contract
  /// @dev set the address of the minter contract
  /// @param _minter address of the minter contract
  function setMinterContractAddress(address _minter) public onlyOwner {
    minterContract = _minter;
  }

  /// @notice sets the address of the halochest contract
  /// @dev set the address of the halochest contract
  /// @param _haloChest address of the halochest contract
  function setHaloChest(address _haloChest) public onlyOwner {
    require(_haloChest != address(0), 'Set to valid address');
    haloChestContract = _haloChest;
  }

  /// @notice set genesis timestamp
  /// @dev set genesis timestamp
  /// @param _genesisTs genesis timestamp
  function setGenesisTs(uint256 _genesisTs) public onlyOwner {
    require(now < genesisTs, 'Already initialized');
    genesisTs = _genesisTs;
  }

  /****************************************
   *               MODIFIERS              *
   ****************************************/

  /// @dev only minter contract can call function
  modifier onlyMinter() {
    require(
      msg.sender == minterContract,
      'Only minter contract can call this function'
    );
    _;
  }

  /****************************************
   *          INTERNAL FUNCTIONS          *
   ****************************************/

  /// @notice Adds to LP token balance of user + updates reward debt of user
  /// @dev tracks either LP token amount or collateral ERC20 amount deposited by user + reward debt of user
  /// @param _poolAddress contract address of pool
  /// @param _account address of the user
  /// @param _amount LP token or collateral ERC20 balance
  function addAmountUpdateRewardDebtForUserForPoolTokens(
    address _poolAddress,
    address _account,
    uint256 _amount
  ) internal {
    PoolInfo storage pool = ammLpPools[_poolAddress];
    UserInfo storage user = ammLpUserInfo[_poolAddress][_account];

    user.amount = user.amount.add(_amount);
    user.rewardDebt = user.amount.mul(pool.accHaloPerShare).div(DECIMALS);
  }

  /// @notice Subtracts from LP token balance of user + updates reward debt of user
  /// @dev tracks either LP token amount or collateral ERC20 amount deposited by user + reward debt of user
  /// @param _poolAddress contract address of pool
  /// @param _account address of the user
  /// @param _amount LP token or collateral ERC20 balance
  function subtractAmountUpdateRewardDebtForUserForPoolTokens(
    address _poolAddress,
    address _account,
    uint256 _amount
  ) internal {
    PoolInfo storage pool = ammLpPools[_poolAddress];
    UserInfo storage user = ammLpUserInfo[_poolAddress][_account];

    user.amount = user.amount.sub(_amount);
    user.rewardDebt = user.amount.mul(pool.accHaloPerShare).div(DECIMALS);
  }

  /// @notice Adds to collateral ERC20 balance of user + updates reward debt of user
  /// @dev tracks either LP token amount or collateral ERC20 amount deposited by user + reward debt of user
  /// @param _collateralAddress contract address of pool
  /// @param _account address of the user
  /// @param _amount LP token or collateral ERC20 balance
  function addAmountUpdateRewardDebtAndForMinter(
    address _collateralAddress,
    address _account,
    uint256 _amount
  ) internal {
    PoolInfo storage pool = minterLpPools[_collateralAddress];
    UserInfo storage user = minterLpUserInfo[_collateralAddress][_account];

    user.amount = user.amount.add(_amount);
    user.rewardDebt = user.amount.mul(pool.accHaloPerShare).div(DECIMALS);
  }

  /// @notice Subtracts from collateral ERC20 balance of user + updates reward debt of user
  /// @dev tracks either LP token amount or collateral ERC20 amount deposited by user + reward debt of user
  /// @param _collateralAddress contract address of pool
  /// @param _account address of the user
  /// @param _amount LP token or collateral ERC20 balance
  function subtractAmountUpdateRewardDebtAndForMinter(
    address _collateralAddress,
    address _account,
    uint256 _amount
  ) internal {
    PoolInfo storage pool = minterLpPools[_collateralAddress];
    UserInfo storage user = minterLpUserInfo[_collateralAddress][_account];

    user.amount = user.amount.sub(_amount);
    user.rewardDebt = user.amount.mul(pool.accHaloPerShare).div(DECIMALS);
  }

  /// @notice withdraw unclaimed rewards
  /// @dev withdraw unclaimed rewards
  /// @param user instance of the UserInfo struct
  /// @param pool instance of the PoolInfo struct
  /// @param account user address
  function withdrawUnclaimedRewards(
    UserInfo storage user,
    PoolInfo storage pool,
    address account
  ) internal {
    uint256 unclaimed =
      user.amount.mul(pool.accHaloPerShare).div(DECIMALS).sub(user.rewardDebt);
    safeHaloTransfer(account, unclaimed);
  }

  /// @notice transfer halo to users
  /// @dev transfer halo to users
  /// @param _to address of the recipient
  /// @param _amount amount of halo tokens
  function safeHaloTransfer(address _to, uint256 _amount) internal {
    uint256 haloBal = IERC20(haloTokenAddress).balanceOf(address(this));
    require(_amount <= haloBal, 'Not enough HALO tokens in the contract');
    IERC20(haloTokenAddress).transfer(_to, _amount);
    claimedHalo[_to] = claimedHalo[_to].add(_amount);
  }

  ///
  /// Calculates reward since last update timestamp based on the decay function
  /// Calculation works as follows:
  /// Rewards since last update = 1. Rewards since the genesis - 2. Rewards since the genesis till last update
  /// 1. Rewards since the genesis
  ///     Number of complete months since genesis = (timestamp_current - timestamp_genesis) / month_length
  ///     Rewards since the genesis = Total rewards till end of last month + reward since end of last month
  ///     I.  Total rewards till end of last month = ( startingRewards * ∑ decayBase ^ n )
  ///     II.  Reward since end of last month = (timediff since end of last month * this month's reward) / (Length of month)
  ///
  /// 2. Rewards since the genesis till last update
  ///     Number of complete months since genesis till last update = (timestamp_last - timestamp_genesis) / month_length
  ///     Rewards since the genesis till last update = Total rewards till end of last month before last update
  ///                                                  + reward since end of last month till last update
  ///     I.  Total rewards till end of last month before last update = ( startingRewards * ∑ decayBase ^ n )
  ///     II.  Reward since end of last month till last update = (timediff since end of last month before last update * that month's reward) / (Length of month)
  ///
  ///
  ///
  /// @notice calculates the unclaimed rewards for last timestamp
  /// @dev calculates the unclaimed rewards for last timestamp
  /// @param _from last timestamp when rewards were updated
  /// @return unclaimed rewards since last update
  function calcReward(uint256 _from) internal view returns (uint256) {
    uint256 nMonths = (_from.sub(genesisTs)).div(epochLength);
    uint256 accMonthlyHalo =
      startingRewards.mul(sumExp(decayBase, nMonths)).div(DECIMALS);
    uint256 diffTime =
      ((_from.sub(genesisTs.add(epochLength.mul(nMonths)))).mul(DECIMALS)).div(
        epochLength
      );

    uint256 thisMonthsReward =
      startingRewards.mul(exp(decayBase, nMonths)).div(DECIMALS);
    uint256 tillFrom =
      (diffTime.mul(thisMonthsReward).div(DECIMALS)).add(accMonthlyHalo);

    nMonths = (now.sub(genesisTs)).div(epochLength);
    accMonthlyHalo = startingRewards.mul(sumExp(decayBase, nMonths)).div(
      DECIMALS
    );
    diffTime = (
      (now.sub(genesisTs.add(epochLength.mul(nMonths)))).mul(DECIMALS)
    )
      .div(epochLength);

    thisMonthsReward = startingRewards.mul(exp(decayBase, nMonths)).div(
      DECIMALS
    );
    uint256 tillNow =
      (diffTime.mul(thisMonthsReward).div(DECIMALS)).add(accMonthlyHalo);

    return tillNow.sub(tillFrom);
  }

  function exp(uint256 m, uint256 n) internal pure returns (uint256) {
    uint256 x = DECIMALS;
    for (uint256 i = 0; i < n; i++) {
      x = x.mul(m).div(DECIMALS);
    }
    return x;
  }

  function sumExp(uint256 m, uint256 n) internal pure returns (uint256) {
    uint256 x = DECIMALS;
    uint256 s;
    for (uint256 i = 0; i < n; i++) {
      x = x.mul(m).div(DECIMALS);
      s = s.add(x);
    }
    return s;
  }

  function addToAmmLpPoolsAddresses(address _lpAddress) internal {
    bool exists = false;
    for (uint8 i = 0; i < ammLpPoolsAddresses.length; i++) {
      if (ammLpPoolsAddresses[i] == _lpAddress) {
        exists = true;
        break;
      }
    }

    if (!exists) {
      ammLpPoolsAddresses.push(_lpAddress);
    }
  }

  function removeFromAmmLpPoolsAddresses(address _lpAddress) internal {
    for (uint8 i = 0; i < ammLpPoolsAddresses.length; i++) {
      if (ammLpPoolsAddresses[i] == _lpAddress) {
        if (i + 1 < ammLpPoolsAddresses.length) {
          ammLpPoolsAddresses[i] = ammLpPoolsAddresses[
            ammLpPoolsAddresses.length - 1
          ];
        }
        ammLpPoolsAddresses.pop();
        break;
      }
    }
  }
}
