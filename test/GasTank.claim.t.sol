// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GasTank} from "../src/GasTank.sol";
import {Reenterer} from "./utils/Reenterer.sol";

contract GasTankClaimTest is Test {
    address internal constant OWNER = 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1;
    uint256 internal constant AMOUNT = 0.05 ether;
    uint256 internal constant MINIMUM = 0.005 ether; // smallest partial payment for AMOUNT: one tenth
    uint256 internal constant START = 1_700_000_000;

    // Reentrancy during distribute(): three shares, each under the Reenterer's ceiling
    // (2 * AMOUNT), plus a division remainder below MINIMUM.
    uint256 internal constant SHARE = 0.03 ether;
    uint256 internal constant REMAINDER = 2;

    GasTank internal tank;
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(START);
        tank = new GasTank(OWNER);
        vm.prank(OWNER);
        tank.setRecipient(alice, AMOUNT);
    }

    function test_claim_notRecipient() public {
        vm.deal(address(tank), 1 ether);

        vm.prank(stranger);
        vm.expectRevert(GasTank.NotRecipient.selector);
        tank.claim();

        assertEq(address(tank).balance, 1 ether);
    }

    function test_claim_firstClaimIsImmediate_paysAmount() public {
        vm.deal(address(tank), 1 ether);

        vm.expectEmit(address(tank));
        emit GasTank.Claimed(alice, AMOUNT);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, AMOUNT);
        assertEq(address(tank).balance, 1 ether - AMOUNT);
        assertEq(tank.lastClaimOf(alice), START);
        assertEq(tank.claimableAt(alice), START + 1 days);
    }

    function test_claim_tooSoon_thenAllowedAtExactly24h() public {
        vm.deal(address(tank), 1 ether);
        vm.prank(alice);
        tank.claim();

        vm.warp(START + 1 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GasTank.ClaimTooSoon.selector, START + 1 days));
        tank.claim();

        vm.warp(START + 1 days);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, 2 * AMOUNT);
        assertEq(tank.lastClaimOf(alice), START + 1 days);
        assertEq(tank.claimableAt(alice), START + 2 days);
    }

    function test_claim_ceiling_exactlyTwiceIsRefused_oneWeiBelowPasses() public {
        vm.deal(address(tank), 1 ether);

        vm.deal(alice, 2 * AMOUNT);
        vm.prank(alice);
        vm.expectRevert(GasTank.BalanceAboveCeiling.selector);
        tank.claim();

        vm.deal(alice, 2 * AMOUNT - 1);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, 3 * AMOUNT - 1);
        assertEq(address(tank).balance, 1 ether - AMOUNT);
    }

    function test_claim_partial_paysWhatIsLeft_andStartsCooldown() public {
        vm.deal(address(tank), AMOUNT - 1);

        vm.expectEmit(address(tank));
        emit GasTank.Claimed(alice, AMOUNT - 1);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, AMOUNT - 1);
        assertEq(address(tank).balance, 0);
        assertEq(tank.lastClaimOf(alice), START);

        // Refilled an hour later, the tank still refuses: the partial payment was the day's claim.
        vm.warp(START + 1 hours);
        vm.deal(address(tank), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GasTank.ClaimTooSoon.selector, START + 1 days));
        tank.claim();
    }

    function test_claim_exactlyAtMinimum_paysIt_andStartsCooldown() public {
        vm.deal(address(tank), MINIMUM);

        vm.expectEmit(address(tank));
        emit GasTank.Claimed(alice, MINIMUM);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, MINIMUM);
        assertEq(address(tank).balance, 0);
        assertEq(tank.lastClaimOf(alice), START);

        // Refilled an hour later, the tank still refuses: the minimum payment was the day's claim.
        vm.warp(START + 1 hours);
        vm.deal(address(tank), 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GasTank.ClaimTooSoon.selector, START + 1 days));
        tank.claim();
    }

    function test_claim_belowMinimum_reverts_andDoesNotStartCooldown() public {
        vm.deal(address(tank), MINIMUM - 1);

        vm.prank(alice);
        vm.expectRevert(GasTank.TankEmpty.selector);
        tank.claim();

        assertEq(alice.balance, 0);
        assertEq(address(tank).balance, MINIMUM - 1);
        assertEq(tank.lastClaimOf(alice), 0);
        assertEq(tank.claimableAt(alice), 0);

        // Refilled an hour later, the claim goes through at once and pays the full amount.
        vm.warp(START + 1 hours);
        vm.deal(address(tank), 1 ether);
        vm.expectEmit(address(tank));
        emit GasTank.Claimed(alice, AMOUNT);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, AMOUNT);
        assertEq(address(tank).balance, 1 ether - AMOUNT);
        assertEq(tank.lastClaimOf(alice), START + 1 hours);
    }

    function test_claim_oneWeiSentByAStranger_cannotLockAKeeper() public {
        vm.deal(stranger, 1);
        vm.prank(stranger);
        (bool ok,) = address(tank).call{value: 1}("");
        assertTrue(ok);
        assertEq(address(tank).balance, 1);

        vm.prank(alice);
        vm.expectRevert(GasTank.TankEmpty.selector);
        tank.claim();

        // Nothing paid and no cooldown started: the 1 wei bought nothing.
        assertEq(alice.balance, 0);
        assertEq(address(tank).balance, 1);
        assertEq(tank.lastClaimOf(alice), 0);
        assertEq(tank.claimableAt(alice), 0);
    }

    function test_claim_emptyTank_reverts_andDoesNotStartCooldown() public {
        vm.prank(alice);
        vm.expectRevert(GasTank.TankEmpty.selector);
        tank.claim();

        assertEq(tank.lastClaimOf(alice), 0);
        assertEq(tank.claimableAt(alice), 0);

        // Funded an hour later, the claim goes through at once.
        vm.warp(START + 1 hours);
        vm.deal(address(tank), 1 ether);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, AMOUNT);
        assertEq(tank.lastClaimOf(alice), START + 1 hours);
    }

    function test_claim_minimumFollowsTheAmount() public {
        vm.prank(OWNER);
        tank.setRecipient(alice, 0.001 ether); // minimum 0.0001 ether

        vm.deal(address(tank), 0.0001 ether - 1);
        vm.prank(alice);
        vm.expectRevert(GasTank.TankEmpty.selector);
        tank.claim();
        assertEq(tank.lastClaimOf(alice), 0);

        // Below the minimum of the old amount (0.005 ether), at the minimum of the new one.
        vm.deal(address(tank), 0.0001 ether);
        vm.expectEmit(address(tank));
        emit GasTank.Claimed(alice, 0.0001 ether);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, 0.0001 ether);
        assertEq(address(tank).balance, 0);
        assertEq(tank.lastClaimOf(alice), START);
    }

    function test_claim_tinyAmount_minimumRoundsToZero_stillNeedsANonEmptyTank() public {
        vm.prank(OWNER);
        tank.setRecipient(alice, 5); // 5 / 10 == 0: only the empty-tank check is left

        vm.prank(alice);
        vm.expectRevert(GasTank.TankEmpty.selector);
        tank.claim();
        assertEq(tank.lastClaimOf(alice), 0);

        vm.deal(address(tank), 1);
        vm.expectEmit(address(tank));
        emit GasTank.Claimed(alice, 1);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, 1);
        assertEq(address(tank).balance, 0);
        assertEq(tank.lastClaimOf(alice), START);
    }

    function test_claim_afterAmountChange_keepsCooldown_usesNewCeiling() public {
        vm.deal(address(tank), 1 ether);
        vm.prank(alice);
        tank.claim();

        vm.warp(START + 1 hours);
        vm.prank(OWNER);
        tank.setRecipient(alice, 0.01 ether);
        assertEq(tank.lastClaimOf(alice), START);

        vm.deal(alice, 0); // only the cooldown can refuse this claim
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GasTank.ClaimTooSoon.selector, START + 1 days));
        tank.claim();

        // Under the old ceiling (0.1 ether), at the new one (0.02 ether).
        vm.warp(START + 1 days);
        vm.deal(alice, 0.02 ether);
        vm.prank(alice);
        vm.expectRevert(GasTank.BalanceAboveCeiling.selector);
        tank.claim();

        vm.deal(alice, 0.02 ether - 1);
        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, 0.03 ether - 1); // paid the new amount
    }

    function test_claim_afterRemoveAndReAdd_isImmediate() public {
        vm.deal(address(tank), 1 ether);
        vm.prank(alice);
        tank.claim();

        vm.warp(START + 1 hours);
        vm.startPrank(OWNER);
        tank.removeRecipient(alice);
        tank.setRecipient(alice, AMOUNT);
        vm.stopPrank();
        assertEq(tank.lastClaimOf(alice), 0);

        vm.prank(alice);
        tank.claim();

        assertEq(alice.balance, 2 * AMOUNT);
        assertEq(tank.lastClaimOf(alice), START + 1 hours);
    }

    function test_distribute_doesNotTouchClaimCooldown() public {
        vm.prank(OWNER);
        tank.setRecipient(bob, AMOUNT);
        vm.deal(address(tank), 1 ether);
        vm.prank(alice);
        tank.claim();

        vm.warp(START + 1 hours);
        vm.prank(OWNER);
        tank.distribute();

        assertEq(tank.lastClaimOf(alice), START);
        // Bob is paid by distribute() before any claim of his.
        assertEq(tank.lastClaimOf(bob), 0);
        assertEq(tank.claimableAt(bob), 0);

        vm.deal(alice, 0); // only the cooldown can refuse this claim
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GasTank.ClaimTooSoon.selector, START + 1 days));
        tank.claim();
    }

    function test_reentrancy_claimDuringClaim_paysOnce() public {
        Reenterer reenterer = new Reenterer(tank);
        vm.prank(OWNER);
        tank.setRecipient(address(reenterer), AMOUNT);
        vm.deal(address(tank), 1 ether);

        reenterer.claim();

        // The inner claim met a balance under the ceiling and a funded tank: only the
        // last claim, written before the transfer, refused it.
        assertEq(reenterer.attempts(), 1);
        assertFalse(reenterer.innerSucceeded());
        assertEq(reenterer.lastRevertData(), abi.encodeWithSelector(GasTank.ClaimTooSoon.selector, START + 1 days));
        assertEq(address(reenterer).balance, AMOUNT);
        assertEq(address(tank).balance, 1 ether - AMOUNT);
        assertEq(tank.lastClaimOf(address(reenterer)), START);
    }

    function test_reentrancy_claimDuringDistribute_isBounded() public {
        // Listed first, the inner claim takes a full AMOUNT out of the shares still owed to
        // alice and bob. Alice is an EOA and accepts any payment, so her share failing proves
        // the inner claim was paid; the whole distribute() reverts.
        (bool ok, bytes memory revertData,) = _distributeToReentererListedAt(0);
        assertFalse(ok, "listed first: distribute should revert");
        assertEq(revertData, abi.encodeWithSelector(GasTank.TransferFailed.selector, alice));

        // Listed last, the inner claim finds only the division remainder, below the minimum
        // partial payment: it is refused, distribute() succeeds and the Reenterer holds exactly
        // its share.
        Reenterer reenterer;
        (ok,, reenterer) = _distributeToReentererListedAt(2);
        assertTrue(ok, "listed last: distribute should succeed");
        assertEq(reenterer.attempts(), 1);
        assertFalse(reenterer.innerSucceeded());
        assertEq(reenterer.lastRevertData(), abi.encodeWithSelector(GasTank.TankEmpty.selector));
        assertEq(address(reenterer).balance, SHARE);
        assertEq(tank.lastClaimOf(address(reenterer)), 0);
        assertEq(address(tank).balance, REMAINDER);
    }

    function testFuzz_claim_neverPaysMoreThanAmountPer24h(uint8[12] calldata hoursBetween) public {
        uint256 funded = 11 * AMOUNT / 2; // five full claims, a partial one, then empty
        vm.deal(address(tank), funded);

        uint256 time = START;
        uint256 received;
        uint256 lastPaidAt; // 0 until the first successful claim
        for (uint256 i; i < hoursBetween.length; ++i) {
            time += bound(hoursBetween[i], 0, 47) * 1 hours;
            vm.warp(time);
            vm.deal(alice, 0); // keeps the ceiling out of the way
            uint256 held = address(tank).balance;

            vm.prank(alice);
            try tank.claim() {
                uint256 paid = alice.balance;
                assertEq(paid, AMOUNT < held ? AMOUNT : held, "paid other than min(amount, held)");
                assertEq(address(tank).balance, held - paid, "tank balance");
                if (lastPaidAt != 0) assertGe(time, lastPaidAt + 1 days, "two claims within 24 h");
                received += paid;
                lastPaidAt = time;
            } catch (bytes memory reason) {
                // Only the cooldown or a tank holding less than the minimum may refuse a claim here.
                if (lastPaidAt != 0 && time < lastPaidAt + 1 days) {
                    assertEq(reason, abi.encodeWithSelector(GasTank.ClaimTooSoon.selector, lastPaidAt + 1 days));
                } else {
                    assertLt(held, MINIMUM, "refused while claimable");
                    assertEq(reason, abi.encodeWithSelector(GasTank.TankEmpty.selector));
                }
            }
            assertLe(received, AMOUNT * (1 + (time - START) / 1 days), "more than the amount per 24 h");
        }
        assertEq(received + address(tank).balance, funded, "funds not conserved");
    }

    // ---------------------------------------------------------------- helpers

    /// On a fresh tank, lists alice, bob and a Reenterer at `position`, funds three shares that
    /// stay under the Reenterer's ceiling (so its inner claim is reachable), distributes, and
    /// checks the outcome is bounded whichever way it went: either nothing moved, or the
    /// Reenterer holds at most one share plus one amount and every wei is accounted for.
    function _distributeToReentererListedAt(uint256 position)
        internal
        returns (bool ok, bytes memory revertData, Reenterer reenterer)
    {
        tank = new GasTank(OWNER);
        reenterer = new Reenterer(tank);
        address[2] memory eoas = [alice, bob];
        address[] memory list = new address[](3);
        uint256 next;
        for (uint256 i; i < list.length; ++i) {
            list[i] = i == position ? address(reenterer) : eoas[next++];
        }
        vm.startPrank(OWNER);
        for (uint256 i; i < list.length; ++i) {
            tank.setRecipient(list[i], AMOUNT);
        }
        vm.stopPrank();
        vm.deal(alice, 0);
        vm.deal(bob, 0);
        uint256 funded = 3 * SHARE + REMAINDER;
        vm.deal(address(tank), funded);

        vm.prank(OWNER);
        (ok, revertData) = address(tank).call(abi.encodeCall(GasTank.distribute, ()));

        uint256 payouts;
        for (uint256 i; i < list.length; ++i) {
            payouts += list[i].balance;
        }
        if (!ok) {
            assertEq(payouts, 0, "a reverted distribute moved funds");
            assertEq(address(tank).balance, funded, "a reverted distribute moved funds");
        } else {
            assertLe(address(reenterer).balance, SHARE + AMOUNT, "more than one share plus one amount");
            assertEq(address(tank).balance + payouts, funded, "funds not conserved");
        }
    }
}
