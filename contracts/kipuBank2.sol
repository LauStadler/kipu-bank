// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBank
 * @notice Banco descentralizado que permite a los usuarios depositar y retirar ETH y tokens ERC20.
 * @dev Todos los depósitos se contabilizan a un valor interno normalizado para respetar un límite global (bankCap).
 * @dev Implementa control de acceso mediante OpenZeppelin AccessControl.
 */
contract KipuBank is AccessControl {
    // ---------- Roles ----------
    /// @notice Rol de administrador con permisos para gestionar usuarios y límites.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Rol de usuario que permite depositar y retirar fondos.
    bytes32 public constant USER_ROLE  = keccak256("USER_ROLE");

    // ---------- Errores ----------
    /// @notice Error cuando un depósito excede el límite permitido.
    /// @param amount Monto normalizado que excede el límite.
    error InvalidDeposit(uint256 amount);

    /// @notice Error cuando un retiro es inválido.
    /// @param amount Monto intentado retirar.
    error InvalidWithdrawal(uint256 amount);

    // ---------- Datos bancarios ----------
    /// @notice Límite máximo de depósitos normalizados en el contrato.
    uint256 public immutable bankCap;

    /// @notice Suma total de depósitos normalizados realizados en el contrato.
    uint256 public totalDepositedNormalized;

    /// @notice Límite máximo de retiro por transacción.
    uint256 public withdrawLimit;

    /// @notice Balance de ETH de cada usuario.
    mapping(address => uint256) public bankBalance;

    /// @notice Balance de cada token ERC20 por usuario.
    mapping(address => mapping(address => uint256)) public tokenBalances;

    /// @notice Decimales de referencia para normalización de cada token ERC20.
    mapping(address => uint8) public tokenDecimals;

    // ---------- Oráculo Chainlink ----------
    /// @notice Oráculo Chainlink para obtener precio ETH/USD (puede usarse para informes o conversiones).
    AggregatorV3Interface internal priceFeed;

    // ---------- Eventos ----------
    event Deposit(address indexed user, uint256 amount);
    event DepositToken(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event WithdrawToken(address indexed user, address indexed token, uint256 amount);
    event WithdrawLimitUpdated(uint256 newLimit);

    // ---------- Constructor ----------
    /**
     * @notice Inicializa el contrato KipuBank.
     * @param _bankCap Límite máximo global de depósitos normalizados.
     * @param _withdrawLimit Límite máximo de retiro por transacción.
     * @param _priceFeed Dirección del oráculo Chainlink ETH/USD.
     */
    constructor(uint256 _bankCap, uint256 _withdrawLimit, address _priceFeed) {
        require(_priceFeed != address(0), "Precio invalido");
        bankCap = _bankCap;
        withdrawLimit = _withdrawLimit;
        priceFeed = AggregatorV3Interface(_priceFeed);

        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(USER_ROLE, msg.sender);
    }

    // ---------- Modificadores ----------
    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Solo admin");
        _;
    }

    modifier onlyUser() {
        require(hasRole(USER_ROLE, msg.sender), "Solo usuario");
        _;
    }

    modifier withdrawalWithinLimit(uint256 _amount) {
        if (_amount > withdrawLimit || _amount > bankBalance[msg.sender])
            revert InvalidWithdrawal(_amount);
        _;
    }

    // ---------- Funciones internas ----------
    /**
     * @notice Normaliza un monto de token a un valor estándar para contabilidad.
     * @param amount Monto a normalizar.
     * @param tokenDec Decimales del token.
     * @param targetDec Decimales de referencia para contabilidad (ej. 6).
     * @return Normalized Monto normalizado.
     */
    function _normalize(uint256 amount, uint8 tokenDec, uint8 targetDec) internal pure returns (uint256) {
        if (tokenDec > targetDec) return amount / (10 ** (tokenDec - targetDec));
        if (tokenDec < targetDec) return amount * (10 ** (targetDec - tokenDec));
        return amount;
    }

    /**
     * @notice Verifica que un depósito no supere el límite global del banco.
     * @param normalizedAmount Monto normalizado a verificar.
     */
    function _checkDepositLimit(uint256 normalizedAmount) internal view {
        if (totalDepositedNormalized + normalizedAmount > bankCap)
            revert InvalidDeposit(normalizedAmount);
    }

    /**
     * @notice Lógica interna para registrar un depósito de ETH.
     * @param sender Dirección del usuario.
     * @param amountETH Cantidad de ETH depositada.
     * @param normalized Monto normalizado contabilizado para bankCap.
     */
    function _handleDeposit(address sender, uint256 amountETH, uint256 normalized) internal {
        require(amountETH > 0, "Monto invalido");
        bankBalance[sender] += amountETH;
        totalDepositedNormalized += normalized;
        emit Deposit(sender, amountETH);
    }

    // ---------- Funciones de usuario ----------
    /**
     * @notice Deposita ETH en la bóveda del usuario.
     * @dev Se normaliza a 6 decimales para contabilizar contra bankCap.
     */
    function deposit() external payable onlyUser {
        uint256 normalized = _normalize(msg.value, 18, 6);
        _checkDepositLimit(normalized);
        _handleDeposit(msg.sender, msg.value, normalized);
    }

    /**
     * @notice Retira ETH de la bóveda del usuario.
     * @param amount Cantidad de ETH a retirar.
     */
    function withdraw(uint256 amount) external onlyUser withdrawalWithinLimit(amount) {
        bankBalance[msg.sender] -= amount;
        uint256 normalized = _normalize(amount, 18, 6);
        totalDepositedNormalized -= normalized;

        payable(msg.sender).transfer(amount);
        emit Withdraw(msg.sender, amount);
    }

    /**
     * @notice Deposita tokens ERC20 en la bóveda del usuario.
     * @param token Dirección del token ERC20.
     * @param amount Cantidad a depositar.
     * @param decimals Decimales del token ERC20 (solo se usa la primera vez que se deposita).
     */
    function depositToken(address token, uint256 amount, uint8 decimals) external onlyUser {
        require(amount > 0, "Monto invalido");
        if (tokenDecimals[token] == 0) {
            tokenDecimals[token] = decimals;
        }
        uint8 dec = tokenDecimals[token];
        uint256 normalized = _normalize(amount, dec, 6);
        _checkDepositLimit(normalized);

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        tokenBalances[token][msg.sender] += amount;
        totalDepositedNormalized += normalized;

        emit DepositToken(msg.sender, token, amount);
    }

    /**
     * @notice Retira tokens ERC20 de la bóveda del usuario.
     * @param token Dirección del token ERC20.
     * @param amount Cantidad a retirar.
     */
    function withdrawToken(address token, uint256 amount) external onlyUser {
        require(tokenBalances[token][msg.sender] >= amount, "Fondos insuficientes");

        tokenBalances[token][msg.sender] -= amount;
        uint8 dec = tokenDecimals[token];
        uint256 normalized = _normalize(amount, dec, 6);
        totalDepositedNormalized -= normalized;

        IERC20(token).transfer(msg.sender, amount);
        emit WithdrawToken(msg.sender, token, amount);
    }

    // ---------- Receive / Fallback ----------
    /// @notice Permite recibir ETH directamente y contabilizarlo.
    receive() external payable onlyUser {
        uint256 normalized = _normalize(msg.value, 18, 6);
        _checkDepositLimit(normalized);
        _handleDeposit(msg.sender, msg.value, normalized);
    }

    /// @notice Función fallback para recibir ETH directamente.
    fallback() external payable onlyUser {
        uint256 normalized = _normalize(msg.value, 18, 6);
        _checkDepositLimit(normalized);
        _handleDeposit(msg.sender, msg.value, normalized);
    }

    // ---------- Chainlink ----------
    /// @notice Devuelve el último precio ETH/USD del oráculo.
    /// @return price Precio ETH/USD.
    function getLatestETHPrice() public view returns (int256 price) {
        (, price,,,) = priceFeed.latestRoundData();
    }

    // ---------- Límite de retiro ----------
    /**
     * @notice Actualiza el límite máximo de retiro por transacción.
     * @param newLimit Nuevo límite a establecer.
     */
    function updateWithdrawLimit(uint256 newLimit) external onlyAdmin {
        require(newLimit > 0, "Limite invalido");
        withdrawLimit = newLimit;
        emit WithdrawLimitUpdated(newLimit);
    }

    // ---------- Gestión de roles ----------
    /// @notice Agrega un usuario al rol USER_ROLE.
    /// @param user Dirección del usuario a agregar.
    function addUser(address user) external onlyAdmin {
        grantRole(USER_ROLE, user);
    }

    /// @notice Remueve un usuario del rol USER_ROLE.
    /// @param user Dirección del usuario a remover.
    function removeUser(address user) external onlyAdmin {
        revokeRole(USER_ROLE, user);
    }
}
