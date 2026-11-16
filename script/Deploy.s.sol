// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {GasTank} from "../src/GasTank.sol";

/// @notice Deploys GasTank through the deterministic CREATE2 factory, so it lands at the same
///         address on every chain. Any EOA can broadcast it: the deployer gets no rights.
contract Deploy is Script {
    address public constant OWNER = 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1;
    address public constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 public constant SALT = keccak256("sigma-labs.gas-tank.v1");
    /// The GasTank address on every chain (PINNED in test/Deploy.t.sol).
    address public constant EXPECTED = 0xe9A731d24c524B9efb032786F3c1C3e53D36f712;

    error FactoryCallFailed();
    error NotDeployed(address predicted);
    error WrongOwner(address owner);
    error UnexpectedAddress(address predicted);
    error OwnerHasNoCode(address owner);

    /// @return GasTank's creation code followed by its ABI-encoded constructor argument.
    function initCode() public pure virtual returns (bytes memory) {
        return abi.encodePacked(type(GasTank).creationCode, abi.encode(OWNER));
    }

    /// @return The CREATE2 address of `initCode()` deployed by `FACTORY` with `SALT`.
    function predicted() public pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), FACTORY, SALT, keccak256(initCode())));
        return address(uint160(uint256(hash)));
    }

    /// @notice Deploys GasTank at `predicted()`, or does nothing when code is already there.
    ///         Either way, reverts unless a GasTank owned by `OWNER` sits at `predicted()`.
    ///         Refuses, before any call, a build whose address is not `EXPECTED` and a chain without the Safe.
    function deploy() public returns (GasTank tank) {
        tank = GasTank(payable(predicted()));
        if (address(tank) != EXPECTED) revert UnexpectedAddress(address(tank));
        if (OWNER.code.length == 0) revert OwnerHasNoCode(OWNER);
        if (address(tank).code.length == 0) {
            // The factory takes `salt ‖ initcode` as raw calldata.
            (bool ok,) = FACTORY.call(abi.encodePacked(SALT, initCode()));
            if (!ok) revert FactoryCallFailed();
        }
        // Also catches a missing factory: a call to an address without code succeeds.
        if (address(tank).code.length == 0) revert NotDeployed(address(tank));
        address owner = tank.owner();
        if (owner != OWNER) revert WrongOwner(owner);
    }

    function run() external {
        vm.startBroadcast();
        deploy();
        vm.stopBroadcast();
    }
}
