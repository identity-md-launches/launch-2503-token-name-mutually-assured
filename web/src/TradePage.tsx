import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { parseUnits, type Address } from "viem";
import {
  ArrowDown,
  ArrowLeftRight,
  ArrowRight,
  ShieldCheck,
} from "lucide-react";
import type { PageProps } from "./App";
import {
  ERC20,
  PERMIT2,
  ROUTER,
  ext,
  snapshot,
  walletState,
  errText,
} from "./chain";
import {
  quoteWithinTick,
  routerArguments,
  assertFreshQuote,
  type Quote,
} from "./trade";
import { useTransactions } from "./Transactions";
import { amount, exact, date, DataRow, Notice, AddressLink } from "./ui";
export function TradePage({ rt, state, wallet }: PageProps) {
  const [buy, setBuy] = useState(true),
    [input, setInput] = useState(""),
    [slippage, setSlippage] = useState(""),
    [minutes, setMinutes] = useState("5"),
    [quote, setQuote] = useState<Quote>(),
    [error, setError] = useState(""),
    [quoting, setQuoting] = useState(false);
  const tx = useTransactions();
  const s = state.data;
  const pair = rt.d.poolKey.currency0;
  const inputToken = buy ? pair : rt.addresses.MadToken;
  const inputSymbol = buy ? "FWA" : "MAD",
    outputSymbol = buy ? "MAD" : "FWA";
  const approvalQuery = useQuery({
    queryKey: ["allowance", wallet.address, inputToken],
    enabled: !!wallet.address,
    queryFn: async () => {
      const [erc, permit] = await Promise.all([
        ext(rt, inputToken, ERC20, "allowance", [
          wallet.address!,
          rt.d.network.uniswapV4.permit2,
        ]),
        ext(rt, rt.d.network.uniswapV4.permit2, PERMIT2, "allowance", [
          wallet.address!,
          inputToken,
          rt.d.network.uniswapV4.universalRouter,
        ]),
      ]);
      return { erc: erc as bigint, permit: permit as [bigint, number, number] };
    },
    refetchInterval: 25000,
    retry: 1,
  });
  function reset() {
    setQuote(undefined);
    setError("");
  }
  async function getQuote() {
    setError("");
    setQuote(undefined);
    setQuoting(true);
    try {
      if (!input || !slippage)
        throw Error("Enter an amount and select your slippage.");
      const fresh = await snapshot(rt);
      if (!fresh.integrity) throw Error("Deployment verification failed.");
      if (!fresh.token.trading)
        throw Error(
          "Trading is closed. Only the contract owner can enable it.",
        );
      if (!fresh.routerApproved)
        throw Error("The verified Universal Router is not currently approved.");
      if (fresh.pairDecimals !== 18 || fresh.pairSymbol !== "FWA")
        throw Error(
          "Base currency metadata differs from the verified FWA route.",
        );
      if (!/^[0-9]+(?:\.[0-9]{1,18})?$/.test(input))
        throw Error(
          "Enter a decimal amount with at most 18 fractional digits.",
        );
      const a = parseUnits(input, 18);
      const p = rt.d.poolKey;
      const q = quoteWithinTick(
        {
          ...p,
          sqrt: fresh.slot[0],
          tick: fresh.slot[1],
          protocolFee: fresh.slot[2],
          lpFee: fresh.slot[3],
          liquidity: fresh.liquidity,
          hookBps: Number(fresh.hook.feeBps),
        },
        a,
        buy,
        Number(slippage),
      );
      setQuote({
        ...q,
        block: fresh.block.number,
        createdAt: Date.now(),
        deadline: fresh.block.timestamp + BigInt(Number(minutes) * 60),
        buy,
        slippageBps: Number(slippage),
      });
    } catch (e) {
      setError(errText(e));
    } finally {
      setQuoting(false);
    }
  }
  const quoteExpired =
    !!quote &&
    (state.now - quote.createdAt > 30000 ||
      quote.deadline <= BigInt(Math.floor(state.now / 1000)));
  const balance = buy ? wallet.data?.fwa : wallet.data?.mad;
  const allowances = approvalQuery.data;
  const ercNeeded = !!quote && !!allowances && allowances.erc < quote.amount;
  const permitNeeded =
    !!quote &&
    !!allowances &&
    (allowances.permit[0] < quote.amount ||
      BigInt(allowances.permit[1]) <= BigInt(Math.floor(state.now / 1000)));
  const baseBlocked = !wallet.address
    ? "Connect a wallet before approving or swapping."
    : wallet.chainId !== 1
      ? "Switch to Ethereum before transacting."
      : !state.safe
        ? "Fresh verified state is required."
        : !s?.token.trading
          ? "Trading has not been enabled."
          : !s.routerApproved
            ? "The verified router is not approved."
            : !wallet.data || wallet.isError
              ? "Wallet balances are unavailable."
              : !buy &&
                  wallet.data.frozenUntil > BigInt(Math.floor(state.now / 1000))
                ? "This wallet is frozen and cannot sell MAD."
                : balance !== undefined && quote && balance < quote.amount
                  ? "Insufficient input balance."
                  : approvalQuery.isError
                    ? "Allowances are unavailable. Retry the reads."
                    : !allowances
                      ? "Reading allowances…"
                      : quoteExpired
                        ? "This quote expired. Get a fresh quote."
                        : "";
  async function approval(kind: "erc20" | "permit") {
    if (!quote || baseBlocked) return;
    const q = quote;
    const tokenName = inputSymbol;
    const spender =
      kind === "erc20"
        ? rt.d.network.uniswapV4.permit2
        : rt.d.network.uniswapV4.universalRouter;
    await tx.prepare({
      title: `Approve ${exact(q.amount)} ${tokenName}`,
      address: kind === "erc20" ? inputToken : rt.d.network.uniswapV4.permit2,
      abi: kind === "erc20" ? ERC20 : PERMIT2,
      functionName: "approve",
      args:
        kind === "erc20"
          ? [spender, q.amount]
          : [inputToken, spender, q.amount, Number(q.deadline)],
      details: [
        { label: "Token", value: inputToken },
        { label: "Spender", value: spender },
        {
          label: "Exact approval",
          value: `${exact(q.amount)} ${tokenName} (${q.amount} base units)`,
        },
        {
          label: "Expiry",
          value:
            kind === "erc20"
              ? "ERC20 approvals have no expiry. This approval is limited to the input amount."
              : date(q.deadline),
        },
        {
          label: "Purpose",
          value:
            kind === "erc20"
              ? "Permit2 pulls only the approved token amount. A separate router approval and swap confirmation follow."
              : "Universal Router may spend this amount through Permit2 until the displayed expiry.",
        },
      ],
      check: (fresh) => {
        assertFreshQuote(q);
        if (!fresh.token.trading) throw Error("Trading is closed.");
      },
      onConfirmed: () => {
        setQuote(undefined);
        setError("Approval confirmed. Get a fresh quote to continue.");
      },
    });
  }
  async function swap() {
    if (!quote || baseBlocked || ercNeeded || permitNeeded) return;
    const q = quote;
    const key = rt.d.poolKey;
    await tx.prepare({
      title: `Swap ${inputSymbol} for ${outputSymbol}`,
      address: rt.d.network.uniswapV4.universalRouter,
      abi: ROUTER,
      functionName: "execute",
      args: routerArguments(key, q),
      details: [
        { label: "Input", value: `${exact(q.amount)} ${inputSymbol}` },
        {
          label: "Expected output",
          value: `${exact(q.output)} ${outputSymbol}`,
        },
        {
          label: "Minimum output",
          value: `${exact(q.minimum)} ${outputSymbol} (${q.minimum} base units)`,
        },
        { label: "Slippage", value: `${q.slippageBps / 100}%` },
        { label: "Deadline", value: date(q.deadline) },
        { label: "Recipient", value: wallet.address! },
        { label: "Pool", value: rt.d.poolId },
        {
          label: "Price impact",
          value: `${q.impactBps / 100}% excluding fees`,
        },
      ],
      check: async (fresh, address) => {
        assertFreshQuote(q);
        if (!fresh.token.trading || !fresh.routerApproved)
          throw Error("Trading or router permission changed.");
        const ws = await walletState(rt, address, fresh.round);
        if ((q.buy ? ws.fwa : ws.mad) < q.amount)
          throw Error("Input balance is insufficient.");
        if (!q.buy && ws.frozenUntil > fresh.block.timestamp)
          throw Error("Your MAD is frozen.");
        const check = quoteWithinTick(
          {
            ...key,
            sqrt: fresh.slot[0],
            tick: fresh.slot[1],
            liquidity: fresh.liquidity,
            protocolFee: fresh.slot[2],
            lpFee: fresh.slot[3],
            hookBps: Number(fresh.hook.feeBps),
          },
          q.amount,
          q.buy,
          q.slippageBps,
        );
        if (check.output < q.minimum)
          throw Error(
            "Price moved beyond your minimum output. Get a new quote.",
          );
      },
      onConfirmed: () => {
        setQuote(undefined);
        void approvalQuery.refetch();
      },
    });
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Trade MAD.</h1>
          <p>The verified MAD / FWA pool on Uniswap v4.</p>
        </div>
        <ArrowLeftRight className="heading-icon" size={32} />
      </div>
      <div className="two-column">
        <section className="panel trade-panel">
          <div className="segmented" aria-label="Trade direction">
            <button
              aria-pressed={buy}
              className={buy ? "active" : ""}
              onClick={() => {
                setBuy(true);
                reset();
              }}
            >
              Buy MAD
            </button>
            <button
              aria-pressed={!buy}
              className={!buy ? "active" : ""}
              onClick={() => {
                setBuy(false);
                reset();
              }}
            >
              Sell MAD
            </button>
          </div>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void getQuote();
            }}
          >
            <label htmlFor="swap-amount">You pay in {inputSymbol}</label>
            <div className="token-input">
              <input
                id="swap-amount"
                inputMode="decimal"
                type="text"
                autoComplete="off"
                placeholder="0.00"
                value={input}
                onChange={(e) => {
                  setInput(e.target.value);
                  reset();
                }}
              />
              <span>{inputSymbol}</span>
            </div>
            <span className="field-help">
              Balance:{" "}
              {wallet.address
                ? wallet.isError
                  ? "Unavailable"
                  : `${amount(balance)} ${inputSymbol}`
                : "Connect to view"}
            </span>
            <div className="swap-arrow">
              <ArrowDown size={18} />
            </div>
            <label htmlFor="swap-output">
              Estimated {outputSymbol} received
            </label>
            <div className="token-input">
              <output id="swap-output">
                {quote ? exact(quote.output) : "Awaiting quote"}
              </output>
              <span>{outputSymbol}</span>
            </div>
            <div className="form-grid">
              <label>
                Slippage
                <select
                  value={slippage}
                  onChange={(e) => {
                    setSlippage(e.target.value);
                    reset();
                  }}
                  required
                >
                  <option value="">Choose</option>
                  <option value="10">0.1%</option>
                  <option value="50">0.5%</option>
                  <option value="100">1%</option>
                  <option value="200">2%</option>
                  <option value="500">5%</option>
                </select>
              </label>
              <label>
                Deadline
                <select
                  value={minutes}
                  onChange={(e) => {
                    setMinutes(e.target.value);
                    reset();
                  }}
                >
                  <option value="5">5 minutes</option>
                  <option value="10">10 minutes</option>
                  <option value="20">20 minutes</option>
                </select>
              </label>
            </div>
            <button
              type="submit"
              className="button primary full"
              disabled={
                quoting ||
                !state.safe ||
                !s?.token.trading ||
                s.liquidity === 0n
              }
            >
              {quoting ? "Reading quote…" : "Get quote"}
              <ArrowRight size={17} />
            </button>
          </form>
          {(!s?.token.trading || s.liquidity === 0n) && (
            <Notice tone="warning">
              {!s
                ? "Reading market state…"
                : !s.token.trading
                  ? "Trading is closed. The owner has not enabled the token."
                  : "There is no active liquidity. Swaps and quotes are unavailable."}
              {s && !s.token.trading && s.liquidity === 0n
                ? " The pool also has no active liquidity."
                : ""}
            </Notice>
          )}
          {error && (
            <p role="alert" className="error">
              {error}
            </p>
          )}
          {quote && (
            <>
              <dl className="detail-list">
                <div>
                  <dt>Minimum received</dt>
                  <dd>
                    {exact(quote.minimum)} {outputSymbol}
                  </dd>
                </div>
                <div>
                  <dt>Hook fee</dt>
                  <dd>{exact(quote.hookFee)} FWA</dd>
                </div>
                <div>
                  <dt>LP input fee</dt>
                  <dd>
                    {exact(quote.lpInputFee)} {inputSymbol}
                  </dd>
                </div>
                <div>
                  <dt>Price impact, excluding fees</dt>
                  <dd>{quote.impactBps / 100}%</dd>
                </div>
                <div>
                  <dt>Quote block</dt>
                  <dd>
                    {String(quote.block)} ·{" "}
                    {quoteExpired ? "Expired" : "Valid for 30 seconds"}
                  </dd>
                </div>
              </dl>
              {baseBlocked && <p className="field-help">{baseBlocked}</p>}
              {ercNeeded ? (
                <button
                  className="button primary full"
                  disabled={!!baseBlocked || tx.busy}
                  onClick={() => void approval("erc20")}
                >
                  Review token approval
                </button>
              ) : permitNeeded ? (
                <button
                  className="button primary full"
                  disabled={!!baseBlocked || tx.busy}
                  onClick={() => void approval("permit")}
                >
                  Review router allowance
                </button>
              ) : (
                <button
                  className="button primary full"
                  disabled={!!baseBlocked || tx.busy}
                  onClick={() => void swap()}
                >
                  Review swap
                </button>
              )}
            </>
          )}
          {approvalQuery.isError && (
            <button
              className="button"
              onClick={() => void approvalQuery.refetch()}
            >
              Retry allowances
            </button>
          )}
        </section>
        <aside className="side-notes">
          <h2>One verified route</h2>
          <DataRow label="Pair" value="MAD / FWA" />
          <DataRow label="LP fee" value="1.25%" />
          <DataRow
            label="Hook fee"
            value={s ? `${Number(s.hook.feeBps) / 100}%` : "Unavailable"}
          />
          <DataRow
            label="Active liquidity"
            value={
              s ? (s.liquidity > 0n ? "Available" : "None") : "Unavailable"
            }
          />
          <p>
            The hook charges FWA in both directions. It starts at 99% when
            trading opens and falls to 1% over 30 minutes. The pool fee is
            separate.
          </p>
          <Notice>
            Native ETH trading is not offered. The verified MAD pool is paired
            with FWA.
          </Notice>
          <h3>Protected before you sign</h3>
          <p>
            Two exact-amount approvals may be needed: token to Permit2, then
            Permit2 to Universal Router. Each approval and swap has its own
            simulation, review and wallet confirmation.
          </p>
          <p>
            Quotes use live pool state and verified fee math. This site quotes
            only within the current tick interval; larger trades must be
            reduced. A full router simulation must also pass.
          </p>
          <AddressLink
            address={rt.d.network.uniswapV4.universalRouter}
            explorer={rt.d.network.explorer}
            label="View Universal Router"
          />
          <a className="quiet-link" href="#protocol">
            Read transfer restrictions <ArrowRight size={16} />
          </a>
        </aside>
      </div>
    </>
  );
}
