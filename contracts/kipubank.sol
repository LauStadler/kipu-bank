// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title KipuBank
 * @notice A simple bank contract to deposit and withdraw ETH with per-user vaults, limits, and secure transfers.
 * @dev This contract is for educational purposes only.
 */
contract KipuBank {

    /*///////////////////////
                Variables
    //////////////////////*/

    /// @notice Mapping to store the balance of each user
    mapping(address => uint256) public bankBalance;

    /// @notice Maximum amount of ETH a user can deposit in total
    uint256 public immutable bankCap;

    /// @notice Maximum amount of ETH a user can withdraw per transaction
    uint256 public immutable withdrawLimit;

    /// @notice Counter for total deposit transactions
    uint256 public totalDeposits;

    /// @notice Counter for total withdrawal transactions
    uint256 public totalWithdrawals;

    /*///////////////////////
                Events
    //////////////////////*/

    /// @notice Emitted when a user deposits ETH
    /// @param user Address of the depositor
    /// @param amount Amount of ETH deposited
    event DepositMade(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws ETH
    /// @param user Address of the withdrawer
    /// @param amount Amount of ETH withdrawn
    event WithdrawalMade(address indexed user, uint256 amount);

    /*///////////////////////
                Errors
    //////////////////////*/

    /// @notice Error thrown when a deposit exceeds the user's bankCap
    /// @param _amount Amount attempted to deposit
    error InvalidDeposit(uint256 _amount);

    /// @notice Error thrown when a withdrawal is invalid
    /// @param _amount Amount attempted to withdraw
    error InvalidWithdrawal(uint256 _amount);

    /// @notice Error thrown if an ETH transfer fails
    /// @param errorData Raw error data returned from failed call
    error TransactionFailed(bytes errorData);

    /*///////////////////////
                Modifiers
    //////////////////////*/

    /// @notice Ensures that a deposit does not exceed the user's bankCap
    /// @param _amount Amount to deposit
    modifier depositWithinLimit(uint256 _amount) {
        if (bankBalance[msg.sender] + _amount > bankCap) revert InvalidDeposit(_amount);
        _;
    }

    /// @notice Ensures that a withdrawal does not exceed withdrawLimit or user's balance
    /// @param _amount Amount to withdraw
    modifier withdrawalWithinLimit(uint256 _amount) {
        if (_amount > withdrawLimit || _amount > bankBalance[msg.sender]) revert InvalidWithdrawal(_amount);
        _;
    }

    /*///////////////////////
                Constructor
    //////////////////////*/

    /**
     * @notice Sets the bankCap and withdrawLimit for all users
     * @param _bankCap Maximum deposit per user
     * @param _withdrawLimit Maximum withdrawal per transaction
     */
    constructor(uint256 _bankCap, uint256 _withdrawLimit) {
        bankCap = _bankCap;
        withdrawLimit = _withdrawLimit;
        totalDeposits = 0;
        totalWithdrawals = 0;
    }

    /*///////////////////////
                Receive / Fallback
    //////////////////////*/

    /// @notice Function to receive ETH sent directly to the contract
    /// @dev Ether sent this way will remain in the contract without attribution
    receive()  external payable{
		bankBalance[msg.sender] += msg.value;
    	emit DepositMade(msg.sender, msg.value);
	}

    fallback() external payable {}

    /*///////////////////////
                Functions
    //////////////////////*/

    /**
     * @notice Deposit ETH into your personal vault
     * @dev Uses `depositWithinLimit` modifier to enforce max deposit
     */
    function deposit() external payable depositWithinLimit(msg.value) {
       
	    bankBalance[msg.sender] += msg.value;
        totalDeposits += 1;

        emit DepositMade(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH from your personal vault
     * @param _amount Amount to withdraw
     * @dev Uses `withdrawalWithinLimit` modifier to enforce limits
     */
    function withdraw(uint256 _amount) external withdrawalWithinLimit(_amount) {
        bankBalance[msg.sender] -= _amount;
        totalWithdrawals += 1;

        emit WithdrawalMade(msg.sender, _amount);

        _transferEth(_amount);
    }

    /**
     * @notice Private function to securely transfer ETH
     * @param _amount Amount of ETH to send
     * @dev Reverts if the transfer fails
     */
    function _transferEth(uint256 _amount) private { 
		(bool success, bytes memory errorData) = msg.sender.call{value: _amount}(""); 
		if (!success) revert TransactionFailed(errorData); // o podés crear un error personalizado }
	}

	/// @notice check the balance of the sender 
	function getMyBalance() external view returns (uint256) { 
		return bankBalance[msg.sender]; 
	}

}