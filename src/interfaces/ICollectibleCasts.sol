// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMetadata} from "./IMetadata.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

/**
 * @title ICollectibleCasts
 * @author Farcaster
 * @notice Interface for minting and managing Farcaster collectible cast NFTs
 */
interface ICollectibleCasts is IERC721 {
    /**
     * @notice Gets contract metadata URI
     * @return Contract-level metadata URI
     */
    function contractURI() external view returns (string memory);

    /**
     * @notice Checks if token exists
     * @param tokenId Token to check
     * @return Token has been minted
     */
    function isMinted(uint256 tokenId) external view returns (bool);

    /**
     * @notice Checks if cast has been minted
     * @param castHash Cast identifier to check
     * @return Cast has been minted
     */
    function isMinted(bytes32 castHash) external view returns (bool);

    /**
     * @notice Gets the current metadata module address
     * @return The address of the metadata module (addess(0) if not set)
     */
    function metadata() external view returns (IMetadata);
}
