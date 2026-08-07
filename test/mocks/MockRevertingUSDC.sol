// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @notice USDC mock that can be made to revert on outgoing transfers.
 * @dev Used to exercise the retryable restore paths in withdraw() and
 *      collectProtocolFees() when the token transfer fails.
 */
contract MockRevertingUSDC is ERC20 {
    bool private _failTransfer;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Enable/disable failing on outgoing transfers (returns false, like USDC).
    function failTransfers(bool fail) external {
        _failTransfer = fail;
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (_failTransfer) {
            return false;
        }
        return super.transfer(to, amount);
    }
}
