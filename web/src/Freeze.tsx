import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { isAddress, zeroAddress } from "viem";
import {
  ArrowRight,
  Snowflake,
  Clock3,
  Flame,
  ArrowUpRight,
  ScanLine,
} from "lucide-react";
import { ABI } from "./config";
import type { PageProps } from "./App";
import { targetState, walletState, read, errText } from "./chain";
import { useTransactions } from "./Transactions";
import {
  amount,
  exact,
  date,
  DataRow,
  Notice,
  Status,
  AddressLink,
} from "./ui";
export function FreezePage({ rt, state, wallet }: PageProps) {
  const [input, setInput] = useState(""),
    [target, setTarget] = useState<`0x${string}`>(),
    [error, setError] = useState("");
  const tx = useTransactions();
  const query = useQuery({
    queryKey: ["target", target],
    queryFn: () => targetState(rt, target!),
    enabled: !!target,
    retry: 1,
    refetchInterval: 25000,
  });
  const s = state.data,
    t = query.data;
  const targetIsCurrent =
    !!t && t.address.toLowerCase() === input.trim().toLowerCase();
  const core =
    target &&
    [zeroAddress, ...Object.values(rt.addresses), s?.token.factory].some(
      (a) => a?.toLowerCase() === target.toLowerCase(),
    );
  const blocked = !s
    ? "Waiting for live contract state."
    : !state.safe
      ? "Fresh verified state is required."
      : !s.token.trading
        ? "Trading has not been enabled by the contract owner."
        : !wallet.address
          ? "Connect a wallet to freeze this holder."
          : wallet.chainId !== 1
            ? "Switch to Ethereum before freezing."
            : wallet.isError
              ? "Wallet balance is unavailable."
              : !wallet.data
                ? "Reading your wallet…"
                : !wallet.data.isEOA
                  ? "A direct wallet with no contract code is required."
                  : !targetIsCurrent
                    ? "Inspect a target wallet first."
                    : query.isError
                      ? "Target state is unavailable."
                      : core || t?.distributor
                        ? "Core contracts and exempt distributors cannot be targeted."
                        : target?.toLowerCase() === wallet.address.toLowerCase()
                          ? "You cannot freeze your own address."
                          : t?.cost === 0n
                            ? "This target has no payable freeze cost."
                            : t && wallet.data.mad < t.cost
                              ? "Your MAD balance is below the freeze cost."
                              : s.block.number < s.blocks[0]
                                ? "The next round opens in the following block."
                                : "";
  function inspect() {
    setError("");
    const a = input.trim();
    if (!isAddress(a)) {
      setError(
        "Enter a complete Ethereum wallet address (0x followed by 40 hex characters).",
      );
      return;
    }
    setTarget(a);
    if (target === a) void query.refetch();
  }
  async function freeze() {
    if (!t || blocked) return;
    const cost = t.cost;
    await tx.prepare({
      title: "Freeze this holder",
      address: rt.addresses.MadToken,
      abi: ABI.MadToken,
      functionName: "freeze",
      args: [t.address],
      details: [
        { label: "Target", value: t.address },
        {
          label: "Current cost",
          value: `${exact(cost)} MAD (${cost} base units)`,
        },
        { label: "Burned", value: `${exact(cost / 2n)} MAD` },
        {
          label: "Credited to target",
          value: `${exact(cost - cost / 2n)} MAD`,
        },
        {
          label: "Duration",
          value: "Resets the target’s lock to 24 hours from execution.",
        },
        {
          label: "Cost can change",
          value:
            "The contract has no maximum-cost argument. Target balance changes before mining can change the amount you pay.",
        },
      ],
      check: async (fresh, address) => {
        if (!fresh.token.trading) throw Error("Trading is closed.");
        const next = await targetState(rt, t.address);
        const w = await walletState(rt, address, fresh.round);
        if (next.cost !== cost)
          throw Error(
            "Freeze cost changed. Inspect the target and review the new cost.",
          );
        if (w.mad < next.cost || !w.isEOA)
          throw Error("This wallet cannot fund or execute the freeze.");
        if (next.distributor)
          throw Error("The target is an exempt distributor.");
      },
    });
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Freeze a holder.</h1>
          <p>Pay MAD to freeze holders and compete for NFT prizes.</p>
        </div>
        <a className="quiet-link" href="#protocol">
          Understand the rules <ArrowUpRight size={16} />
        </a>
      </div>
      <div className="freeze-layout">
        <section className="freeze-panel panel">
          <div className="panel-heading">
            <h2>Make your move</h2>
            <Snowflake size={22} />
          </div>
          <p className="panel-description">
            Lock a holder’s outgoing MAD for 24 hours.
          </p>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              inspect();
            }}
            noValidate
          >
            <label htmlFor="target">Target wallet</label>
            <div className="input-action">
              <input
                id="target"
                name="target"
                type="text"
                autoComplete="off"
                autoCapitalize="off"
                spellCheck={false}
                placeholder="0x…"
                value={input}
                onChange={(e) => {
                  setInput(e.target.value);
                  setError("");
                }}
                aria-invalid={!!error}
                aria-describedby="target-help target-error"
              />
              <button
                className="button primary"
                disabled={query.isFetching}
                type="submit"
              >
                <ScanLine size={17} />
                {query.isFetching ? "Inspecting…" : "Inspect wallet"}
              </button>
            </div>
            <span id="target-help" className="field-help">
              Cost: 1% of the target’s current MAD balance.
            </span>
            <p
              id="target-error"
              role={error ? "alert" : undefined}
              className="error"
            >
              {error}
            </p>
          </form>
          {query.isError && (
            <Notice tone="error">
              Target unavailable. {errText(query.error)} Inspect again to retry.
            </Notice>
          )}
          {t && targetIsCurrent && !query.isError && (
            <div className="target-details">
              <DataRow
                label="Target balance"
                value={`${amount(t.balance)} MAD`}
              />
              <DataRow label="Freeze cost" value={`${exact(t.cost)} MAD`} />
              <DataRow
                label="Burn / target credit"
                value={`${exact(t.cost / 2n)} / ${exact(t.cost - t.cost / 2n)} MAD`}
              />
              <DataRow
                label="Current lock"
                value={
                  t.until > BigInt(Math.floor(state.now / 1000))
                    ? date(t.until)
                    : "Unfrozen"
                }
              />
              <button
                className="button primary full"
                disabled={!!blocked || tx.busy}
                onClick={() => void freeze()}
              >
                Review freeze <ArrowRight size={17} />
              </button>
              {blocked && <p className="field-help">{blocked}</p>}
            </div>
          )}
          {!t && (
            <div className="freeze-explainer">
              <div>
                <Flame size={19} />
                <span>Half the cost burns</span>
              </div>
              <div>
                <ArrowUpRight size={19} />
                <span>Half goes to the target</span>
              </div>
              <div>
                <Clock3 size={19} />
                <span>The lock resets to 24h</span>
              </div>
            </div>
          )}
          <div className="availability">
            <Status ok={!!s?.token.trading && state.safe}>
              {!s
                ? "Checking protocol"
                : !s.token.trading
                  ? "Awaiting trading enablement"
                  : state.stale
                    ? "State is stale"
                    : "Freezes are open"}
            </Status>
            <span>Direct wallets only</span>
          </div>
        </section>
        <aside className="freeze-aside">
          <div className="freeze-visual" aria-hidden="true">
            <div className="orbit orbit-one" />
            <div className="orbit orbit-two" />
            <div className="orbit orbit-three" />
            <div className="ice-symbol">
              <Snowflake strokeWidth={1} size={112} />
            </div>
            <span className="visual-24">24h</span>
            <span className="visual-text">24-hour outgoing transfer lock</span>
          </div>
          <div className="round-preview">
            <div className="panel-heading">
              <h2>{s?.round ? `Round ${s.round}` : "Next round"}</h2>
              <TrophyMark />
            </div>
            <DataRow
              label="Status"
              value={
                !s
                  ? "Loading…"
                  : s.token.trading
                    ? "In progress"
                    : "Not started"
              }
            />
            <DataRow
              label="Leader spending"
              value={s ? `${amount(s.leaderSpent)} MAD` : "Unavailable"}
            />
            <a href="#rounds">
              Explore NFT rewards <ArrowRight size={16} />
            </a>
          </div>
        </aside>
      </div>
      <div className="protocol-metrics">
        <div>
          <span>Freeze duration</span>
          <strong>
            24 <small>hours</small>
          </strong>
        </div>
        <div>
          <span>Freeze cost</span>
          <strong>
            1% <small>of target balance</small>
          </strong>
        </div>
        <div>
          <span>Hook fee now</span>
          <strong>
            {s ? `${Number(s.hook.feeBps) / 100}%` : "Unavailable"}
          </strong>
          <span>
            {s?.token.trading
              ? "Plus the 1.25% pool fee"
              : "Starts at enablement; plus 1.25% pool fee"}
          </span>
        </div>
        <div>
          <span>Retained NFT prizes</span>
          <strong>{s ? String(s.rewards.prizeCount) : "Unavailable"}</strong>
          <span>Acquired through FWA V2</span>
        </div>
      </div>
      <section className="rules-strip">
        <h2>A freeze has consequences.</h2>
        <p>
          Frozen holders can receive MAD and freeze others. They cannot send or
          sell MAD until their lock expires. A later freeze resets the timer.
        </p>
        <a href="#protocol">
          Read all rules & risks <ArrowUpRight size={16} />
        </a>
      </section>
    </>
  );
}
function TrophyMark() {
  return <span className="round-symbol">↗</span>;
}
