// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

// Interface for ERC20 tokens
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

// Interface for burnable ERC20 tokens
interface IERC20Burnable {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

/// @custom:proxied
/// @custom:predeploy 0x4300000000000000000000000000000000000001
/// @title GasStation
/// @notice The GasStation is a registry for self-service gasless contracts.

contract GasStation {

    /// @custom:storage-location erc7201:gasstation.main
    struct GasStationStorage {
        address dao;
        mapping(address => GaslessContract) contracts;
        mapping(uint256 => CreditPackage) creditPackages;
        uint256 nextPackageId;
    }

    struct GaslessContract {
        bool registered;
        bool active;
        address admin;
        uint256 credits;
        bool whitelistEnabled;
        // EOA's that are allowed to send gasless transactions to this contract
        mapping(address => bool) whitelist;
    }

    struct CreditPackage {
        bool active;
        string name;
        uint256 costInWei;
        uint256 creditsAwarded;
        address paymentToken; // address(0) for ETH, token address for ERC20
        uint256 burnPercentage; // Percentage to burn (0-10000, where 10000 = 100%)
    }

    // keccak256(abi.encode(uint256(keccak256("gasstation.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GasStationStorageLocation =
        0xc2eaf2cedf9e23687c6eb7c4717aa3eacbd015cc86eaad3f51aae2d3c955db00;

    function _getGasStationStorage() private pure returns (GasStationStorage storage $) {
        assembly {
            $.slot := GasStationStorageLocation
        }
    }

    // Events
    event ContractRegistered(address indexed contractAddress, address indexed admin);
    event CreditsAdded(address indexed contractAddress, uint256 amount);
    event CreditsUsed(address indexed contractAddress, address caller, uint256 gasUsed);
    event CreditsRemoved(address indexed contractAddress, uint256 amount);
    event CreditsSet(address indexed contractAddress, uint256 amount);
    event ContractUnregistered(address indexed contractAddress);
    event ContractRemoved(address indexed contractAddress);
    event AdminChanged(address indexed contractAddress, address indexed oldAdmin, address indexed newAdmin);
    event ActiveStatusChanged(address indexed contractAddress, bool active);
    event WhitelistStatusChanged(address indexed contractAddress, bool enabled);
    event DAOChanged(address indexed oldDAO, address indexed newDAO);
    event CreditPackageAdded(uint256 indexed packageId, string name, uint256 cost, uint256 creditsAwarded, address paymentToken, uint256 burnPercentage);
    event CreditPackageUpdated(uint256 indexed packageId, string name, uint256 cost, uint256 creditsAwarded, address paymentToken, uint256 burnPercentage);
    event CreditPackageStatusChanged(uint256 indexed packageId, bool active);
    event CreditsPurchased(address indexed contractAddress, uint256 indexed packageId, uint256 amount, uint256 cost);
    event TokensBurned(address indexed token, uint256 amount);

    // Custom errors for better gas efficiency
    error NotDAO();
    error NotAdmin();
    error NotAuthorized();
    error AlreadyRegistered();
    error NotRegistered();
    error ZeroAddress();
    error InsufficientCredits();
    error InvalidContract();
    error PackageNotFound();
    error PackageNotActive();
    error InsufficientPayment();
    error EmptyPackageName();
    error InvalidBurnPercentage();
    error TokenTransferFailed();
    error InvalidTokenPayment();

    /// @notice Modifier to check if caller is the DAO multisig
    modifier onlyDAO() {
        if (msg.sender != _getGasStationStorage().dao) revert NotDAO();
        _;
    }

    /// @notice Modifier to check if caller is the specific gasless contract admin
    modifier onlyAdmin(address contractAddress) {
        if (msg.sender != _getGasStationStorage().contracts[contractAddress].admin) revert NotAdmin();
        _;
    }

    /// @notice Modifier to check if caller is the contract admin or the DAO multisig
    modifier onlyAdminOrDAO(address contractAddress) {
        GasStationStorage storage $ = _getGasStationStorage();
        if (msg.sender != $.contracts[contractAddress].admin && msg.sender != $.dao) {
            revert NotAuthorized();
        }
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    modifier contractExists(address contractAddress) {
        if (!_getGasStationStorage().contracts[contractAddress].registered) revert NotRegistered();
        _;
    }

    constructor(address _dao) validAddress(_dao) {
        GasStationStorage storage $ = _getGasStationStorage();
        $.dao = _dao;
        $.nextPackageId = 1;
    }

    function dao() public view returns (address) {
        return _getGasStationStorage().dao;
    }

    function contracts(address contractAddress) public view returns (
        bool registered,
        bool active,
        address admin,
        uint256 credits,
        bool whitelistEnabled
    ) {
        GaslessContract storage gc = _getGasStationStorage().contracts[contractAddress];
        return (gc.registered, gc.active, gc.admin, gc.credits, gc.whitelistEnabled);
    }

    function creditPackages(uint256 packageId) public view returns (
        bool active,
        string memory name,
        uint256 costInWei,
        uint256 creditsAwarded,
        address paymentToken,
        uint256 burnPercentage
    ) {
        CreditPackage storage package = _getGasStationStorage().creditPackages[packageId];
        return (package.active, package.name, package.costInWei, package.creditsAwarded, package.paymentToken, package.burnPercentage);
    }

    // === Public functions ===

    /**
     * @dev Register a contract for gasless transactions
     * @param contractAddress Address of the contract to register
     * @param admin Address of the contract admin
     */
    function registerContract(address contractAddress, address admin)
        external
        validAddress(contractAddress)
        validAddress(admin)
    {
        if (_getGasStationStorage().contracts[contractAddress].registered) revert AlreadyRegistered();

        // Validate that contractAddress is actually a contract
        uint256 size;
        assembly { size := extcodesize(contractAddress) }
        if (size == 0) revert InvalidContract();

        GaslessContract storage gc = _getGasStationStorage().contracts[contractAddress];
        gc.registered = true;
        gc.active = true;
        gc.admin = admin;
        gc.credits = 0;
        gc.whitelistEnabled = true;

        emit ContractRegistered(contractAddress, admin);
    }

    /**
     * @dev Purchase credits for a contract using a specific package
     * @param contractAddress Address of the contract to add credits to
     * @param packageId ID of the credit package to purchase
     */
    function purchaseCredits(address contractAddress, uint256 packageId)
        external
        payable
        contractExists(contractAddress)
    {
        CreditPackage storage package = _getGasStationStorage().creditPackages[packageId];

        // Check if package exists
        if (bytes(package.name).length == 0) revert PackageNotFound();

        // Check if package is active
        if (!package.active) revert PackageNotActive();

        if (package.paymentToken == address(0)) {
            // ETH payment
            _handleETHPayment(package);
        } else {
            // ERC20 token payment
            if (msg.value > 0) revert InvalidTokenPayment();
            _handleTokenPayment(package);
        }

        // Add credits to the contract
        _getGasStationStorage().contracts[contractAddress].credits += package.creditsAwarded;

        emit CreditsPurchased(contractAddress, packageId, package.creditsAwarded, package.costInWei);
    }

    /**
     * @dev Get the admin of a contract
     */
    function getAdmin(address contractAddress) external view returns (address) {
        return _getGasStationStorage().contracts[contractAddress].admin;
    }

    /**
     * @dev Get the current credit balance of a contract
     */
    function getCredits(address contractAddress) external view returns (uint256) {
        return _getGasStationStorage().contracts[contractAddress].credits;
    }

    /**
     * @dev Check if a contract is registered
     */
    function isRegistered(address contractAddress) external view returns (bool) {
        return _getGasStationStorage().contracts[contractAddress].registered;
    }

    /**
     * @dev Check if a contract is active
     */
    function isActive(address contractAddress) external view returns (bool) {
        return _getGasStationStorage().contracts[contractAddress].active;
    }

    /**
     * @dev Check if an address is whitelisted
     */
    function isWhitelisted(address contractAddress, address user) external view returns (bool) {
        return !_getGasStationStorage().contracts[contractAddress].whitelistEnabled || _getGasStationStorage().contracts[contractAddress].whitelist[user];
    }

    /**
     * @dev Get the whitelist status of a contract
     */
    function getWhitelistStatus(address contractAddress) external view returns (bool) {
        return _getGasStationStorage().contracts[contractAddress].whitelistEnabled;
    }

    /**
     * @dev Get the next package ID
     */
    function getNextPackageId() external view returns (uint256) {
        return _getGasStationStorage().nextPackageId;
    }

    /**
     * @dev Check if a credit package exists and is active
     */
    function isPackageActive(uint256 packageId) external view returns (bool) {
        return _getGasStationStorage().creditPackages[packageId].active;
    }

    /**
     * @dev Get all active package IDs (limited to reasonable number)
     */
    function getActivePackageIds() external view returns (uint256[] memory) {
        GasStationStorage storage $ = _getGasStationStorage();
        uint256 count = 0;

        // First, count active packages
        for (uint256 i = 1; i < $.nextPackageId; i++) {
            if ($.creditPackages[i].active) {
                count++;
            }
        }

        // Then, populate the array
        uint256[] memory activePackages = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i < $.nextPackageId; i++) {
            if ($.creditPackages[i].active) {
                activePackages[index] = i;
                index++;
            }
        }

        return activePackages;
    }

    // === Configuration functions (onlyAdminOrDAO) ===

    /**
     * @dev Configure the admin of a contract
     */
    function setAdmin(address contractAddress, address newAdmin)
        external
        onlyAdminOrDAO(contractAddress)
        contractExists(contractAddress)
        validAddress(newAdmin)
    {
        address oldAdmin = _getGasStationStorage().contracts[contractAddress].admin;
        _getGasStationStorage().contracts[contractAddress].admin = newAdmin;
        emit AdminChanged(contractAddress, oldAdmin, newAdmin);
    }

    /**
     * @dev Configure the active status of a contract
     */
    function setActive(address contractAddress, bool active)
        external
        onlyAdminOrDAO(contractAddress)
        contractExists(contractAddress)
    {
        _getGasStationStorage().contracts[contractAddress].active = active;
        emit ActiveStatusChanged(contractAddress, active);
    }

    /**
     * @dev Configure whitelist status for a contract
     * @param enabled Whether whitelist is enabled
     */
    function setWhitelistEnabled(address contractAddress, bool enabled) external onlyAdminOrDAO(contractAddress) {
        _getGasStationStorage().contracts[contractAddress].whitelistEnabled = enabled;
        emit WhitelistStatusChanged(contractAddress, enabled);
    }

    /**
     * @dev Add addresses to whitelist
     * @param users Array of addresses to whitelist
     */
    function addToWhitelist(address contractAddress, address[] calldata users) external onlyAdminOrDAO(contractAddress) {
        for (uint256 i = 0; i < users.length; i++) {
            _getGasStationStorage().contracts[contractAddress].whitelist[users[i]] = true;
        }
    }

    /**
     * @dev Remove addresses from whitelist
     * @param users Array of addresses to remove from whitelist
     */
    function removeFromWhitelist(address contractAddress, address[] calldata users) external onlyAdminOrDAO(contractAddress) {
        for (uint256 i = 0; i < users.length; i++) {
            _getGasStationStorage().contracts[contractAddress].whitelist[users[i]] = false;
        }
    }

    // === DAO functions (onlyDAO) ===

    /**
     * @dev Add credits to a contract
     * @param contractAddress Address of the contract
     * @param amount Amount of credits to add
     */
    function addCredits(address contractAddress, uint256 amount) external onlyDAO {
        _getGasStationStorage().contracts[contractAddress].credits += amount;
        emit CreditsAdded(contractAddress, amount);
    }

    /**
     * @dev Remove credits from a contract with underflow protection
     */
    function removeCredits(address contractAddress, uint256 amount)
        external
        onlyDAO
        contractExists(contractAddress)
    {
        uint256 currentCredits = _getGasStationStorage().contracts[contractAddress].credits;
        if (currentCredits < amount) revert InsufficientCredits();

        _getGasStationStorage().contracts[contractAddress].credits = currentCredits - amount;
        emit CreditsRemoved(contractAddress, amount);
    }

    /**
     * @dev Set the credits of a contract
     * @param contractAddress Address of the contract
     * @param amount Amount of credits to set
     */
    function setCredits(address contractAddress, uint256 amount) external onlyDAO {
        _getGasStationStorage().contracts[contractAddress].credits = amount;
        emit CreditsSet(contractAddress, amount);
    }

    /**
     * @dev Unregister a contract
     * @param contractAddress Address of the contract
     */
    function unregisterContract(address contractAddress) external onlyDAO {
        delete _getGasStationStorage().contracts[contractAddress];
        emit ContractUnregistered(contractAddress);
    }

    /**
     * @dev Remove a contract
     * @param contractAddress Address of the contract
     */
    function removeContract(address contractAddress) external onlyDAO {
        delete _getGasStationStorage().contracts[contractAddress];
        emit ContractRemoved(contractAddress);
    }

    /**
     * @dev Set the DAO address with proper validation
     */
    function setDAO(address newDAO) external onlyDAO validAddress(newDAO) {
        address oldDAO = _getGasStationStorage().dao;
        _getGasStationStorage().dao = newDAO;
        emit DAOChanged(oldDAO, newDAO);
    }

    /**
     * @dev Add a new credit package
     * @param name Name of the package (e.g., "Developer", "Startup", "Enterprise")
     * @param cost Cost to purchase this package (in wei for ETH, or token units for ERC20)
     * @param creditsAwarded Credits awarded when purchasing this package
     * @param paymentToken Token address for ERC20 payments, or address(0) for ETH
     * @param burnPercentage Percentage to burn (0-10000, where 10000 = 100%)
     */
    function addCreditPackage(
        string calldata name,
        uint256 cost,
        uint256 creditsAwarded,
        address paymentToken,
        uint256 burnPercentage
    ) external onlyDAO {
        if (bytes(name).length == 0) revert EmptyPackageName();
        if (burnPercentage > 10000) revert InvalidBurnPercentage();

        GasStationStorage storage $ = _getGasStationStorage();
        uint256 packageId = $.nextPackageId;

        CreditPackage storage package = $.creditPackages[packageId];
        package.active = true;
        package.name = name;
        package.costInWei = cost;
        package.creditsAwarded = creditsAwarded;
        package.paymentToken = paymentToken;
        package.burnPercentage = burnPercentage;

        $.nextPackageId++;

        emit CreditPackageAdded(packageId, name, cost, creditsAwarded, paymentToken, burnPercentage);
    }

    /**
     * @dev Update an existing credit package
     * @param packageId ID of the package to update
     * @param name New name of the package
     * @param cost New cost (in wei for ETH, or token units for ERC20)
     * @param creditsAwarded New credits awarded
     * @param paymentToken Token address for ERC20 payments, or address(0) for ETH
     * @param burnPercentage Percentage to burn (0-10000, where 10000 = 100%)
     */
    function updateCreditPackage(
        uint256 packageId,
        string calldata name,
        uint256 cost,
        uint256 creditsAwarded,
        address paymentToken,
        uint256 burnPercentage
    ) external onlyDAO {
        if (bytes(name).length == 0) revert EmptyPackageName();
        if (burnPercentage > 10000) revert InvalidBurnPercentage();

        CreditPackage storage package = _getGasStationStorage().creditPackages[packageId];
        if (bytes(package.name).length == 0) revert PackageNotFound();

        package.name = name;
        package.costInWei = cost;
        package.creditsAwarded = creditsAwarded;
        package.paymentToken = paymentToken;
        package.burnPercentage = burnPercentage;

        emit CreditPackageUpdated(packageId, name, cost, creditsAwarded, paymentToken, burnPercentage);
    }

    /**
     * @dev Set the active status of a credit package
     * @param packageId ID of the package
     * @param active New active status
     */
    function setCreditPackageActive(uint256 packageId, bool active) external onlyDAO {
        CreditPackage storage package = _getGasStationStorage().creditPackages[packageId];
        if (bytes(package.name).length == 0) revert PackageNotFound();

        package.active = active;
        emit CreditPackageStatusChanged(packageId, active);
    }

    /**
     * @dev Handle ETH payment for credit purchase
     * @param package The credit package being purchased
     */
    function _handleETHPayment(CreditPackage storage package) private {
        if (msg.value < package.costInWei) revert InsufficientPayment();

        // Refund excess payment if any
        if (msg.value > package.costInWei) {
            payable(msg.sender).transfer(msg.value - package.costInWei);
        }
    }

    /**
     * @dev Handle ERC20 token payment for credit purchase
     * @param package The credit package being purchased
     */
    function _handleTokenPayment(CreditPackage storage package) private {
        IERC20 token = IERC20(package.paymentToken);

        // Check allowance
        if (token.allowance(msg.sender, address(this)) < package.costInWei) {
            revert InsufficientPayment();
        }

        // Transfer tokens from user to contract
        if (!token.transferFrom(msg.sender, address(this), package.costInWei)) {
            revert TokenTransferFailed();
        }

        // Handle burning if specified
        if (package.burnPercentage > 0) {
            uint256 burnAmount = (package.costInWei * package.burnPercentage) / 10000;

            // Try to burn tokens (if token supports burning)
            try IERC20Burnable(package.paymentToken).burn(burnAmount) {
                emit TokensBurned(package.paymentToken, burnAmount);
            } catch {
                // If burning fails, tokens remain in contract
                // This is acceptable as some tokens may not support burning
            }
        }
    }

    /**
     * @dev Withdraw accumulated tokens from credit purchases (DAO only)
     * @param token Token address to withdraw (address(0) for ETH)
     * @param to Address to send the tokens to
     * @param amount Amount to withdraw (0 = all available)
     */
    function withdrawTokens(address token, address payable to, uint256 amount)
        external
        onlyDAO
        validAddress(to)
    {
        if (token == address(0)) {
            // Withdraw ETH
            uint256 balance = address(this).balance;
            uint256 withdrawAmount = amount == 0 ? balance : amount;

            if (withdrawAmount > balance) revert InsufficientCredits();

            to.transfer(withdrawAmount);
        } else {
            // Withdraw ERC20 tokens
            IERC20 erc20 = IERC20(token);
            uint256 balance = erc20.balanceOf(address(this));
            uint256 withdrawAmount = amount == 0 ? balance : amount;

            if (withdrawAmount > balance) revert InsufficientCredits();

            if (!erc20.transfer(to, withdrawAmount)) {
                revert TokenTransferFailed();
            }
        }
    }

    /**
     * @dev Legacy function for withdrawing ETH - use withdrawTokens instead
     * @param to Address to send the ETH to
     * @param amount Amount of ETH to withdraw (0 = all)
     */
    function withdrawETH(address payable to, uint256 amount) external onlyDAO validAddress(to) {
        uint256 balance = address(this).balance;
        uint256 withdrawAmount = amount == 0 ? balance : amount;

        if (withdrawAmount > balance) revert InsufficientCredits();

        to.transfer(withdrawAmount);
    }

    /**
     * @dev Allow contract to receive ETH for credit purchases
     */
    receive() external payable {}
}