// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {GasTank} from "../src/GasTank.sol";

contract GasTankAdminTest is Test {
    using stdStorage for StdStorage;

    address internal constant OWNER = 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1;
    uint256 internal constant SEEDED_LAST_CLAIM = 1_700_000_000;

    GasTank internal tank;
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address payable internal to = payable(makeAddr("to"));

    // Mirror of what the tank should list, used by the removal test.
    address[] internal _expected;
    mapping(address => uint256) internal _expectedAmount;

    function setUp() public {
        tank = new GasTank(OWNER);
    }

    function test_constructor_setsOwner_andRejectsZero() public {
        assertEq(tank.owner(), OWNER);

        vm.expectRevert(GasTank.InvalidRecipient.selector);
        new GasTank(address(0));
    }

    function test_receive_creditsAndEmitsFunded() public {
        address funder = makeAddr("funder");
        vm.deal(funder, 1 ether);

        vm.expectEmit(address(tank));
        emit GasTank.Funded(funder, 1 ether);
        vm.prank(funder);
        (bool ok,) = address(tank).call{value: 1 ether}("");

        assertTrue(ok);
        assertEq(address(tank).balance, 1 ether);
        assertEq(funder.balance, 0);
    }

    function test_setRecipient_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(GasTank.NotOwner.selector);
        tank.setRecipient(alice, 0.05 ether);
    }

    function test_setRecipient_addsThenUpdatesAmount() public {
        vm.expectEmit(address(tank));
        emit GasTank.RecipientSet(alice, 0.05 ether);
        vm.prank(OWNER);
        tank.setRecipient(alice, 0.05 ether);

        assertEq(tank.amountOf(alice), 0.05 ether);
        address[] memory list = tank.recipients();
        assertEq(list.length, 1);
        assertEq(list[0], alice);

        vm.expectEmit(address(tank));
        emit GasTank.RecipientSet(alice, 0.02 ether);
        vm.prank(OWNER);
        tank.setRecipient(alice, 0.02 ether);

        assertEq(tank.amountOf(alice), 0.02 ether);
        list = tank.recipients();
        assertEq(list.length, 1);
        assertEq(list[0], alice);
    }

    function test_setRecipient_rejectsZeroAddress_self_andZeroAmount() public {
        vm.startPrank(OWNER);
        vm.expectRevert(GasTank.InvalidRecipient.selector);
        tank.setRecipient(address(0), 0.05 ether);
        vm.expectRevert(GasTank.InvalidRecipient.selector);
        tank.setRecipient(address(tank), 0.05 ether);
        vm.expectRevert(GasTank.InvalidAmount.selector);
        tank.setRecipient(alice, 0);
        vm.stopPrank();

        assertEq(tank.recipients().length, 0);
    }

    function test_setRecipient_capsTheListAt32() public {
        vm.startPrank(OWNER);
        for (uint256 i; i < 32; ++i) {
            tank.setRecipient(_eoa(i), 0.05 ether);
        }
        assertEq(tank.recipients().length, 32);

        address extra = _eoa(32);
        vm.expectRevert(GasTank.TooManyRecipients.selector);
        tank.setRecipient(extra, 0.05 ether);

        address listed = _eoa(7);
        tank.setRecipient(listed, 0.01 ether);
        vm.stopPrank();

        assertEq(tank.amountOf(listed), 0.01 ether);
        assertEq(tank.amountOf(extra), 0);
        assertEq(tank.recipients().length, 32);
    }

    function test_removeRecipient_onlyOwner_andMustBeListed() public {
        vm.prank(OWNER);
        tank.setRecipient(alice, 0.05 ether);

        vm.prank(stranger);
        vm.expectRevert(GasTank.NotOwner.selector);
        tank.removeRecipient(alice);

        vm.prank(OWNER);
        vm.expectRevert(GasTank.NotRecipient.selector);
        tank.removeRecipient(bob);

        assertEq(tank.amountOf(alice), 0.05 ether);
        assertEq(tank.recipients().length, 1);
    }

    function test_removeRecipient_first_middle_last_only_keepListConsistent() public {
        for (uint256 i; i < 5; ++i) {
            address eoa = _eoa(i);
            uint256 amount = (i + 1) * 0.01 ether;
            vm.prank(OWNER);
            tank.setRecipient(eoa, amount);
            _expected.push(eoa);
            _expectedAmount[eoa] = amount;
        }
        _assertListMatchesExpected();

        _removeAt(0); // first of 5
        _removeAt(tank.recipients().length / 2); // middle of 4
        _removeAt(tank.recipients().length - 1); // last of 3
        _removeAt(0); // first of 2, leaves a single entry
        _removeAt(0); // the only one
        assertEq(tank.recipients().length, 0);

        address back = _eoa(0);
        vm.prank(OWNER);
        tank.setRecipient(back, 0.04 ether);
        _expected.push(back);
        _expectedAmount[back] = 0.04 ether;

        _assertListMatchesExpected();
        assertEq(tank.lastClaimOf(back), 0);
        assertEq(tank.claimableAt(back), 0);
    }

    function test_withdraw_onlyOwner_sendsAndEmits() public {
        vm.deal(address(tank), 1 ether);

        vm.prank(stranger);
        vm.expectRevert(GasTank.NotOwner.selector);
        tank.withdraw(to, 0.3 ether);

        vm.expectEmit(address(tank));
        emit GasTank.Withdrawn(to, 0.3 ether);
        vm.prank(OWNER);
        tank.withdraw(to, 0.3 ether);

        assertEq(to.balance, 0.3 ether);
        assertEq(address(tank).balance, 0.7 ether);
    }

    function test_withdraw_rejectsZeroAddress_andMoreThanBalance() public {
        vm.deal(address(tank), 1 ether);

        vm.startPrank(OWNER);
        vm.expectRevert(GasTank.InvalidRecipient.selector);
        tank.withdraw(payable(address(0)), 0.3 ether);
        vm.expectRevert(abi.encodeWithSelector(GasTank.TransferFailed.selector, to));
        tank.withdraw(to, 1 ether + 1);
        vm.stopPrank();

        assertEq(address(tank).balance, 1 ether);
        assertEq(to.balance, 0);
    }

    function test_views_defaultToZeroForUnknownAddress() public {
        address unknown = makeAddr("unknown");

        assertEq(tank.amountOf(unknown), 0);
        assertEq(tank.lastClaimOf(unknown), 0);
        assertEq(tank.claimableAt(unknown), 0);
    }

    // ---------------------------------------------------------------- helpers

    function _eoa(uint256 i) internal returns (address) {
        return makeAddr(string.concat("eoa", vm.toString(i)));
    }

    /// Removes the entry at `index` of `recipients()` and checks the list stays dense
    /// and the removed EOA keeps no amount and no claim history.
    function _removeAt(uint256 index) internal {
        address victim = tank.recipients()[index];

        // claim() does not exist yet: seed a last claim so the clearing is observable.
        stdstore.target(address(tank)).sig(tank.lastClaimOf.selector).with_key(victim).checked_write(SEEDED_LAST_CLAIM);
        assertEq(tank.lastClaimOf(victim), SEEDED_LAST_CLAIM);
        assertEq(tank.claimableAt(victim), SEEDED_LAST_CLAIM + 1 days);

        vm.expectEmit(address(tank));
        emit GasTank.RecipientRemoved(victim);
        vm.prank(OWNER);
        tank.removeRecipient(victim);

        _dropExpected(victim);
        _assertListMatchesExpected();
        assertEq(tank.amountOf(victim), 0);
        assertEq(tank.lastClaimOf(victim), 0);
        assertEq(tank.claimableAt(victim), 0);
    }

    /// Same length, no hole, no duplicate and every entry expected: the list is a
    /// permutation of `_expected`, each entry with its expected amount.
    function _assertListMatchesExpected() internal view {
        address[] memory list = tank.recipients();
        assertEq(list.length, _expected.length, "length");
        for (uint256 i; i < list.length; ++i) {
            assertTrue(list[i] != address(0), "hole");
            for (uint256 j = i + 1; j < list.length; ++j) {
                assertTrue(list[i] != list[j], "duplicate");
            }
            assertTrue(_isExpected(list[i]), "unexpected entry");
            assertEq(tank.amountOf(list[i]), _expectedAmount[list[i]], "amount");
        }
    }

    function _isExpected(address eoa) internal view returns (bool) {
        for (uint256 i; i < _expected.length; ++i) {
            if (_expected[i] == eoa) return true;
        }
        return false;
    }

    function _dropExpected(address eoa) internal {
        for (uint256 i; i < _expected.length; ++i) {
            if (_expected[i] == eoa) {
                _expected[i] = _expected[_expected.length - 1];
                _expected.pop();
                return;
            }
        }
    }
}
