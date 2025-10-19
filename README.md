# MultiWalletBalanceTrap

Цей репозиторій містить реалізацію контролю балансу для кількох адрес (whale‑адрес), з виявленням аномалій змін балансу. Контракт реалізує інтерфейс `ITrap` і призначений для інтеграції з Drosera / іншим моніторингом.

## 🚀 Функціональність

- collect() — збирає поточні баланси та timestamp

- shouldRespond() — порівнює з попередніми даними

- обчислює зміну в ppm (parts per million)

- перевіряє мінімальний абсолютний поріг (0.01 ETH за замовчуванням)

- викликає тригер, якщо перевищено один із порогів або минуло 5 хвилин (boundary-cross)

  ⚙️ Константи
uint256 public constant thresholdPPM = 10;         // 0.001%
uint256 public constant MIN_ABS_WEI = 0.01 ether;  // Мінімальна абсолютна зміна
uint256 public constant PERIOD_SECONDS = 300;      // 5 хвилин

🧾 Формат відповіді

Контракт завжди повертає дві змінні, щоб уникнути Drosera-ABI помилок:

(bool shouldRespond, bytes memory payload)


де payload = abi.encode(string message, uint256 value)
→ повністю відповідає конфігурації TOML:

response_function = "logAnomaly(string,uint256)"


🔍 Алгоритм роботи

collect() зчитує баланси всіх targets та block.timestamp

shouldRespond():

порівнює current і previous знімки

обчислює зміну у ppm

якщо (ppm >= thresholdPPM && diff >= MIN_ABS_WEI) — спрацьовує тригер

додатково спрацьовує при перетині 5-хвилинного інтервалу

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

/// @notice Interface required by Drosera traps
interface ITrap {
    function collect() external view returns (bytes memory);
    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory);
}

/// @notice Interface for optional config registry (safe try/catch call)
interface IConfigRegistry {
    function getTargets() external view returns (address[] memory);
}

/// @title MultiWalletBalanceTrap (Drosera-compliant)
/// @notice Detects large or unusual balance changes for key wallets.
contract MultiWalletBalanceTrap is ITrap {
    address[] public hardcodedTargets;

    // ======= Parameters =======
    uint256 public constant thresholdPPM = 10;         // relative change threshold (0.001%)
    uint256 public constant MIN_ABS_WEI = 0.01 ether;  // absolute change floor (0.01 ETH)
    uint256 public constant MAX_TARGETS = 5;           // safety cap on monitored list

    // Optional config registry (Drosera-safe; can revert gracefully)
    address public constant CONFIG_REGISTRY = 0x0000000000000000000000000000000000000000;

    constructor() {
        // Hardcoded fallback targets (if registry unavailable)
        hardcodedTargets.push(0x2D6c3Aaaa53BE2989F8C0a49CD143BBae8a3aeac);
        hardcodedTargets.push(0x8172A4Ebc9e274A4cDF5aBCc29B3fA3DE5f82778);
        hardcodedTargets.push(0xC08642612Bcb9910Cb444a3a5CD5A5C0630c6e57);
    }

    /// @notice Collects balances for monitored addresses
    function collect() external view override returns (bytes memory) {
        address[] memory targets = _getTargets();
        if (targets.length > MAX_TARGETS) {
            // clamp length for Drosera payload limits
            assembly {
                mstore(targets, MAX_TARGETS)
            }
        }

        uint256[] memory balances = new uint256[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            balances[i] = targets[i].balance;
        }

        return abi.encode(balances, block.timestamp);
    }

    /// @notice Evaluates whether to trigger the responder
    /// @return (shouldTrigger, encodedPayload)
    /// encodedPayload = abi.encode(uint256 index, uint256 ppm)
    function shouldRespond(bytes[] calldata data) external pure override returns (bool, bytes memory) {
        if (data.length < 2) return (false, abi.encode(0, 0));

        (uint256[] memory curr, uint256 currTs) = abi.decode(data[0], (uint256[], uint256));
        (uint256[] memory prev, uint256 prevTs) = abi.decode(data[1], (uint256[], uint256));
        if (curr.length != prev.length) return (false, abi.encode(0, 0));

        uint256 maxPpm = 0;
        uint256 maxIndex = 0;
        uint256 maxDiff = 0;

        for (uint256 i = 0; i < curr.length; i++) {
            uint256 p = prev[i];
            uint256 c = curr[i];
            if (p == 0 && c > 0) {
                return (true, abi.encode(i, 1_000_000)); // brand new balance
            }
            if (p > 0) {
                uint256 diff = c > p ? c - p : p - c;
                uint256 ppm = (diff * 1_000_000) / p;
                if (ppm > maxPpm) {
                    maxPpm = ppm;
                    maxIndex = i;
                    maxDiff = diff;
                }
            }
        }

        // 🔍 Dual-gate trigger (relative + absolute)
        if (maxPpm >= thresholdPPM && maxDiff >= MIN_ABS_WEI) {
            return (true, abi.encode(maxIndex, maxPpm));
        }

        // ⏱ Periodic trigger (every 5 min window)
        bool crossed5m = (currTs / 300) != (prevTs / 300);
        if (crossed5m) {
            return (true, abi.encode(0, currTs));
        }

        return (false, abi.encode(0, 0));
    }

    /// @notice Returns either config-registry or fallback addresses
    function _getTargets() internal view returns (address[] memory targets) {
        if (CONFIG_REGISTRY != address(0)) {
            try IConfigRegistry(CONFIG_REGISTRY).getTargets() returns (address[] memory regTargets) {
                return regTargets;
            } catch {
                // fallback to hardcoded if registry call fails
            }
        }
        return hardcodedTargets;
    }

    /// @notice Exposes monitored addresses for transparency
    function getTargets() external view returns (address[] memory) {
        return _getTargets();
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

<img width="1113" height="397" alt="image" src="https://github.com/user-attachments/assets/2854b5f2-6a1e-47f5-a9de-c4f6c8b38c04" />


# Testing the Trap 

1. Send ETH to/from target address on Ethereum Hoodi testnet.

2. Wait 1-3 blocks.

3. Observe logs from Drosera operator:

4. get ShouldRespond='true' in logs and Drosera dashboard
---

# Extensions & Improvements 

Additional tips

--Replace the targets array in MultiWalletBalanceTrap.sol before deploying.

--For versatility, you can add a try/catch to read addresses from an external config registry.

--Do not use abi.encodePacked() for strings - only abi.encode(string,uint256).


# Date & Author

_First created: September 28, 2025_

## Author: ANGIROma 
TG : _@AngiRom_

Discord: _andreroma1_

