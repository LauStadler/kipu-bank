// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

/**
 * @title KipuBank
 * @notice Banco descentralizado que permite depósitos en cualquier token soportado y los convierte automáticamente a USDC.
 * @dev Los fondos se contabilizan en USDC usando Uniswap V2. Mantiene límites globales y oráculo Chainlink para referencia de precios ETH/USD.
 */
contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------- Roles ----------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant USER_ROLE = keccak256("USER_ROLE");

    // ---------- Variables ----------
    uint256 public immutable bankCap;
    uint256 public totalDepositedNormalized;
    uint256 public withdrawLimit;

    mapping(address => uint256) public usdcBalances;

    AggregatorV3Interface internal priceFeed;
    IUniswapV2Factory public immutable FACTORY;
    address public immutable usdc;

    // ---------- Eventos ----------
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived);
    event Withdraw(address indexed user, uint256 usdcAmount);
    event WithdrawAsETH(address indexed user, uint256 usdcSpent, uint256 ethOut);
    event WithdrawLimitUpdated(uint256 newLimit);
     event SwapModule_SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
   
    //------------Errores------------
    error SwapModule_InsufficientOutputAmount();
    error SwapModule_InsufficientLiquidity();
    error SwapModule_PairDoesNotExist();
    error SwapModule_InvalidAddress();
    error SwapModule_InvalidAmount();

    // ---------- Constructor ----------
    /**
     * @param _bankCap Límite máximo global de depósitos (en unidades de USDC).
     * @param _withdrawLimit Límite máximo de retiro por transacción.
     * @param _priceFeed Dirección del oráculo Chainlink ETH/USD.
     * @param _usdc Dirección del token USDC.
     */
    constructor(
        uint256 _bankCap,
        uint256 _withdrawLimit,
        address _priceFeed,
        address _usdc,
        address _factory
    ) {
        require(_priceFeed != address(0), "PriceFeed invalido");
        require(_usdc != address(0), "USDC invalido");

        bankCap = _bankCap;
        withdrawLimit = _withdrawLimit;
        priceFeed = AggregatorV3Interface(_priceFeed);
        usdc = _usdc;
        FACTORY = IUniswapV2Factory(_factory);
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

    //---------FUNCIONES-------------

    /// @notice Valida que ambas direcciones no sean cero y sean diferentes
    /// @param tokenA Primera dirección a validar
    /// @param tokenB Segunda dirección a validar
    modifier validTokenAddresses(address tokenA, address tokenB) {
        if (tokenA == address(0) || tokenB == address(0)) {
            revert SwapModule_InvalidAddress();
        }
        if (tokenA == tokenB) {
            revert SwapModule_InvalidAddress();
        }
        _;
    }

    /// @notice Valida que la cantidad sea mayor que cero
    /// @param amount Cantidad a validar
    modifier validAmount(uint256 amount) {
        if (amount == 0) {
            revert SwapModule_InvalidAmount();
        }
        _;
    }

    /// @notice Valida que el par de tokens exista en el factory
    /// @param tokenA Primer token
    /// @param tokenB Segundo token
    modifier pairExists(address tokenA, address tokenB) {
        address pair = FACTORY.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            revert SwapModule_PairDoesNotExist();
        }
        _;
    }
    
    /**
     * @notice Función para ejecutar swaps de inputs exactos en Uniswap V2
     * @notice Los outputs pueden variar según el valor mínimo amountOutMin
     * @param tokenIn La dirección del token de entrada
     * @param tokenOut La dirección del token de salida
     * @param amountIn La cantidad a intercambiar
     * @param amountOutMin La cantidad mínima aceptada después de un swap
     * @dev Esta función sigue las mejores prácticas de Uniswap V2
     * @return amountOut cantidad de tokens recibidos
     */
    function swapExactInputSingle(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin)
        internal
        validTokenAddresses(tokenIn, tokenOut)
        validAmount(amountIn)
        pairExists(tokenIn, tokenOut)
        returns (uint256 amountOut)
    {
        // Obtener el par (ya validado por el modificador pairExists)
        address pair = FACTORY.getPair(tokenIn, tokenOut);

        // 1. Obtener reservas antes del swap (para cálculo)
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair)
            .getReserves();

        // Determinar cuál token es token0 y token1
        address token0 = IUniswapV2Pair(pair).token0();
        bool token0IsTokenIn = token0 == tokenIn;

        // 2. Calcular la cantidad de salida esperada
        uint256 amountOutExpected = getAmountOut(
            amountIn,
            token0IsTokenIn ? reserve0 : reserve1,
            token0IsTokenIn ? reserve1 : reserve0
        );

        // Verificar que el cálculo produce al menos el mínimo esperado
        if (amountOutExpected < amountOutMin) {
            revert SwapModule_InsufficientOutputAmount();
        }

        // 3. Transferir tokens del usuario al par usando SafeERC20
        IERC20(tokenIn).safeTransferFrom(msg.sender, pair, amountIn);

        // 4. Registrar balance antes del swap para verificación
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // 5. Realizar el swap en el par
        uint256 amount0Out;
        uint256 amount1Out;
        if (token0IsTokenIn) {
            amount0Out = 0;
            amount1Out = amountOutExpected;
        } else {
            amount0Out = amountOutExpected;
            amount1Out = 0;
        }

        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), "");

        // 6. Obtener balance después del swap y calcular amountOut real
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;

        // 7. Verificar que recibimos al menos el mínimo esperado (seguridad extra)
        if (amountOut < amountOutMin) {
            revert SwapModule_InsufficientOutputAmount();
        }

        // 8. Transferir tokens de salida al usuario usando SafeERC20
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit SwapModule_SwapExecuted(
            msg.sender,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut
        );

        return amountOut;
    }

    /**
     * @notice Función auxiliar para calcular la cantidad de salida
     * @param amountIn Cantidad de entrada
     * @param reserveIn Reserva del token de entrada
     * @param reserveOut Reserva del token de salida
     * @return amountOut Cantidad calculada de salida
     * @dev Implementa la fórmula AMM de Uniswap V2: amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) {
            revert SwapModule_InsufficientLiquidity();
        }

        // Uniswap V2 tiene una fee del 0.3% (3/1000)
        // El input se multiplica por 997 (1000 - 3)
        uint256 amountInWithFee = amountIn * 997;

        // Calcular el denominador y numerador
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;

        amountOut = numerator / denominator;
    }

    /**
     * @notice Función para obtener el par de tokens
     * @param tokenA Primer token
     * @param tokenB Segundo token
     * @return pair Dirección del par
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair) {
        return FACTORY.getPair(tokenA, tokenB);
    }

 // ---------- Depósitos ----------
    /**
     * @notice Permite depositar ETH o cualquier token ERC20 soportado. Los fondos se convierten automáticamente a USDC.
     * @param tokenIn Dirección del token a depositar. Use address(0) para ETH.
     * @param amountIn Cantidad del token a depositar (se ignora si es ETH, ya que se usa msg.value).
     */

    function deposit(address tokenIn, uint256 amountIn) 
    public 
    payable 
    onlyUser 
    nonReentrant 
{
    uint256 amount = tokenIn == address(0) ? msg.value : amountIn;
    require(amount > 0, "Monto invalido");

    uint256 estimatedUSDC = _getUSDCValue(tokenIn, amount);

    _checkDepositLimit(estimatedUSDC);

    uint256 usdcReceived;

    if (tokenIn == address(0)) {
        usdcReceived = estimatedUSDC;
    } else {
        address tokenOut = usdc; 
        uint256 amountOutMin = (amountIn * 95) / 100;
        usdcReceived = swapExactInputSingle(tokenIn, tokenOut, amountIn, amountOutMin);
    }

    usdcBalances[msg.sender] += usdcReceived;
    totalDepositedNormalized += estimatedUSDC;

    emit Deposit(msg.sender, tokenIn, amount, usdcReceived);
}


    // ---------- Retiros ----------
    /**
     * @notice Retira USDC directamente del balance del usuario.
     * @param amountUSDC Monto de USDC a retirar.
     */
    function withdrawUSDC(uint256 amountUSDC) external nonReentrant {
        require(amountUSDC > 0, "Monto invalido");
        require(usdcBalances[msg.sender] >= amountUSDC, "Fondos insuficientes");
        require(amountUSDC <= withdrawLimit, "Excede limite retiro");

        usdcBalances[msg.sender] -= amountUSDC;
        totalDepositedNormalized -= amountUSDC;

        IERC20(usdc).safeTransfer(msg.sender, amountUSDC);

        emit Withdraw(msg.sender, amountUSDC);
    }

    // ---------- Auxiliares ----------
    function _checkDepositLimit(uint256 normalizedAmount) internal view {
        require(totalDepositedNormalized + normalizedAmount <= bankCap, "Excede limite banco");
    }

    /// @notice Devuelve el último precio ETH/USD desde Chainlink.
    function getLatestETHPrice() public view returns (int256 price) {
        (, price,,,) = priceFeed.latestRoundData();
    }

    /**
     * @notice Estima valor de un token en USDC usando Chainlink (solo ETH soportado en esta versión).
     */
    function _getUSDCValue(address token, uint256 amount) internal view returns (uint256) {
        if (token == address(0)) {
            int256 ethPrice = getLatestETHPrice(); // en USD * 1e8
            uint256 usdValue = (uint256(ethPrice) * amount) / 1e8;
            return usdValue / 1e12; // ajustar a 6 decimales (USDC)
        }
        return amount; // para tokens ya en USDC
    }

    // ---------- Admin ----------
    function updateWithdrawLimit(uint256 newLimit) external onlyAdmin {
        require(newLimit > 0, "Limite invalido");
        withdrawLimit = newLimit;
        emit WithdrawLimitUpdated(newLimit);
    }

    // ---------- Roles ----------
    function addUser(address user) external onlyAdmin {
        grantRole(USER_ROLE, user);
    }

    function removeUser(address user) external onlyAdmin {
        revokeRole(USER_ROLE, user);
    }

    // ---------- Fallbacks ----------
    receive() external payable {
        deposit(address(0), msg.value);
    }

    fallback() external payable {
        deposit(address(0), msg.value);
    }
}
