#!/usr/bin/env python3
"""Replays a GasTank batch through the REAL Safe.execTransaction on an anvil fork, then checks the result.

python3 batch/fork_test.py --config batch/config/<chain>.json [--batch <file>.json] [--deployed]

--batch: the Transaction Builder file to sign. It must equal what the config generates (chainId, Safe,
transactions); its own transactions are then the ones replayed, and its sha256 is printed.
--deployed: FAIL when the tank is not on the real chain yet (without it, a WARNING says so); also refuses a
config that still holds the example's fictive EOAs.

Before the batch, it prints what the batch changes in the tank's list (NEW, AMOUNT, unchanged, NOT IN CONFIG)
against the fork's state, which is the real chain's, and the safeTxHash the Safe app must show.

The fork URL is read from the environment variable named by the config's `rpc_env` and handed to anvil only:
it is never printed, and the cast/forge children run without it (they talk to the local fork only).
Prints one PASS/FAIL line per check and exits non-zero on any failure."""
import argparse
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from gen_batch import SAFE, TANK, batch_mismatches, build, calldata, load_config, native, placeholders

REPO = Path(__file__).resolve().parents[1]
MULTISEND = "0x9641d764fc13c8B624c04430C7356C1C7C8102e2"  # MultiSendCallOnly 1.4.1
DEPLOYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"  # anvil's first dev account, unlocked on any fork
ZERO = "0x0000000000000000000000000000000000000000"
DELEGATECALL = 1
ETHER = 10**18
MIN_PARTIAL_DIVISOR = 10  # GasTank: claim() refuses when the tank holds less than amount / 10
EXEC = "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)"
TX_HASH = "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)"
_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}")


class Fork:
    """An anvil fork on a free local port. Every printed text goes through `redact`."""

    def __init__(self, rpc_env: str):
        self.rpc_env, self.secret = rpc_env, os.environ.get(rpc_env, "")
        if not self.secret:
            raise SystemExit(f"{rpc_env} is not set: export it with the chain's RPC endpoint (see .env.example)")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}"
        # The cast/forge children run without the real endpoint: no Foundry default RPC to fall back on,
        # nothing for them to echo. anvil, which needs it, gets it on its command line: never printed, but
        # visible to local users in the process list while the replay runs.
        self.env = {k: v for k, v in os.environ.items()
                    if k not in (rpc_env, "ETH_RPC_URL") and v != self.secret}
        self.anvil = None

    def redact(self, text: str) -> str:
        text = text.replace(self.secret, f"${self.rpc_env}")
        return re.sub(r"(?i)\b(?:https?|wss?)://(?!127\.0\.0\.1[:/])\S+", "<url redacted>", text)

    def start(self) -> None:
        self.anvil = subprocess.Popen(["anvil", "--port", str(self.port), "--fork-url", self.secret, "--silent"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=self.env)
        for _ in range(120):
            if self.anvil.poll() is not None:
                break
            try:
                self.rpc("eth_chainId")
                return
            except OSError:
                time.sleep(0.5)
        raise SystemExit(f"anvil did not start a fork from ${self.rpc_env}: check the endpoint it holds")

    def stop(self) -> None:
        if self.anvil:
            self.anvil.terminate()
            try:
                self.anvil.wait(timeout=10)
            except subprocess.TimeoutExpired:  # its message would quote anvil's command line, URL included
                self.anvil.kill()
                self.anvil.wait()

    def try_rpc(self, method: str, *params):
        """JSON-RPC to the local fork. Returns (result, None), or (None, error) when the node answers an error."""
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=120) as r:
            answer = json.load(r)
        return answer.get("result"), answer.get("error")

    def rpc(self, method: str, *params):
        result, error = self.try_rpc(method, *params)
        if error:
            raise SystemExit(f"{method} failed: {self.redact(json.dumps(error))[-600:]}")
        return result

    def run(self, *cmd: str) -> subprocess.CompletedProcess:
        return subprocess.run(cmd, capture_output=True, text=True, env=self.env, cwd=REPO)

    def call(self, to: str, sig: str, *args) -> str:
        r = self.run("cast", "call", "--rpc-url", self.url, to, sig, *map(str, args))
        if r.returncode:
            raise SystemExit(f"cast call {sig} failed: {self.redact(r.stderr)[-600:]}")
        return r.stdout.strip()

    def uint(self, to: str, sig: str, *args) -> int:
        return int(self.call(to, sig, *args).split()[0])

    def balance(self, who: str) -> int:
        return int(self.rpc("eth_getBalance", who, "latest"), 16)

    def set_balance(self, who: str, wei: int) -> None:
        self.rpc("anvil_setBalance", who, hex(wei))

    def send(self, frm: str, to: str, sig: str, *args):
        """Transaction from an impersonated account. Returns (receipt, None) or (None, error text)."""
        self.rpc("anvil_impersonateAccount", frm)
        r = self.run("cast", "send", "--rpc-url", self.url, "--unlocked", "--from", frm, "--json", to, sig,
                     *map(str, args))
        if r.returncode:
            return None, self.redact(r.stderr.strip())[-800:]
        receipt = json.loads(r.stdout)
        return (receipt, None) if receipt["status"] == "0x1" else (None, f"status {receipt['status']}")


def pack_multisend(txs: list[dict]) -> str:
    """MultiSendCallOnly payload, per tx: operation (1 byte, 0 = call) | to (20) | value (32) | length (32) | data."""
    out = ""
    for t in txs:
        data = t["data"][2:]
        out += "00" + t["to"][2:].lower() + int(t["value"]).to_bytes(32, "big").hex()
        out += (len(data) // 2).to_bytes(32, "big").hex() + data
    return "0x" + out


def exec_through_safe(fork: Fork, txs: list[dict]):
    """The batch as the Safe UI sends it: one execTransaction, delegatecall to MultiSendCallOnly, signed by
    `threshold` owners. The first owners approve the hash on-chain; the last one executes. Every signature is the
    pre-validated kind (r = owner, s = 0, v = 1), sorted by owner address as the Safe requires.
    Prints the safeTxHash. Returns (signers, gas used or None, error text or None)."""
    owners = _ADDRESS.findall(fork.call(SAFE, "getOwners()(address[])"))
    threshold = fork.uint(SAFE, "getThreshold()(uint256)")
    signers = owners[:threshold]
    nonce = fork.uint(SAFE, "nonce()(uint256)")
    safe_tx = [MULTISEND, 0, calldata("multiSend(bytes)", pack_multisend(txs)), DELEGATECALL, 0, 0, 0, ZERO, ZERO]
    tx_hash = fork.call(SAFE, TX_HASH, *safe_tx, nonce)
    print(f"safeTxHash {tx_hash} for Safe nonce {nonce} (the Safe's nonce on the chain at replay time): the Safe "
          f"app shows this same hash only if it gives this batch nonce {nonce}", flush=True)

    for owner in signers:
        fork.set_balance(owner, ETHER)  # gas for the owner's own transaction
    for owner in signers[:-1]:
        _, err = fork.send(owner, SAFE, "approveHash(bytes32)", tx_hash)
        if err:
            return signers, None, f"approveHash by {owner} failed: {err}"
    signatures = "0x" + "".join(o[2:].lower().rjust(64, "0") + "00" * 32 + "01"
                                for o in sorted(signers, key=lambda a: int(a, 16)))
    receipt, err = fork.send(signers[-1], SAFE, EXEC, *safe_tx, signatures)
    if err:
        return signers, None, f"execTransaction failed: {err}"
    topic = fork.run("cast", "keccak", "ExecutionSuccess(bytes32,uint256)").stdout.strip()
    emitted = any(log["address"].lower() == SAFE.lower() and log["topics"][:2] == [topic, tx_hash]
                  for log in receipt["logs"])
    gas = int(receipt["gasUsed"], 16)
    return signers, gas, None if emitted else "no ExecutionSuccess event for this Safe transaction"


def recipient_changes(cfg: dict, on_chain: list[tuple[str, int]]) -> list[str]:
    """What the batch's setRecipient calls change, against `on_chain`, the (EOA, amount) pairs the tank lists
    before the batch. One line per configured EOA (NEW, AMOUNT old -> new, or unchanged), one per EOA listed
    on chain but absent from the config (NOT IN CONFIG), then a summary line. The order is not a change."""
    chain_id, current = cfg["chain_id"], {eoa.lower(): (eoa, amount) for eoa, amount in on_chain}
    counts = {"NEW": 0, "AMOUNT": 0, "unchanged": 0, "NOT IN CONFIG": 0}
    lines = []
    for r in cfg["recipients"]:
        want = int(r["amount_wei"])
        _, old = current.pop(r["eoa"].lower(), (None, None))
        if old is None:
            kind, amounts = "NEW", f"{want} wei ({native(want, chain_id)})"
        elif old != want:
            kind, amounts = "AMOUNT", f"{old} -> {want} wei ({native(old, chain_id)} -> {native(want, chain_id)})"
        else:
            kind, amounts = "unchanged", f"{want} wei ({native(want, chain_id)})"
        counts[kind] += 1
        lines.append(f"{kind:<9} {r['name']} {r['eoa']} {amounts}")
    for eoa, amount in current.values():
        counts["NOT IN CONFIG"] += 1
        lines.append(f"NOT IN CONFIG {eoa} {amount} wei ({native(amount, chain_id)}): listed on chain, "
                     "absent from the config, the batch does not remove it")
    return lines + ["changes: " + ", ".join(f"{n} {kind}" for kind, n in counts.items())]


def list_mismatches(listed: list[str], recipients: list[dict]) -> list[str]:
    """How the tank's list differs from the config's EOAs, ignoring the order: removeRecipient moves the last
    EOA into the removed one's slot, so the on-chain order legitimately differs from the config's."""
    have = {a.lower(): a for a in listed}
    want = {r["eoa"].lower(): r for r in recipients}
    return [f"{r['name']} {r['eoa']} is in the config but not in recipients()" for k, r in want.items()
            if k not in have] + [f"{a} is in recipients() but not in the config" for k, a in have.items()
                                 if k not in want]


def not_on_chain(chain_id: int) -> str:
    return f"tank NOT on chain {chain_id}: deployed on this fork only, do not sign this batch on the real chain"


def replay(fork: Fork, cfg: dict, txs: list[dict], check, warn, deployed: bool) -> None:
    """Deploys the tank if needed, runs `txs` through the Safe, then checks every effect. Stops at a failure the
    later checks cannot survive (no tank, batch not executed). `warn` prints a WARNING that main() repeats."""
    recipients, fund = cfg["recipients"], int(cfg["fund_wei"])
    chain_id = int(fork.rpc("eth_chainId"), 16)
    if chain_id != cfg["chain_id"]:
        raise SystemExit(f"${cfg['rpc_env']} serves chain {chain_id}, the config says {cfg['chain_id']}")
    print(f"fork of chain {chain_id} at block {int(fork.rpc('eth_blockNumber'), 16)}, "
          f"batch of {len(txs)} transaction(s)", flush=True)

    # The fork starts at the real chain's latest block: what is read before any change is the real chain's state.
    on_chain = fork.rpc("eth_getCode", TANK, "latest") not in (None, "0x")
    if deployed:
        if not check(f"tank already on chain {chain_id} at {TANK} (--deployed)", on_chain, not_on_chain(chain_id)):
            warn(not_on_chain(chain_id), echo=False)
    elif on_chain:
        print(f"NOTE tank already on chain {chain_id}: the deploy script below only verifies it", flush=True)
    else:
        warn(not_on_chain(chain_id))
    real_safe = fork.balance(SAFE)
    if real_safe < fund:
        warn(f"the Safe holds {real_safe} wei ({native(real_safe, chain_id)}) on chain {chain_id}, less than "
             f"fund_wei {fund} wei ({native(fund, chain_id)}): on the real chain the batch fails until the Safe "
             "holds the funding (this fork gives it fund_wei plus 1 native token to replay the batch)")
    for r in recipients:
        if fork.rpc("eth_getCode", r["eoa"], "latest") not in (None, "0x"):
            warn(f"recipient {r['name']} {r['eoa']} has code on chain {chain_id} (a contract, or an EOA delegated "
                 "with EIP-7702): it can refuse funds, and distribute() then fails for every EOA until the Safe "
                 "removes it")

    deploy = fork.run("forge", "script", "script/Deploy.s.sol", "--rpc-url", fork.url, "--broadcast",
                      "--unlocked", "--sender", DEPLOYER)
    check("deploy script ran (forge script script/Deploy.s.sol --broadcast)", deploy.returncode == 0,
          fork.redact(deploy.stdout + deploy.stderr)[-800:])
    code = fork.rpc("eth_getCode", TANK, "latest")
    if not check(f"tank at {TANK} on the fork after the deploy script", code not in (None, "0x"), "no code there"):
        return
    owner = fork.call(TANK, "owner()(address)")
    check(f"owner() == Safe {SAFE}", owner.lower() == SAFE.lower(), owner)

    listed = _ADDRESS.findall(fork.call(TANK, "recipients()(address[])"))
    print(f"recipients before the batch: the tank on chain {chain_id} lists {len(listed)} EOA(s)" if on_chain else
          f"recipients before the batch: none, the tank is not on chain {chain_id} yet, so every EOA is NEW",
          flush=True)
    for line in recipient_changes(cfg, [(a, fork.uint(TANK, "amountOf(address)(uint256)", a)) for a in listed]):
        print(fork.redact("  " + line), flush=True)

    fork.set_balance(SAFE, fund + ETHER)
    nonce = fork.uint(SAFE, "nonce()(uint256)")
    safe_before, tank_before = fork.balance(SAFE), fork.balance(TANK)
    before = {r["eoa"]: fork.balance(r["eoa"]) for r in recipients}

    signers, gas, err = exec_through_safe(fork, txs)
    if not check(f"batch executed by Safe.execTransaction ({len(signers)} owners: {', '.join(signers)}"
                 + (f"; gas used {gas})" if gas else ")"), err is None, err):
        return

    listed = _ADDRESS.findall(fork.call(TANK, "recipients()(address[])"))
    problems = list_mismatches(listed, recipients)
    check(f"recipients() holds exactly the config's {len(recipients)} EOAs (in any order: a removal reorders "
          "the list)", not problems, "; ".join(problems))
    for r in recipients:
        amount = fork.uint(TANK, "amountOf(address)(uint256)", r["eoa"])
        check(f"amountOf({r['name']}) == {r['amount_wei']}", amount == int(r["amount_wei"]), amount)

    held = tank_before + fund
    share, rest = (held // len(recipients), held % len(recipients)) if cfg["distribute"] else (0, held)
    for r in recipients:
        got = fork.balance(r["eoa"]) - before[r["eoa"]]
        check(f"{r['name']} balance +{share} wei", got == share, got)
    tank_after = fork.balance(TANK)
    check(f"tank balance == {rest} wei", tank_after == rest, tank_after)
    check("Safe nonce +1", fork.uint(SAFE, "nonce()(uint256)") == nonce + 1)
    spent = safe_before - fork.balance(SAFE)
    check(f"Safe balance -{fund} wei (the funding, nothing else)", spent == fund, spent)

    if recipients:
        claimer = recipients[0]
        amount = int(claimer["amount_wei"])
        fork.set_balance(claimer["eoa"], 0)  # far below the ceiling: only the tank's balance can refuse
        # A claim within the last 24 h would answer ClaimTooSoon first: move the fork's clock past it.
        claimable_at = fork.uint(TANK, "claimableAt(address)(uint256)", claimer["eoa"])
        now = int(fork.rpc("eth_getBlockByNumber", "latest", False)["timestamp"], 16)
        if claimable_at > now:
            fork.rpc("evm_increaseTime", claimable_at - now)
            fork.rpc("evm_mine")
            print(f"NOTE {claimer['name']} claimed less than 24 h ago: the fork's clock is moved past its "
                  f"claimableAt {claimable_at} for the claim() check below", flush=True)
        # eth_call from the EOA: the contract's own answer, with no key and no gas needed.
        _, error = fork.try_rpc("eth_call", {"from": claimer["eoa"], "to": TANK, "input": calldata("claim()")},
                                 "latest")
        if tank_after == 0 or tank_after < amount // MIN_PARTIAL_DIVISOR:
            tank_empty = fork.run("cast", "sig", "TankEmpty()").stdout.strip()
            check(f"claim() by {claimer['name']} refused with TankEmpty (tank holds {tank_after} wei, "
                  f"below a tenth of {amount})", (error or {}).get("data") == tank_empty, error or "claim() succeeded")
        else:
            check(f"claim() by {claimer['name']} accepted (would pay {min(amount, tank_after)} wei)",
                  error is None, error)


def main() -> int:
    ap = argparse.ArgumentParser(description="Replays a GasTank batch through the real Safe on a fork.")
    ap.add_argument("--config", required=True, help="batch/config/<chain>.json")
    ap.add_argument("--batch", help="the Transaction Builder file to sign: checked against the config, then replayed")
    ap.add_argument("--deployed", action="store_true",
                    help="FAIL when the tank is not on the real chain yet; refuse the example's fictive EOAs")
    args = ap.parse_args()
    cfg = load_config(args.config)
    fake = placeholders(cfg)
    if args.deployed and fake:
        raise SystemExit(f"{args.config}: {', '.join(fake)} still hold the example's fictive EOAs (0x7e57, then "
                         "zeros): put the real keeper EOAs in the config, generate the batch again, then replay")
    fork = Fork(cfg["rpc_env"])
    failures, warnings = 0, []

    def check(name: str, ok: bool, detail="") -> bool:
        nonlocal failures
        failures += not ok
        line = ("PASS " if ok else "FAIL ") + name + ("" if ok or detail == "" else f"  [{detail}]")
        print(fork.redact(line), flush=True)
        return ok

    def warn(text: str, echo: bool = True) -> None:
        warnings.append(text)
        if echo:
            print(fork.redact("WARNING " + text), flush=True)

    txs = build(cfg)
    if args.batch:
        try:
            raw = Path(args.batch).read_bytes()
            batch = json.loads(raw)
        except (OSError, ValueError) as e:
            raise SystemExit(f"{args.batch}: {e}") from None
        print(f"batch file {args.batch} sha256 {hashlib.sha256(raw).hexdigest()}", flush=True)
        problems = batch_mismatches(cfg, batch)
        if not check(f"batch file is what {args.config} generates (chainId, Safe, every transaction)", not problems,
                     f"{len(problems)} difference(s), listed below"):
            for problem in problems:
                print("    " + fork.redact(problem))
            print(f"{failures} CHECK(S) FAILED: the file is not the replayed batch, do not sign it")
            return 1
        txs = batch["transactions"]  # the file's own transactions are the ones replayed

    if fake:
        warn(f"{', '.join(fake)}: the example's fictive EOAs (0x7e57...), never to be funded: do not sign this batch")
    try:
        fork.start()
        replay(fork, cfg, txs, check, warn, args.deployed)
    finally:
        fork.stop()
    print("ALL CHECKS PASSED" if failures == 0 else f"{failures} CHECK(S) FAILED")
    for text in warnings:  # repeated after the verdict, where the eye lands
        print(fork.redact("WARNING " + text))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
