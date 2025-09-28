# MultiWalletBalanceTrap

Цей репозиторій містить реалізацію контролю балансу для кількох адрес (whale‑адрес), з виявленням аномалій змін балансу. Контракт реалізує інтерфейс `ITrap` і призначений для інтеграції з Drosera / іншим моніторингом.

## 🚀 Функціональність

- Збирає баланси для заданого списку адрес (`collect()`)
- Визначає, чи є аномалія у зміні балансу між попереднім і поточним знімками (`shouldRespond()`)
- Прапор зміни балансу за поріг ppm (0.0001 % = 10 ppm)
- Підтримка періодичного тригеру (вбудовано в `collect()` → передається timestamp)  
- Повна сумісність з вимогами Drosera (функція `shouldRespond` лишається `pure`)

## 📂 Структура проекту

| Директорія / файл | Призначення |
|-------------------|------------------|
| `contracts/` | Solidity контракти |
| `test/` | Юніт‑тести контрактів |
| `scripts/` | Скрипти для розгортання або демонстрацій |
| `drosera.toml` | Конфігурація для Drosera |
| `hardhat.config.js` / `foundry.toml` | Конфігурація середовища розробки |

# Problem

Ethereum wallets involved in DAO treasury, DeFi protocol management, or vesting operations must maintain a consistent balance. Any unexpected change — loss or gain — could indicate compromise, human error, or exploit.

Solution: _Monitor ETH balance of a wallet across blocks. Trigger a response if there's a significant deviation in either direction._

---

# Trap Logic Summary

## 📝 Приклад коду контракту
wallets in targets.push replace to any, which you like monitoring
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITrap {
    function collect() external view returns (bytes memory);
    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory);
}

contract MultiWalletBalanceTrap is ITrap {
    address[] public targets;
    uint256 public constant thresholdPPM = 10;

    constructor() {
        targets.push(0x2D6c3Aaaa53BE2989F8C0a49CD143BBae8a3aeac);
        targets.push(0x8172A4Ebc9e274A4cDF5aBCc29B3fA3DE5f82778);
        targets.push(0xC08642612Bcb9910Cb444a3a5CD5A5C0630c6e57);
    }

    function collect() external view override returns (bytes memory) {
        uint256[] memory balances = new uint256[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            balances[i] = targets[i].balance;
        }
        return abi.encode(balances, block.timestamp);
    }

    function shouldRespond(bytes[] calldata data) external pure override returns (bool, bytes memory) {
        if (data.length < 2) return (false, "Insufficient data");
        (uint256[] memory current, uint256 currTimestamp) = abi.decode(data[0], (uint256[], uint256));
        (uint256[] memory previous, ) = abi.decode(data[1], (uint256[], uint256));
        if (current.length != previous.length) {
            return (false, "Array length mismatch");
        }
        uint256 maxPpm = 0;
        uint256 maxIndex = 0;
        for (uint256 i = 0; i < current.length; i++) {
            uint256 prev = previous[i];
            uint256 curr = current[i];
            if (prev == 0 && curr > 0) {
                return (true, abi.encodePacked("New balance at index=", uint2str(i)));
            }
            if (prev > 0) {
                uint256 diff = curr > prev ? curr - prev : prev - curr;
                uint256 ppm = (diff * 1_000_000) / prev;
                if (ppm > maxPpm) {
                    maxPpm = ppm;
                    maxIndex = i;
                }
            }
        }
        if (maxPpm >= thresholdPPM) {
            return (true, abi.encodePacked("Anomaly index=", uint2str(maxIndex), " change=", uint2str(maxPpm), " ppm"));
        }
        if (currTimestamp % 300 == 0) {
            return (true, abi.encodePacked("Periodic trigger at ", uint2str(currTimestamp)));
        }
        return (false, "");
    }

    function uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory b = new bytes(len);
        uint256 k = len;
        j = _i;
        while (j != 0) {
            b[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        str = string(b);
    }
}
```

# Response Contract: LogAlertReceiver.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract LogAlertReceiver {
    event Alert(string message);
    event AlertWithValue(string message, uint256 value);

    // Виклик для простих повідомлень
    function logAnomaly(string calldata message) external {
        emit Alert(message);
    }

    // Виклик для повідомлень з числовим параметром (наприклад, ppm зміни)
    function logAnomaly(string calldata message, uint256 value) external {
        emit AlertWithValue(message, value);
    }
}

```
---

# What It Solves 
Контракт LogAlertReceiver — це простий логер, який можна використовувати для виводу повідомлень у вигляді подій (events). Його можна викликати з інших контрактів, таких як Trap, або через Drosera для зручного відстеження тригерів.

🧩 Основні події

event Alert(string message) — лог простого повідомлення

event AlertWithValue(string message, uint256 value) — лог повідомлення з числовим параметром (наприклад, PPM)
---

# Deployment & Setup Instructions 

1. ## _Deploy Contracts (e.g., via Foundry)_ 
```
forge create src/MultiWalletBalanceTrap.sol:MultiWalletBalanceTrap \
  --rpc-url https://ethereum-hoodi-rpc.publicnode.com \
  --private-key 0x...
```
```
forge create src/LogAlertReceiver.sol:LogAlertReceiver \
  --rpc-url https://ethereum-hoodi-rpc.publicnode.com \
  --private-key 0x...
```
2. ## _Update drosera.toml_ 
```
[traps.mytrap]
path = "out/MultiWalletBalanceTrap.sol/MultiWalletBalanceTrap.json"
response_contract = "<LogAlertReceiver address>"
response_function = "logAnomaly(string, uint256)"
```
3. ## _Apply changes_ 
```
DROSERA_PRIVATE_KEY=0x... drosera apply
```

<img width="547" height="354" alt="{F13A1A68-C0D0-4DFE-AF0B-03BA506B3899}" src="https://github.com/user-attachments/assets/e4ad73d9-5d32-4b65-9803-41c9872d3e4c" />


# Testing the Trap 

1. Send ETH to/from target address on Ethereum Hoodi testnet.

2. Wait 1-3 blocks.

3. Observe logs from Drosera operator:

4. get ShouldRespond='true' in logs and Drosera dashboard
---

# Extensions & Improvements 

- Allow dynamic threshold setting via setter,

- Track ERC-20 balances in addition to native ETH,

- Chain multiple traps using a unified collector.


# Date & Author

_First created: September 28, 2025_

## Author: ANGIROma 
TG : _@AngiRom_

Discord: _andreroma1_

