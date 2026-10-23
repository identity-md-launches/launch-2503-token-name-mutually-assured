import { useEffect, useRef, useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useSwitchChain,
  type Connector,
} from "wagmi";
import { Wallet, X, LogOut, ArrowUpRight } from "lucide-react";
import { getAddress } from "viem";
import type { Runtime } from "./config";
import { errText } from "./chain";
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const coinbase =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28"><rect width="28" height="28" rx="7" fill="#2C5FF6"/><circle cx="14" cy="14" r="9.8" fill="white"/><rect x="10.8" y="10.8" width="6.4" height="6.4" rx=".75" fill="#2C5FF6"/></svg>';
const mobileWallets = [
  {
    id: "metamask",
    name: "MetaMask",
    href: (u: string) =>
      `https://link.metamask.io/dapp/${u.replace(/^https?:\/\//, "")}`,
  },
  {
    id: "coinbase",
    name: "Coinbase Wallet",
    href: (u: string) =>
      `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(u)}`,
  },
  {
    id: "rabby",
    name: "Rabby",
    href: (u: string) =>
      `https://go.rabby.io/mobile/?_cmd=open-dapp&dapp=${encodeURIComponent(u)}`,
  },
  {
    id: "phantom",
    name: "Phantom",
    href: (u: string) =>
      `https://phantom.app/ul/browse/${encodeURIComponent(u)}?ref=${encodeURIComponent(new URL(u).origin)}`,
  },
];
export function WalletControl({ rt }: { rt: Runtime }) {
  const { address, isConnected, chainId } = useAccount();
  const { connectors, connectAsync, isPending, variables } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChainAsync, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(false),
    [error, setError] = useState("");
  const dialog = useRef<HTMLDialogElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const mobile =
    /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) &&
    !connectors.some((c) => c.type === "injected" && c.id !== "injected") &&
    !(window as any).ethereum;
  useEffect(() => {
    if (open) {
      dialog.current?.showModal();
    } else if (dialog.current?.open) {
      dialog.current.close();
      trigger.current?.focus();
    }
  }, [open]);
  useEffect(() => {
    setError("");
    if (isConnected) setOpen(false);
  }, [address, isConnected]);
  const named = connectors.some(
    (c) => c.type === "injected" && c.id !== "injected",
  );
  const listed = [
    ...connectors.filter((c) => c.type === "injected"),
    ...connectors.filter((c) => c.type !== "injected"),
  ].filter(
    (c) =>
      !(c.id === "injected" && named) && (!mobile || c.type !== "injected"),
  );
  async function choose(c: Connector) {
    setError("");
    try {
      await connectAsync({ connector: c });
      setOpen(false);
    } catch (e) {
      setError(errText(e));
    }
  }
  async function switchNetwork() {
    setError("");
    try {
      await switchChainAsync({
        chainId: 1,
        addEthereumChainParameter: rt.d.walletAddChain as any,
      });
    } catch (e) {
      setError(errText(e));
    }
  }
  return (
    <div className="wallet-control">
      {isConnected && address ? (
        <>
          <button
            ref={trigger}
            className="button wallet-button"
            onClick={() =>
              chainId !== 1 ? void switchNetwork() : setOpen(true)
            }
          >
            <Wallet size={16} />
            {switching
              ? "Switching…"
              : chainId !== 1
                ? "Switch to Ethereum"
                : short(getAddress(address))}
          </button>
        </>
      ) : (
        <button
          ref={trigger}
          className="button wallet-button"
          onClick={() => setOpen(true)}
        >
          <Wallet size={16} />
          Connect<span className="desktop-only"> wallet</span>
        </button>
      )}
      {error && !open && (
        <span className="wallet-error" role="alert">
          {error}
        </span>
      )}
      <dialog
        ref={dialog}
        className="wallet-dialog"
        aria-labelledby="wallet-title"
        onCancel={() => setOpen(false)}
        onClick={(e) => {
          if (e.target === dialog.current) setOpen(false);
        }}
      >
        <div className="dialog-head">
          <h2 id="wallet-title">
            {isConnected ? "Connected wallet" : "Connect a wallet"}
          </h2>
          <button
            className="icon-button"
            aria-label="Close wallet chooser"
            onClick={() => setOpen(false)}
          >
            <X />
          </button>
        </div>
        {isConnected && address ? (
          <>
            <p className="address">{getAddress(address)}</p>
            <p>Ethereum mainnet · Chain 1</p>
            {chainId !== 1 && (
              <button
                className="button primary"
                onClick={() => void switchNetwork()}
              >
                Switch to Ethereum
              </button>
            )}
            <button
              className="wallet-row"
              onClick={() => {
                disconnect();
                setOpen(false);
              }}
            >
              <LogOut size={24} />
              Disconnect
            </button>
          </>
        ) : (
          <>
            <p className="muted">
              Browse freely. Every transaction needs your confirmation.
            </p>
            {mobile &&
              mobileWallets.map((w) => (
                <a
                  key={w.id}
                  className="wallet-row"
                  href={w.href(location.href)}
                >
                  <img
                    width="28"
                    height="28"
                    src={`${import.meta.env.BASE_URL}wallets/${w.id}.svg`}
                    alt=""
                  />
                  Open in {w.name}
                  <ArrowUpRight size={16} />
                </a>
              ))}
            {listed.map((c) => (
              <button
                key={c.uid}
                className="wallet-row"
                disabled={isPending}
                onClick={() => void choose(c)}
              >
                {c.icon ? (
                  <img width="28" height="28" src={c.icon} alt="" />
                ) : c.id === "coinbaseWalletSDK" ? (
                  <img
                    width="28"
                    height="28"
                    src={`data:image/svg+xml,${encodeURIComponent(coinbase)}`}
                    alt=""
                  />
                ) : (
                  <Wallet size={28} />
                )}
                <span>
                  {c.id === "injected"
                    ? "Browser wallet"
                    : c.id === "coinbaseWalletSDK" && mobile
                      ? "Coinbase Smart Wallet"
                      : c.name}
                  {isPending &&
                  (variables?.connector as Connector)?.uid === c.uid
                    ? " · opening…"
                    : ""}
                </span>
              </button>
            ))}
          </>
        )}
        {error && (
          <p role="alert" className="error">
            {error}
          </p>
        )}
      </dialog>
    </div>
  );
}
