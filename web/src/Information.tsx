import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  Activity,
  ArrowUpRight,
  BookOpen,
  ExternalLink,
  Snowflake,
} from "lucide-react";
import type { PageProps } from "./App";
import { ABI } from "./config";
import { activity, errText } from "./chain";
import { useTransactions } from "./Transactions";
import { amount, exact, DataRow, Notice, Empty, AddressLink, date } from "./ui";
const labels: Record<string, string> = {
  Bound: "Token and hook bound",
  SwarmCaptured: "Distributor registered",
  Initialized: "Canonical pool initialized",
  Fees: "Swap fees recorded",
  EthFwaPoolSet: "Conversion market updated",
  FwaV2Set: "NFT source updated",
  AcquisitionBoundsSet: "NFT acquisition bounds updated",
  OracleSettingsSet: "Oracle configuration updated",
  Frozen: "Holder frozen",
  TradingEnabled: "Trading enabled",
  RoundClosed: "Round closed",
  PlaygroundPaid: "Playground FWA paid",
  NFTBudgetRedeemed: "NFT ETH budget redeemed",
  ExcessBurned: "Excess FWA burned",
  Bought: "NFT acquisition requested",
  Kept: "NFT added to prize queue",
  Closed: "NFT assigned to round",
  Asked: "Winner requested",
  WinnerAccepted: "Oracle winner accepted",
  Awarded: "NFT prize delivered",
  AwardDeferred: "NFT delivery deferred",
  ConversionBoundsSet: "Conversion bounds updated",
  RouterSet: "Router permission updated",
  GlobalDistributorsSet: "Global distributors updated",
  DistributorSet: "Distributor permission updated",
  NFTConverted: "NFT FWA converted",
  BurnDeferred: "Excess FWA burn deferred",
  RefundRecovered: "NFT refund recovered",
};
function eventValue(event: string, key: string, value: unknown): string {
  if (typeof value === "bigint" || typeof value === "number") {
    const n = BigInt(value);
    if (["until", "timestamp"].includes(key)) return date(n);
    if (key === "cost") return `${exact(n)} MAD`;
    if (
      [
        "base",
        "total",
        "playground",
        "nft",
        "burned",
        "fwaAmount",
        "fwaSpent",
        "fwaClaims",
      ].includes(key)
    )
      return `${exact(n)} FWA`;
    if (
      ["ethAmount", "ethReceived", "paid"].includes(key) ||
      (event === "RefundRecovered" && key === "amount")
    )
      return `${exact(n)} ETH`;
  }
  if (typeof value === "object")
    return JSON.stringify(value, (_, v) =>
      typeof v === "bigint" ? v.toString() : v,
    );
  return String(value);
}
export function ActivityPage({ rt }: PageProps) {
  const [filter, setFilter] = useState("all");
  const q = useQuery({
    queryKey: ["activity"],
    queryFn: () => activity(rt),
    refetchInterval: 60000,
    retry: 1,
  });
  const events = q.data?.events.filter(
    (e) =>
      filter === "all" ||
      (filter === "freezes"
        ? e.eventName === "Frozen"
        : filter === "rewards"
          ? [
              "Bought",
              "Kept",
              "Closed",
              "Asked",
              "WinnerAccepted",
              "Awarded",
              "AwardDeferred",
              "NFTBudgetRedeemed",
            ].includes(e.eventName)
          : [
              "PlaygroundPaid",
              "ExcessBurned",
              "NFTConverted",
              "BurnDeferred",
              "RefundRecovered",
            ].includes(e.eventName)),
  );
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Moves, on the record.</h1>
          <p>Recent verified events from MAD’s deployed contracts.</p>
        </div>
        <Activity className="heading-icon" size={32} />
      </div>
      <div className="activity-toolbar">
        <label>
          Show events
          <select value={filter} onChange={(e) => setFilter(e.target.value)}>
            <option value="all">All protocol events</option>
            <option value="freezes">Freezes</option>
            <option value="rewards">NFT rewards</option>
            <option value="revenue">Revenue & burns</option>
          </select>
        </label>
        <button
          className="button"
          disabled={q.isFetching}
          onClick={() => void q.refetch()}
        >
          {q.isFetching ? "Reading…" : "Refresh activity"}
        </button>
      </div>
      {q.isError ? (
        <Notice tone="error">
          Activity is unavailable. {errText(q.error)} No empty history is
          inferred from this error. Use Refresh activity to retry.
        </Notice>
      ) : q.isPending ? (
        <p role="status">Reading recent event logs…</p>
      ) : (
        <>
          <p className="field-help">
            Blocks {String(q.data?.first)}–{String(q.data?.latest)} · Last 2,000
            blocks at most · Up to 40 protocol events. Token amounts use exact
            decimal units; other numbers are contract IDs or raw setting values.
          </p>
          {events?.length ? (
            <div className="event-list">
              {events.map((e, i) => (
                <article key={`${e.transactionHash}-${e.logIndex}-${i}`}>
                  <div className="event-icon">
                    {e.eventName === "Frozen" ? (
                      <Snowflake size={18} />
                    ) : (
                      <Activity size={18} />
                    )}
                  </div>
                  <div>
                    <h2>{labels[e.eventName] || e.eventName}</h2>
                    <div className="event-values">
                      {Object.entries(
                        (e.args || {}) as Record<string, any>,
                      ).map(([k, v]) => (
                        <span key={k}>
                          {k}:{" "}
                          <span className="address">
                            {eventValue(e.eventName, k, v)}
                          </span>
                        </span>
                      ))}
                    </div>
                    <span className="field-help">
                      Block {String(e.blockNumber)}
                    </span>
                  </div>
                  <a
                    aria-label={`View ${labels[e.eventName] || e.eventName} transaction`}
                    href={`${rt.d.network.explorer}/tx/${e.transactionHash}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    <ArrowUpRight size={20} />
                  </a>
                </article>
              ))}
            </div>
          ) : (
            <Empty
              title={
                filter === "all"
                  ? "No protocol events in this window"
                  : "No matching events in this window"
              }
            >
              The event window is limited. Older activity may exist. Change the
              filter or open the token on Etherscan.
            </Empty>
          )}
          <a
            className="quiet-link"
            href={`${rt.d.network.explorer}/address/${rt.addresses.MadToken}#events`}
            target="_blank"
            rel="noreferrer"
          >
            Explore token event history <ArrowUpRight size={16} />
          </a>
        </>
      )}
    </>
  );
}
export function ProtocolPage({ rt, state, wallet }: PageProps) {
  const s = state.data;
  const tx = useTransactions();
  const canWrite =
    state.safe && wallet.chainId === 1 && !!wallet.address && !tx.busy;
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Know the cold rules.</h1>
          <p>What MAD does, what it costs, and where the funds go.</p>
        </div>
        <BookOpen className="heading-icon" size={32} />
      </div>
      <div className="guide-grid">
        <article>
          <h2>Pay to freeze. Spend to lead.</h2>
          <p>
            MAD is an Ethereum token game with paid holder freezes and NFT
            prizes. It has 18 decimals and an initial supply of 1 billion MAD.
            No new tokens can be minted; freeze payments reduce supply.
          </p>
          <p>
            A freeze costs floor(target balance ÷ 100) in MAD base units. Half
            the cost, rounded down, burns. The rest goes to the target. The full
            cost counts toward the caller’s round spending. Equal spending
            totals keep the first leader.
          </p>
          <p>
            The target’s outgoing MAD locks until 24 hours after the new freeze.
            Refreezing resets that deadline. Frozen holders can receive MAD and
            freeze other holders.
          </p>
          <h2>Wallet restrictions matter.</h2>
          <p>
            Freezes require a direct transaction from a wallet with no contract
            code. You cannot target yourself, core contracts, the factory or
            exempt distributors. Ordinary direct transfers require no-code
            wallets unless an exemption applies.
          </p>
          <p>
            Smart wallets, multisigs and EIP-7702 delegated accounts cannot
            freeze. Receiving MAD from the pool also requires a no-code address
            or exempt custody. Connecting a smart wallet does not remove these
            onchain restrictions.
          </p>
          <h2>NFTs are earned through rounds.</h2>
          <p>
            Each round needs a kept NFT, at least 7,200 blocks and a leader who
            spent at least 1,000 MAD before it can close. The next round starts
            in the next block. Low participation can leave a round open
            indefinitely.
          </p>
          <p>
            An oracle request can be made 8 blocks after closure using donated
            payment tokens. A live request can be superseded after 6 hours,
            potentially spending another fee. After 72 hours without a valid
            winner, the saved spending leader becomes the fallback beneficiary.
          </p>
          <p>
            NFT purchases use FWA V2 and depend on its allocation and settlement
            process. Public keepers must settle allocations within their window.
            Late delivery can be adopted if the helper already holds its own
            allocated NFT. A rejecting prize recipient can leave delivery
            pending indefinitely.
          </p>
          <h2>Fee and custody risks</h2>
          <p>
            The hook fee starts at 99% when the owner enables trading, then
            decays to 1% over 30 minutes. It is paid in FWA on buys and sells,
            in addition to the pool’s 1.25% fee. Fees can exceed any expected
            gain during the initial period.
          </p>
          <p>
            The permanent hook revenue is 1% of the gross FWA trade base. Half
            goes to Playground claims and half to NFT claims; an odd base unit
            goes to NFTs. Excess decaying fees are burned as FWA, sometimes
            deferred until physical liquidity is available.
          </p>
          <p>
            The fixed owner controls custody exemptions, trusted routers,
            external oracle settings, FWA V2 settings and conversion bounds.
            Exempt custody is a trust assumption. Oracle truth depends on the
            panel and signer; the fallback provides liveness, not independent
            verification.
          </p>
          <p>
            Freezing a wallet you control has an effective burn cost of half the
            freeze payment. There is no promised protection against
            self-dealing, parking in approved custody, market loss or
            unavailable liquidity.
          </p>
        </article>
        <aside>
          <section className="panel contract-panel">
            <h2>Verified deployment</h2>
            <DataRow label="Network" value="Ethereum · 1" />
            <DataRow
              label="Integrity"
              value={!s ? "Checking…" : s.integrity ? "Matched" : "Mismatch"}
            />
            <DataRow
              label="Current supply"
              value={
                s ? `${amount(s.token.totalSupply, 18, 0)} MAD` : "Unavailable"
              }
            />
            {Object.entries(rt.addresses).map(([n, a]) => (
              <div className="contract-row" key={n}>
                <strong>{n}</strong>
                <AddressLink address={a} explorer={rt.d.network.explorer} />
              </div>
            ))}
            <div className="contract-row">
              <strong>Bound distributor</strong>
              {s &&
              s.token.swarm !== "0x0000000000000000000000000000000000000000" ? (
                <AddressLink
                  address={s.token.swarm}
                  explorer={rt.d.network.explorer}
                />
              ) : (
                <span>{s ? "Not captured" : "Unavailable"}</span>
              )}
            </div>
            <p className="field-help">
              Distributor claims are unavailable here: the handoff contains no
              verified distributor ABI, claim tree or wallet proofs. Its
              original cliff still applies; trading must also be enabled.
            </p>
            <div className="contract-row">
              <strong>Fixed contract owner</strong>
              {s ? (
                <AddressLink
                  address={s.token.owner}
                  explorer={rt.d.network.explorer}
                />
              ) : (
                <span>Unavailable</span>
              )}
            </div>
            <a
              className="quiet-link"
              href={`${rt.d.network.explorer}/tx/${(rt.d as any).contracts[0].txHash}`}
              target="_blank"
              rel="noreferrer"
            >
              Deployment transaction <ExternalLink size={14} />
            </a>
            <p className="field-help address">
              Source commit: {rt.d.sourceCommit}
            </p>
          </section>
        </aside>
      </div>
      <section className="revenue-section">
        <div className="section-heading">
          <h2>Playground revenue</h2>
          <span>Existing project {rt.d.revenue.projectId}</span>
        </div>
        <p>
          MAD’s payout sends only Playground FWA claims directly from the
          PoolManager to the fixed receiver. NFT funds remain separate. It does
          not convert FWA or pay a site visitor.
        </p>
        <div className="revenue-grid">
          <div className="panel">
            <DataRow
              label="Hook FWA claims"
              value={
                s ? `${exact(s.hook.playgroundFwaClaims)} FWA` : "Unavailable"
              }
            />
            <DataRow
              label="FWA held by receiver"
              value={s ? `${exact(s.receiverHeld)} FWA` : "Unavailable"}
            />
            <DataRow
              label="Receiver registration"
              value={
                !s ? "Checking…" : s.revenueVerified ? "Confirmed" : "Mismatch"
              }
            />
            <div className="button-row">
              <button
                className="button"
                disabled={
                  !canWrite ||
                  !s?.revenueVerified ||
                  s.hook.playgroundFwaClaims === 0n
                }
                onClick={() =>
                  void tx.prepare({
                    title: "Pay Playground FWA revenue",
                    address: rt.addresses.MadHook,
                    abi: ABI.MadHook,
                    functionName: "payout",
                    details: [
                      {
                        label: "Immutable receiver",
                        value: rt.d.revenue.receiver,
                      },
                      {
                        label: "Claims",
                        value: `${exact(s!.hook.playgroundFwaClaims)} FWA`,
                      },
                      {
                        label: "Payout",
                        value:
                          "Redeems only available physical FWA directly to the registered receiver. This does not convert or distribute ETH.",
                      },
                    ],
                    check: (fresh) => {
                      if (!fresh.revenueVerified)
                        throw Error(
                          "Receiver registration could not be verified.",
                        );
                    },
                  })
                }
              >
                Review FWA payout
              </button>
              <button
                className="button"
                disabled={!canWrite || !s || s.hook.pendingBurnClaims === 0n}
                onClick={() =>
                  void tx.prepare({
                    title: "Burn deferred excess FWA",
                    address: rt.addresses.MadHook,
                    abi: ABI.MadHook,
                    functionName: "burnExcess",
                    details: [
                      {
                        label: "Pending burn claims",
                        value: `${exact(s!.hook.pendingBurnClaims)} FWA`,
                      },
                      {
                        label: "Effect",
                        value:
                          "Burns only excess fee claims backed by currently available physical FWA. Revenue claims are preserved.",
                      },
                    ],
                  })
                }
              >
                Review excess burn
              </button>
            </div>
            <p className="field-help">
              No wallet payment is requested. Public keeper calls cost network
              gas.
            </p>
          </div>
          <div>
            <div className="contract-row">
              <strong>Immutable fee receiver</strong>
              <AddressLink
                address={rt.d.revenue.receiver}
                explorer={rt.d.network.explorer}
              />
            </div>
            <div className="contract-row">
              <strong>Playground hub</strong>
              <AddressLink
                address={rt.d.revenue.hub}
                explorer={rt.d.network.explorer}
              />
            </div>
            <p>
              Held FWA is not claimable ETH. The Playground owner must configure
              a conversion adapter, then an active member or authorized swap
              operator can convert. This site does not offer receiver
              conversions or invent an adapter.
            </p>
            <p>
              ETH sent to the receiver waits until anyone calls depositETH().
              Never send plain ETH to the hub; it reverts. The hub handles
              deposits, membership, rounding and claims.
            </p>
            <p>
              Deposited ETH splits 50% to the original creator, 30% among other
              active members and 20% to the fixed Tokenworks splitter. With no
              other active members, the creator receives 80%. These are
              downstream hub rules, not new MAD fees.
            </p>
            <Notice>
              The parent objective identifies this receiver as its IMD payer. No
              personal claimable ETH is inferred from receiver holdings; a
              verified hub claim ABI is not included. This site does not add a
              payment or hub management flow.
            </Notice>
          </div>
        </div>
      </section>
    </>
  );
}
