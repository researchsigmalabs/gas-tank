#!/usr/bin/env python3
"""Safe Transaction Builder batch for GasTank: setRecipient per EOA, then the funding, then distribute().

python3 batch/gen_batch.py --config batch/config/<chain>.json --out <file>.json

Reads nothing from any chain: the batch depends on the config file only (plus the file's creation date).
Replay it on a fork with batch/fork_test.py before anyone signs it."""
import argparse
import json
import re
import subprocess
import time

SAFE = "0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1"  # ops Safe, GasTank's immutable owner
TANK = "0xe9A731d24c524B9efb032786F3c1C3e53D36f712"  # GasTank on every chain (PINNED in test/Deploy.t.sol)
ZERO = "0x0000000000000000000000000000000000000000"
MAX_RECIPIENTS = 32  # GasTank.MAX_RECIPIENTS
NATIVE = {1: "ETH", 10: "ETH", 8453: "ETH", 42161: "ETH", 137: "POL", 143: "MON", 999: "HYPE"}

CONFIG_KEYS = {"chain_id", "rpc_env", "recipients", "fund_wei", "distribute"}
RECIPIENT_KEYS = {"name", "eoa", "amount_wei"}
_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")
_PLACEHOLDER = re.compile(r"0x7e570{24}[0-9a-f]{12}")  # the fictive EOAs of batch/config/example.json
_WEI = re.compile(r"-?[0-9]+")
_ENV_NAME = re.compile(r"[A-Z_][A-Z0-9_]*")


def native(wei: int, chain_id: int) -> str:
    """`wei` in the chain's native token, exactly: native(50000000000000000, 1) == "0.05 ETH"."""
    whole, frac = divmod(wei, 10**18)
    digits = str(whole) + (("." + f"{frac:018d}".rstrip("0")) if frac else "")
    return f"{digits} {NATIVE.get(chain_id, 'native units')}"


def _checksummed(address: str) -> str:
    return subprocess.run(["cast", "to-check-sum-address", address], capture_output=True, text=True,
                          check=True).stdout.strip()


def _check_keys(obj, expected: set, where: str) -> None:
    if not isinstance(obj, dict):
        raise ValueError(f"{where} must be a JSON object")
    unknown, missing = set(obj) - expected, expected - set(obj)
    if unknown:
        raise ValueError(f"{where}: unknown key(s) {sorted(unknown)}; allowed: {sorted(expected)}")
    if missing:
        raise ValueError(f"{where}: missing key(s) {sorted(missing)}")


def _wei(value, where: str) -> int:
    # A string, as in the Tx Builder JSON: a JSON number above 2**53 loses digits in many tools.
    if not isinstance(value, str) or not _WEI.fullmatch(value):
        raise ValueError(f"{where} must be a whole number of wei written as a string, e.g. \"50000000000000000\"")
    wei = int(value)
    if wei >= 2**256:
        raise ValueError(f"{where} does not fit in a uint256")
    return wei


def _validate(cfg) -> None:
    _check_keys(cfg, CONFIG_KEYS, "config")
    if not isinstance(cfg["chain_id"], int) or isinstance(cfg["chain_id"], bool) or cfg["chain_id"] <= 0:
        raise ValueError("chain_id must be a positive integer, e.g. 1 for Ethereum")
    if not isinstance(cfg["rpc_env"], str) or not _ENV_NAME.fullmatch(cfg["rpc_env"]):
        raise ValueError("rpc_env must be the NAME of an environment variable, e.g. \"ETH_RPC_URL\" (never the URL)")
    if not isinstance(cfg["distribute"], bool):
        raise ValueError("distribute must be true or false")
    if _wei(cfg["fund_wei"], "fund_wei") < 0:
        raise ValueError(f"fund_wei must be >= 0, got {cfg['fund_wei']}")

    recipients = cfg["recipients"]
    if not isinstance(recipients, list):
        raise ValueError("recipients must be a list")
    if len(recipients) > MAX_RECIPIENTS:
        raise ValueError(f"{len(recipients)} recipients: the tank holds at most {MAX_RECIPIENTS}")
    if cfg["distribute"] and not recipients:
        raise ValueError("distribute is true but there is no recipient to distribute to")

    forbidden = {SAFE.lower(): "the ops Safe", TANK.lower(): "the tank itself", ZERO: "the zero address"}
    seen = set()
    for i, r in enumerate(recipients):
        where = f"recipients[{i}]"
        _check_keys(r, RECIPIENT_KEYS, where)
        if not isinstance(r["name"], str) or not r["name"]:
            raise ValueError(f"{where}: name must be a non-empty string")
        where = f"recipient {r['name']!r}"
        eoa = r["eoa"]
        if not isinstance(eoa, str) or not _ADDRESS.fullmatch(eoa):
            raise ValueError(f"{where}: eoa {eoa!r} is not an address (0x followed by 40 hex digits)")
        if eoa.lower() in forbidden:
            raise ValueError(f"{where}: eoa {eoa} is {forbidden[eoa.lower()]}, not a keeper EOA")
        if eoa.lower() in seen:
            raise ValueError(f"{where}: duplicate EOA {eoa} (listed twice)")
        seen.add(eoa.lower())
        # EIP-55: the mix of upper- and lower-case letters is a checksum, so a mistyped character is caught.
        # The expected form is not printed: pasting it would turn a typo into a valid address.
        if eoa != _checksummed(eoa):
            if eoa[2:] in (eoa[2:].lower(), eoa[2:].upper()):
                raise ValueError(f"{where}: eoa {eoa} is written in a single case, so its EIP-55 checksum cannot "
                                 "catch a typo: copy it again, with its upper- and lower-case letters, from its source")
            raise ValueError(f"{where}: eoa {eoa} fails its EIP-55 checksum (its pattern of upper- and lower-case "
                             "letters): a character is probably wrong, copy it again from its source")
        amount = _wei(r["amount_wei"], f"{where}: amount_wei")
        if amount <= 0:
            raise ValueError(f"{where}: amount_wei must be > 0, got {r['amount_wei']}")
        if amount >= 2**255:
            raise ValueError(f"{where}: amount_wei must be below 2**255: the tank computes twice the amount "
                             "(its balance ceiling), which would overflow")


def load_config(path: str) -> dict:
    """Reads and validates a chain config; any problem stops the program with a message naming it."""
    try:
        with open(path) as f:
            cfg = json.load(f)
        _validate(cfg)
    except (OSError, json.JSONDecodeError, ValueError) as e:
        raise SystemExit(f"{path}: {e}") from None
    return cfg


def placeholders(cfg: dict) -> list[str]:
    """Names of the recipients that still hold one of the example's fictive EOAs (0x7e57, then 24 zeros)."""
    return [r["name"] for r in cfg["recipients"] if _PLACEHOLDER.fullmatch(r["eoa"].lower())]


def calldata(sig: str, *args) -> str:
    return subprocess.run(["cast", "calldata", sig, *[str(a) for a in args]], capture_output=True, text=True,
                          check=True).stdout.strip()


def _tx(value: int, data: str) -> dict:
    return {"to": TANK, "value": str(value), "data": data, "contractMethod": None, "contractInputsValues": None}


def build(cfg: dict) -> list[dict]:
    """The batch, in order: setRecipient for each EOA, the funding (if any), distribute() (if asked)."""
    txs = [_tx(0, calldata("setRecipient(address,uint256)", r["eoa"], int(r["amount_wei"])))
           for r in cfg["recipients"]]
    fund = int(cfg["fund_wei"])
    if fund > 0:
        txs.append(_tx(fund, "0x"))  # plain transfer: lands in the tank's receive()
    if cfg["distribute"]:
        txs.append(_tx(0, calldata("distribute()")))
    return txs


def tx_builder_json(cfg: dict, txs: list[dict]) -> dict:
    n, fund = len(cfg["recipients"]), int(cfg["fund_wei"])
    steps = [f"setRecipient for {n} EOA(s)"] + ([f"fund {fund} wei"] if fund else []) + \
        (["distribute()"] if cfg["distribute"] else [])
    name = f"GasTank batch (chain {cfg['chain_id']})"
    if placeholders(cfg):
        name = "EXAMPLE, DO NOT SIGN (fictive EOAs): " + name
    return {"version": "1.0", "chainId": str(cfg["chain_id"]), "createdAt": int(time.time() * 1000),
            "meta": {"name": name,
                     "description": f"GasTank {TANK}: " + ", then ".join(steps) + ".",
                     "txBuilderVersion": "1.18.0", "createdFromSafeAddress": SAFE, "createdFromOwnerAddress": ""},
            "transactions": txs}


def batch_mismatches(cfg: dict, batch) -> list[str]:
    """How a Transaction Builder file differs from what `cfg` generates: its chainId, its Safe, and its
    transactions, which must equal build(cfg) exactly. An empty list means the file is the config's batch."""
    if not isinstance(batch, dict):
        return ["the file is not a Transaction Builder batch (a JSON object)"]
    problems = []
    if batch.get("chainId") != str(cfg["chain_id"]):
        problems.append(f"chainId is {batch.get('chainId')!r} in the file, {str(cfg['chain_id'])!r} in the config")
    meta = batch.get("meta") if isinstance(batch.get("meta"), dict) else {}
    safe = meta.get("createdFromSafeAddress")
    if not isinstance(safe, str) or safe.lower() != SAFE.lower():
        problems.append(f"meta.createdFromSafeAddress is {safe!r} in the file, the ops Safe is {SAFE}")

    got, want = batch.get("transactions"), build(cfg)
    if not isinstance(got, list):
        return problems + ["the file has no transactions list"]
    if len(got) != len(want):
        problems.append(f"the file has {len(got)} transaction(s), the config gives {len(want)}")
    for i, (g, w) in enumerate(zip(got, want), 1):
        if not isinstance(g, dict):
            problems.append(f"transaction {i} is not a JSON object")
            continue
        for key in sorted(set(g) | set(w)):
            if g.get(key) != w.get(key):
                problems.append(f"transaction {i}: {key} is {g.get(key)!r} in the file, {w.get(key)!r} from the config")
    return problems


def main() -> None:
    ap = argparse.ArgumentParser(description="Writes the Safe Transaction Builder JSON for a GasTank chain config.")
    ap.add_argument("--config", required=True, help="batch/config/<chain>.json")
    ap.add_argument("--out", required=True, help="the JSON file to upload in the Safe Transaction Builder")
    a = ap.parse_args()
    cfg = load_config(a.config)
    txs = build(cfg)
    with open(a.out, "w") as f:
        json.dump(tx_builder_json(cfg, txs), f, indent=1)
        f.write("\n")

    chain_id = cfg["chain_id"]
    print(f"{a.out}: {len(txs)} transaction(s) for the Safe {SAFE} on chain {chain_id}, all to {TANK}")
    for i, r in enumerate(cfg["recipients"], 1):
        amount = int(r["amount_wei"])
        print(f"  {i}. setRecipient {r['name']} {r['eoa']} amount {amount} wei ({native(amount, chain_id)})")
    step = len(cfg["recipients"])
    fund = int(cfg["fund_wei"])
    if fund > 0:
        step += 1
        print(f"  {step}. send {fund} wei ({native(fund, chain_id)}) to the tank")
    if cfg["distribute"]:
        print(f"  {step + 1}. distribute()")
    fake = placeholders(cfg)
    if fake:
        print(f"WARNING {', '.join(fake)}: the example's fictive EOAs (0x7e57...), never to be funded. "
              "The file is named \"EXAMPLE, DO NOT SIGN\": do not sign it.")


if __name__ == "__main__":
    main()
