# Mainnet smoke-test runbook — Walendria Protocol on Gnosis Chain

Paste-run scenarios for verifying live mainnet contract behavior with real xDAI.

**Origin**: every command below was first run against a `--fork-url gnosis` anvil clone of Gnosis
mainnet on 2026-07-17 (fork block 47244896), with all 6 scenarios passing end-to-end. The fork
executes the real deployed bytecode, so the same commands run against `--rpc-url gnosis` with a
signing account should reproduce the same behavior — the only differences are (a) real xDAI moves
and (b) `evm_increaseTime` / `anvil_impersonateAccount` don't exist on mainnet, so the time-wait
scenarios need real elapsed time or must be skipped.

**Do not run without a funded signing wallet.** Every `cast send` charges real xDAI. Scenarios
1-2 combined cost roughly 4.5 xDAI in locked IB (returned on close) plus ~1.5 xDAI in real value
transfer between seller and buyer (returned on completion). Gas is trivially cheap on Gnosis
mainnet (~0.001 gwei) — the whole runbook consumes well under 1 US cent in gas.

## Environment

```bash
export RPC=https://rpc.gnosischain.com
export ACC=walendria-chiado   # your keystore account name
export W1=0xC8bfedCC142b0C915CA83E214a71d6607C89d310   # seller wallet (also protocol deployer)
export W2=<your buyer wallet>                          # a second wallet you control
export IB=0xba8a0E4C8F0E46de6E82231d2243b9E8DF66143a
export LM=0xAF070b902aB31262b35E0Dc24809aE80B70918b9
export SET=0x301690a2Dd9A95ca7EBE4CC457Cd0024201c5AB0
export DM=0x75ba345B89A9653C98E38958d84359A6cE9233b6
export SM=0xa68a83944BDD92Fc066c32b69f07E1519b728857
export SC=0xd07B2bEFB8590A861f8D6c1eF8AFb39c89197509
export DP=0xa560e000E53957ec7bcD6f6EbD2c7c66657B7EaE

# Standard low-gas flags used for every send below — see CLAUDE.md § "Deploying to Chiado"
GAS="--gas-price 1000000 --priority-gas-price 1000"
# Signer flags. Every send prompts once for keystore password unless cached.
SIG="--account $ACC"
```

## Scale before running

The fork used price = 1 xDAI per slot for readability. On live mainnet with a low-balance test
wallet (e.g. 0.001 xDAI), divide every value by 1000 (price = 0.001 xDAI, deposit = 0.0015 xDAI,
etc). The protocol has no minimum transaction size, so pricing at any positive integer wei works.
`MAX_TRANSACTION_VALUE = 100 xDAI` is the immutable cap.

---

## Scenario 1 — Happy path (deposit → create → pay → confirm → close → withdraw)

```bash
# Seller deposits 1.5 xDAI IB
cast send $IB "deposit()" --value 1500000000000000000 --from $W1 $SIG --rpc-url $RPC $GAS

# Seller creates listing (price 1 xDAI, 1 slot, 72h window)
cast send $LM "createListing(uint256,uint256,uint256,string,string)" 1000000000000000000 1 259200 "smoke-1" "happy-path" --from $W1 $SIG --rpc-url $RPC $GAS
# → grab listing id from the ListingCreated event; check with:
# cast logs --from-block <block> --address $LM 'ListingCreated(uint256,address,uint256,uint256,uint256,uint256)' --rpc-url $RPC
LID=<listing id>

# Buyer pays for slot 0
cast send $SET "pay(uint256,uint256)" $LID 0 --value 1000000000000000000 --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS

# Seller wallet should be UP by 0.995 xDAI (1 xDAI - 0.5% fee)
# DevPool should be UP by 0.005 xDAI

# Buyer confirms completion
cast send $LM "confirmCompletion(uint256,uint256)" $LID 0 --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS

# Seller closes listing (unlocks per-slot IB back to Free)
cast send $LM "closeListing(uint256)" $LID --from $W1 $SIG --rpc-url $RPC $GAS

# Seller withdraws the 1.5 xDAI back
cast send $IB "withdraw(uint256)" 1500000000000000000 --from $W1 $SIG --rpc-url $RPC $GAS
```

**Fork-verified outcomes**:
- W1 net gain: +0.995 xDAI (before gas)
- W2 net cost: -1.000 xDAI (before gas)
- DevPool: +0.005 xDAI

---

## Scenario 2 — Extend completion window

After a slot is paid, the seller can extend (never shrink below 72h) the window if delivery
needs more time.

```bash
# Assumes L=<id> exists with slot 0 paid, original window 72h (259200s)
# Extend to 168h (604800s = 7 days)
cast send $LM "extendWindow(uint256,uint256,uint256)" $L 0 604800 --from $W1 $SIG --rpc-url $RPC $GAS

# Verify the deadline shifted:
cast call $LM "slots(uint256,uint256)(uint8,uint256,address,uint256)" $L 0 --rpc-url $RPC
cast call $LM "slotWindowOverride(uint256,uint256)(uint256)" $L 0 --rpc-url $RPC
```

**Attempting to shrink below MIN_COMPLETION_WINDOW reverts** with
`CompletionWindowTooShort(requested, minimum)`. Verified on fork.

---

## Scenario 3 — Reduce empty slots

Free IB tied to slots that never got paid.

```bash
# Assumes L=<id> is a 3-slot listing with 3 empty slots
cast send $LM "reduceSlots(uint256,uint256)" $L 2 --from $W1 $SIG --rpc-url $RPC $GAS
# → totalSlots and emptySlots both drop by 2; W1 IB `locked` decreases by 2 * perSlotLocked
```

---

## Scenario 4 — MutualClose Innocent

Fast dispute resolution when both parties agree.

```bash
# Setup: L=<id>, slot 0 already paid by W2
# W2 opens dispute by funding Guilty side at exactly 0.5 * P
cast send $DM "fundGuiltySide(uint256,uint256)" $L 0 --value 500000000000000000 --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS

# Compute market id (cycle=1 for first dispute on this slot)
MID=$(cast call $DM "marketIdOf(uint256,uint256,uint256)(uint256)" $L 0 1 --rpc-url $RPC | awk '{print $1}')

# Both parties vote Innocent (verdict=1)
cast send $DM "mutualClose(uint256,uint256,uint8)" $L 0 1 --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS
cast send $DM "mutualClose(uint256,uint256,uint8)" $L 0 1 --from $W1 $SIG --rpc-url $RPC $GAS
# → market resolves; SpectralMarket.markets(MID).resolved = true, winningSide = 1 (Innocent)

# Seller (winner) finalizes + redeems
cast send $DM "finalizeDispute(uint256,uint256)" $L 0 --from $W1 $SIG --rpc-url $RPC $GAS
cast send $SM "redeem(uint256)" $MID --from $W1 $SIG --rpc-url $RPC $GAS
```

**Fork-verified**: seller receives full 1 xDAI redeem (their 0.5P injection + buyer's forfeited
0.5P), the frozen 1P bond unlocks back to Free IB.

---

## Scenario 5 — Poke resolves Guilty (adversarial buyer wins after 1h)

Real-money version of the scenario that fork tested with `evm_increaseTime`. On mainnet the wait
is real wall-clock time (≥ 1 hour after the last checkpoint that put the price above 93%).

```bash
# Setup: dispute opened as in Scenario 4
MID=$(cast call $DM "marketIdOf(uint256,uint256,uint256)(uint256)" $L 0 1 --rpc-url $RPC | awk '{print $1}')

# W2 buys ~10x P more Guilty shares to push price above 93%
cast send $SM "buy(uint256,uint8,uint256)" $MID 0 10000000000000000000 --value 20000000000000000000 --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS

# Check price crossed threshold
cast call $SM "currentPrice(uint256)(uint256,uint256)" $MID --rpc-url $RPC
# → first value (pGuilty) should be > 0.93e18

# Try to poke NOW — will revert ConditionsNotYetMet
cast send $SC "pokeSettlement(uint256)" $MID --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS

# WAIT 1 HOUR of wall-clock time (fork used evm_increaseTime; mainnet has no shortcut)

# After 1h, poke succeeds
cast send $SC "pokeSettlement(uint256)" $MID --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS

cast send $DM "finalizeDispute(uint256,uint256)" $L 0 --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS
cast send $SM "redeem(uint256)" $MID --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS
```

**Fork-verified capped-payout behavior**: W2 held 11 xDAI in Guilty shares, but pool only had 10.3
xDAI — redeem paid the pool cap (10.3), not the full share obligation. This is the whitepaper's
"bounded loss" property.

---

## Scenario 6 — Reclaim Guilty funding (below-threshold refund)

If a buyer opens a dispute but the funding never reaches 0.5×P (so no market ever opens), the
funder can reclaim after the slot cycle completes.

```bash
# Setup: L=<id> with slot 0 paid
CYC=$(cast call $LM "slots(uint256,uint256)(uint8,uint256,address,uint256)" $L 0 --rpc-url $RPC | sed -n '4p' | awk '{print $1}')

# W2 funds only 0.3*P (below threshold — market does NOT open)
cast send $DM "fundGuiltySide(uint256,uint256)" $L 0 --value 300000000000000000 --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS

# WAIT until slot completion window expires (default 72h). Then either:
#   a) buyer confirmCompletion (skips wait), or
#   b) anyone finalizeExpiredSlot

cast send $LM "finalizeExpiredSlot(uint256,uint256)" $L 0 --from $W1 $SIG --rpc-url $RPC $GAS

# Now check reclaimable amount from the completed cycle
cast call $DM "guiltyFundingReclaimable(uint256,uint256,uint256,address)(uint256)" $L 0 $CYC $W2 --rpc-url $RPC

# Reclaim
cast send $DM "reclaimGuiltyFunding(uint256,uint256,uint256)" $L 0 $CYC --from $W2 --account $ACC-buyer --rpc-url $RPC $GAS
```

**Fork-verified**: W2 recovers full 0.3 xDAI funding after cycle completion.

---

## Deployed constants (fork-verified against source)

| Constant | Value | Meaning |
|---|---|---|
| `ListingManager.maxTransactionValue()` | 100 xDAI | Immutable hardcap per transaction |
| `ListingManager.MIN_COMPLETION_WINDOW()` | 72 hours | Minimum window seller can offer |
| `SettlementConditions.CUMULATIVE_THRESHOLD()` | 0.93e18 | 93% price dominance for resolution |
| `SettlementConditions.CUMULATIVE_DURATION()` | 3600 seconds | 1 hour cumulative required |

## Post-mainnet-smoke-test cleanup

Always call `closeListing(LID)` and `withdraw(amount)` from IB to return capital to your wallet
after each test scenario, so free IB doesn't pile up locked. Uncleaned test listings will sit
publicly on the mainnet contract forever.
