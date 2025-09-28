// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITrap {
    function collect() external view returns (bytes memory);
    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory);
}

contract MultiWalletBalanceTrap is ITrap {
    address[] public targets;

    // 0.0001% = 10 ppm (parts per million)
    uint256 public constant thresholdPPM = 10; 

    constructor() {
        targets.push(0x2D6c3Aaaa53BE2989F8C0a49CD143BBae8a3aeac); // ETH Whale 1
        targets.push(0x8172A4Ebc9e274A4cDF5aBCc29B3fA3DE5f82778); // ETH Whale 2
        targets.push(0xC08642612Bcb9910Cb444a3a5CD5A5C0630c6e57); // Binance Cold Wallet
    }

    function collect() external view override returns (bytes memory) {
        uint256[] memory balances = new uint256[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            balances[i] = targets[i].balance;
        }

        // Повертаємо також поточний timestamp
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
                return (true, abi.encodePacked("New balance detected at index=", uint2str(i)));
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
            return (
                true,
                abi.encodePacked(
                    "Balance anomaly index=",
                    uint2str(maxIndex),
                    " change=",
                    uint2str(maxPpm),
                    " ppm"
                )
            );
        }

        // 🧠 Перевірка на "кожні 5 хвилин"
        if (currTimestamp % 300 == 0) {
            return (true, abi.encodePacked("Periodic test trigger at ", uint2str(currTimestamp)));
        }

        return (false, "");
    }

    // ---- helpers ----
    function uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        str = string(bstr);
    }
}
