# Gas Tank

Open reference material for the σ-Labs **Gas Tank**, the contract that supplies the keepers' EOAs
with each chain's native token for gas.

Each keeper strategy signs its transactions with its own EOA, so no two strategies share a nonce
sequence. Every one of those EOAs needs gas on every chain it runs on. The tank gives the team a
single balance to fund per chain instead of one per EOA. This repository publishes the contract, its
deterministic deployment, and the tooling that generates the Safe batch that configures and funds it,
then replays that batch on a fork before anyone signs it. To see how it works and how to verify it,
read [`docs/gas-tank.md`](./docs/gas-tank.md).

- **Address, the same on every chain:** `0xe9A731d24c524B9efb032786F3c1C3e53D36f712`
- **Owner:** the σ-Labs ops Safe
  [`0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1`](https://etherscan.io/address/0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1).
  The owner is immutable and set in the constructor.

## How it hands out gas

- **`distribute()`**: the owner Safe sends the tank's **whole balance**, split equally between the
  listed EOAs. The division remainder, which is fewer wei than there are EOAs, stays in the tank.
  `distribute()` ignores the 24 h delay and the balance ceiling, and does not change any EOA's last
  claim. It is all or nothing: if one transfer fails, nobody is paid.
- **`claim()`**: a listed EOA takes its own **fixed amount** for itself, at most once every **24 h**
  (its first claim is immediate), and only while its own balance is below **twice** that amount.
  When the tank holds less than the amount, the EOA receives what is left, as long as that is at
  least **one tenth** of the amount, and its 24 h delay starts. When the tank holds less than one
  tenth, or is empty, the claim is refused and the delay does not start.

The two modes combine. Funding the tank and then calling `distribute()` spreads everything. Funding
it without distributing leaves a reserve that the keepers who burn the most gas draw on with
`claim()`.

Only the owner Safe can list EOAs and set their amounts (`setRecipient`, `removeRecipient`), at most
**32** EOAs per tank. It can also withdraw any part of the balance, at any time (`withdraw`). Anyone
can fund the tank with a plain transfer. There is no proxy, no upgrade path and no ownership
transfer. To change a rule, the Safe withdraws the funds and a new contract is deployed.

## Address and chains

The tank's address is known before any deployment. It is the CREATE2 address of GasTank's init code
(its creation code followed by the ABI-encoded owner), deployed through the deterministic deployment
factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` with the salt
`keccak256("sigma-labs.gas-tank.v1")`. Any EOA can broadcast the deployment, and doing so gives it no
rights. The address changes if anything that feeds the init code changes: `src/GasTank.sol` (even a
comment), the compiler settings in `foundry.toml`, or the remappings. If that happens,
`test_predictedAddress_isPinned` fails on purpose and `script/Deploy.s.sol` refuses to deploy.

| Chain | Native token | Chain ID | RPC variable | Status |
|---|---|---|---|---|
| Ethereum | ETH | 1 | `ETH_RPC_URL` | not deployed |
| Optimism | ETH | 10 | `OP_RPC_URL` | not deployed |
| Base | ETH | 8453 | `BASE_RPC_URL` | not deployed |
| Arbitrum | ETH | 42161 | `ARB_RPC_URL` | not deployed |
| Polygon | POL | 137 | `POLYGON_RPC_URL` | not deployed |
| Monad | MON | 143 | `MONAD_RPC_URL` | not deployed |
| HyperEVM | HYPE | 999 | `HYPEREVM_RPC_URL` | not deployed |

## Layout

| Path | What |
|------|------|
| [`src/GasTank.sol`](./src/GasTank.sol) | The contract. |
| [`script/Deploy.s.sol`](./script/Deploy.s.sol) | Deterministic CREATE2 deployment. It refuses any address other than the pinned one, and any chain where the owner Safe has no code. |
| [`test/`](./test) | Foundry tests: every rule and its errors, fuzzing, reentrancy, the deployment, and a fork test on the seven chains. |
| [`batch/gen_batch.py`](./batch/gen_batch.py) | Generates the Safe Transaction Builder JSON from a chain config: `setRecipient` per EOA, then the funding, then `distribute()`. |
| [`batch/fork_test.py`](./batch/fork_test.py) | Replays that batch through the real Safe on an `anvil` fork and checks every effect before anyone signs. |
| [`batch/config/example.json`](./batch/config/example.json) | An example config with fictive EOAs (`0x7e57…`). Its batch is named "EXAMPLE, DO NOT SIGN". |
| [`batch/tests/`](./batch/tests) | `pytest` tests of the generator, its config validation, and the replay's comparison of the tank's list with the config. |
| [`docs/gas-tank.md`](./docs/gas-tank.md) | How it works: rules, security model, trade-offs, address verification, batch replay. |
| [`.env.example`](./.env.example) | Public RPC endpoints for the seven chains. |

## Running the tests

You need Foundry (`forge`, `cast`, `anvil`) and Python 3 with `pytest`. Run every command from the
repository root.

```bash
git submodule update --init --recursive
cp .env.example .env            # public RPC endpoints; .env is never committed
set -a; source .env; set +a     # in every new shell
```

Contract and deployment tests:

```bash
forge test -vv
```

- **With the seven RPC variables set:** `43 tests passed, 0 failed, 0 skipped`, followed by seven
  `… ran: chain id …` lines. On a fork of each chain, the fork test checks that the factory and the
  Safe exist, then deploys the tank and checks that it lands at the address above, owned by the Safe.
- **With only some of the variables set:** the fork test passes, but it checked only those chains.
- **With none set:** `42 tests passed, 0 failed, 1 skipped`. The skipped test is the fork test, which
  checked nothing.

Batch generator and replay tests (expected: `42 passed`):

```bash
python3 -m pytest batch/tests -q
```

Fork replay of the example batch on Ethereum, through the real Safe (this needs `ETH_RPC_URL`):

```bash
python3 batch/gen_batch.py --config batch/config/example.json --out example-batch.json
python3 batch/fork_test.py --config batch/config/example.json --batch example-batch.json
```

Expected result:

- Every check prints `PASS`, and the run ends with `ALL CHECKS PASSED`.
- Each of the six example EOAs receives 28879366047419450 wei and 1 wei stays in the tank.
- The final `claim()` check is refused with `TankEmpty`, because 1 wei is less than a tenth of the
  amount.

The `WARNING` lines say why this batch must never be signed. Its EOAs are fictive, and the tank exists
only on the fork. A third warning appears when the Safe does not hold the funding amount on Ethereum.

## License

[Apache-2.0](./LICENSE) © σ-Labs
