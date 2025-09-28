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
