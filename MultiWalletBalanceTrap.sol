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
