// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ICollectibleCasts} from "../../src/interfaces/ICollectibleCasts.sol";
import {IMetadata} from "../../src/interfaces/IMetadata.sol";

contract MockCollectible is ERC721 {
    mapping(uint256 => bool) private _minted;

    constructor() ERC721("Collectible Casts", "CAST") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
        _minted[tokenId] = true;
    }

    function isMinted(uint256 tokenId) external view returns (bool) {
        return _minted[tokenId];
    }

    // Stub — not used by MarketPlace but required by interface
    function isMinted(bytes32) external pure returns (bool) {
        return false;
    }

    function contractURI() external pure returns (string memory) {
        return "";
    }

    function metadata() external pure returns (IMetadata) {
        return IMetadata(address(0));
    }
}
