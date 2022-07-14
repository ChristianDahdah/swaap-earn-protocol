// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.15;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "src/Errors.sol";

contract Registry is Ownable {
    /**
     * @notice Emitted when a new contract is registered.
     * @param id value representing the unique ID tied to the new contract
     * @param newContract address of the new contract
     */
    event Registered(uint256 indexed id, address indexed newContract);

    /**
     * @notice Emitted when the address of a contract is changed.
     * @param id value representing the unique ID tied to the changed contract
     * @param oldAddress address of the contract before the change
     * @param newAddress address of the contract after the contract
     */
    event AddressChanged(uint256 indexed id, address oldAddress, address newAddress);

    /**
     * @notice The unique ID that the next registered contract will have.
     */
    uint256 public currentId;

    /**
     * @notice Get the address associated with an id.
     */
    mapping(uint256 => address) public getAddress;

    /**
     * @notice Set the address of the contract at a given id.
     */
    function setAddress(uint256 id, address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert USR_InvalidAddress(newAddress);

        address oldAddress = getAddress[id];
        if (oldAddress == address(0)) revert USR_ContractNotRegistered(id);

        getAddress[id] = newAddress;

        emit AddressChanged(id, oldAddress, newAddress);
    }

    /**
     * @param gravityBridge address of GravityBridge contract
     * @param swapRouter address of SwapRouter contract
     * @param priceRouter address of PriceRouter contract
     */
    constructor(
        address gravityBridge,
        address swapRouter,
        address priceRouter
    ) Ownable() {
        _register(gravityBridge);
        _register(swapRouter);
        _register(priceRouter);
    }

    /**
     * @notice Register the address of a new contract.
     * @param newContract address of the new contract to register
     */
    function register(address newContract) external onlyOwner {
        _register(newContract);
    }

    function _register(address newContract) internal {
        getAddress[currentId] = newContract;

        emit Registered(currentId, newContract);

        currentId++;
    }
}
