// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GasTank} from "../src/GasTank.sol";

/// A listed address that refuses the native token: no receive(), no fallback.
contract EtherRefuser {}

contract GasTankDistributeTest is Test {
    address internal constant OWNER = 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1;
    uint256 internal constant AMOUNT = 0.05 ether;

    GasTank internal tank;
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        tank = new GasTank(OWNER);
    }

    function test_distribute_referenceExample() public {
        address[] memory list = _listRecipients(6);
        vm.deal(address(tank), 173276196284516701);

        vm.expectEmit(address(tank));
        emit GasTank.Distributed(28879366047419450, 6);
        vm.prank(OWNER);
        tank.distribute();

        for (uint256 i; i < list.length; ++i) {
            assertEq(list[i].balance, 28879366047419450);
            assertEq(tank.lastClaimOf(list[i]), 0);
        }
        assertEq(address(tank).balance, 1);
    }

    function test_distribute_onlyOwner() public {
        _listRecipients(2);
        vm.deal(address(tank), 1 ether);

        vm.prank(stranger);
        vm.expectRevert(GasTank.NotOwner.selector);
        tank.distribute();

        assertEq(address(tank).balance, 1 ether);
    }

    function test_distribute_revertsWithoutRecipients() public {
        vm.deal(address(tank), 1 ether);

        vm.prank(OWNER);
        vm.expectRevert(GasTank.NothingToDistribute.selector);
        tank.distribute();

        assertEq(address(tank).balance, 1 ether);
    }

    function test_distribute_revertsWhenShareIsZero() public {
        address[] memory list = _listRecipients(3);
        vm.deal(address(tank), 2);

        vm.prank(OWNER);
        vm.expectRevert(GasTank.NothingToDistribute.selector);
        tank.distribute();

        for (uint256 i; i < list.length; ++i) {
            assertEq(list[i].balance, 0);
        }
        assertEq(address(tank).balance, 2);
    }

    function test_distribute_exactlyOneWeiEach() public {
        address[] memory list = _listRecipients(3);
        vm.deal(address(tank), 3);

        vm.expectEmit(address(tank));
        emit GasTank.Distributed(1, 3);
        vm.prank(OWNER);
        tank.distribute();

        for (uint256 i; i < list.length; ++i) {
            assertEq(list[i].balance, 1);
        }
        assertEq(address(tank).balance, 0);
    }

    function test_distribute_ignoresCeiling() public {
        vm.startPrank(OWNER);
        tank.setRecipient(alice, AMOUNT);
        tank.setRecipient(bob, AMOUNT);
        vm.stopPrank();
        vm.deal(alice, 10 * AMOUNT);
        vm.deal(address(tank), 1 ether);

        vm.prank(OWNER);
        tank.distribute();

        assertEq(alice.balance, 10 * AMOUNT + 0.5 ether);
        assertEq(bob.balance, 0.5 ether);
        assertEq(address(tank).balance, 0);
    }

    function test_distribute_isAllOrNothing_whenARecipientRefuses() public {
        address refuser = address(new EtherRefuser());
        vm.startPrank(OWNER);
        tank.setRecipient(alice, AMOUNT); // paid before the refuser in list order
        tank.setRecipient(refuser, AMOUNT);
        tank.setRecipient(bob, AMOUNT);
        vm.stopPrank();
        vm.deal(address(tank), 3 ether);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(GasTank.TransferFailed.selector, refuser));
        tank.distribute();

        assertEq(alice.balance, 0);
        assertEq(refuser.balance, 0);
        assertEq(bob.balance, 0);
        assertEq(address(tank).balance, 3 ether);
    }

    function testFuzz_distribute_conservesFunds(uint96 funded, uint8 n) public {
        uint256 count = bound(n, 1, 32);
        uint256 balance = bound(funded, count, type(uint96).max);
        address[] memory list = _listRecipients(count);
        vm.deal(address(tank), balance);

        vm.prank(OWNER);
        tank.distribute();

        uint256 share = list[0].balance;
        uint256 sent;
        for (uint256 i; i < count; ++i) {
            assertEq(list[i].balance, share, "unequal share");
            sent += list[i].balance;
        }
        uint256 remainder = address(tank).balance;
        assertEq(sent + remainder, balance, "funds not conserved");
        assertLt(remainder, count, "remainder too large");
    }

    // ---------------------------------------------------------------- helpers

    function _eoa(uint256 i) internal returns (address) {
        return makeAddr(string.concat("eoa", vm.toString(i)));
    }

    /// Lists `count` fresh EOAs, each with balance 0 and claim amount `AMOUNT`.
    function _listRecipients(uint256 count) internal returns (address[] memory list) {
        list = new address[](count);
        vm.startPrank(OWNER);
        for (uint256 i; i < count; ++i) {
            list[i] = _eoa(i);
            tank.setRecipient(list[i], AMOUNT);
        }
        vm.stopPrank();
    }
}
