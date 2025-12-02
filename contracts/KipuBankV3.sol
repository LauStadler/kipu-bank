// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title KipuBank
 * @notice Banco descentralizado que permite depósitos en cualquier token soportado, convirtiéndolos automáticamente a USDC
 *         mediante swaps Uniswap V2. Los fondos quedan contabilizados internamente en USDC.
 * @dev Incluye:
 *      - Roles basados en AccessControl
 *      - Límite máximo de TVL en USDC
 *      - Retiros con límite dinámico
 *      - Swaps directos con Uniswap V2 Pair
 *      - Soporte para ETH mediante WETH
 *      - Feed de precios Chainlink solo para estimaciones previas
 */
contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    //                                 ROLES
    // -----------------------------------------------------------------------

    /// @notice Rol de administrador del sistema (puede agregar usuarios, cambiar límites, etc.)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Rol asignado a usuarios habilitados (actualmente solo administrado, no restrictivo para depositar)
    bytes32 public constant USER_ROLE = keccak256("USER_ROLE");

    // -----------------------------------------------------------------------
    //                             VARIABLES
    // -----------------------------------------------------------------------

    /// @notice Capacidad máxima total del banco expresada en USDC (6 decimales)
    uint256 public immutable bankCap;

    /// @notice Suma total de fondos depositados (siempre expresados en USDC normalizado)
    uint256 public totalDepositedNormalized;

    /// @notice Límite máximo que un usuario puede retirar en una sola operación
    uint256 public withdrawLimit;

    /// @notice Balance interno de cada usuario expresado únicamente en USDC
    mapping(address => uint256) public usdcBalances;

    /// @notice Oráculo Chainlink ETH/USD para estimaciones previas
    AggregatorV3Interface internal priceFeed;

    /// @notice Dirección del factory de Uniswap V2 usado para obtener pares
    IUniswapV2Factory public immutable FACTORY;

    /// @notice Dirección del token USDC usado como unidad de cuenta del banco
    address public immutable usdc;

    /// @notice Dirección del contrato WETH necesario para manejar depósitos en ETH
    address public immutable weth;

    // -----------------------------------------------------------------------
    //                               EVENTOS
    // -----------------------------------------------------------------------

    /**
     * @notice Emitted when a user performs a deposit
     * @param user Usuario que deposita
     * @param tokenIn Token depositado (address(0) si es ETH)
     * @param amountIn Cantidad de token depositado
     * @param usdcReceived USDC obtenido luego del swap
     */
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived);

    /// @notice Emitido cuando un usuario retira USDC
    event Withdraw(address indexed user, uint256 usdcAmount);

    /// @notice Emitido cuando un usuario retira en ETH (si existiera un flujo así)
    event WithdrawAsETH(address indexed user, uint256 usdcSpent, uint256 ethOut);

    /// @notice Emitido cuando el límite de retiro es modificado por admins
    event WithdrawLimitUpdated(uint256 newLimit);

    /**
     * @notice Emitido tras la ejecución de un swap Uniswap V2
     * @param user Usuario que originó la transacción
     * @param tokenIn Token ingresado al swap
     * @param tokenOut Token recibido
     * @param amountIn Cantidad entregada al swap
     * @param amountOut Cantidad recibida del swap
     */
    event SwapModule_SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    // -----------------------------------------------------------------------
    //                                ERRORES
    // -----------------------------------------------------------------------

    /// @notice Error lanzado cuando la salida del swap es inferior al mínimo permitido por slippage
    error SwapModule_InsufficientOutputAmount();

    /// @notice Error lanzado si la liquidez del par es insuficiente o nula
    error SwapModule_InsufficientLiquidity();

    /// @notice Error lanzado si el par no existe en Uniswap V2
    error SwapModule_PairDoesNotExist();

    /// @notice Error por direcciones inválidas o coincidentes
    error SwapModule_InvalidAddress();

    /// @notice Error por montos de entrada inválidos (ej: amountIn = 0)
    error SwapModule_InvalidAmount();

    // -----------------------------------------------------------------------
    //                              CONSTRUCTOR
    // -----------------------------------------------------------------------

    /**
     * @notice Inicializa el contrato configurando límites, direcciones externas, oráculo, factory,
     *         token USDC y dirección WETH.
     * @param _bankCap Capacidad total del banco en USDC (6 decimales)
     * @param _withdrawLimit Límite inicial de retiro
     * @param _priceFeed Dirección del oráculo Chainlink ETH/USD
     * @param _usdc Dirección del token USDC
     * @param _factory Dirección del Uniswap Factory
     * @param _weth Dirección del contrato WETH
     */
    constructor(
        uint256 _bankCap,
        uint256 _withdrawLimit,
        address _priceFeed,
        address _usdc,
        address _factory,
        address _weth
    ) {
        require(_priceFeed != address(0), "PriceFeed invalido");
        require(_usdc != address(0), "USDC invalido");
        require(_factory != address(0), "Factory invalido");
        require(_weth != address(0), "WETH invalido");

        bankCap = _bankCap;
        withdrawLimit = _withdrawLimit;
        priceFeed = AggregatorV3Interface(_priceFeed);
        usdc = _usdc;
        FACTORY = IUniswapV2Factory(_factory);
        weth = _weth;

        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(USER_ROLE, msg.sender);
    }

    // -----------------------------------------------------------------------
    //                              MODIFIERS
    // -----------------------------------------------------------------------

    /// @notice Restringe funciones a administradores
    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Solo admin");
        _;
    }

    /**
     * @notice Verifica que dos direcciones de tokens sean válidas y distintas
     */
    modifier validTokenAddresses(address tokenA, address tokenB) {
        if (tokenA == address(0) || tokenB == address(0)) revert SwapModule_InvalidAddress();
        if (tokenA == tokenB) revert SwapModule_InvalidAddress();
        _;
    }

    /**
     * @notice Verifica que el monto sea mayor a cero
     */
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert SwapModule_InvalidAmount();
        _;
    }

    /**
     * @notice Verifica que el par exista en Uniswap
     */
    modifier pairExists(address tokenA, address tokenB) {
        address pair = FACTORY.getPair(tokenA, tokenB);
        if (pair == address(0)) revert SwapModule_PairDoesNotExist();
        _;
    }

    // -----------------------------------------------------------------------
    //                           SWAP UNISWAP V2
    // -----------------------------------------------------------------------

    /**
     * @notice Realiza un swap unidireccional usando directamente Uniswap V2 Pair,
     *         aceptando tanto balances del contrato como transferencias del usuario.
     *
     * @dev Implementa el modelo constante-product (x*y=k).
     *      No transfiere el tokenOut al usuario; solo lo retorna al caller.
     *
     * @param tokenIn Token entregado
     * @param tokenOut Token recibido
     * @param amountIn Monto a intercambiar
     * @param amountOutMin Mínimo aceptable a recibir
     * @return amountOut Cantidad real obtenida del swap
     */
    function swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    )
        internal
        validTokenAddresses(tokenIn, tokenOut)
        validAmount(amountIn)
        pairExists(tokenIn, tokenOut)
        returns (uint256 amountOut)
    {
        address pair = FACTORY.getPair(tokenIn, tokenOut);

        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        address token0 = IUniswapV2Pair(pair).token0();
        bool token0IsTokenIn = token0 == tokenIn;

        uint256 amountOutExpected = getAmountOut(
            amountIn,
            token0IsTokenIn ? reserve0 : reserve1,
            token0IsTokenIn ? reserve1 : reserve0
        );

        if (amountOutExpected < amountOutMin) revert SwapModule_InsufficientOutputAmount();

        uint256 contractBal = IERC20(tokenIn).balanceOf(address(this));

        if (contractBal >= amountIn) {
            IERC20(tokenIn).safeTransfer(pair, amountIn);
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, pair, amountIn);
        }

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        uint256 amount0Out = token0IsTokenIn ? 0 : amountOutExpected;
        uint256 amount1Out = token0IsTokenIn ? amountOutExpected : 0;

        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), "");

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;

        if (amountOut < amountOutMin) revert SwapModule_InsufficientOutputAmount();

        emit SwapModule_SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Calcula el output esperado en un swap según la fórmula de Uniswap x*y=k
     * @param amountIn Cantidad que entra
     * @param reserveIn Reserva del token de entrada
     * @param reserveOut Reserva del token de salida
     * @return amountOut Cantidad resultante estimada
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) revert SwapModule_InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;

        amountOut = numerator / denominator;
    }

    /**
     * @notice Retorna la dirección del par entre dos tokens
     */
    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return FACTORY.getPair(tokenA, tokenB);
    }

    // -----------------------------------------------------------------------
    //                               DEPÓSITOS
    // -----------------------------------------------------------------------

    /**
     * @notice Permite depositar ETH o cualquier token ERC20. El monto depositado se convierte
     *         automáticamente a USDC mediante Uniswap V2.
     *
     * @dev Si tokenIn == address(0), se trata de ETH y se envuelve en WETH antes del swap.
     * @param tokenIn Token que ingresa (address(0) = ETH)
     * @param amountIn Cantidad depositada (ignorada si es ETH)
     */
    function deposit(address tokenIn, uint256 amountIn) public payable nonReentrant {
        uint256 amount = tokenIn == address(0) ? msg.value : amountIn;
        require(amount > 0, "Monto invalido");

        uint256 estimatedUSDC = _getUSDCValue(tokenIn, amount);
        _checkDepositLimit(estimatedUSDC);

        uint256 usdcReceived;

        if (tokenIn == address(0)) {
            IWETH(weth).deposit{value: amount}();
            usdcReceived = swapExactInputSingle(weth, usdc, amount, 1);
        } else {
            uint256 amountOutMin = (amountIn * 95) / 100;
            usdcReceived = swapExactInputSingle(tokenIn, usdc, amountIn, amountOutMin);
        }

        _checkDepositLimit(usdcReceived);

        usdcBalances[msg.sender] += usdcReceived;
        totalDepositedNormalized += usdcReceived;

        emit Deposit(msg.sender, tokenIn, amount, usdcReceived);
    }

    // -----------------------------------------------------------------------
    //                                 RETIROS
    // -----------------------------------------------------------------------

    /**
     * @notice Permite retirar USDC que el usuario haya depositado previamente
     * @param amountUSDC Cantidad a retirar
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

    // -----------------------------------------------------------------------
    //                               AUXILIARES
    // -----------------------------------------------------------------------

    /**
     * @notice Revisa si un depósito excedería el límite total del banco
     * @param normalizedAmount Monto en USDC normalizado
     */
    function _checkDepositLimit(uint256 normalizedAmount) internal view {
        require(totalDepositedNormalized + normalizedAmount <= bankCap, "Excede limite banco");
    }

    /**
     * @notice Devuelve el último precio ETH/USD desde Chainlink (8 decimales)
     * @return price Precio actual
     */
    function getLatestETHPrice() public view returns (int256 price) {
        (, price,,,) = priceFeed.latestRoundData();
    }

    /**
     * @notice Estima el valor equivalente en USDC para un token dado
     * @dev Solo ETH tiene soporte nativo vía Chainlink
     * @param token Token a evaluar
     * @param amount Cantidad del token
     * @return Valor aproximado en USDC
     */
    function _getUSDCValue(address token, uint256 amount) internal view returns (uint256) {
        if (token == address(0)) {
            int256 ethPrice = getLatestETHPrice();
            require(ethPrice > 0, "Precio ETH invalido");
            uint256 usdValue = (uint256(ethPrice) * amount) / 1e8;
            return usdValue / 1e12;
        }

        if (token == usdc) return amount;

        return amount;
    }

    // -----------------------------------------------------------------------
    //                                ADMIN
    // -----------------------------------------------------------------------

    /**
     * @notice Actualiza el límite máximo de retiro permitido para todos
     * @param newLimit Nuevo límite
     */
    function updateWithdrawLimit(uint256 newLimit) external onlyAdmin {
        require(newLimit > 0, "Limite invalido");
        withdrawLimit = newLimit;
        emit WithdrawLimitUpdated(newLimit);
    }

    /**
     * @notice Asigna rol USER_ROLE a un usuario
     */
    function addUser(address user) external onlyAdmin {
        grantRole(USER_ROLE, user);
    }

    /**
     * @notice Revoca el rol USER_ROLE de un usuario
     */
    function removeUser(address user) external onlyAdmin {
        revokeRole(USER_ROLE, user);
    }

    // -----------------------------------------------------------------------
    //                              FALLBACKS
    // -----------------------------------------------------------------------

    /**
     * @notice Permite depositar enviando ETH directamente al contrato
     */
    receive() external payable {
        deposit(address(0), msg.value);
    }

    /**
     * @notice Fallback que también considera ETH como depósito
     */
    fallback() external payable {
        deposit(address(0), msg.value);
    }
}
