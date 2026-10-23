import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import {
  Snowflake,
  ArrowLeftRight,
  Trophy,
  Activity,
  BookOpen,
  Settings2,
  ArrowUpRight,
  RefreshCw,
  ShieldCheck,
  ArrowRight,
  Radio,
  ExternalLink,
} from "lucide-react";
import type { Runtime } from "./config";
import { snapshot, walletState, errText } from "./chain";
import { WalletControl, short } from "./Wallet";
import { Transactions } from "./Transactions";
import { Notice, amount, exact, date } from "./ui";
import { FreezePage } from "./Freeze";
import { TradePage } from "./TradePage";
import { RoundsPage } from "./Rounds";
import { ActivityPage, ProtocolPage } from "./Information";
import { ManagePage } from "./Manage";
export type PageProps = {
  rt: Runtime;
  state: ReturnType<typeof useSnapshot>;
  wallet: ReturnType<typeof useWallet>;
};
const nav = [
  { id: "freeze", label: "Freeze", icon: Snowflake },
  { id: "trade", label: "Trade", icon: ArrowLeftRight },
  { id: "rounds", label: "NFT rewards", icon: Trophy },
  { id: "activity", label: "Activity", icon: Activity },
  { id: "protocol", label: "How it works", icon: BookOpen },
  { id: "manage", label: "Manage", icon: Settings2 },
];
export function useSnapshot(rt: Runtime) {
  const q = useQuery({
    queryKey: ["snapshot"],
    queryFn: () => snapshot(rt),
    refetchInterval: 25000,
    staleTime: 12000,
    retry: 1,
  });
  const [clock, setClock] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setClock(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  const stale =
    !!q.data &&
    (clock - q.data.receivedAt > 60000 ||
      clock - Number(q.data.block.timestamp) * 1000 > 180000 ||
      q.isError);
  return {
    ...q,
    stale,
    safe: !!q.data?.integrity && !stale && !q.isError,
    now: clock,
  };
}
export function useWallet(rt: Runtime, round: bigint) {
  const { address, isConnected, chainId } = useAccount();
  const q = useQuery({
    queryKey: ["wallet", address, round.toString()],
    queryFn: () => walletState(rt, address!, round),
    enabled: !!address,
    refetchInterval: 25000,
    retry: 1,
  });
  return { ...q, address, isConnected, chainId };
}
export function App({ rt }: { rt: Runtime }) {
  const [page, setPage] = useState(location.hash.slice(1) || "freeze");
  const state = useSnapshot(rt);
  const wallet = useWallet(rt, state.data?.round || 0n);
  useEffect(() => {
    const listener = () => {
      setPage(location.hash.slice(1) || "freeze");
      window.scrollTo({ top: 0 });
    };
    addEventListener("hashchange", listener);
    return () => removeEventListener("hashchange", listener);
  }, []);
  const props = { rt, state, wallet };
  const selected = nav.find((n) => n.id === page) || nav[0];
  return (
    <Transactions rt={rt}>
      <a
        className="skip-link"
        href="#content"
        onClick={(e) => {
          e.preventDefault();
          document.getElementById("content")?.focus();
        }}
      >
        Skip to content
      </a>
      <div className="shell">
        <aside className="sidebar">
          <a className="brand" href="#freeze" aria-label="MAD home">
            <span className="brand-mark">
              <Snowflake size={30} />
            </span>
            <span>
              MAD<span className="brand-sub">Mutually Assured Destruction</span>
            </span>
          </a>
          <nav aria-label="Main navigation">
            {nav.map((n) => (
              <a
                key={n.id}
                href={`#${n.id}`}
                className={selected.id === n.id ? "selected" : ""}
                aria-current={selected.id === n.id ? "page" : undefined}
              >
                <n.icon size={19} />
                <span className="desktop-nav-label">{n.label}</span>
                <span className="mobile-nav-label">
                  {n.id === "rounds"
                    ? "Rewards"
                    : n.id === "protocol"
                      ? "Rules"
                      : n.label}
                </span>
                {selected.id === n.id && (
                  <ArrowUpRight className="nav-arrow" size={16} />
                )}
              </a>
            ))}
          </nav>
          <div className="sidebar-bottom">
            <div className="sidebar-rule" />
            <p>Every move is onchain.</p>
            <a
              href={`${rt.d.network.explorer}/address/${rt.addresses.MadToken}`}
              target="_blank"
              rel="noreferrer"
            >
              View MAD contract <ArrowUpRight size={16} />
            </a>
            <span className="chain-mark">
              <span />
              Ethereum mainnet
            </span>
          </div>
        </aside>
        <div className="workspace">
          <header className="topbar">
            <span className="breadcrumb">
              Control room <span>/</span> {selected.label}
            </span>
            <div className="topbar-actions">
              <span className="network">
                <span className="eth-diamond">♦</span> Ethereum
              </span>
              <WalletControl rt={rt} />
            </div>
          </header>
          <main id="content" tabIndex={-1}>
            <div className="read-status">
              <span>
                <Radio size={14} />
                {state.isPending
                  ? "Reading Ethereum…"
                  : state.isError
                    ? "Live reads unavailable"
                    : state.stale
                      ? "State is stale"
                      : `${state.data?.integrity ? "Verified" : "Deployment mismatch"} at block ${state.data?.block.number.toLocaleString()}`}
              </span>
              <button
                className="refresh-button"
                disabled={state.isFetching}
                onClick={() => void state.refetch()}
              >
                <RefreshCw size={14} />
                {state.isFetching ? "Refreshing…" : "Refresh"}
              </button>
            </div>
            {state.isError && (
              <Notice tone="error">
                {state.data
                  ? "Last successful values remain visible as stale."
                  : "Public state is unavailable."}{" "}
                {errText(state.error)} Use Refresh to retry.
              </Notice>
            )}
            {state.data && !state.data.integrity && (
              <Notice tone="error">
                Contract integrity does not match the verified deployment.
                Transactions are disabled.
              </Notice>
            )}
            {wallet.isConnected && wallet.chainId !== 1 && (
              <Notice tone="warning">
                Your wallet is on another network. Switch to Ethereum using the
                wallet control before any transaction.
              </Notice>
            )}
            {selected.id === "freeze" ? (
              <FreezePage {...props} />
            ) : selected.id === "trade" ? (
              <TradePage {...props} />
            ) : selected.id === "rounds" ? (
              <RoundsPage {...props} />
            ) : selected.id === "activity" ? (
              <ActivityPage {...props} />
            ) : selected.id === "manage" ? (
              <ManagePage {...props} />
            ) : (
              <ProtocolPage {...props} />
            )}
            {selected.id !== "protocol" && (
              <section className="wallet-section">
                <div className="section-heading">
                  <h2>Wallet position</h2>
                  <span>
                    {wallet.address ? short(wallet.address) : "Read-only mode"}
                  </span>
                </div>
                {!wallet.address ? (
                  <div className="wallet-empty">
                    <ShieldCheck size={22} />
                    <p>
                      Connect to see your balances, freeze status and round
                      spending.
                    </p>
                  </div>
                ) : wallet.isPending ? (
                  <p>Reading wallet balances…</p>
                ) : wallet.isError ? (
                  <Notice tone="error">
                    Wallet balances unavailable. {errText(wallet.error)}
                    <button
                      className="button"
                      onClick={() => void wallet.refetch()}
                    >
                      Retry wallet reads
                    </button>
                  </Notice>
                ) : (
                  wallet.data && (
                    <>
                      <div className="position-grid">
                        <div>
                          <span>MAD balance</span>
                          <strong>
                            {amount(wallet.data.mad)} <small>MAD</small>
                          </strong>
                        </div>
                        <div>
                          <span>FWA balance</span>
                          <strong>
                            {amount(wallet.data.fwa)} <small>FWA</small>
                          </strong>
                        </div>
                        <div>
                          <span>ETH for network gas</span>
                          <strong>
                            {exact(wallet.data.eth)} <small>ETH</small>
                          </strong>
                        </div>
                        <div>
                          <span>Round spending</span>
                          <strong>
                            {amount(wallet.data.spent)} <small>MAD</small>
                          </strong>
                        </div>
                        <div>
                          <span>Outgoing transfers</span>
                          <strong>
                            {wallet.data.frozenUntil >
                            BigInt(Math.floor(state.now / 1000))
                              ? "Frozen"
                              : "Unfrozen"}
                          </strong>
                        </div>
                      </div>
                      {wallet.data.frozenUntil >
                        BigInt(Math.floor(state.now / 1000)) && (
                        <p className="field-help">
                          Outgoing MAD remains frozen until{" "}
                          {date(wallet.data.frozenUntil)}. You can still receive
                          MAD or freeze other eligible holders.
                        </p>
                      )}
                      {!wallet.data.isEOA && (
                        <Notice tone="warning">
                          This address has contract code. MAD freezes require a
                          direct wallet with no code; smart accounts and
                          EIP-7702 accounts cannot freeze. Transfers and swap
                          receipts may also be restricted.
                        </Notice>
                      )}
                    </>
                  )
                )}
              </section>
            )}
            <footer>
              <span>
                <Snowflake size={16} /> MAD · Onchain, with consequences.
              </span>
              <a href="#protocol">
                Rules & risks <ArrowUpRight size={14} />
              </a>
              <a
                href={`${rt.d.network.explorer}/address/${rt.addresses.MadHook}`}
                target="_blank"
                rel="noreferrer"
              >
                Verified contracts <ExternalLink size={14} />
              </a>
            </footer>
          </main>
        </div>
      </div>
    </Transactions>
  );
}
