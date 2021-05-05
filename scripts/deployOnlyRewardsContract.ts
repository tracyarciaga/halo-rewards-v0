import { ethers } from 'hardhat'
import { formatEther } from 'ethers/lib/utils'

const deployOnlyRewards = async () => {
  // We get the contract to deploy
  const [deployer] = await ethers.getSigners()

  // Deployer information
  console.log('Deployer Address:', deployer.address)
  console.log('Deployer balance:', formatEther(await deployer.getBalance()))

  // Rewards constants
  const BASIS_POINTS = 10 ** 4
  const INITIAL_MINT = 10 ** 6
  const RewardsContract = await ethers.getContractFactory('Rewards')

  const haloTokenContractAddress = '0xc4b3F0437c5D53B01B3C7dDEd7318A60ecE76650'
  const minterContractAddress = '0xE94B97b6b43639E238c851A7e693F50033EfD75C'
  const dummyCollateralAddress = '0xcE2E091802c44191ca147EAee66bFE064A01FE37'
  const BPTAddress = '0x37f80ac90235ce0d3911952d0ce49071a0ffdb1e'

  const startingRewards = ethers.utils.parseEther('7500000')
  const minterLpRewardsRatio = 0.4 * BASIS_POINTS
  const ammLpRewardsRatio = 0.4 * BASIS_POINTS
  const vestingRewardsRatio = 0.2 * BASIS_POINTS
  const genesisBlock = await ethers.provider.getBlockNumber()
  const minterLpPools = [[dummyCollateralAddress, 10]]
  const ammLpPools = [[BPTAddress, 10]]

  // Get contract instance
  const haloTokenContract = await ethers.getContractAt(
    'HaloToken',
    haloTokenContractAddress
  )

  // Rewards constructor
  const rewardsContract = await RewardsContract.deploy(
    haloTokenContractAddress,
    startingRewards,
    minterLpRewardsRatio, //in BASIS_POINTS, multiplied by 10^4
    ammLpRewardsRatio, //in BASIS_POINTS, multiplied by 10^4
    vestingRewardsRatio, //in BASIS_POINTS, multiplied by 10^4
    minterContractAddress,
    genesisBlock,
    minterLpPools,
    ammLpPools
  )

  await rewardsContract.deployed()
  console.log('Rewards Contract deployed: ', rewardsContract.address)

  // Temporary dev thing: Mint HALO to contract
  await haloTokenContract.mint(
    rewardsContract.address,
    ethers.utils.parseEther((40 * INITIAL_MINT).toString())
  )

  console.log(
    (40 * INITIAL_MINT).toString() +
      ' HALO minted to ' +
      rewardsContract.address
  )
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
deployOnlyRewards()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
