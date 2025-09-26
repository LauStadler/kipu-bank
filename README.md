# kipu-bank

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
