# How the Gas Tank works

This document explains [`src/GasTank.sol`](../src/GasTank.sol) for a reader who wants to verify it.
The code is the source of truth, and every rule below is a line of it. The tests in
[`test/`](../test) check each rule, and at least one test triggers each error the contract defines.

## The model

Each keeper strategy signs its transactions with its own EOA, and every one of those EOAs pays gas in
the chain's native token (ETH, POL, MON or HYPE). On each chain, one `GasTank` holds that token and
hands it to the EOAs it lists, so there is a single balance to fund per chain. The tank is never in
the path of a keeper's own transactions. An EOA that still has gas can act whether the tank is full,
empty or blocked.

The tank pays out in two ways:

- **`distribute()`** is a push from the owner Safe. The tank's whole balance is split equally between
  the listed EOAs.
- **`claim()`** is a pull by a listed EOA. The EOA takes its own fixed amount, at most once per 24 h,
  and only while its own balance is below twice that amount.

The two modes combine. Funding the tank and then calling `distribute()` spreads everything. Funding
it without distributing leaves a reserve that the EOAs which spend the most draw on with `claim()`.

The contract handles the native token only. It has no proxy, no upgrade path and no ownership
transfer. The owner is set once, in the constructor.

## Constants

| Name | Value | Meaning |
|---|---|---|
| `CLAIM_PERIOD` | `1 days` (86 400 s) | The minimum time between two claims by the same EOA. It is measured with `block.timestamp`, never in blocks. |
| `CEILING_MULTIPLE` | `2` | `claim()` is refused once the EOA's own balance reaches twice its amount. |
| `MIN_PARTIAL_DIVISOR` | `10` | The smallest partial payment is `amount / 10`. |
| `MAX_RECIPIENTS` | `32` | The list never holds more than 32 EOAs. |
| `owner` | immutable | The ops Safe `0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1`. It is the constructor's argument, and the constructor reverts with `InvalidRecipient` on the zero address. |

For each listed EOA, the tank stores its claim `amount`, which is 0 when the EOA is not listed, and
`lastClaim`, the timestamp of its last claim, which is 0 when it has never claimed. It also stores the
EOA's position in the list.

## Rules

| Function | Who | Conditions (otherwise it reverts with) | Effect |
|---|---|---|---|
| `receive()` | anyone | none | Credits the tank and emits `Funded(from, amount)`. |
| `setRecipient(eoa, amount)` | owner | `eoa` is not the zero address or the tank itself (`InvalidRecipient`). `amount > 0` (`InvalidAmount`). A new EOA needs fewer than 32 listed (`TooManyRecipients`). | Lists `eoa` with `amount`, or changes the amount of an EOA already listed while keeping its `lastClaim`. Emits `RecipientSet(eoa, amount)`. |
| `removeRecipient(eoa)` | owner | `eoa` is listed (`NotRecipient`). | Unlists `eoa` and erases its amount and `lastClaim`. The last entry of the list moves into the freed slot. Emits `RecipientRemoved(eoa)`. |
| `distribute()` | owner | At least one EOA is listed, and `balance / count > 0` (`NothingToDistribute`). | Sends `share = balance / count` (rounded down) to every listed EOA. The remainder, below `count` wei, stays. Ignores the ceiling and the 24 h delay, and leaves every `lastClaim` untouched. Emits `Distributed(share, count)`. All or nothing: one failed transfer reverts everything (`TransferFailed`). |
| `withdraw(to, amount)` | owner | `to` is not the zero address (`InvalidRecipient`). The transfer succeeds: `amount` is at most the balance and `to` accepts it (`TransferFailed`). | Sends `amount` to `to`. Emits `Withdrawn(to, amount)`. |
| `claim()` | a listed EOA, for itself | The caller is listed (`NotRecipient`). Its first claim, or at least 24 h since its `lastClaim` (`ClaimTooSoon(claimableAt)`). Its own balance is below `2 × amount` (`BalanceAboveCeiling`). The tank holds more than 0 and at least `amount / 10` (`TankEmpty`). The payment is accepted (`TransferFailed`). | Records `lastClaim = block.timestamp`, then sends `min(amount, tank balance)` to the caller. Emits `Claimed(eoa, paid)`. |

Any caller other than the owner gets `NotOwner` from the four owner functions. Nobody can claim on
behalf of another EOA, because `claim()` always pays `msg.sender`.

`claim()` checks its conditions in this order: `NotRecipient`, `ClaimTooSoon`, `BalanceAboveCeiling`,
`TankEmpty`. It reverts at the first one that fails. A refused claim changes nothing, so the 24 h
delay does not start. A claim exactly 24 h after the last one is accepted. `amount / 10` is an integer
division. For an amount below 10 wei, the minimum is 0, and only an empty tank refuses the claim. For
an amount of 0.05 ETH, the ceiling is 0.1 ETH and the smallest partial payment is 0.005 ETH.

`distribute()` reference example, from `test_distribute_referenceExample` and from the example batch
replayed on a fork: six EOAs share 173276196284516701 wei (0.173276196284516701 ETH). Each receives
28879366047419450 wei, and 1 wei stays in the tank.

The read functions:

- `recipients()` returns the list. Its order changes when an EOA is removed.
- `amountOf(eoa)` returns the EOA's amount, or 0 when it is not listed.
- `lastClaimOf(eoa)` returns the timestamp of its last claim, or 0 when it has never claimed.
- `claimableAt(eoa)` returns `lastClaim + 1 days`, or 0 when it has never claimed.

Every error has its own name, so a keeper can tell why it was refused. These are the first four bytes
of the revert data, from `cast sig`:

| Error | Selector | Error | Selector |
|---|---|---|---|
| `NotOwner()` | `0x30cd7471` | `NothingToDistribute()` | `0x01663f24` |
| `NotRecipient()` | `0x586d3357` | `ClaimTooSoon(uint256)` | `0x854f3dd0` |
| `InvalidRecipient()` | `0x9c8d2cd2` | `BalanceAboveCeiling()` | `0xb7234d17` |
| `InvalidAmount()` | `0x2c5211c6` | `TankEmpty()` | `0xf0c2d88e` |
| `TooManyRecipients()` | `0x5531b495` | `TransferFailed(address)` | `0x39f1c8d9` |

## Security model

| Who | Can | Cannot |
|---|---|---|
| Anyone | Fund the tank. Broadcast its deployment, which gives the same code with the same owner at the same address. | Anything else. Every other change of state is owner-only, and `claim()` pays only a listed caller, to itself. |
| The deployer | The same as anyone. The owner is a constructor argument bound into the address, not `msg.sender`. | Anything after the deployment. |
| A compromised keeper key | Claim its own amount: once immediately, then at most once per 24 h. The ceiling looks only at the EOA's own balance, which the attacker can move elsewhere. The real bound is therefore **one amount per 24 h until the Safe removes the EOA**. If the key attaches code to its EOA (EIP-7702), it can also refuse payments, which blocks `distribute()` for every EOA until the Safe removes it. | Change its amount, claim for another EOA, touch the list, withdraw, or block another EOA's `claim()`. |
| The owner Safe | Everything: the list, the amounts, `distribute()`, and `withdraw()` of any part of the balance to any address. | Change the owner or the code. No function does either. |

The owner Safe is trusted by design. Its owners and threshold are public, and a Safe's owners are set
chain by chain, so read them on the chain you are checking:

```bash
cast call 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1 "getOwners()(address[])" --rpc-url "$ETH_RPC_URL"
cast call 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1 "getThreshold()(uint256)" --rpc-url "$ETH_RPC_URL"
```

**Reentrancy.** There is no reentrancy lock, because state is written before any transfer:

- `claim()` records `lastClaim` before it pays, so a `claim()` re-entered from the payment fails with
  `ClaimTooSoon` (`test_reentrancy_claimDuringClaim_paysOnce`).
- `distribute()` and `withdraw()` write no state.
- A recipient that re-enters `claim()` from a `distribute()` payment makes an ordinary claim, bound by
  the same rules. If that claim takes funds a later share needs, the later transfer fails and the
  whole `distribute()` reverts (`test_reentrancy_claimDuringDistribute_isBounded`).

## Known trade-offs

- **The equal split ignores consumption.** `distribute()` gives every EOA the same share, so the EOA
  that sends the most transactions runs dry first. A reserve left in the tank and `claim()` cover that
  case.
- **`distribute()` is all or nothing.** Only an address with code can refuse a payment: a contract, or
  an EOA with EIP-7702 code. If one listed address refuses, the whole call reverts with
  `TransferFailed(recipient)`, and `distribute()` stays blocked until the Safe removes that address.
  The alternative, skipping the recipient and going on, would leave an EOA without gas and nobody
  would notice. The fork replay warns when a listed EOA has code.
- **A partial payment starts the 24 h delay.** An EOA paid only what was left in the tank cannot claim
  again for 24 h. This happens without any attacker. Suppose two keepers both see their full amount,
  in a tank that cannot pay both, and both claim: the second one gets the remainder, provided it
  reaches a tenth of its amount. The Safe can top it up earlier by funding the tank and calling
  `distribute()`, which ignores the delay.
- **Residual dust top-up griefing.** The minimum partial payment stops a 1 wei top-up from costing a
  keeper its 24 h, but it cannot stop a larger one. When the tank holds less than a tenth of a keeper's
  amount, anyone can top it up to exactly one tenth just before that keeper claims. The keeper then
  receives a tenth and waits 24 h. The griefer pays for the top-up, which is at most a tenth of the
  amount (0.005 ETH for an amount of 0.05 ETH), and that money ends up with the keeper. Keepers reduce
  the exposure by claiming only when the tank holds their full amount. That rule belongs to the keeper,
  and the contract does not enforce it.
- **Removing an EOA erases its history.** If the EOA is listed again, it can claim at once. Changing an
  amount keeps the last claim and applies the new ceiling.
- **Native token only.** Nothing in the contract moves ERC-20 tokens, so tokens sent to the tank cannot
  be recovered. The contract has no `fallback`, so a transfer that carries calldata reverts. Fund the
  tank with a plain transfer.
- **Immutable.** To change a rule, the Safe withdraws the funds and a new contract is deployed, at a new
  address.

## The same address on every chain

```
address = last 20 bytes of keccak256(0xff ‖ factory ‖ salt ‖ keccak256(init code))
```

| Input | Value |
|---|---|
| factory | `0x4e59b44847b379578588920cA78FbF26c0B4956C`, the deterministic deployment proxy. It takes `salt ‖ init code` as calldata. |
| salt | `keccak256("sigma-labs.gas-tank.v1")` = `0xa3327ad65b27473db735f4310260d49a8e61b8b0a58cf5df0fae6c16ce963b7a` |
| init code | GasTank's creation code, followed by `abi.encode(0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1)` |
| result | **`0xe9A731d24c524B9efb032786F3c1C3e53D36f712`** |

The creation code ends with a hash of the compiler's metadata. That hash covers the source, comments
and licence line included, the compiler version, the compiler settings and the remappings. The
settings live in [`foundry.toml`](../foundry.toml): `solc 0.8.26`, `evm_version = "paris"`, optimizer
on with 200 runs. Targeting `paris` keeps `PUSH0` out of the bytecode, so one bytecode is accepted on
all seven chains, and the fork test deploys it on each. Any change to one of these inputs moves the
address. Three places pin it: `PINNED` in `test/Deploy.t.sol`, `EXPECTED` in `script/Deploy.s.sol`
and `TANK` in `batch/gen_batch.py`. If the build drifts, `test_predictedAddress_isPinned` fails on
purpose. The owner is part of the init code, so it is part of the address: whoever broadcasts the
deployment, the contract at this address has this owner.

`script/Deploy.s.sol` can be broadcast by any EOA. It behaves as follows:

- **Before any call**, it refuses a build whose address is not `EXPECTED` (`UnexpectedAddress`). It also
  refuses a chain where the owner Safe has no code (`OwnerHasNoCode`).
- **When the tank is already deployed**, it does not call the factory. It only verifies the tank.
- **After calling the factory**, it reverts unless code sits at the address (`NotDeployed`) and
  `owner()` is the Safe (`WrongOwner`). The `NotDeployed` check also catches a chain without the
  factory, because a call to an address without code succeeds.

Funds sent to the address before the deployment are not lost. The tank holds them as soon as it is
deployed there.

### Check it yourself

Recompute the address from the source, from the repository root:

```bash
SALT=$(cast keccak "sigma-labs.gas-tank.v1")
INIT=$(forge inspect src/GasTank.sol:GasTank bytecode)$(cast abi-encode "constructor(address)" 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1 | cut -c3-)
cast create2 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C --salt "$SALT" --init-code "$INIT"
# 0xe9A731d24c524B9efb032786F3c1C3e53D36f712
```

`forge test --match-test test_predictedAddress_isPinned` runs the same check in Solidity.

Check a deployment on a chain. Use that chain's RPC variable:

```bash
cast code 0xe9A731d24c524B9efb032786F3c1C3e53D36f712 --rpc-url "$ETH_RPC_URL"
cast call 0xe9A731d24c524B9efb032786F3c1C3e53D36f712 "owner()(address)" --rpc-url "$ETH_RPC_URL"
```

Once the tank is deployed, `cast code` prints a long hex string that starts with `0x608060405260`.
Until then, it prints `0x` alone. `owner()` must print `0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1`.
The address commits to the hash of the init code. Code at this address can therefore only come from
this exact init code, which means this source, these settings and this owner, deployed through this
factory with this salt.

## Safe batches: generate, replay on a fork, then sign

The owner Safe configures and funds a tank in one batch:

1. `setRecipient` for each EOA,
2. then, when `fund_wei` is above 0, a plain transfer of the funding to the tank,
3. then, if asked, `distribute()`.

The batch comes from a config file, one per chain:

| Field | Content |
|---|---|
| `chain_id` | The chain ID, for example `1` for Ethereum. |
| `rpc_env` | The **name** of the environment variable that holds the RPC URL, for example `"ETH_RPC_URL"`. Never the URL itself. |
| `recipients` | The full list of the tank's EOAs on that chain. Each entry has a `name`, an `eoa` in EIP-55 mixed case, and an `amount_wei` written as a string. |
| `fund_wei` | What the Safe sends to the tank in this batch, in wei, as a string. Use `"0"` for nothing. |
| `distribute` | `true` to end the batch with `distribute()`. |

```bash
python3 batch/gen_batch.py --config batch/config/<chain>.json --out <chain>-batch.json
python3 batch/fork_test.py --config batch/config/<chain>.json --batch <chain>-batch.json --deployed
```

The generator reads nothing from any chain. It writes a Safe Transaction Builder file and prints every
amount in wei and in native units. It refuses a config, with a message that names the problem, in
these cases:

- a key is unknown or missing;
- `chain_id` is not a positive integer, `rpc_env` is not the name of an environment variable, or
  `distribute` is not `true` or `false`;
- an EOA is listed twice;
- there are more than 32 EOAs;
- an amount is 0 or less, or reaches 2^255 wei, which the tank could not double for its ceiling;
- `fund_wei` is negative;
- an EOA is the Safe, the tank or the zero address;
- an address fails its EIP-55 checksum, or is written in a single case, so its checksum cannot catch a
  typo;
- `distribute` is `true` with no EOA;
- an amount is not written as a string.

The example config's EOAs (`0x7e57…`) are fictive. Their batch is named "EXAMPLE, DO NOT SIGN".

The replay checks the batch on an `anvil` fork of the real chain before anyone signs. In order, it:

1. Prints the batch file's sha256 and checks that the file is exactly what the config generates: the
   chain ID, the Safe, and every transaction's target, value and data. Any difference is a `FAIL`,
   and the replay stops.
2. Forks the latest block of the chain, checks that the endpoint serves the config's chain, and reads
   the real state before changing anything:
   - Is the tank deployed? With `--deployed`, its absence is a `FAIL`. With `--deployed`, a config that
     still holds the example's fictive EOAs is also refused before the replay starts.
   - Does the Safe hold the funding? If not, it prints a `WARNING`.
   - Does a listed EOA have code? If so, it prints a `WARNING`.
3. Runs `script/Deploy.s.sol` on the fork, which deploys the tank or only verifies it. Then it checks
   the code at the address and `owner()`.
4. Prints what the batch changes in the tank's list, compared with the real chain: `NEW`,
   `AMOUNT old -> new` and `unchanged` for each EOA in the config, and `NOT IN CONFIG` for an EOA listed
   on chain but missing from the config.
5. Gives the Safe the funding plus 1 native token on the fork. Then it prints the `safeTxHash` and the
   Safe nonce it was computed for.
6. Executes the file's own transactions through the Safe's real `execTransaction`, as the Safe app
   does: one delegatecall to MultiSendCallOnly 1.4.1 (`0x9641d764fc13c8B624c04430C7356C1C7C8102e2`).
   The batch is signed by as many Safe owners as the threshold requires, impersonated on the fork, so
   no key is used. It prints the gas used.
7. Checks every effect:
   - the list holds exactly the config's EOAs, in any order;
   - every amount;
   - what each EOA received;
   - what is left in the tank;
   - the Safe's nonce went up by 1;
   - the Safe paid exactly the funding and nothing else;
   - the answer to a `claim()` by the first EOA, run as an `eth_call`.

It prints one `PASS` or `FAIL` line per check, then a verdict: `ALL CHECKS PASSED`, or the number of
failed checks. It repeats any `WARNING` after that verdict. A single `FAIL` means the batch must not be signed. The RPC URL is never printed.
`anvil` receives it on its command line, so it shows in the local process list while the replay runs.
A `FAIL` whose detail contains `Fork Error` comes from the RPC endpoint refusing a request, not from
the batch. Replay with another endpoint until every check passes.

Before signing, each signer runs the replay on their own machine and then checks two things:

- **The file.** `shasum -a 256 <chain>-batch.json` must equal the replay's `sha256` line. Do not
  generate the file again after the replay: each generation stamps its creation time, which changes
  the hash.
- **The transaction.** The nonce and `safeTxHash` the Safe app shows must equal the replay's
  `safeTxHash … for Safe nonce …` line. The same nonce and the same hash prove that the transaction
  is the one replayed. A different nonce means another Safe transaction is queued first: execute or
  reject that one, then replay again. One exception: for a batch of a single transaction, the Safe
  app may call the tank directly instead of going through MultiSend, so the hash differs. Decode that
  transaction's data with `cast calldata-decode` instead.

The example batch replayed on Ethereum (without `--deployed`, since the tank is not deployed there
and the example's EOAs are fictive), trimmed:

```
PASS batch file is what batch/config/example.json generates (chainId, Safe, every transaction)
WARNING sigmausd, leverage, strategy-3, strategy-4, strategy-5, strategy-6: the example's fictive EOAs (0x7e57...), never to be funded: do not sign this batch
fork of chain 1 at block <block>, batch of 8 transaction(s)
WARNING tank NOT on chain 1: deployed on this fork only, do not sign this batch on the real chain
PASS deploy script ran (forge script script/Deploy.s.sol --broadcast)
PASS tank at 0xe9A731d24c524B9efb032786F3c1C3e53D36f712 on the fork after the deploy script
PASS owner() == Safe 0xEd93F0ED8F3cF989806c1A7AFb223870D83bEbc1
  NEW       sigmausd 0x7e57000000000000000000000000000000000001 50000000000000000 wei (0.05 ETH)
…
  changes: 6 NEW, 0 AMOUNT, 0 unchanged, 0 NOT IN CONFIG
safeTxHash 0x<64 hex digits> for Safe nonce <nonce> (the Safe's nonce on the chain at replay time): …
PASS batch executed by Safe.execTransaction (2 owners: …; gas used <gas>)
PASS recipients() holds exactly the config's 6 EOAs (in any order: a removal reorders the list)
…
PASS sigmausd balance +28879366047419450 wei
…
PASS tank balance == 1 wei
PASS Safe nonce +1
PASS Safe balance -173276196284516701 wei (the funding, nothing else)
PASS claim() by sigmausd refused with TankEmpty (tank holds 1 wei, below a tenth of 50000000000000000)
ALL CHECKS PASSED
```
