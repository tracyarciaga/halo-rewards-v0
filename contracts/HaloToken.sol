// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract HaloToken is ERC20, Ownable {
    bool private canMint;
    bool private isCappedFuncLocked;
    uint256 private _cap;

    /// @notice initiates the contract with predefined params
    /// @dev initiates the contract with predefined params
    /// @param _name name of the halo erc20 token
    /// @param _symbol symbol of the halo erc20 token
    constructor(string memory _name, string memory _symbol)
        public
        ERC20(_name, _symbol)
    {
        canMint = true;
        isCappedFuncLocked = false;
    }

    /**
     * @dev Returns the cap on the token's total supply.
     */
    function cap() public view returns (uint256) {
        return _cap;
    }
    /// @notice Locks the cap and disables mint func.
    /// @dev Should be called only once. Allows owner to lock the cap and disable mint function.
    function setCapped() external onlyOwner {
        require(isCappedFuncLocked == false, "Cannot execute setCapped more than once.");
        canMint = false;
        isCappedFuncLocked = true;   
    }

    /// @notice Creates halo token, increasing total supply.
    /// @dev Allows owner to mint HALO tokens.
    /// @param account address of the owner
    /// @param amount amount to mint
    function mint(address account, uint256 amount) external onlyOwner {
        require(canMint == true, "Total supply is now capped, cannot mint more");
        _mint(account, amount);
        _cap += amount;
    }

    /// @notice Destroys halo token, decreasing total supply.
    /// @dev Allows owner to burn HALO tokens.
    /// @param account address of the owner
    /// @param amount amount to burn
    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }
}