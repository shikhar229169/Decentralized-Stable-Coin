// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**@title Decentralized Stable Coin
 * @author Shikhar Agarwal
 * Collateral - Exogeneous (ETH, BTC)
 * Minting - Algorithmic
 * Relative Stability - Pegged with USD
 * 
 * It is meant to be governed by DSC-Engine. This is just an ERC20 implementation of our stablecoin
*/
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmtShouldBeGreaterThanZero();
    error DecentralizedStableCoin__BurnAmtExceedsBalance();
    error DecentralizedStableCoin__cantMintToZeroAddress();

    constructor() ERC20("Decentralized Stable Coin", "DSC") {

    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmtShouldBeGreaterThanZero();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmtExceedsBalance();
        }

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__cantMintToZeroAddress();
        }
        if (_amount == 0) {
            revert DecentralizedStableCoin__AmtShouldBeGreaterThanZero();
        }

        _mint(_to, _amount);

        return true;
    }
}