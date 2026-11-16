// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {GasTank} from "../../src/GasTank.sol";

/// Test-only malicious recipient: every time the tank pays it, its receive() calls
/// `claim()` back inside a try/catch and records what happened.
contract Reenterer {
    GasTank internal immutable _tank;

    /// Number of inner `claim()` calls made from receive().
    uint256 public attempts;
    /// True once an inner `claim()` has succeeded.
    bool public innerSucceeded;
    /// Revert data of the last inner `claim()` that failed.
    bytes public lastRevertData;

    constructor(GasTank tank) {
        _tank = tank;
    }

    /// The outer claim, made for itself.
    function claim() external {
        _tank.claim();
    }

    receive() external payable {
        ++attempts;
        try _tank.claim() {
            innerSucceeded = true;
        } catch (bytes memory reason) {
            lastRevertData = reason;
        }
    }
}
