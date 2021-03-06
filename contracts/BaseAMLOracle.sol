// SPDX-License-Identifier: UNLICENCED
pragma solidity 0.7.0; // See README.md's section "Solidity version"

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
 *  - non-custodial logic,
 *  - AML Status handling logic, and
 *  - fee handling.
 *
 * We follow the modern OpenZeppelin design pattern on contract encapsulation,
 * that's why we are using mainly `private` state variables with `internal`
 * setters and getters.
 *
 * We also implement our own design pattern where client smart contract
 * accessible entry points are marked `external` for two reasons: semantically
 * it marks a user-accessible entry point, and gives us marginal gas savings
 * when handling complex data types. Setters and getters from OpenZeppelin's
 * contract encapsulation pattern also supports our pattern.
 *
 * External functions are overridable: in the future it might be useful that
 * the Oracle (contract inheriting this contract) can override external
 * entry points.
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
 * NOTE: Role `DEFAULT_ADMIN_ROLE` makes an admin, the account having this role
 * can freely grant and revoke any role to/from any account. For more
 * information on access control, see:
 * https://docs.openzeppelin.com/contracts/2.x/access-control.
 *
 * At first the *Oracle Operator* is the *Admin*, but later the Operator can
 * assign various other actors to various roles.
 */


abstract contract BaseAMLOracle is AccessControl, IBaseAMLOracle {
    using SafeMath for uint256; // Applicable only for uint256

    /// @dev The core structure containing all the information for an AML
    /// status
    struct AMLStatus {
        bytes32 amlID;
        uint8 cScore;
        uint120 flags;
        uint128 timestamp;
        uint256 fee;
    }

    // Roles for our Role Based Access Control model which combines function
    // based access control:
    bytes32 public constant SET_DEFAULT_FEE_ROLE = keccak256("setDefaultFee()");
    bytes32 public constant SET_FEE_ACCOUNT_ROLE = keccak256("setFeeAccount()");
    bytes32 public constant NOTIFY_ROLE = keccak256("notify()");
    bytes32 public constant SET_AML_STATUS_ROLE = keccak256("setAMLStatus()");
    bytes32 public constant DELETE_AML_STATUS_ROLE = keccak256("deleteAMLStatus()");
    bytes32 public constant FORCE_WITHDRAW_ROLE = keccak256("FORCE_WITHDRAW");

    // Hard-coded constant for our ERC1820 support:
    IERC1820Registry constant ERC1820REGISTRY = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);

    /// @dev All the {AMLStatus} entries reside here
    mapping (address => mapping (string => AMLStatus)) private _amlStatuses;
    /// @dev Balance tracking for non-custodial and fee handling logic is done
    /// here
    mapping (address => uint256) private _balances;

    /// @dev Primary purpose is to provide `assert()`s regarding our
    /// non-custodial logic a way to compare balances.
    uint256 private _totalDeposits;
    /// @dev This is the account where the fees are paid upon
    /// {_fetchAMLStatus}.
    address private _feeAccount;
    /// @dev We store default fee, so upon placing an {AMLStatus} on chain, we
    /// can save some gas by not setting the fee, if so desired.
    uint256 private _defaultFee;

    /**
     * @dev Constructor sets up the Role Based Access Control, and sets the
     * initial _feeAccount to `admin`.
     *
     * @param admin The address which will initally be the superadmin, and part
     * of all the roles.
     * @param defaultFee_ The initial default fee, can be 0
     */
    constructor(address admin, uint256 defaultFee_) {
        require(admin != address(0), "BaseAMLOracle: the admin account must not be 0x0");

        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(SET_DEFAULT_FEE_ROLE, admin);
        _setupRole(SET_FEE_ACCOUNT_ROLE, admin);
        _setupRole(NOTIFY_ROLE, admin);
        _setupRole(SET_AML_STATUS_ROLE, admin);
        _setupRole(DELETE_AML_STATUS_ROLE, admin);
        _setupRole(FORCE_WITHDRAW_ROLE, admin);

        _feeAccount = admin;
        _defaultFee = defaultFee_;
    }

    /**
     * @dev See {IBaseAMLOracle-setDefaultFee}.
     */
    function setDefaultFee(uint256 defaultFee_) external virtual override {
        require(hasRole(SET_DEFAULT_FEE_ROLE, msg.sender), "BaseAMLOracle: the caller is not allowed to set the default fee");

        emit DefaultFeeSet(_defaultFee, defaultFee_);

        _defaultFee = defaultFee_;
        assert(_defaultFee == defaultFee_);
    }

    /**
     * @dev See {IBaseAMLOracle-setFeeAccount}.
     */
    function setFeeAccount(address feeAccount_) external virtual override {
        require(hasRole(SET_FEE_ACCOUNT_ROLE, msg.sender), "BaseAMLOracle: the caller is not allowed to set the fee account");
        require(feeAccount_ != address(0), "BaseAMLOracle: the fee account must not be 0x0");

        emit FeeAccountSet(_feeAccount, feeAccount_);

        _feeAccount = feeAccount_;
        assert(_feeAccount == feeAccount_);
    }

    /**
     * @dev See {IBaseAMLOracle-notify}.
     */
    function notify(address client, string calldata message) external virtual override {
        require(hasRole(NOTIFY_ROLE, msg.sender), "BaseAMLOracle: the caller is not allowed to notify the clients");
        require(client != address(0), "BaseAMLOracle: client must not be 0x0");

        emit Notified(client, message);
    }

    /**
     * @dev See {IBaseAMLOracle-setAMLStatus}.
     */
    function setAMLStatus(address client, string calldata target, bytes32 amlID, uint8 cScore, uint120 flags, uint256 fee) external virtual override {
        require(hasRole(SET_AML_STATUS_ROLE, msg.sender), "BaseAMLOracle: the caller is not allowed to set AML statuses");
        AMLStatus memory status;

        // The timestamp is not critical, so we can:
        // - use block.timestamp, and
        // - truncate it directly from uint256 to uint128.
        status = AMLStatus(amlID, cScore, flags, uint128(block.timestamp), fee);
        _setAMLStatus(client, target, status);
    }

    /**
     * @dev See {IBaseAMLOracle-deleteAMLStatus}.
     */
    function deleteAMLStatus(address client, string calldata target) external virtual override {
        require(hasRole(DELETE_AML_STATUS_ROLE, msg.sender), "BaseAMLOracle: the caller is not allowed to delete AML statuses");

        _deleteAMLStatus(client, target);
    }

    /**
     * @dev See {IBaseAMLOracle-askAMLStatus}.
     */
    function askAMLStatus(uint256 maxFee, string calldata target) external virtual override {
        require(_getStringLength(target) > 0, "BaseAMLOracle: target must not be an empty string");

        emit AMLStatusAsked(msg.sender, maxFee, target);
    }

    /**
     * @dev See {IBaseAMLOracle-fetchAMLStatus}.
     */
    function fetchAMLStatus(string calldata target) external virtual override returns (bytes32 amlID, uint8 cScore, uint120 flags) {
        return _fetchAMLStatus(msg.sender, target, 0);
    }

    /**
     * @dev See {IBaseAMLOracle-fetchAMLStatus}.
     */
    function fetchAMLStatus(uint256 maxFee, string calldata target) external virtual override returns (bytes32 amlID, uint8 cScore, uint120 flags) {
        return _fetchAMLStatus(msg.sender, target, maxFee);
    }

    /**
     * @dev See {IBaseAMLOracle-getAMLStatusMetadata}.
     */
    function getAMLStatusMetadata(string calldata target) external view virtual override returns (uint256 timestamp, uint256 fee) {
        AMLStatus memory status = _getAMLStatusCopy(msg.sender, target);

        return (status.timestamp, _getFee(status));
    }

    /**
     * @dev See {IBaseAMLOracle-getAMLStatusMetadata}.
     */
    function getAMLStatusMetadata(address client, string calldata target) external view virtual override returns (uint256 timestamp, uint256 fee) {
        AMLStatus memory status = _getAMLStatusCopy(client, target);

        return (status.timestamp, _getFee(status));
    }

    /**
     * @dev See {IBaseAMLOracle-getAMLStatusTimestamp}.
     */
    function getAMLStatusTimestamp(address client, string calldata target) external view virtual override returns (uint256 timestamp) {
        require(client != address(0), "BaseAMLOracle: client must not be 0x0");
        require(_getStringLength(target) > 0, "BaseAMLOracle: target must not be an empty string");

        return _amlStatuses[client][target].timestamp;
    }

    /**
     * @notice {getAMLStatusMetadata} is the preferred way to access the fee
     * (and timestamp)! If you are using this function, please read this part
     * of the documentation carefully!
     *
     * @dev See {IBaseAMLOracle-getAMLStatusFee}.
     */
    function getAMLStatusFee(address client, string calldata target) external view virtual override returns (uint256 fee) {
        require(client != address(0), "BaseAMLOracle: client must not be 0x0");
        require(_getStringLength(target) > 0, "BaseAMLOracle: target must not be an empty string");

        return _amlStatuses[client][target].fee;
    }

    /**
     * @dev See {IBaseAMLOracle-getDefaultFee}.
     */
    function getDefaultFee() public view virtual override returns (uint256 defaultFee) {
        return _defaultFee;
    }

    /**
     * @dev See {IBaseAMLOracle-getFeeAccount}.
     */
    function getFeeAccount() public view virtual override returns (address feeAccount) {
        return _feeAccount;
    }

    /**
     * @dev See {IBaseAMLOracle-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256 balance) {
        return _balances[account];
    }

    /**
     * @dev See {IBaseAMLOracle-getTotalDeposits}.
     */
    function getTotalDeposits() public view virtual override returns (uint256 totalDeposits) {
        return _totalDeposits;
    }

    /**
     * @dev See {IBaseAMLOracle-getTotalBalance}.
     */
    function getTotalBalance() public view virtual override returns (uint256 balance);

    /**
     * @dev See {IBaseAMLOracle-getInterfaceHash}.
     */
    function getInterfaceHash() public pure virtual override returns (bytes32 interfaceHash);

    /**
     * @dev Internal setter for setting/updating any given {AMLStatus}.
     *
     * @param client Client smart contract whose AML status database is used
     * for this action
     * @param target The target address whose {AMLStatus} entry is going to be
     * set/updated
     * @param status The {AMLStatus} being set or updated
     */
    function _setAMLStatus(address client, string calldata target, AMLStatus memory status) internal {
        require(client != address(0), "BaseAMLOracle: cannot set AML status for 0x0");
        require(_getStringLength(target) > 0, "BaseAMLOracle: target must not be an empty string");
        require(status.cScore < 100, "BaseAMLOracle: the cScore must be between 0 and 99");

        _amlStatuses[client][target] = status;

        emit AMLStatusSet(client, target);
    }

    /**
     * @dev Internal function to delete an {AMLStatus}.
     *
     * @param client Client smart contract whose AML status database is used
     * for this action
     * @param target The target address whose {AMLStatus} entry is going to be
     * deleted
     */
    function _deleteAMLStatus(address client, string calldata target) internal {
        require(client != address(0), "BaseAMLOracle: cannot delete AML status for 0x0");
        require(_getStringLength(target) > 0, "BaseAMLOracle: target must not be an empty string");

        delete(_amlStatuses[client][target]);

        emit AMLStatusDeleted(client, target);
    }

    /**
     * @dev Internal getter for an {AMLStatus}. The status will be deleted
     * after fetching.
     *
     * @param client Client smart contract whose AML status database is used
     * for this action
     * @param target The target address whose {AMLStatus} entry is going to be
     * fetched
     * @param maxFee Maximum fee the client is willing to pay for the fetch
     */
    function _fetchAMLStatus(address client, string calldata target, uint256 maxFee) internal returns (bytes32 amlID, uint8 cScore, uint120 flags) {
        assert(client != address(0)); // Should never happen
        AMLStatus memory status = _getAMLStatusCopy(client, target);
        uint256 fee = _getFee(status);

        if (maxFee > 0 && fee > maxFee) {
            revert("BaseAMLOracle: the required fee is greater than the specified maximum fee");
        }

        _balances[client] = _balances[client].sub(fee);
        _balances[_feeAccount] = _balances[_feeAccount].add(fee);

        _deleteAMLStatus(client, target);

        emit AMLStatusFetched(client, target);
        return (status.amlID, status.cScore, status.flags);
    }

    /**
     * @dev Accounting mechanism for donations.
     *
     * All donations must go through this function, so the destination
     * account's willingness to accept donations can be checked via an ERC-1820
     * interface implementation check.
     *
     * @param donor The account giving the donation
     * @param account The account receiving the donation
     * @param amount The amount of the donation
     */
    function _donate(address donor, address account, uint256 amount) internal {
        assert(donor != address(0)); // Should never be 0x0
        address recipient = ERC1820REGISTRY.getInterfaceImplementer(account, getInterfaceHash());
        require(recipient != address(0), "BaseAMLOracle: the account does not accept donations");

        _deposit(recipient, amount);

        emit Donated(donor, recipient, amount);
    }

    /**
     * @dev Internal mechanism for handling deposits in general (including
     * donations).
     *
     * This will be also invoked by _donate() in addition to the oracle (when
     * doing a normal deposit).
     *
     * @param account Account whose balance will be increased
     * @param amount How much the internal balance of the `account` will be
     * increased
     */
    function _deposit(address account, uint256 amount) internal {
        assert(account != address(0)); // Should never be 0x0
        require(amount > 0, "BaseAMLOracle: amount to deposit must be greater than 0");

        _balances[account] = _balances[account].add(amount);
        _totalDeposits = _totalDeposits.add(amount);

        assert(getTotalBalance() >= _totalDeposits);
        emit Deposited(account, amount);
    }

    /**
     * @dev Internal mechanism for handling withdrawals.
     *
     * @param account Account which is doing the withrawal
     * @param amount The amount to debit from `account`s internal balance
     */
    function _withdraw(address account, uint256 amount) internal {
        assert(account != address(0)); // Should never be 0x0
        require(amount > 0, "BaseAMLOracle: amount to withdraw must be greater than 0");

        _balances[account] = _balances[account].sub(amount);
        _totalDeposits = _totalDeposits.sub(amount);

        if (!hasRole(FORCE_WITHDRAW_ROLE, account)) {
            assert(getTotalBalance() >= _totalDeposits);
        }

        emit Withdrawn(account, amount);
    }

    /**
     * @dev We take a copy of the {AMLStatus} entry in question and place it
     * to `memory` for cheaper handling.
     *
     * @param client Client smart contract whose AML status database is used
     * for this action
     * @param target The target address whose {AMLStatus} entry was
     * requested
     * @return status The in-memory copy of {AMLStatus} in question
     */
    function _getAMLStatusCopy(address client, string calldata target) internal view returns (AMLStatus memory status) {
        require(client != address(0), "BaseAMLOracle: client must not be 0x0");
        require(_getStringLength(target) > 0, "BaseAMLOracle: target must not be an empty string");

        status = _amlStatuses[client][target];
        require(status.timestamp > 0, "BaseAMLOracle: no such AML status");

        return status;
    }

    /**
     * @dev Determine fee for this particular {AMLStatus} query.
     *
     * The fee can be unique for each {AMLStatus} query. Default fee can be
     * also used, in order to save gas while placing the status on-chain.
     *
     * @param status The {AMLStatus} in question
     * @return fee The resulting fee
     */
    function _getFee(AMLStatus memory status) internal view returns (uint256 fee) {
        if (status.fee > 0) { // Braces for clarity
            return status.fee;
        } else {
            return _defaultFee;
        }
    }

    /**
     * @dev A helper function to calculate string length in calldata.
     *
     * In our exceptional case, strings reside in `calldata`, calculating
     * string length there is much cheaper than in `memory`
     * (let alone `storage`).
     *
     * @param str The string to calculate length for
     * @return length The length of the string
     */
    function _getStringLength(string calldata str) internal pure returns (uint256 length) {
        bytes memory tmp = bytes(str);
        return tmp.length;
    }
}
