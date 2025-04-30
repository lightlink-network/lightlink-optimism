// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Gas Station
 * @dev Registry for self-service gasless contracts
 */
contract GasStation {

    struct GaslessContract {
        bool registered;
        bool active;
        address owner;
        uint256 credits;
        bool whitelistEnabled;
        mapping(address => bool) whitelist;
    }

    // Maps contract address to its configuration
    mapping(address => GaslessContract) public contracts;

    // Events
    event ContractRegistered(address indexed contractAddress, address indexed owner);
    event CreditsAdded(address indexed contractAddress, uint256 amount, address paymentToken);
    event CreditsUsed(address indexed contractAddress, address caller, uint256 gasUsed);

    constructor() {}

    /**
     * @dev Register a contract for gasless transactions
     */
    function registerContract(address contractAddress, address owner) external payable {
        require(!contracts[contractAddress].registered, "already registered");

        GaslessContract storage gc = contracts[contractAddress];
        gc.registered = true;
        gc.active = true;
        gc.owner = owner;
        gc.credits = 1000000000000000000;
        gc.whitelistEnabled = false;

        emit ContractRegistered(contractAddress, owner);
    }

    // === Configuration functions (Admin, Owner) ===

    /**
     * @dev Configure whitelist status for a contract
     * @param enabled Whether whitelist is enabled
     */
    function setWhitelistEnabled(address contractAddress, bool enabled) external {
        contracts[contractAddress].whitelistEnabled = enabled;
    }

    /**
     * @dev Add address to whitelist
     * @param user Address to whitelist
     */
    function addToWhitelist(address contractAddress, address user) external {
        contracts[contractAddress].whitelist[user] = true;
    }

    /**
     * @dev Remove address from whitelist
     * @param user Address to remove from whitelist
     */
    function removeFromWhitelist(address contractAddress, address user) external {
        contracts[contractAddress].whitelist[user] = false;
    }

    // === Admin functions (Admin) ===

    /**
     * @dev Check if a gasless transaction should be accepted
     */
    function validateTx(address contractAddress, address originalCaller) external view returns (bool) {
        if (!contracts[contractAddress].registered) {
            return false;
        }

        if (!contracts[contractAddress].active) {
            return false;
        }

        if (contracts[contractAddress].whitelistEnabled && !contracts[contractAddress].whitelist[originalCaller]) {
            return false;
        }

        return true;
    }

    /**
     * @dev Check and deduct credits
     */
    function chargeCredits(address contractAddress, uint256 creditCharge) external returns (bool) {
        GaslessContract storage gc = contracts[contractAddress];

        if (gc.credits < creditCharge) {
            return false;
        }

        gc.credits -= creditCharge;
        emit CreditsUsed(contractAddress, tx.origin, creditCharge);
        return true;
    }

    /**
     * @dev Add credits to a contract
     * @param contractAddress Address of the contract
     * @param amount Amount of credits to add
     */
    function addCredits(address contractAddress, uint256 amount) external {
        contracts[contractAddress].credits += amount;
    }

    /**
     * @dev Remove a contract
     * @param contractAddress Address of the contract
     */
    function removeContract(address contractAddress) external {
        delete contracts[contractAddress];
    }


    // === View functions (User) ===

    /**
     * @dev Get the current credit balance of a contract
     */
    function getCredits(address contractAddress) external view returns (uint256) {
        return contracts[contractAddress].credits;
    }

    /**
     * @dev Check if a contract is registered
     */
    function isRegistered(address contractAddress) external view returns (bool) {
        return contracts[contractAddress].registered;
    }

    /**
     * @dev Check if a contract is active
     */
    function isActive(address contractAddress) external view returns (bool) {
        return contracts[contractAddress].active;
    }

    /**
     * @dev Check if an address is whitelisted
     */
    function isWhitelisted(address contractAddress, address user) external view returns (bool) {
        return !contracts[contractAddress].whitelistEnabled || contracts[contractAddress].whitelist[user];
    }
}