// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet-only stablecoin for demos on chains without a USDC faucet.
contract TestUSD is ERC20 {
    constructor() ERC20("Mihenk Test USD", "tUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev Open faucet: anyone can mint up to 10,000 tUSD per call. Testnet only.
    function mint(address to, uint256 amount) external {
        require(amount <= 10_000e6, "max 10k per mint");
        _mint(to, amount);
    }
}
