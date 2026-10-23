import { ExternalLink, Info } from "lucide-react";
import { formatUnits, type Address } from "viem";
import type { ReactNode } from "react";
export const amount = (
  value: bigint | undefined,
  decimals = 18,
  maximum = 5,
) =>
  value === undefined
    ? "Unavailable"
    : new Intl.NumberFormat("en-US", { maximumFractionDigits: maximum }).format(
        Number(formatUnits(value, decimals)),
      );
export const exact = (value: bigint, decimals = 18) =>
  formatUnits(value, decimals);
export const date = (seconds: bigint | number) =>
  new Date(Number(seconds) * 1000).toLocaleString();
export function AddressLink({
  address,
  explorer,
  label,
}: {
  address: Address | string;
  explorer: string;
  label?: string;
}) {
  return (
    <a
      className="address-link"
      href={`${explorer}/address/${address}`}
      target="_blank"
      rel="noreferrer"
    >
      {label || address}
      <ExternalLink size={13} />
    </a>
  );
}
export function Notice({
  children,
  tone = "neutral",
}: {
  children: ReactNode;
  tone?: "neutral" | "warning" | "error" | "success";
}) {
  return (
    <div className={`notice ${tone}`}>
      <Info size={17} />
      <div>{children}</div>
    </div>
  );
}
export function DataRow({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="data-row">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}
export function Status({
  children,
  ok = false,
}: {
  children: ReactNode;
  ok?: boolean;
}) {
  return (
    <span className={`status ${ok ? "ok" : ""}`}>
      <span />
      {children}
    </span>
  );
}
export function Empty({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <div className="empty">
      <Info size={24} />
      <h3>{title}</h3>
      <p>{children}</p>
    </div>
  );
}
