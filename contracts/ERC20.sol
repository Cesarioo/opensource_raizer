// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./customOFT.sol"; // your abstract OFT contract
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MyOFT is OFT {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address _lzEndpoint,
        address _delegate,
        address _admin
    )
        OFT(
            name,
            symbol,
            _lzEndpoint,
            _delegate,
            _admin
        )  Ownable(_delegate)
    {
        // Mint initial supply if specified
        if (initialSupply > 0) {
            _mint(_admin, initialSupply);
        }
    }
}
