import {
  createContext,
  useContext,
  useRef,
  useState,
  useEffect,
  type ReactNode,
} from "react";
import { useAccount, useWalletClient } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { type Abi, type Address, type Hash, formatEther } from "viem";
import { CheckCircle2, ExternalLink, LoaderCircle, X } from "lucide-react";
import { type Runtime, type ContractName } from "./config";
import { snapshot, read, errText, type Snapshot } from "./chain";
export type Action = {
  title: string;
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
  details: { label: string; value: string }[];
  ownerContract?: ContractName;
  check?: (state: Snapshot, address: Address) => Promise<void> | void;
  onConfirmed?: () => void;
};
type TxState = {
  phase:
    | "idle"
    | "checking"
    | "review"
    | "wallet"
    | "pending"
    | "confirmed"
    | "reverted"
    | "cancelled"
    | "unknown"
    | "error";
  message: string;
  hash?: Hash;
};
const Context = createContext<{
  prepare: (a: Action) => Promise<void>;
  busy: boolean;
}>({ prepare: async () => {}, busy: false });
export const useTransactions = () => useContext(Context);
export function Transactions({
  rt,
  children,
}: {
  rt: Runtime;
  children: ReactNode;
}) {
  const account = useAccount();
  const { data: wallet } = useWalletClient();
  const query = useQueryClient();
  const [tx, setTx] = useState<TxState>({ phase: "idle", message: "" });
  const [action, setAction] = useState<Action>();
  const lock = useRef(false);
  const dialog = useRef<HTMLDialogElement>(null);
  const accountRef = useRef(account);
  accountRef.current = account;
  const reviewAccount = useRef<Address | undefined>(undefined);
  const storageKey = `mad:pending:1:${rt.addresses.MadToken}`;
  const busy = ["checking", "wallet", "pending", "unknown"].includes(tx.phase);
  useEffect(() => {
    if (tx.phase === "review") dialog.current?.showModal();
    else dialog.current?.close();
  }, [tx.phase]);
  async function refresh() {
    await query.invalidateQueries();
  }
  async function wait(hash: Hash, cb?: () => void) {
    try {
      let cancelled = false;
      let replaced = false;
      const receipt = await rt.client.waitForTransactionReceipt({
        hash,
        confirmations: 1,
        timeout: 180000,
        onReplaced: (r) => {
          cancelled = r.reason === "cancelled";
          replaced = r.reason === "replaced";
          const h = r.transaction.hash;
          localStorage.setItem(storageKey, h);
          setTx({
            phase: "pending",
            message: cancelled
              ? "Cancellation pending…"
              : replaced
                ? "Replacement pending…"
                : "Repriced transaction pending…",
            hash: h,
          });
        },
      });
      localStorage.removeItem(storageKey);
      lock.current = false;
      setTx({
        phase: cancelled
          ? "cancelled"
          : receipt.status === "reverted"
            ? "reverted"
            : "confirmed",
        message: cancelled
          ? "Transaction cancelled."
          : receipt.status === "reverted"
            ? "Transaction reverted. Balances have been refreshed."
            : replaced
              ? "Replacement confirmed. Check the receipt for its actual action."
              : "Transaction confirmed. Live state has been refreshed.",
        hash: receipt.transactionHash,
      });
      await refresh();
      if (!cancelled && !replaced && receipt.status === "success") cb?.();
    } catch (e) {
      setTx({
        phase: "unknown",
        message:
          "Confirmation is unavailable. The transaction may still be pending. Check its receipt before sending another transaction.",
        hash,
      });
      lock.current = true;
    }
  }
  useEffect(() => {
    const hash = localStorage.getItem(storageKey);
    if (hash && /^0x[0-9a-f]{64}$/i.test(hash)) {
      lock.current = true;
      setTx({
        phase: "pending",
        message: "Checking your previous pending transaction…",
        hash: hash as Hash,
      });
      void wait(hash as Hash);
    }
  }, []);
  async function preflight(a: Action) {
    const addr = accountRef.current.address;
    if (!accountRef.current.isConnected || !addr)
      throw Error("Connect a wallet to review this transaction.");
    if (accountRef.current.chainId !== 1)
      throw Error("Switch your wallet to Ethereum before continuing.");
    const fresh = await snapshot(rt);
    if (!fresh.integrity)
      throw Error(
        "Deployment integrity could not be verified. Transactions are disabled.",
      );
    if (a.ownerContract) {
      const owner = await read(rt, a.ownerContract, "owner");
      if (owner.toLowerCase() !== addr.toLowerCase())
        throw Error("The connected wallet does not own this contract.");
    }
    await a.check?.(fresh, addr);
    return addr;
  }
  async function prepare(a: Action) {
    if (lock.current || busy) return;
    lock.current = true;
    setTx({
      phase: "checking",
      message: "Checking current state and simulating…",
    });
    try {
      const addr = await preflight(a);
      await rt.client.simulateContract({
        address: a.address,
        abi: a.abi,
        functionName: a.functionName,
        args: a.args || [],
        account: addr,
        value: a.value || 0n,
      });
      reviewAccount.current = addr;
      setAction(a);
      setTx({
        phase: "review",
        message: "Simulation passed. Review the exact transaction.",
      });
    } catch (e) {
      setTx({ phase: "error", message: errText(e) });
      lock.current = false;
    }
  }
  async function confirm() {
    if (!action || tx.phase !== "review" || !wallet) return;
    const a = action;
    setTx({
      phase: "wallet",
      message: "Confirm this transaction in your wallet.",
    });
    try {
      const addr = await preflight(a);
      if (addr.toLowerCase() !== reviewAccount.current?.toLowerCase())
        throw Error("Wallet account changed. Review the transaction again.");
      const [addresses, id] = await Promise.all([
        wallet.getAddresses(),
        wallet.getChainId(),
      ]);
      if (id !== 1 || addresses[0]?.toLowerCase() !== addr.toLowerCase())
        throw Error(
          "Wallet account or network changed. Review the transaction again.",
        );
      const simulation = await rt.client.simulateContract({
        address: a.address,
        abi: a.abi,
        functionName: a.functionName,
        args: a.args || [],
        account: addr,
        value: a.value || 0n,
      });
      const hash = await wallet.writeContract({
        ...simulation.request,
        chain: rt.client.chain,
        account: addr,
      });
      localStorage.setItem(storageKey, hash);
      setTx({
        phase: "pending",
        message: "Submitted. Waiting for an Ethereum receipt…",
        hash,
      });
      await wait(hash, a.onConfirmed);
    } catch (e) {
      setTx({ phase: "error", message: errText(e) });
      lock.current = false;
    }
  }
  function cancel() {
    setAction(undefined);
    lock.current = false;
    setTx({ phase: "idle", message: "" });
  }
  return (
    <Context.Provider value={{ prepare, busy: busy || tx.phase === "review" }}>
      {children}
      {tx.message && tx.phase !== "review" && (
        <div
          className={`transaction-banner ${["error", "reverted", "cancelled"].includes(tx.phase) ? "error" : ""}`}
          role="status"
        >
          <div>
            {tx.phase === "confirmed" ? (
              <CheckCircle2 size={20} />
            ) : busy ? (
              <LoaderCircle size={20} />
            ) : null}
            <span>{tx.message}</span>
          </div>
          {tx.hash && (
            <a
              href={`${rt.d.network.explorer}/tx/${tx.hash}`}
              target="_blank"
              rel="noreferrer"
            >
              View transaction <ExternalLink size={14} />
            </a>
          )}
          {tx.phase === "unknown" && tx.hash && (
            <button
              className="button"
              onClick={() => {
                setTx({ ...tx, phase: "pending" });
                void wait(tx.hash!);
              }}
            >
              Check receipt
            </button>
          )}
          {!busy && (
            <button
              className="icon-button"
              aria-label="Dismiss transaction status"
              onClick={() => setTx({ phase: "idle", message: "" })}
            >
              <X size={18} />
            </button>
          )}
        </div>
      )}
      <dialog
        ref={dialog}
        className="review-dialog"
        aria-labelledby="review-title"
        onCancel={cancel}
        onClick={(e) => {
          if (e.target === dialog.current) cancel();
        }}
      >
        <div className="dialog-head">
          <h2 id="review-title">{action?.title}</h2>
          <button
            className="icon-button"
            aria-label="Close transaction review"
            onClick={cancel}
          >
            <X />
          </button>
        </div>
        <p className="muted">
          Simulation passed on Ethereum. State is checked again before your
          wallet opens.
        </p>
        <dl className="detail-list">
          <div>
            <dt>Contract</dt>
            <dd className="address">{action?.address}</dd>
          </div>
          <div>
            <dt>Function</dt>
            <dd>{action?.functionName}</dd>
          </div>
          <div>
            <dt>Native value</dt>
            <dd>{formatEther(action?.value || 0n)} ETH, plus network gas</dd>
          </div>
          {action?.details.map((d, i) => (
            <div key={i}>
              <dt>{d.label}</dt>
              <dd>{d.value}</dd>
            </div>
          ))}
        </dl>
        <button
          className="button primary full"
          disabled={!wallet || busy}
          onClick={() => void confirm()}
        >
          Confirm in wallet
        </button>
        <button className="button full" onClick={cancel}>
          Cancel review
        </button>
      </dialog>
    </Context.Provider>
  );
}
