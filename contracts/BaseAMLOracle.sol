// SPDX-License-Identifier: UNLICENCED

// We lock the Solidity version, per:
// https://consensys.github.io/smart-contract-best-practices/recommendations/#lock-pragmas-to-specific-compiler-version
pragma solidity 0.7.0; // See README.md for our Solidity version strategy

import "openzeppelin-solidity/contracts/introspection/IERC1820Registry.sol";
import "openzeppelin-solidity/contracts/access/AccessControl.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "./IBaseAMLOracle.sol";

/**
 * @title BaseAMLOracle - the abstract base contract for developing AML Oracles
 * @author Ville Sundell <development@solarius.fi>
 * @dev This is the base contract for developing AML Oracles. AML Oracles
 * itself will consist of two parts:
 *  - payment logic implemented by the AML Oracle itself, and
 *  - rest of the AML Oracle logic, including AML Status handling and
 *    non-custodial logic implemented in this contract.
 *
 * This contract covers:
 *  - non-custodial logic ({}),
 *  - AML Status handling logic ({}), and
 *  - fee handling.
 *
 * We follow modern OpenZeppelin design pattern on contract encapsulation,
 * that's why we are using mainly `private` state variables with `internal`
 * setters and getters.
 *
 * We also implement our own design pattern where client smart contract
 * accessible entry points are marked `external` for two reasons: semantically
 * it marks a user-accessible entry point, and gives us marginal gas savings
 * when handling complex data types. Setters and getters from OpenZeppelin's
 * contract encapsulation pattern also supports our pattern.
 *
 * We also implement a granular role-based access control by inheriting
 * {AccessControl}. Because we combine role-based access control with function
 * based access control, we use function names as our role names. Role check is
 * done in `external` functions, where applicable.
 *
 * Although our access control model is consistently function based, there is
 * one exception: FORCE_WITHDRAW_ROLE which can be used to skip the `assert()`
 * upon withdrawal if there is ever such need.
 *
 * At first the _Oracle Operator_ is the _Admin_, but later the Operator can
 * assign various other actors to various roles, including the Admin.
 */
abstract contract BaseAMLOracle is AccessControl, IBaseAMLOracle {
    using SafeMath for uint256; // Applicable only for uint256

    /// @dev The core structure containing all the information for an AML Status
    struct AMLStatus {
        bytes32 amlID;
        uint8 cScore;
        uint120 flags;
        uint128 timestamp;
        uint256 fee;
    }

    // Roles for our Role Based Access Control model which combines function based access control:
    bytes32 public constant SET_DEFAULT_FEE_ROLE = keccak256("setDefaultFee()");
    bytes32 public constant SET_FEE_ACCOUNT_ROLE = keccak256("setFeeAccount()");
    bytes32 public constant NOTIFY_ROLE = keccak256("notify()");
    bytes32 public constant SET_AML_STATUS_ROLE = keccak256("setAMLStatus()");
    bytes32 public constant DELETE_AML_STATUS_ROLE = keccak256("deleteAMLStatus()");
    bytes32 public constant FORCE_WITHDRAW_ROLE = keccak256("FORCE_WITHDRAW");

    // Two hard-coded constants for our ERC1820 support:
    IERC1820Registry constant ERC1820REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 constant INTERFACEHASH = keccak256(abi.encodePacked("AMLOracleAcceptDonations"));

    /// @dev All the {AMLStatus} entries reside here
    mapping (address => mapping (string => AMLStatus)) private _AMLStatuses;
    /// @dev Balance tracking for non-custodial and fee handling logic is done here
    mapping (address => uint256) private _balances;

    /// @dev Primary purpose is to provide `assert()`s regarding our
    /// non-custodial logic a way to compare balances.
    uint256 private _totalDeposits;
    /// @dev This is the account where the fees are paid upon `_fetchAMLStatus()`
    address private _feeAccount;
    /// @dev We store default fee, so upon placing an {AMLStatus} on chain, we
    /// can save some gas by not setting the fee, if so desired.
    uint256 private _defaultFee;

    /**
     * @dev Constructor sets up the Role Based Access Control, and sets the
     * initial _feeAccount to `admin`.
     * @param admin The address which will initally be the superadmin, and part
     * of all the roles.
     * @param defaultFee_ The initial default fee, can be 0
     */
    constructor(address admin, uint256 defaultFee_) {
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(SET_DEFAULT_FEE_ROLE, admin);
        _setupRole(SET_FEE_ACCOUNT_ROLE, admin);
        _setupRole(NOTIFY_ROLE, admin);
        _setupRole(SET_AML_STATUS_ROLE, admin);
        _setupRole(DELETE_AML_STATUS_ROLE, admin);
        _setupRole(FORCE_WITHDRAW_ROLE, admin);

        _feeAccount = admin;
        _defaultFee = defaultFee_;
        // Event?
    }

    /**
     * @dev See {IBaseAMLOracle-setDefaultFee}.
     */
    function setDefaultFee(uint256 defaultFee_) external override {
        require(hasRole(SET_DEFAULT_FEE_ROLE, msg.sender), "BaseAMLOracle: Caller is not allowed to set the default fee");

        emit DefaultFeeSet(_defaultFee, defaultFee_); // Omitting setter for consistency

        _defaultFee = defaultFee_;
        assert(_defaultFee == defaultFee_);
    }

    /**
     * @dev See {IBaseAMLOracle-setFeeAccount}.
     */
    function setFeeAccount(address feeAccount_) external override {
        require(hasRole(SET_FEE_ACCOUNT_ROLE, msg.sender), "BaseAMLOracle: Caller is not allowed to set the fee account");

        emit FeeAccountSet(_feeAccount, feeAccount_); // Omitting setter for consistency

        _feeAccount = feeAccount_;
        assert(_feeAccount == feeAccount_);
    }

    /**
     * @dev See {IBaseAMLOracle-notify}.
     */
    function notify(address client, string calldata message) override external {
        require(hasRole(NOTIFY_ROLE, msg.sender), "BaseAMLOracle: Caller is not allowed to notify the clients");

        emit Notified(client, message);
    }

    /**
     * @dev See {IBaseAMLOracle-setAMLStatus}.
     */
    function setAMLStatus(address client, string calldata target, bytes32 amlID, uint8 cScore, uint120 flags, uint256 fee) external override {
        require(hasRole(SET_AML_STATUS_ROLE, msg.sender), "BaseAMLOracle: Caller is not allowed to set AML Statuses");
        require(cScore < 100, "BaseAMLOracle: The cScore must be between 0 and 99");
        AMLStatus memory status;

        status = AMLStatus(amlID, cScore, flags, uint128(block.timestamp), fee); // The timestamp is not critical, and will overflow in ~10 nonillion (US) years (10,783,118,943,836,478,994,022,445,749,252)
        _setAMLStatus(client, target, status);
    }

    /**
     * @dev See {IBaseAMLOracle-deleteAMLStatus}.
     */
    function deleteAMLStatus(address client, string calldata target) external override {
        require(hasRole(DELETE_AML_STATUS_ROLE, msg.sender), "BaseAMLOracle: Caller is not allowed to delete AML Statuses");

        _deleteAMLStatus(client, target);
    }

    /**
     * @dev See {IBaseAMLOracle-askAMLStatus}.
     */
    function askAMLStatus(uint256 maxFee, string calldata target) external override {
        emit AMLStatusAsked(msg.sender, maxFee, target);
    }

    /**
     * @dev See {IBaseAMLOracle-fetchAMLStatus}.
     */
    function fetchAMLStatus(string calldata target) external override returns (bytes32 amlID, uint8 cScore, uint120 flags) {
        return _fetchAMLStatus(msg.sender, target);
    }

    /**
     * @dev {IBaseAMLOracle-getAMLStatusMetadata}.
     */
    function getAMLStatusMetadata(address client, string calldata target) external view override returns (uint256 timestamp, uint256 fee) {
        AMLStatus memory status = _getAMLStatusCopy(client, target);

        return (status.timestamp, _getFee(status));
    }

    /**
     * @dev See {IBaseAMLOracle-getDefaultFee}.
     */
    function getDefaultFee() public view override returns (uint256 defaultFee) {
        return _defaultFee;
    }

    /**
     * @dev See {IBaseAMLOracle-getFeeAccount}.
     */
    function getFeeAccount() public view override returns (address feeAccount) {
        return _feeAccount;
    }

    /**
     * @dev See {IBaseAMLOracle-balanceOf}.
     */
    function balanceOf(address account) public view override returns (uint256 balance) {
        return _balances[account];
    }

    function _setAMLStatus(address client, string calldata target, AMLStatus memory status) internal {
        require(client != address(0), "BaseAMLOracle: client must not be 0x0");
        // Check how much gas target length check would require

        _AMLStatuses[client][target] = status;

        emit AMLStatusSet(client, target);
    }

    function _deleteAMLStatus(address client, string calldata target) internal {
        require(client != address(0), "BaseAMLOracle: client must not be 0x0");
        delete(_AMLStatuses[client][target]);

        emit AMLStatusDeleted(client, target);
    }

    function _fetchAMLStatus(address client, string calldata target) internal returns (bytes32 amlID, uint8 cScore, uint120 flags) {
        AMLStatus memory status = _getAMLStatusCopy(client, target);
        require(status.timestamp > 0, "BaseAMLOracle: No such AML Status");

        _balances[client] = _balances[client].sub(_getFee(status));
        _balances[_feeAccount] = _balances[_feeAccount].add(_getFee(status));

        _deleteAMLStatus(client, target);

        emit AMLStatusFetched(client, target);
        return (status.amlID, status.cScore, status.flags);
    }

    function _donate(address donor, address account, uint256 amount) internal {
        address recipient = ERC1820REGISTRY.getInterfaceImplementer(account, INTERFACEHASH);
        require(recipient != address(0), "Account does not accept donations.");
        _deposit(recipient, amount);

        emit Donated(donor, recipient, amount);
    }

    function _deposit(address account, uint256 amount) internal {
        assert(account != address(0)); // Should never be 0x0
        require(amount > 0, "BaseAMLOracle: amount to deposit must be greater than 0");

        _balances[account] = _balances[account].add(amount);
        _totalDeposits = _totalDeposits.add(amount);

        assert(_getTotalBalance() >= _totalDeposits);
        emit Deposited(account, amount);
    }

    function _withdraw(address account, uint256 amount) internal {
        assert(account != address(0)); // Should never be 0x0
        require(amount > 0, "BaseAMLOracle: amount to withdraw must be greater than 0");

        _balances[account] = _balances[account].sub(amount);
        _totalDeposits = _totalDeposits.sub(amount);

        if (!hasRole(FORCE_WITHDRAW_ROLE, account)) {
            assert(_getTotalBalance() >= _totalDeposits);
        }

        emit Withdrawn(account, amount);
    }

    function _getTotalDeposits() internal view returns (uint256 totalDeposits) {
        return _totalDeposits;
    }

    function _getAMLStatusCopy(address client, string calldata target) internal view returns (AMLStatus memory status) {
        require(client != address(0), "BaseAMLOracle: client must not be 0x0");
        //require(target.len > 0, "BaseAMLOracle: target must not be a zero length string");

        return _AMLStatuses[client][target];
    }

    function _getFee(AMLStatus memory status) internal view returns (uint256 fee) {
        if (status.fee > 0) { // Braces for clarity
            return status.fee;
        } else {
            return _defaultFee;
        }
    }

    function _getTotalBalance() internal virtual view returns (uint256 balance);
}
