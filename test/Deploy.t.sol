// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {GasTank} from "../src/GasTank.sol";
import {Deploy} from "../script/Deploy.s.sol";

/// A build that drifted from the pinned one (another compiler setting, an edited source): its init code
/// differs, so it would land a working GasTank owned by the Safe at another address.
contract DriftedDeploy is Deploy {
    function initCode() public pure override returns (bytes memory) {
        return abi.encodePacked(super.initCode(), hex"00");
    }
}

contract DeployTest is Test {
    address internal constant OWNER = 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1;
    address internal constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Runtime code of the deterministic deployment proxy, as read on Ethereum mainnet with
    /// `cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C`. Foundry already places this
    /// factory in its test EVM; etching the mainnet bytes keeps the fixture independent of that.
    bytes internal constant FACTORY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    /// The GasTank address on every chain. Any change to GasTank's source, the compiler
    /// settings, the salt or the owner moves it, and must fail here on purpose.
    address internal constant PINNED = 0xe9A731d24c524B9efb032786F3c1C3e53D36f712;

    Deploy internal script;

    function setUp() public {
        vm.etch(FACTORY, FACTORY_RUNTIME);
        // A stand-in for the Safe, absent from a bare test EVM: deploy() only checks that the owner has code.
        vm.etch(OWNER, hex"00");
        script = new Deploy();
    }

    function test_deploy_landsAtPredictedAddress_withTheSafeAsOwner() public {
        address predicted = script.predicted();
        assertEq(predicted.code.length, 0);

        GasTank tank = script.deploy();

        assertEq(address(tank), predicted);
        assertGt(predicted.code.length, 0);
        assertEq(tank.owner(), OWNER);
    }

    function test_deploy_twice_isANoOp() public {
        GasTank first = script.deploy();
        bytes32 codeHash = address(first).codehash;

        // The factory must not be called again: count 0, any calldata.
        vm.expectCall(FACTORY, "", 0);
        GasTank second = script.deploy();

        assertEq(address(second), address(first));
        assertEq(address(second).codehash, codeHash);
        assertEq(second.owner(), OWNER);
    }

    function test_predictedAddress_isPinned() public view {
        assertEq(script.predicted(), PINNED);
    }

    function test_expectedAddress_isThePinnedOne() public view {
        assertEq(script.EXPECTED(), PINNED);
    }

    function test_deploy_refusesADriftedBuild_beforeCallingTheFactory() public {
        Deploy drifted = new DriftedDeploy();
        address stray = drifted.predicted();
        assertTrue(stray != PINNED);

        vm.expectCall(FACTORY, "", 0);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedAddress.selector, stray));
        drifted.deploy();
        assertEq(stray.code.length, 0);
    }

    function test_deploy_refusesWhenTheSafeHasNoCode_beforeCallingTheFactory() public {
        vm.etch(OWNER, "");

        vm.expectCall(FACTORY, "", 0);
        vm.expectRevert(abi.encodeWithSelector(Deploy.OwnerHasNoCode.selector, OWNER));
        script.deploy();
        assertEq(PINNED.code.length, 0);
    }

    /// For each chain whose RPC variable is set: the factory and the Safe exist there, and
    /// deploy() lands at the predicted address with the Safe as owner. Unset chains are skipped;
    /// with none set, the test reports SKIPPED, since it checked nothing.
    function testFork_factoryAndSafeExist_andDeployWorks() public {
        // Not `ran = ran || _checkChain(...)`: that would stop checking after the first chain.
        bool ran;
        if (_checkChain("ETH_RPC_URL")) ran = true;
        if (_checkChain("OP_RPC_URL")) ran = true;
        if (_checkChain("BASE_RPC_URL")) ran = true;
        if (_checkChain("ARB_RPC_URL")) ran = true;
        if (_checkChain("POLYGON_RPC_URL")) ran = true;
        if (_checkChain("MONAD_RPC_URL")) ran = true;
        if (_checkChain("HYPEREVM_RPC_URL")) ran = true;
        if (!ran) vm.skip(true, "no RPC variable set: no chain checked");
    }

    /// @return ran False when `rpcVar` is unset and nothing was checked.
    function _checkChain(string memory rpcVar) internal returns (bool ran) {
        string memory url = vm.envOr(rpcVar, string(""));
        if (bytes(url).length == 0) {
            console.log("%s unset: chain skipped", rpcVar);
            return false;
        }

        vm.createSelectFork(url);
        assertGt(FACTORY.code.length, 0, "factory has no code");
        assertGt(OWNER.code.length, 0, "Safe has no code");

        // The fork does not hold the script instance created by setUp.
        Deploy forkScript = new Deploy();
        address predicted = forkScript.predicted();
        bool existed = predicted.code.length > 0;

        GasTank tank = forkScript.deploy();

        assertEq(address(tank), predicted);
        assertGt(predicted.code.length, 0);
        assertEq(tank.owner(), OWNER);
        console.log("%s ran: chain id %d, block %d", rpcVar, block.chainid, block.number);
        console.log("  GasTank at %s, code there before deploy: %s", predicted, existed);
        return true;
    }
}
