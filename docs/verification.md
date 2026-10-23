# Verification and external references

All runtime assets and dependencies needed by the delivered tests are committed as ordinary files. No submodule, package cache, PDF audit archive, generated build output, compiler binary, remote import or network-dependent test is required.

## Sources and deployed router behavior

- MAD's gate and signed transfer accounting are adapted from [token-works/ERC20T](https://github.com/token-works/ERC20T/blob/802fca585a15825ea44aefcef8f1b163010c8891/src/ERC20T/ERC20T.sol), commit `802fca585a15825ea44aefcef8f1b163010c8891`. Its MIT notice is retained in `docs/ERC20T-LICENSE`. MAD uses no clones, mutable owner, configurable tax or generic launch flow from that implementation.
- The task's pinned FWA V2 ABI/reference supplies acquisition, settlement, refund and official ETH/FWA market definitions. Public source: [adamlizek/fwa](https://github.com/adamlizek/fwa/tree/190ce259/src). The runtime-matched verified FWA token, market hook and FWA V2 sources were also inspected through Sourcify's v2 API. Runtime service settings are read from the configured contracts when used, rather than hardcoding the reference's quoted prices/windows.
- OracleAttestation and OracleQuestion are copied from the supplied canonical reference. The only library compatibility adjustment is `SignatureChecker.isValidSignatureNow` in place of its newer calldata convenience overload, for OpenZeppelin 5.4. The protocol's fixed digest, signature and question-hash vectors are tested independently of signatures produced by our test key.
- Dependency revisions appear in [dependencies.json](dependencies.json). Only the needed Solidity sources and licenses are shipped.

[mainnet-code-check.json](mainnet-code-check.json) records read-only Ethereum code observations at block **26,256,680**, including the named PoolManager, FWA, FWA V2, router, registry, intake, IMD and Playground receiver. At that block, `FWA.isDistributor(PoolManager)` also returned true, confirming the transfer path used for fee burning and direct receiver payouts. These are observations of the named public contracts, not deployments performed by this assignment; external protocol settings remain their administrators' responsibility.

The Universal Router's [verified source and deployed bytecode](https://sourcify.dev/server/v2/contract/1/0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af?fields=all) match at runtime. The verified build is Solidity 0.8.26, Cancun, via IR, optimizer 44,444,444 runs, metadata hash disabled. Its deployed `V4Router._handleAction` recognizes four swap actions plus `SETTLE`, `SETTLE_ALL`, `TAKE`, `TAKE_ALL` and `TAKE_PORTION`. Other actions revert `UnsupportedAction`. In particular, the existence of `MINT_6909` and `BURN_6909` constants in the shared Actions library does **not** mean the router supports those actions. `CLEAR_OR_TAKE` is likewise absent from its dispatcher. `DeltaResolver._take` calls `poolManager.take`; `V4SwapRouter._pay` settles to the manager through `payOrPermit2Transfer`.

Offline integration tests execute the **unmodified deployed runtime** at the real router and Permit2 addresses. A fresh local PoolManager is constructed at the Ethereum manager address, preserving its NoDelegateCall immutable. The MAD pool and FWA mock are local. This tests deployed router dispatch and real Permit2 approval/payment behavior without a fork or remote service. The two small JSON runtime fixtures have narrowly scoped read-only test permissions.

| Runtime fixture | Bytes | Ethereum code hash |
| --- | ---: | --- |
| Universal Router | 19,499 | `0x6a5f46971b50c6e1b7eef97902311444e479d734e4f80ad88367783cf373fe7f` |
| Permit2 | 9,152 | `0xc67d1657868aa5146eaf24fb879fb1fdec3d2d493b3683a61c9c2f4fb2851131` |

The tests assert these hashes before executing the fixtures. They exercise buys/sells in both exact modes, frozen seller rollback, and rejection of a MAD ERC-6909 payout. They do not claim that an arbitrary owner-approved router is safe; inspecting each additional router remains an operational requirement.

## Coverage

`MadToken.t.sol` checks full supply/fixed owners, runtime size and forbidden opcodes, atomic binding and expired bootstrap rejection, launch transfers, swarm lock ordering and original cliff/proof rollback, direct versus delegated transfers, Safe/EIP-7702 behavior, local/global custody, forbidden distributors, frozen sender precedence, exact internal freeze payments, burn/credit conservation and first-to-total ties.

`MadHook.t.sol` uses a real v4 PoolManager, full-range liquidity and an FWA transfer-gate mock. Its two suites force opposite token orderings. They check all four swap modes at 0/15/30 minutes, fuzzed amounts/times, gross/net conservation, permanent revenue shares, exact excess burn, payout idempotence, bounded partial conversions, deferred conversions, ETH claim redemption, signed netting and consumption, multiple unlocks, other-pool transfers, unsafe recipients, bad routers, frozen sales and factory fee collection. The conversion market mock reproduces exact-input-only FWA sales and a 1% ETH output fee.

`MadRewards.t.sol` checks live quote/budget/blackout rules, purchase bounds, original FWA-source snapshots, in-window and late settlement, ungated gifted-draw settlement, refunds, NFT queue order, minimum participation and round age, same-block closure, exact oracle question/body/hash, live IMD pricing, callback sender/signature/domain/chain/window/panel/answer checks, global UUID replay, invalid/superseded requests, six-hour retry, request-time authority snapshots, the 72-hour boundary, immutable fallback/beneficiary, failure/retry/double-award behavior and reentrancy.

`OracleConformance.t.sol` keeps the canonical protocol vectors. The rewards mock delivers through the canonical callback under a **200,000 gas** stipend, including successful acceptance.

## Review limits and operational checks

Final local checks used the pinned Solidity 0.8.26 compiler and the required fuzz seed. A forced rebuild from all 119 compilation units passed. `forge build --sizes`, `forge test` and `forge fmt --check` passed after the final code changes: **84 tests, zero failures, zero skips**, including five fuzz tests with 256 cases each. The two swap suites force opposite MAD/FWA currency orderings.

| Launch contract | Runtime bytes | Initcode bytes |
| --- | ---: | ---: |
| MadToken | 9,333 | 9,626 |
| MadHook | 11,462 | 31,504 |
| MadRewards | 17,762 | 19,297 |

All three are below EIP-170 and EIP-3860 limits and contain no unresolved library links. The delivered sources, dependencies, licenses and runtime fixtures total approximately **1.6 MB**, below the assignment's 8 MiB upload limit. Generated build/cache artifacts are omitted.

The supplied protected checks were read as acceptance definitions; their environment-driven bytecode harness is run by the independent verifier. The delivered tests independently exercise their relevant supply, initialization, permission, ownership, runtime and factory-flow properties, with no test environment reads or writes.

This work includes a local adversarial code review and the executable checks above. It is not an independent audit, a live launch-factory rehearsal, or a claim that FWA/IdentityMD will fulfill future requests. The independent deployment review must verify the actual factory transaction order, mined address, external references and owner-supplied conversion bounds. FWA randomness/selection and oracle truth are external protocol responsibilities. The exact fixed question is shipped as requested; no live oracle request is purchased and no off-chain wording acceptance is asserted.

Price bounds begin explicitly unconfigured. An absent or stale bound preserves NFT FWA claims, while fee burning and Playground payout continue. NFT settlement requires timely public keeper calls; recipients that never accept ERC721s can leave their assigned NFT indefinitely undelivered. Neither situation authorizes a new owner withdrawal or beneficiary override.
