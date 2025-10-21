# kipu-bank
KipuBank version 2

KipuBank es un contrato inteligente en Solidity que simula un banco simple para almacenar y gestionar ETH y tokens ERC20 de múltiples usuarios. Cada usuario tiene una “bóveda personal” dentro del contrato, y el deployer inicial se convierte en administrador (ADMIN_ROLE) del banco.

Características principales:

Control de acceso basado en roles:

ADMIN_ROLE: Puede agregar o eliminar usuarios, habilitar/deshabilitar tokens y cambiar límites de retiro.

USER_ROLE: Puede depositar y retirar fondos.

Los usuarios pueden depositar ETH en su bóveda personal, respetando el límite máximo por usuario (bankCap).

Los usuarios pueden retirar ETH hasta un límite por transacción (withdrawLimit) y siempre según su saldo disponible.

Soporte multi-token ERC20: los usuarios pueden depositar y retirar tokens aprobados por el admin.

Los depósitos y retiros de ETH y tokens se registran mediante eventos (Deposit, Withdraw, DepositToken, WithdrawToken).

Todos los depósitos (incluyendo transfers directas a receive() o fallback()) se redirigen a la misma lógica central, manteniendo consistencia contable.

Función de oráculo Chainlink integrada para obtener el precio actual de ETH en USD.

Validaciones de límites implementadas con modificadores y errores personalizados (InvalidDeposit, InvalidWithdrawal) para eficiencia y claridad.

Instrucciones de despliegue

Usando Remix IDE

Preparar el contrato

Abrir Remix IDE.

Crear un archivo KipuBank.sol y pegar el contrato completo.

Seleccionar Solidity Compiler → Version 0.8.20 (o superior compatible).

Presionar Compile.

Desplegar el contrato

Ir a Deploy & Run Transactions.

Seleccionar Environment (por ejemplo: Injected Web3 para usar MetaMask).

Ingresar los parámetros:

bankCap: límite máximo de depósito por usuario (en wei).

withdrawLimit: límite máximo de retiro por operación (en wei).

priceFeed: dirección del oráculo Chainlink ETH/USD.

Presionar Deploy.

Remix mostrará la dirección del contrato y las funciones disponibles.

Usando Etherscan (testnet o mainnet)

Verificar el contrato

Copiar la dirección del contrato desplegado.

Ir a Etherscan de la red correspondiente (por ejemplo, Sepolia).

Buscar el contrato por dirección.

Haz Verify & Publish: pegar el código fuente, seleccionar compilador 0.8.20 y licencia MIT.

Interactuar con el contrato

En la pestaña Contract → Write Contract, conectar MetaMask.

Funciones disponibles:

deposit() payable: envía ETH al contrato.

withdraw(uint256 _amount): retira ETH.

depositToken(address token, uint256 amount): deposita un token ERC20 soportado.

withdrawToken(address token, uint256 amount): retira un token ERC20.

Para leer balances y datos:

bankBalance(address user) → saldo en ETH.

tokenBalances(address user, address token) → saldo de un token ERC20.

getLatestETHPrice() → precio de ETH en USD desde Chainlink.

Cómo interactuar con el contrato

Depositar ETH

Función: deposit() payable

El usuario envía ETH al contrato usando esta función o mediante transferencia directa (receive/fallback).

Se verifica que no supere bankCap y se actualiza el balance interno.

Evento: Deposit(address user, uint256 amount)

Retirar ETH

Función: withdraw(uint256 _amount)

El usuario puede retirar hasta su balance disponible y respetando withdrawLimit.

Evento: Withdraw(address user, uint256 amount)

Depositar Tokens ERC20

Función: depositToken(address token, uint256 amount)

Solo se pueden depositar tokens habilitados por el admin (supportedTokens[token] = true).

El usuario debe aprobar previamente el token al contrato usando IERC20(token).approve(...).

Evento: DepositToken(address user, address token, uint256 amount)

Retirar Tokens ERC20

Función: withdrawToken(address token, uint256 amount)

Se retira hasta el saldo disponible del usuario para ese token.

Evento: WithdrawToken(address user, address token, uint256 amount)

Consultar saldo

ETH: bankBalance(address user)

Tokens: tokenBalances(address user, address token)

Gestión de roles (solo ADMIN_ROLE)

addUser(address user) → asigna rol de usuario.

removeUser(address user) → revoca rol de usuario.

setTokenSupport(address token, bool supported) → habilita/deshabilita tokens.

updateWithdrawLimit(uint256 newLimit) → ajusta límite de retiro por operación.

Consideraciones sobre transferencias directas

Si alguien envía ETH directamente al contrato (sin llamar a deposit()), se registra automáticamente en el balance del usuario mediante receive() o fallback().

Esto mantiene consistencia contable, pero se siguen aplicando las validaciones de bankCap.

Address del contrato 0x51eCaC5A8C2681fC88113D15F7fe0ed4720d8E1d https://sepolia.etherscan.io/address/0x51ecac5a8c2681fc88113d15f7fe0ed4720d8e1d#code

KipuBank version 1
Descripción

KipuBank es un contrato inteligente en Solidity que simula un banco simple para almacenar y gestionar ETH de múltiples usuarios. Cada usuario tiene una “bóveda personal” dentro del contrato.

Características principales:

Los usuarios pueden depositar ETH en su bóveda personal.
Los usuarios pueden retirar ETH, respetando un límite por transacción definido al desplegar el contrato (withdrawLimit).
Se aplica un límite máximo de depósito por usuario (bankCap).
El contrato mantiene un registro de la cantidad de depósitos y retiros.
Se emiten eventos en cada depósito y retiro exitoso.
La lógica de envío de ETH se realiza de forma segura usando una función privada (_transferEth).

Instrucciones de despliegue usando Remix IDE
a) Preparar el contrato
Abre Remix IDE
Crea un archivo KipuBank.sol y pega tu contrato.
Selecciona Solidity Compiler → Version 0.8.26.
Presiona Compile KipuBank.sol.

b) Desplegar el contrato
Ve a Deploy & Run Transactions.
Selecciona Environment
Ingresa los valores de bankCap y withdrawLimit.
Presiona Deploy.
Una vez desplegado, Remix te mostrará la dirección del contrato y las funciones disponibles.

Usando Etherscan (si el contrato está desplegado en testnet o mainnet)

a) Verificar el contrato
Copia la dirección del contrato desplegado.
Ve a Etherscan de la red correspondiente (Sepholia).
Busca el contrato por dirección.
Haz Verify & Publish: pega el código fuente, selecciona compilador 0.8.26 y licencia MIT.

b) Interactuar con el contrato
En la pestaña Contract → Write Contract, conecta tu MetaMask.
Funciones disponibles:

deposit() payable: envía ETH al contrato.

withdraw(uint256 _amount): retira ETH.

Para leer el saldo, usa Read Contract → getMyBalance(), con tu dirección.

Etherscan permite enviar ETH directamente a funciones payable, igual que en Remix.

Cómo interactuar con el contrato
1. Depositar ETH
Función: deposit() payable
El usuario envía ETH al contrato usando esta función.
Ejemplo en Remix:
Poner el monto en Value (ETH) y presionar transact.
Emite evento DepositMade(address user, uint256 amount).

2. Retirar ETH
Función: withdraw(uint256 _amount)
El usuario especifica la cantidad a retirar (hasta withdrawLimit y su balance disponible).
Ejemplo en Remix:
Introducir la cantidad de ETH a retirar y presionar transact.
Emite evento WithdrawalMade(address user, uint256 amount).

3. Consultar saldo
Función: getMyBalance() view returns (uint256)
Permite al usuario ver su saldo en el contrato.

4. Consideraciones sobre transferencias directas
Si alguien envía ETH directamente al contrato (sin llamar a deposit()), el contrato lo acepta mediante la función receive(), pero y se registra automáticamente en el balance del usuario.


Link y dirección a mi contrato 
Address 0x91233Ca013E035641fC60dC9fA1093818D4aa362
[Address: 0x91233ca0...18d4aa362 | Etherscan](https://sepolia.etherscan.io/address/0x91233ca013e035641fc60dc9fa1093818d4aa362)
