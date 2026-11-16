"""Unit tests for the pure parts of the fork replay. Run from the repo root: python3 -m pytest batch/tests -q"""
import json
import sys
from pathlib import Path

BATCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BATCH_DIR))

import fork_test  # noqa: E402

CFG = json.loads((BATCH_DIR / "config" / "example.json").read_text())
EOAS = [r["eoa"] for r in CFG["recipients"]]
AMOUNT = 50000000000000000


def _changes(on_chain) -> tuple[dict, str]:
    """recipient_changes(), as {name or address: line} plus the summary line."""
    *lines, summary = fork_test.recipient_changes(CFG, on_chain)
    by_key = {}
    for line in lines:
        words = line.split()
        by_key[words[3] if words[0] == "NOT" else words[1]] = line
    return by_key, summary


def test_fresh_tank_lists_every_eoa_as_new():
    lines, summary = _changes([])
    assert all(line.split()[0] == "NEW" for line in lines.values())
    assert "0.05 ETH" in lines["sigmausd"]
    assert summary == "changes: 6 NEW, 0 AMOUNT, 0 unchanged, 0 NOT IN CONFIG"


def test_same_list_in_another_order_is_unchanged():
    # Swap-and-pop order after a removal and a re-add: the order is not a change.
    lines, summary = _changes([(e.upper().replace("0X", "0x"), AMOUNT) for e in reversed(EOAS)])
    assert all(line.split()[0] == "unchanged" for line in lines.values())
    assert summary == "changes: 0 NEW, 0 AMOUNT, 6 unchanged, 0 NOT IN CONFIG"


def test_changed_amount_shows_old_and_new():
    lines, summary = _changes([(e, AMOUNT if i else 40000000000000000) for i, e in enumerate(EOAS)])
    assert lines["sigmausd"].split()[0] == "AMOUNT"
    assert "40000000000000000 -> 50000000000000000 wei (0.04 ETH -> 0.05 ETH)" in lines["sigmausd"]
    assert summary == "changes: 0 NEW, 1 AMOUNT, 5 unchanged, 0 NOT IN CONFIG"


def test_eoa_removed_by_hand_but_still_in_the_config_shows_as_new():
    # The last EOA was removed on chain (a plain pop); the stale config would list it again.
    lines, summary = _changes([(e, AMOUNT) for e in EOAS[:-1]])
    assert lines["strategy-6"].split()[0] == "NEW"
    assert summary == "changes: 1 NEW, 0 AMOUNT, 5 unchanged, 0 NOT IN CONFIG"


def test_eoa_listed_on_chain_but_absent_from_the_config_is_reported():
    other = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    lines, summary = _changes([(e, AMOUNT) for e in EOAS] + [(other, 7)])
    assert lines[other].startswith("NOT IN CONFIG")
    assert "the batch does not remove it" in lines[other]
    assert summary == "changes: 0 NEW, 0 AMOUNT, 6 unchanged, 1 NOT IN CONFIG"


def test_recipients_check_ignores_the_order():
    assert fork_test.list_mismatches(EOAS, CFG["recipients"]) == []
    swapped = [EOAS[0], EOAS[5], EOAS[2], EOAS[3], EOAS[4], EOAS[1]]  # remove [1], then re-add it
    assert fork_test.list_mismatches([e.lower() for e in swapped], CFG["recipients"]) == []


def test_recipients_check_reports_missing_and_extra_eoas():
    other = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    problems = fork_test.list_mismatches(EOAS[1:] + [other], CFG["recipients"])
    assert any("sigmausd" in p and "not in recipients()" in p for p in problems), problems
    assert any(other in p and "not in the config" in p for p in problems), problems
    assert len(problems) == 2
