"""Unit tests for the Safe batch generator. Run from the repo root: python3 -m pytest batch/tests -q"""
import copy
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

BATCH_DIR = Path(__file__).resolve().parents[1]
REPO = BATCH_DIR.parent
sys.path.insert(0, str(BATCH_DIR))

import gen_batch  # noqa: E402
from gen_batch import SAFE, TANK, build, calldata, load_config, tx_builder_json  # noqa: E402

EXAMPLE = BATCH_DIR / "config" / "example.json"
ZERO = "0x" + "00" * 20
TX_KEYS = {"to", "value", "data", "contractMethod", "contractInputsValues"}
REAL = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"  # EIP-55 form (anvil's second dev account), not a placeholder


def cast(*args) -> str:
    return subprocess.run(["cast", *args], capture_output=True, text=True, check=True).stdout.strip()


SET_RECIPIENT = cast("sig", "setRecipient(address,uint256)")
DISTRIBUTE = cast("sig", "distribute()")


def example() -> dict:
    return json.loads(EXAMPLE.read_text())


def write(tmp_path, cfg: dict) -> str:
    path = tmp_path / "config.json"
    path.write_text(json.dumps(cfg))
    return str(path)


def test_batch_order_is_recipients_then_funding_then_distribute():
    cfg = load_config(str(EXAMPLE))
    n = len(cfg["recipients"])
    txs = build(cfg)

    assert n == 6
    assert len(txs) == n + 2
    assert [t["to"] for t in txs] == [TANK] * n + [TANK, TANK]
    assert [t["value"] for t in txs] == ["0"] * n + [cfg["fund_wei"], "0"]
    assert all(t["data"].startswith(SET_RECIPIENT) for t in txs[:n])
    assert txs[n]["data"] == "0x"  # plain value transfer: the tank's receive()
    assert txs[n + 1]["data"] == DISTRIBUTE


def test_set_recipient_calldata_decodes_back():
    cfg = load_config(str(EXAMPLE))
    for recipient, t in zip(cfg["recipients"], build(cfg)):
        lines = cast("calldata-decode", "setRecipient(address,uint256)", t["data"]).splitlines()
        eoa, amount = (line.split()[0] for line in lines)
        assert [eoa.lower(), amount] == [recipient["eoa"].lower(), recipient["amount_wei"]]


def test_no_funding_and_no_distribute_gives_only_set_recipient(tmp_path):
    cfg = example()
    cfg["fund_wei"] = "0"
    cfg["distribute"] = False
    txs = build(load_config(write(tmp_path, cfg)))

    assert len(txs) == len(cfg["recipients"])
    assert all(t["to"] == TANK and t["value"] == "0" and t["data"].startswith(SET_RECIPIENT) for t in txs)


def test_tx_builder_json_shape():
    cfg = load_config(str(EXAMPLE))
    txs = build(cfg)
    j = tx_builder_json(cfg, txs)

    assert j["version"] == "1.0"
    assert j["chainId"] == "1"
    assert j["meta"]["createdFromSafeAddress"] == SAFE
    assert j["transactions"] == txs
    for t in txs:
        assert set(t) == TX_KEYS
        assert t["contractMethod"] is None and t["contractInputsValues"] is None


def test_main_writes_the_tx_builder_file(tmp_path):
    out = tmp_path / "batch.json"
    subprocess.run([sys.executable, "batch/gen_batch.py", "--config", str(EXAMPLE), "--out", str(out)],
                   cwd=REPO, capture_output=True, text=True, check=True)

    written = json.loads(out.read_text())
    assert written["transactions"] == build(load_config(str(EXAMPLE)))
    assert written["meta"]["createdFromSafeAddress"] == SAFE


def _thirty_three_recipients(cfg):
    cfg["recipients"] = [{"name": f"keeper-{i}", "eoa": "0x7e57" + f"{i + 1:036x}", "amount_wei": "1"}
                         for i in range(33)]


def _set_recipient(field, value):
    return lambda cfg: cfg["recipients"][0].update({field: value})


# (case, how the example config is broken, a fragment of the expected message)
REFUSALS = [
    ("unknown key", lambda cfg: cfg.update(extra=1), "unknown key"),
    ("unknown recipient key", _set_recipient("note", "x"), "unknown key"),
    ("missing key", lambda cfg: cfg.pop("fund_wei"), "missing key"),
    ("duplicate EOA", lambda cfg: cfg["recipients"][1].update(eoa=cfg["recipients"][0]["eoa"].upper().replace("X", "x")),
     "duplicate EOA"),
    ("more than 32 recipients", _thirty_three_recipients, "at most 32"),
    ("amount_wei zero", _set_recipient("amount_wei", "0"), "amount_wei must be > 0"),
    ("amount_wei negative", _set_recipient("amount_wei", "-1"), "amount_wei must be > 0"),
    ("fund_wei negative", lambda cfg: cfg.update(fund_wei="-1"), "fund_wei must be >= 0"),
    ("recipient is the Safe", _set_recipient("eoa", SAFE.lower()), "is the ops Safe"),
    ("recipient is the tank", _set_recipient("eoa", TANK), "is the tank"),
    ("recipient is the zero address", _set_recipient("eoa", ZERO), "is the zero address"),
    ("distribute with no recipient", lambda cfg: cfg.update(recipients=[]), "no recipient"),
    ("malformed address", _set_recipient("eoa", "0x1234"), "not an address"),
    ("wei as a JSON number", _set_recipient("amount_wei", 50000000000000000), "string"),
    ("eoa all in lowercase", _set_recipient("eoa", REAL.lower()), "single case"),
    ("eoa with one letter in the wrong case", _set_recipient("eoa", REAL.replace("C5", "c5")),
     "fails its EIP-55 checksum"),
    ("amount_wei at 2**255", _set_recipient("amount_wei", str(2**255)), "would overflow"),
]


@pytest.mark.parametrize("bad", REFUSALS, ids=[case for case, _, _ in REFUSALS])
def test_config_is_refused(bad, tmp_path):
    _, breaks, message = bad
    cfg = copy.deepcopy(example())
    breaks(cfg)
    with pytest.raises(SystemExit, match=message):
        load_config(write(tmp_path, cfg))


def test_checksummed_eoa_and_amount_just_below_2_255_are_accepted(tmp_path):
    cfg = example()
    cfg["recipients"][0].update(eoa=REAL, amount_wei=str(2**255 - 1))
    assert load_config(write(tmp_path, cfg))["recipients"][0]["eoa"] == REAL


def _real_eoas(cfg: dict) -> dict:
    cfg["recipients"] = [dict(cfg["recipients"][0], eoa=REAL)]
    return cfg


def test_example_eoas_are_flagged_as_placeholders(tmp_path):
    assert gen_batch.placeholders(load_config(str(EXAMPLE))) == [
        "sigmausd", "leverage", "strategy-3", "strategy-4", "strategy-5", "strategy-6"]
    assert gen_batch.placeholders(load_config(write(tmp_path, _real_eoas(example())))) == []


def test_example_batch_is_marked_not_signable(tmp_path):
    cfg = load_config(str(EXAMPLE))
    assert "DO NOT SIGN" in tx_builder_json(cfg, build(cfg))["meta"]["name"]
    cfg = load_config(write(tmp_path, _real_eoas(example())))
    assert "DO NOT SIGN" not in tx_builder_json(cfg, build(cfg))["meta"]["name"]


def test_native_units_are_exact():
    assert gen_batch.native(50000000000000000, 1) == "0.05 ETH"
    assert gen_batch.native(173276196284516701, 10) == "0.173276196284516701 ETH"
    assert gen_batch.native(2 * 10**18, 137) == "2 POL"
    assert gen_batch.native(10**18 + 1, 143) == "1.000000000000000001 MON"
    assert gen_batch.native(0, 999) == "0 HYPE"


def test_main_prints_native_units_and_flags_the_example(tmp_path):
    out = subprocess.run([sys.executable, "batch/gen_batch.py", "--config", str(EXAMPLE), "--out",
                          str(tmp_path / "batch.json")], cwd=REPO, capture_output=True, text=True, check=True).stdout
    assert "amount 50000000000000000 wei (0.05 ETH)" in out
    assert "send 173276196284516701 wei (0.173276196284516701 ETH) to the tank" in out
    assert "WARNING" in out and "DO NOT SIGN" in out


def test_replay_with_deployed_refuses_the_example_eoas():
    # Refused before any fork is started: no RPC variable is needed.
    env = {k: v for k, v in os.environ.items() if not k.endswith("_RPC_URL")}
    r = subprocess.run([sys.executable, "batch/fork_test.py", "--config", str(EXAMPLE), "--deployed"],
                       cwd=REPO, capture_output=True, text=True, env=env)
    assert r.returncode == 1
    assert "fictive" in r.stderr and "sigmausd" in r.stderr


def _generated_file(tmp_path) -> dict:
    """The batch file exactly as `gen_batch.py --out` writes it, read back from disk."""
    out = tmp_path / "batch.json"
    subprocess.run([sys.executable, "batch/gen_batch.py", "--config", str(EXAMPLE), "--out", str(out)],
                   cwd=REPO, capture_output=True, text=True, check=True)
    return json.loads(out.read_text())


def test_generated_batch_file_matches_its_config(tmp_path):
    assert gen_batch.batch_mismatches(load_config(str(EXAMPLE)), _generated_file(tmp_path)) == []


def _edit_tx(index, **fields):
    return lambda batch: batch["transactions"][index].update(fields)


def _other_amount(batch):
    eoa = example()["recipients"][2]["eoa"]
    batch["transactions"][2]["data"] = calldata("setRecipient(address,uint256)", eoa, 40000000000000000)


# (case, how the generated file is edited, a fragment of the expected message)
FILE_EDITS = [
    ("changed EOA", lambda batch: batch["transactions"][0].update(
        data=batch["transactions"][0]["data"].replace("7e57000000000000000000000000000000000001",
                                                      "7e57000000000000000000000000000000000009")),
     "transaction 1: data"),
    ("changed amount", _other_amount, "transaction 3: data"),
    ("changed funding value", _edit_tx(6, value="173276196284516700"), "transaction 7: value"),
    ("wrong chainId", lambda batch: batch.update(chainId="10"), "chainId"),
    ("wrong Safe address", lambda batch: batch["meta"].update(
        createdFromSafeAddress="0x405dBF6606336AB3d6574f78EDdfA68038e9F9A1"), "createdFromSafeAddress"),
    ("extra transaction", lambda batch: batch["transactions"].append(dict(batch["transactions"][-1])),
     "9 transaction"),
]


@pytest.mark.parametrize("edit", FILE_EDITS, ids=[case for case, _, _ in FILE_EDITS])
def test_edited_batch_file_is_flagged(edit, tmp_path):
    _, edits, message = edit
    batch = _generated_file(tmp_path)
    edits(batch)
    problems = gen_batch.batch_mismatches(load_config(str(EXAMPLE)), batch)
    assert any(message in p for p in problems), problems
