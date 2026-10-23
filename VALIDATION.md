# Website validation

This report describes worker-side checks of the MAD website. It is not an independent audit or a network certification.

## Revision validation, 2026-10-23

This revision addresses the four reported website defects and preserves the accepted contracts, ABIs, deployment handoff, fees, routes, dependencies and build configuration. The sections below this revision record retain the original implementation’s evidence; Solidity checks listed there were not repeated for this frontend-only revision.

All four reports reproduced in Chromium against the accepted `dist/` before editing. Delaying the quote snapshot, then selecting Sell, produced a “Swap MAD for FWA” review whose decoded Universal Router settlement actually spent FWA and received MAD. Changing amount, slippage or deadline also allowed obsolete quotes to publish. A chain-137 mock wallet rejecting switching made Disconnect unreachable and intercepted five navigation centers at both 320 and 390px. Both NFT ID forms lacked error associations and used the same remote error.

| Finding and final source | Correction and recheck |
| --- | --- |
| High, quote race; `web/src/TradePage.tsx:28` | Request generations invalidate on all four form changes and unmount. Superseded results, errors and loading updates are ignored. Rendered quotes and approval/swap preflight require the current generation, direction, inputs and parsed amount; review assets derive from that quote. Delayed requests, edits back to the original value, old errors, navigation, out-of-order completion, edits during all three preflight paths, buy/sell encoding and both approval spenders pass. |
| Medium, wrong-network disconnect; `web/src/Wallet.tsx:107` | The header always opens the existing wallet dialog. Switch and Disconnect remain available after a rejected switch; current chain and pending-switch state are explicit. Rejection, reopening and disconnect pass at 320, 390 and 1440px. |
| Medium, obstructed navigation; `web/src/Wallet.tsx:128`, `web/src/style.css:333` | Removed the floating error and its CSS. Errors remain inside the dialog and clear on close. Escape restores focus; all six navigation centers hit their link and all six links can be clicked at each tested width. |
| Medium, detached NFT form errors; `web/src/Rounds.tsx:120`, `:425`, `:562` | Separate adjacent errors, field-specific copy, `aria-invalid`, `aria-describedby` and focus on invalid submission. Acquisition error measured at y=395.86–418.25 and round error at y=715.25–760.03 in the 390×844 viewport. Independent clearing and uint256 overflow feedback pass. |

The new `web/scripts/revision-check.mjs` runs against the production export and writes only temporary evidence under `test/scratch/revision/`. Contract code, deployment bindings, ABIs and receiver registration are retained and read through Ethereum. Its explicit trade fixture supplies open trading, active liquidity, current timestamps, wallet balances/allowances and successful swap/approval simulations. It tests browser behavior when the currently closed pool eventually opens; fixture simulations do not establish live swap availability. Its mock wallet prohibits every signature and transaction send. The original wallet suite separately uses real onchain simulations and synthetic wallet/receipt responses to check rejection and post-confirmation refresh.

Dependencies were installed from the unchanged lockfile into an exact temporary copy of `web/` at `/tmp/mad-revision-build/web`; repository dependency directories and package/build files were not modified. Actual build commands were `npm --prefix /tmp/mad-revision-build/web run typecheck` and `npm --prefix /tmp/mad-revision-build/web run build -- --outDir <repository>/dist`. The quote runner and new revision runner used that same dependency copy; existing browser/wallet runners used the repository scripts. Public Ethereum source: `https://ethereum-rpc.publicnode.com`; the supplied worker relay was used for read-only checks and is not embedded in outputs. README commands reproduce the checks after a normal `npm --prefix web ci`.

| Revision check | Actual result |
| --- | --- |
| Unchanged-lockfile dependency installation | Passed; 53 packages, audit reported zero vulnerabilities |
| Typecheck and production build | Passed; final relative-asset export in `dist/` |
| Quote/reference/encoding suite | 142 passed |
| New regression suite | 24 scenario groups passed; zero signing or sends |
| Existing live browser suite | 24 checks passed, including read-only routes, primary action, unavailable live trading and no uncaught exceptions |
| Existing wallet suite | 9 checks passed, including actual role/preflight reads, rejection, synthetic receipt refresh and stale RPC handling |
| Pinned design probe | 16/16 passed at 320, 390 and 1440; reduced-motion and metadata checks included |
| Visual inspection | Viewed entry screen at 390, wrong-network rejection at 320, both adjacent NFT errors at 390 and buy/sell reviews |

Better Interface coverage for the affected components: **Accessibility checked** through field associations/focus and dialog Escape/focus return; **Layout checked** through navigation hit tests, real clicks, screenshots and the overflow probe; **Writing checked** through exact asset/amount/spender comparisons and specific recovery copy; **Typography checked** through the unchanged six-step scale and probe; **Colors checked** through reused status tokens and the entry probe’s rendered contrast check; **UI checked** through cancellation, loading, error, rejection, disconnect and review states. No new visual system or unrelated screen redesign was introduced. Native screen-reader output, physical wallet apps, WebKit, RTL, browser-native 200% zoom and separate contrast measurements of every error state remain unperformed. Build advisories about the existing large chunk and unused dependency’s browser externalization remain unchanged.

`docs/website-revision-check-results.json` records the reproduction and final check summaries plus current export hashes. Temporary screenshots are deliberately excluded from submission. `.imd-responses.json` answers all four exact finding IDs. Complete for this revision’s scope; no mainnet transaction was signed, broadcast or deployed.

## Scope and evidence

Read the pinned project history, network and deployment handoffs; all three application contracts and interfaces; existing tests, runtime fixtures and verification notes. The complete original objective was retrieved from the [parent pull request](https://github.com/identity-md-launches/launch-2503-token-name-mutually-assured/pull/1), because the pinned history excerpt truncates it. The lineage contains one completed contract project and no previous website to replace.

Ethereum reads were made through the supplied worker relay, represented in published evidence by `https://ethereum-rpc.publicnode.com`. The website itself contains only the handoff’s public RPC URLs. No relay address, credentials or private keys are part of the deliverable.

`docs/website-deployment-check.json` records the exact block and hash, source commit, compiled ABI digests, runtime code hashes, bindings, pool key, live settings and receiver checks. Both canonical ABI hashes match the handoff. All three deployed runtime bodies match the compiled source after masking compiler-declared immutable regions. The Universal Router and Permit2 runtime hashes match the existing pinned bytecode fixtures. The browser checks deployment/runtime identity again before enabling a write.

The registered receiver is project 3’s receiver in both directions: receiver → hub/project ID and hub → receiver. It is also the hook’s immutable `PLAYGROUND`. The full parent objective names it as the IMD payer. That historical objective is the available paidBy evidence; a separate protocol payment receipt was not supplied. No destination is guessed or newly wired.

At the recorded check: trading is closed, current round is zero, active liquidity is zero, conversion bounds are unset, no NFT prizes are retained and spendable reward ETH is zero. These are successful live reads. They are not used as fallback values after read errors.

## Requirements

| Requirement | Result |
| --- | --- |
| Complete responsive website | Six hash-routed screens: Freeze, Trade, NFT rewards, Activity, How it works, Manage |
| Static export with relative assets | `dist/index.html`, local JS/CSS/images/wallet marks, handoff; Vite `base: './'` |
| Original contracts and economics | Existing Solidity, launch manifest, build configuration and dependencies preserved |
| Live token actions | Target inspection and guarded `freeze`; gate and cost follow actual source and state |
| Trading route | Verified MAD/FWA v4 key and router; exact-input buy/sell, bounded quotes, slippage, min output, deadlines and two exact approvals |
| Current live swap availability | Explicitly disabled: trading closed and no active liquidity |
| ETH trading | No ETH/MAD route invented; only the actual FWA pair is offered |
| Wallet state | MAD, FWA, gas ETH, round spending, freeze deadline, no-code eligibility; read failures unavailable |
| Public keeper flows | Existing reward acquisition/settlement/refund, round closure/oracle/award, NFT claim redemption, Playground FWA payout and excess burn |
| Recent events | Real bounded log reads; source-derived decoding; transaction links; dates and token units formatted |
| Administration | Actual owner reads; controls hidden for nonowners; fresh role check and simulation before every write |
| Revenue | Held FWA, hook claims, NFT claims and spendable ETH kept distinct; fixed receiver preserved; no payment or receiver-conversion UI added |
| Wallet coverage | EIP-6963, browser wallet fallback, four mobile open-in paths, Coinbase Smart Wallet, switching/disconnect/account changes |
| Transaction safety | Review and explicit wallet prompt per write; account and state revalidation; duplicate-send lock; receipt refresh; replacement/cancellation/unknown handling |
| First 390px screen | Product and Inspect wallet visible; measured action y=495px, height=48px |
| Metadata | Real title, description, favicon, og:title and local 1200×630 PNG og:image |
| Documentation | README install/preview/rebuild/validation; DESIGN final source tokens/components; third-party notices |

Distributor claims remain unavailable because the handoff contains no verified distributor ABI, claim tree or wallet proofs. The visible contract reference and explanation identify that limitation. Hub claimability and receiver conversion are not inferred from receiver holdings. Current-owner controls do not assume that a project creator or member owns a contract.

## Actual checks

| Check | Result |
| --- | --- |
| `npm --prefix web ci --cache /tmp/mad-npm-cache` | Fresh installation succeeded from the committed lockfile; 53 packages installed |
| `npm --prefix web run typecheck` | Passed |
| `npm --prefix web run build` | Passed; export written at repo-root `dist/` |
| `npm --prefix web run test:quotes` | 142 passed: 24 independent SwapMath vectors, 108 TickMath vectors, 10 validation/encoding edge checks |
| `forge build --offline` | Compiled 123 Solidity files successfully; source unchanged |
| `forge test --offline` | 128 passed, zero failed, zero skipped across 13 suites |
| `node web/scripts/verify-deployment.mjs [worker RPC]` | Passed ABI, masked runtime, binding, route-code and receiver checks |
| Browser interaction script | Passed actual snapshot/target/round reads; invalid address; unavailable trade; read-only roles; all routes; viewport overflow; wallet chooser; mobile wallet paths before RPC completion; Escape/focus return; no uncaught browser errors |
| Wallet script | Passed wrong network/switching, owner/nonowner account changes, real preflight simulation, account change during review blocking a send, wallet rejection, duplicate-send count, mocked successful receipt refresh, role-control removal and RPC stale/error behavior |
| Pinned taste probe | 16/16 passed, including render, layout, targets, measured contrast, scale, reduced motion, copy and share metadata |
| `npm audit --omit=dev` | Zero vulnerabilities after removing the unnecessary SDK toolchain dependency |

The browser and wallet commands are run from the repository root with `PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright`. Both scripts import the supplied Playwright module, serve `dist/` only for the duration of the foreground check and accept an optional RPC argument. The pinned probe was invoked exactly with the supplied module and browser paths:

```sh
IMD_PLAYWRIGHT=/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs PLAYWRIGHT_BROWSERS_PATH=/opt/imd-tools/ms-playwright node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste
```

Vite reports a large-chunk advisory and an unused dependency’s `node:worker_threads` browser-externalization advisory. The export has no observed uncaught browser exceptions or missing runtime files. Those advisories are retained as build limitations rather than represented as failed checks.

The wallet script has a mock EIP-1193 provider and a synthetic receipt. It uses actual Ethereum reads and `eth_call` simulations, including the real owner getter and actual owner-only setter simulation. It never forwards `eth_sendTransaction` to Ethereum. Its successful receipt is a UI/state-refresh fixture, not evidence of a mainnet write. Actual extension signing, pending replacement mining and live swaps are not claimed. Existing Solidity tests exercise actual deployed router/Permit2 bytecode offline for both buy/sell directions, approval settlement and frozen-seller rollback.

## Better Interface review

The pinned workflow and the core principles of all six domains were applied during implementation. Supporting guidance covered forms, keyboard/focus, spacing, long values, contrast, native dialogs and final design documentation.

| Domain | Coverage and evidence | Limitations |
| --- | --- | --- |
| Accessibility | Native controls and labels, headings/landmarks, skip link, input validation, focus outlines, modal Escape/focus restoration, written disabled states, persistent transaction errors; target and contrast probe passed | No native screen reader, physical touch-device test or full WCAG certification |
| Layout | Screenshots and overflow checks at 320/390/1440; all six routes at 390; long owner addresses and exact transaction values wrap; 390px primary action measured above fold | Native 200% browser zoom and RTL/localized variants not tested; English only |
| Writing | Source review of rules, fees, transfer restrictions, budget/claim distinctions, transaction consequences and recovery text; copy/slogan probe passed | External protocol terms remain their source contract definitions |
| Typography | Six source sizes, three weights, system font fallback; inputs 16px; monospace only for identifiers; measured type-scale/tracking probe passed | Physical iOS input behavior and every locally installed fallback font not tested |
| Colors | Shared role tokens; measured rendered entry-page text contrast passed 4.5:1, 3:1 large; redundant icons/text for statuses; focus ring visually inspected | No claim of contrast measurement for every historical NFT or wallet-vendor icon |
| UI | Consistent buttons, panel radii and notices; native wallet/review dialogs; read/loading/empty/unavailable/stale/rejected/confirmed states; reduced-motion probe passed | WebKit and physical mobile-app handoffs not performed; replacement/cancellation handled via viem but not mined live |

## Findings and repairs

- **Repeated slogan fragments, medium:** `web/src/Freeze.tsx:139` originally used two short slogan stacks. The first probe flagged four two-beat lines, counting their containers. Replaced them with one descriptive subtitle and one literal duration caption. The probe subsequently passed slogans and copy budget.
- **Phone select clipping, medium:** `web/src/TradePage.tsx:353` used “Choose slippage” inside a narrow select. The 390px screenshot showed the prompt clipped. Shortened the option to “Choose” under the persistent Slippage label; the final mobile view fits.
- **Account change during transaction review, high:** `web/src/Transactions.tsx:194` now saves the reviewing account, then checks it again alongside current chain, ownership and state before wallet submission. The wallet test changes accounts after successful simulation and confirms zero sends.
- **Historical settlement window, medium:** `web/src/Rounds.tsx:61` now reads `settlementWindow()` from the purchase’s saved source, rather than displaying the current FWA source’s window for every draw. Source-specific reads and typechecking verify the path; no historical live draw was available for a mainnet settlement rehearsal.
- **Missing deployment events / raw units, medium:** `web/src/chain.ts:335` and `web/src/Information.tsx:45` now include initial binding/distributor/pool events and settings/fee events. Token values display exact MAD/FWA/ETH units, timestamps display dates and IDs/settings remain explicit raw values. Recent history is never seeded.
- **Dependency footprint, low:** removed the unused general Uniswap SDK toolchain after generating independent reference vectors. The runtime uses a small attributed integer TickMath port. All 142 math/encoding checks pass and npm audit reports zero vulnerabilities.
- **Mobile density, low:** `web/src/style.css:1679` uses a six-item mobile navigation row and one consistent six-size type scale. The main action moved higher without removing controls. The final entry probe reports no overflow, clipping or overlapping text.

Final source locations and implementation details are in `DESIGN.md` and the readable frontend source; the recorded fixes were rechecked after implementation. No confirmed high or medium finding remains open in the implemented scope.

## Rendered evidence and completion

Temporary screenshots include `test/scratch/freeze-320.png`, `freeze-390.png`, `freeze-1440.png`, the other route screenshots at 390px, `owner-390.png`, `mobile-wallet-390.png` and the probe’s `taste/shots/390.png` and `1440.png`. They were generated and inspected locally; `test/scratch/` is intentionally not part of the submission. Summary results are preserved under `docs/website-check-results.json`.

Complete for the stated website scope. External limitations remain visible: trading enablement, active liquidity, owner conversion bounds, donated oracle funds, NFT fulfillment/settlement, missing distributor proofs and unavailable hub-claim interfaces. No contract was deployed or changed and no real transaction was signed or broadcast.

### Submission boundary

Git metadata is read-only inside this execution sandbox. `git add` returned `Unable to create .git/index.lock: Read-only file system`; no commit or staging success is claimed. The complete source, lockfile, documentation and static export are present for the network worker’s normal commit/upload step. Installed dependency directories were moved out of the repository after validation. No ignore file was changed.
