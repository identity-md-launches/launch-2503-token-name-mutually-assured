# Mutually Assured Destruction (MAD)

## Website continuation

The complete wallet-connected website is in `web/`; its production static export is in repo-root `dist/`. It includes Freeze, Trade, NFT rewards, Activity, How it works and Manage screens. It uses the existing Ethereum deployment and its FWA pair.

### Install, rebuild and preview

From the repository root, with Node 22 or newer:

```sh
npm --prefix web ci
npm --prefix web run typecheck
npm --prefix web run build
npm --prefix web run preview
```

The preview command serves the export locally, normally on port 4173. For source development, use `npm --prefix web run dev`. The static host serves the committed `dist/`; no backend or hosting action is required from this project. Vite uses `base: './'`, local assets and hash navigation, so the export supports a gateway subpath without server rewrites.

`dist/imd-deployment.json` is copied from `web/public/imd-deployment.json` at build time. The browser loads addresses, the exact network block, wallet chain parameters and the verified pool key from that file. Source-derived ABIs are under `docs/abi/` and `web/src/abi/`. No wallet secret or provider key is needed.

### What works and what is currently gated

- Inspect any wallet’s MAD balance, freeze cost and lock before connecting. After connection, show MAD/FWA/ETH balances, round spending and eligibility. Freezes require a direct wallet with no contract code; smart accounts cannot bypass that rule.
- Offer MAD/FWA buys and sells through the verified Universal Router. Require selected slippage, positive minimum output, fresh quotes and deadlines. Exact-amount ERC20 and Permit2 approvals are separate reviewed transactions. Quotes are deliberately limited to the current tick interval; reduce an amount that crosses it. Native ETH/MAD trading is not offered.
- Inspect reward budgets, acquisition quotes and blackout status, settle allocations by request ID, recover current-source refunds, redeem NFT ETH claims, close eligible rounds, request winners and deliver prizes. These public keeper calls use existing protocol budgets; the caller pays network gas.
- Show a bounded, genuine event history with transaction links. Errors remain unavailable rather than becoming zero balances or empty history.
- Show supported management forms only to current onchain owners. Recheck roles and deployment state, simulate before review, recheck and simulate before submission, and request an explicit wallet confirmation for each write. Pending, rejected, reverted, replaced, cancelled and unknown confirmations have distinct handling.

At the recorded verification block, trading was **closed**, active liquidity was **zero**, NFT conversion bounds were **unset** and the reward budget had **no spendable ETH**. The website shows these real conditions. It cannot enable trading on behalf of the owner, supply liquidity or choose conversion bounds. Those are existing protocol decisions, not missing website configuration.

The distributor’s address is visible, but claims cannot be reconstructed without its verified ABI, claim tree and wallet proofs. The website explains that limitation. Historical acquisition settlements use the purchase’s saved FWA source and that source’s live settlement window.

### Revenue and deployment verification

`docs/website-deployment-check.json` records source/runtime comparison, both exact canonical ABI hashes, contract bindings, router/Permit2 runtime checks, live settings and receiver registration. The fixed receiver’s `playground()` and `projectId()` match the supplied hub and project 3, and `hub.projects(3).receiver` points back to it. The complete [parent objective](https://github.com/identity-md-launches/launch-2503-token-name-mutually-assured/pull/1) explicitly identifies this receiver as the IMD payer; a separate payment receipt was not supplied.

Hook `payout()` sends only Playground FWA claims directly to this immutable receiver. Receiver-held FWA is not claimable ETH. Adapter configuration/conversion and downstream ETH claims belong to the existing hub/receiver contracts; the site does not add a payment flow or a conversion adapter. NFT FWA/ETH claims and spendable reward ETH are shown separately. The rules screen explains the existing downstream split and native-ETH deposit behavior.

To reproduce verification, first run `forge build --offline`, then:

```sh
npm --prefix web run verify:deployment
```

This read-only check uses the public RPC in the saved handoff by default. An optional RPC argument is supported for a worker-provided relay; its address is never embedded in the export or evidence. The script checks compiled ABI hashes and runtime code with compiler-declared immutable regions masked, verifies bindings, and regenerates the public handoff and ABI exports. It also works after pinned `.imd/reads` inputs are removed, using the saved handoff. Rebuild `dist/` after regeneration.

### Validation

```sh
npm --prefix web run test:quotes
PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node web/scripts/browser-check.mjs
PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node web/scripts/wallet-check.mjs
```

The browser scripts use the supplied Playwright module, run their own bounded local static server, and write temporary results to `test/scratch/`. Each accepts an optional public or worker-provided Ethereum RPC argument. The wallet suite uses a clearly identified mock EIP-1193 signing provider and a mock receipt; it never broadcasts a transaction. Its contract reads and preflight simulations use the real Ethereum contracts.

Actual results: production build and typecheck passed; **142** quote/encoding/reference checks passed; **128** existing Solidity tests passed; live browser interactions and wallet-state checks passed; the pinned design probe passed **16/16**. A fresh `npm ci` succeeded and npm audit reported **zero vulnerabilities**. Vite emits a chunk-size advisory and an unused dependency’s browser-externalization advisory; no corresponding browser exception or missing runtime resource was observed.

`DESIGN.md` documents final source tokens and components; `VALIDATION.md` records requirements, six-domain review coverage, fixes and remaining limitations. No real-wallet signing, mainnet swap, physical wallet-app handoff, WebKit, native screen reader or browser-native 200% zoom is claimed. Closed trading and empty active liquidity prevent a live swap rehearsal; the existing offline tests execute the actual deployed Universal Router and Permit2 runtimes for buy/sell/approval behavior.

## Existing contract documentation

Ethereum contracts for paid holder freezes and NFT prizes. This repository includes all Solidity dependencies as ordinary source files; verification needs no network. The existing launch manifest is retained; website runtime configuration comes from the verified deployment handoff.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200 runs, via IR, and `bytecode_hash = "none"`. The fuzz seed is the assignment's `0x4505d2dc9770c5d9f475d85cef833894c8d9e4401e4b51235ade9e4240de895a`. Tests use local PoolManagers, service mocks, protocol oracle vectors, and pinned Ethereum Universal Router/Permit2 bytecode. They require no environment variables, fork, FFI, or credentials. File permissions are read-only for the two committed runtime fixtures under `test/fixtures/`; there is no filesystem write permission.

## Contracts and launch parameters

| Contract | Constructor | Responsibility |
| --- | --- | --- |
| `MadToken` | none | Solady ERC20; transfer gates; paid freezes; spending and round windows |
| `MadHook` | `(IPoolManager manager_, MadToken token_, address factory_)` | Canonical MAD/FWA pool; FWA fees, claims, burns and NFT-only conversion |
| `MadRewards` | Created by the hook constructor | NFT purchases, settlement, queue, oracle requests and awards |

The launch deploys only the token and hook. Hook arguments are `$poolManager`, `$token`, `$factory`. `hook.rewards()` exposes the helper; it is not an additional launch argument. All three contracts have the same fixed owner, **`0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774`**, and no ownership transfer, proxy, arbitrary withdrawal, recipient replacement, rate setter, or result setter.

The token is **Mutually Assured Destruction / MAD**, 18 decimals, **1,000,000,000 MAD** (`1e27` base units). Its no-argument constructor mints everything to its deploying factory, records that factory, and opens a transient bootstrap capability for that transaction only. There is no subsequent mint or ordinary transfer tax.

The launch must atomically:

1. Deploy `MadToken` from the launch factory.
2. Fund the existing launch MerkleDistributor's 10% allocation **before binding**. The first funded contract whose `token()` is MAD and whose `opener()` is that factory is permanently recorded as the swarm distributor. No distributor is created by these contracts.
3. Deploy the mined `MadHook`, then initialize its MAD/FWA key from the same factory. The hook authenticates the PoolManager and factory; the token requires its live constructor capability, hook identity, factory, fixed owner, token, manager, helper and complete key. Binding consumes the capability and cannot be repeated. The registry is not consulted during binding.
4. Seed the factory's pool position with the pool allocation and deliver any remainder according to the launch policy. This implementation preserves those flows and does not reserve MAD for the hook/helper.

Pool terms: chain **1**, pair FWA **`0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845`**, LP fee **12500**, tick spacing **60**. The launch factory derives the opening price from its policy; the contracts do not replace it with the tests' 1:1 price. Supply allocation remains the launch's 10% swarm / 90% pool policy, with its usual remainder handling.

For Ethereum, supply PoolManager **`0x000000000004444c5dc75cB358380D2e3dE08A90`** as the constructor argument. Hook address permission bits must equal **`0x20cc`** under mask `0x3fff`: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta. Initialization protects the predicted pool before deployment. There are no liquidity-removal callbacks or fee-collection taxes, so the factory's zero-liquidity fee collection remains available. All enabled callbacks authenticate the manager and canonical pool.

## Token gates and trust

Only the fixed owner can call `MadToken.enableTrading()`, once and after binding. It simultaneously starts swaps, paid freezes, the fee decay clock and round one. Initialization, seeding, owner/factory funding and remainder flows work beforehand. Swarm **outflows**, including sweeps and payments to owner/factory/exempt addresses, remain blocked until enablement. A failed claim reverts the distributor's claim state as part of the same transaction. The distributor's own original cliff and proofs still apply; this code never changes or restarts them.

Except the initial mint and exact internal freeze payment, transfers check:

1. Swarm's pre-trading lock.
2. Frozen sender, including a sender later made exempt.
3. PoolManager transfers: factory seeding/fee collection, or a signed transient allowance from this pool's raw MAD swap deltas. Allowances net both signs and are consumed toward zero; exemptions do not skip this step. Outgoing MAD must go to a no-code address or an exempt custodian.
4. Either side is factory, owner, swarm, an owner-approved contract distributor, or a global distributor while that option is enabled.
5. Otherwise a direct self-initiated EOA transfer (`msg.sender == from == tx.origin`) between no-code addresses. Other transferFrom, Safe contracts, constructors as senders and EIP-7702 delegated accounts fail this path.

PoolManager, hook, token and rewards can never be distributors, including through the global registry. `setDistributors(address[],bool)` is contract-only when granting. `setUseGlobalDistributors(bool)` controls the initially enabled registry at **`0xDf99bd1218E7EB288CfFeCF9775385167Bb09B2D`**. Explicit ERC20 approvals are required, including for Permit2.

Buys require a trusted, take-only router. Ethereum Universal Router **`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`** starts approved. Its deployed v4 action dispatcher permits physical takes, not ERC-6909 mint/burn or clear actions; see [verification notes](docs/verification.md). Owners must verify the same property before approving another router. Sells may return FWA claims through other routers. Routers, the factory, owner and global registry are trust assumptions. Approved distributor custody cannot be targeted by a new freeze, and contracts can be deployed at previously empty recipient addresses: this is not an absolute anti-parking guarantee. Existing freezes and PoolManager accounting still apply.

## Freezes and rounds

`freeze(target)` requires a direct no-code EOA caller. The target cannot be zero, the caller, core infrastructure, factory or any distributor. The caller pays `floor(target.balance / 100)` MAD; zero cost and insufficient balance fail. `floor(cost / 2)` burns and the rest credits the target. The full cost counts toward the caller's current-round spending. The target's lock resets to **now + 24 hours**, rather than adding another day to its prior deadline.

Frozen holders can receive MAD and freeze others. The internal payment consumes an exact, private one-use authorization for the caller, target and amounts, with no intervening external calls; it is not an exposed burn, allowance or delegated payment. Ordinary sales and sends still fail. `Frozen(by,target,cost,until)` records the full cost. Views include `frozenUntil(address)`, `freezeCost(address)`, `currentRound()`, `roundBlocks(round)`, `spent(round,address)` and `leader(round)`.

The highest cumulative spender leads; equal totals retain the first spender to reach that total in execution order. Public `MadRewards.closeRound()` assigns the oldest unassigned **kept** NFT only when the current round is at least **7,200 blocks old** and its leader has spent at least **1,000 MAD**. Age is measured from the round's first block. The rewards helper closes through the bound hook; it cannot skip NFT assignment. The round ends in the closing block, further freezes in that block fail, and the next round begins next block. Low participation can leave a round open indefinitely. The closed range, time, saved leader and NFT never change.

## Fees, rounding and accounting

The additional hook fee is in **FWA only**. At enablement it is 99%; it decreases linearly, at basis-point precision, to 1% over 1,800 seconds, then stays at 1%. For elapsed `e` clamped to `[0,1800]`, the rate in bps is `9900 - floor(9800 * e / 1800)`. The pool's existing 1.25% LP fee is separate.

Let `D = 10000`, rate `r`, gross FWA trade base `G`, and net FWA `N`:

| Mode | Calculation |
| --- | --- |
| Buy, exact FWA input | `G = specified`, fee `floor(G*r/D)`, pool gets `G-fee` |
| Buy, exact MAD output | Pool requires `N` FWA; `G = ceil(N*D/(D-r))`, fee `G-N` |
| Sell, exact MAD input | Pool outputs `G` FWA; fee `floor(G*r/D)`, trader gets `G-fee` |
| Sell, exact FWA output | Trader requests `N`; pool must output `G = ceil(N*D/(D-r))`, fee `G-N` |

The two specified-FWA modes require that leg to fill completely; otherwise the entire swap reverts. This avoids charging a specified-leg fee on unfilled volume or refunding it in MAD. Unspecified-FWA modes calculate fees from the actual executed delta. Amounts are checked before int128 conversion.

Permanent revenue is always **1% of the FWA trade base**, including during decay: `permanent = floor(G/100)`, Playground gets `floor(permanent/2)`, NFTs get the remainder (at most one wei more). Excess fee above `permanent`, including exact-output gross-up rounding dust, is physically taken from the manager and burned with `FWA.burn(exactAmount)` in the same swap, as far as the manager's FWA float covers it. A buyer settles its FWA input only after `afterSwap` (the Universal Router swaps, then `SETTLE_ALL`), so during the decay an early buy can owe more excess than the manager physically holds. The uncovered part is minted as a burn-only FWA ERC-6909 claim (`pendingBurnClaims`, event `BurnDeferred`), backed by the buyer's own settlement, and is burned by the next swap's collection or by public `burnExcess()` (event `ExcessBurned`). `totalBurned` counts excess committed to burning, deferred part included; revenue claims are never used for it. There is no MAD protocol cut or configurable revenue recipient.

The hook retains separate Playground FWA, NFT FWA and NFT ETH claim balances. Public `MadHook.payout()` burns only Playground's claims and transfers **FWA directly from the PoolManager** to the immutable receiver **`0x04454514ad6dc4C01d7064C308F8853183FDD39C`**. It can redeem partially if physical liquidity is temporarily insufficient. It neither converts nor invokes a hub/adapter, adds requester fees, splits revenue again, or depends on NFT conversion. The receiver's existing adapters handle later token conversion. The task's general ETH footer does not replace this explicit FWA payout.

Only NFT FWA claims are sold, inside a MAD swap's current unlock, on the configured official ETH/FWA market using exact input. Its own 1% ETH fee and price impact reduce NFT proceeds. The owner supplies an absolute sqrt-price ceiling and minimum ETH per FWA. Unsold amounts, absent bounds, unavailable markets and failed price checks leave NFT FWA claims waiting for a later MAD swap. The isolated conversion call rolls back all of its effects on failure. There is no public standalone conversion function.

Actual ETH goes directly to `MadRewards`; if the manager lacks enough physical ETH for those proceeds, the hook mints NFT ETH claims instead. The official market first requires physical ETH for its own fee: if even that fee cannot be paid, the conversion rolls back and NFT FWA claims wait. Public `redeemNFTBudget()` later redeems available native liquidity to the fixed helper; `buy()` also invokes it. Claims are not spendable NFT purchase budget until redeemed. No Playground claims or MAD principal fund NFT purchases.

## NFT and oracle operations

Any keeper/user can:

- Call `payout()` on the hook for Playground, `redeemNFTBudget()` to fund the helper from NFT ETH claims, or `burnExcess()` to burn deferred excess fee once the manager holds enough FWA (the next swap does this too).
- Call rewards `buy()` after trading starts, outside the FWA purchase blackout. It reads the live quote, sends exactly `quote.total`, and calls `acquire(address(this),1,fee+margin,0,slippage)`. Defaults: fee margin **0.001 ETH**, negative slippage **500 bps**. The actual ETH balance is the budget.
- Watch acquisitions, then promptly call `claim(requestId)` while the allocation is fulfilled/allocated and **before** `allocatedAt + settlementWindow()`. `claim` has no trading gate. It can also adopt a fulfilled draw someone bought for the helper through the current FWA V2 pool. If the window is missed, FWA V2 still delivers the allocation to its purchaser later (`finalizeUnsettled`, depositor reclaim, stuck recovery); `claim(requestId)` then adopts any NFT the helper already owns from its own allocation, regardless of the listing's current status, so a late delivery still becomes a prize. Each purchase made by `buy()` retains its source address across settings changes. The helper receives ERC721s and queues each NFT it holds once: the registration guard lasts only while the helper owns the NFT, so a prize that a winner relists in FWA V2 and the helper draws again can be kept again. An NFT sent to the helper outside its own allocation is not a prize and has no rescue path.
- Call `recoverRefund(source)` for a current or historical configured FWA pool. Acquisition refunds return to the same NFT budget; VRF charges may not be refundable. Keepers should use FWA's public processing functions as needed and monitor its settlement window; missed windows can lose the intended NFT outcome.
- Call `closeRound()`, then wait at least eight blocks and call `askWinner(round)`. Donate IMD to the helper to pay the intake's **live** `priceOf`; no ETH budget is used. One active ask per round is allowed. A failure callback permits immediate retry; after six hours without an answer a new `askWinner` may supersede the request. Only that supersession invalidates it: until then a valid answer to the live request is accepted up to the 72-hour deadline, so a late but unsuperseded answer is not wasted. A retry never refunds the spent intake price.
- Call `award(round)` after a valid answer, or at/after the 72-hour fallback deadline. Any recipient failure retains both NFT and fixed beneficiary for retry. A rejecting beneficiary has no alternate recipient or owner rescue path.

Initial oracle references are Intake v2 **`0xa43e6F75ee006411F79Ac1C84120606C2330DE82`**, IMD **`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`**, signer **`0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`**, action `bytes32("oracle.request@oracle-1")`. Requests use `requestWithFailure` and the canonical OracleQuestion hash/body: chain 1, absolute round block window, address[] answer, head 1, chain evidence (the protocol default), panel 30, quorum 20, valid-for 3600 seconds. The fixed question is:

> Rank MAD freeze spending in round {N}, token {lowercase mad address}, Ethereum blocks {first}-{last} inclusive. Sum its Frozen.cost in base units grouped by Frozen.by, highest first. Ties: first to total in block/transaction/log order.

The callback checks the current live intake ID, original intake and signer, question hash, consumer EIP-712 domain, chain, exact blocks, answer type, panel agreement, validity and global oracle UUID replay. Its only effect is storing the first valid nonzero winner. Request-time settings remain authoritative after admin changes. It never transfers an NFT or ETH during the oracle's 200,000-gas callback.

No request/answer can replace the winner after **close + 72 hours**. Without a winner by then, the saved leader is the irrevocable effective beneficiary. `award` stores the beneficiary before attempting delivery, including on a caught delivery failure. Oracle truth still depends on the panel and signer; timeout fallback provides liveness, not independent verification of their answer.

## After launch

| Owner call | Configuration / responsibility |
| --- | --- |
| `MadToken.enableTrading()` | Irreversible launch decision after successful binding and seeding |
| `MadToken.setDistributors(accounts,allowed)` | Approve only audited custody/distribution contracts; all ordinary frozen-sender checks remain |
| `MadToken.setUseGlobalDistributors(enabled)` | Accept or reject the supplied global registry's custody policy |
| `MadHook.setRouters(routers,approved)` | Add only inspected take-only router implementations; no MAD claim mint, clear or unsupported-pool escape |
| `MadHook.setEthFwaPool(key)` | Initially native ETH/FWA, fee 0, spacing 60, hook `0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444`; update only to FWA's verified official market |
| `MadHook.setConversionBounds(sqrtLimit,minEthPerFwaX18)` | **Required to enable NFT conversion. Initially unset.** Obtain acceptable absolute bounds from the official ETH/FWA market and independent price assessment. A stale bound leaves claims waiting; it does not stop MAD swaps or Playground payouts |
| `MadRewards.setFwaV2(pool)` | Initially `0x958C41181182e76F221331b2755b77D9e1426A98`; update from FWA's verified deployment publications. Settle outstanding draws from their saved source |
| `MadRewards.setAcquisitionBounds(margin,slippageBps)` | Maintain quote-fee margin and NFT acquisition negative-slippage bound; live quote/window/blackout remain FWA's settings |
| `MadRewards.setOracleSettings(intake,imd,action,signer)` | Obtain upgrades from IdentityMD's verified protocol deployments. Only future asks use the new settings; panel, quorum, question, deadline and round results are fixed |

Owner-key trust, stated plainly: the owner is a trust assumption of the brief, and these powers are deliberately not constrained further. `setOracleSettings` accepts any intake contract and signer, so an owner-chosen intake decides what `askWinner` pays (donated IMD is spent at the intake's live `priceOf`) and the owner-chosen signer decides which attestations later asks accept; outstanding asks keep their request-time intake and signer. `setFwaV2` must point at a pool whose request ids never repeat an earlier pool's (the live FWA V2 uses VRF request ids): `purchases` are keyed by request id, and a colliding id reverts `buy()` after the live acquire. `setConversionBounds` are absolute, static floors; between resets a sandwich on the ETH/FWA market can sell accumulated NFT claims down to the floor, so set bounds close to market and refresh them, especially before the first conversion after launch. `setUseGlobalDistributors(false)` is immediate: MAD already parked in a registry-only contract becomes immovable and freezable until the owner re-enables the registry or adds the contract locally; mirror such custodians with `setDistributors` before flipping. Freeze economics are the brief's: the full cost counts as spending while only half burns, so freezing a wallet one controls costs an effective 0.5%; the brief grants no anti-parking or anti-self-dealing guarantee beyond the listed target checks.

Keepers must maintain IMD donations, acquisition processing/claims, refunds, fee redemption, deferred burn flushing and eventual awards. FWA's owner may need to register the launch factory for that factory's own downstream FWA fee distributions; this implementation does not add to or redirect the factory's existing requester fees. Playground performs its own downstream split.

The deployment team remains responsible for the launch factory transaction, correct hook address mining, verified external settings, and an independent security review. These contracts and tests do not constitute a production audit or an authorization to broadcast transactions.
