import { useState, type FormEvent } from "react";
import { isAddress, isHex, zeroAddress, type Address } from "viem";
import { Settings2, LockKeyhole } from "lucide-react";
import type { PageProps } from "./App";
import { ABI, type ContractName } from "./config";
import { read, ext, ERC20 } from "./chain";
import { useTransactions, type Action } from "./Transactions";
import { DataRow, Notice, AddressLink, exact } from "./ui";
export function ManagePage({ rt, state, wallet }: PageProps) {
  const s = state.data;
  const tx = useTransactions();
  const [error, setError] = useState("");
  const owns = (name: "token" | "hook" | "rewards") =>
    !!s &&
    !!wallet.address &&
    s[name].owner.toLowerCase() === wallet.address.toLowerCase();
  const owner = owns("token") || owns("hook") || owns("rewards");
  const enabled = state.safe && wallet.chainId === 1 && !tx.busy;
  async function submit(
    e: FormEvent<HTMLFormElement>,
    name: ContractName,
    fn: string,
    title: string,
    make: (f: FormData) => readonly unknown[],
    consequence: string,
  ) {
    e.preventDefault();
    setError("");
    try {
      const f = new FormData(e.currentTarget);
      const args = make(f);
      const current: Action["details"] = [];
      if (fn === "setDistributors" || fn === "setRouters") {
        for (const a of args[0] as Address[]) {
          const value = await read(
            rt,
            name,
            fn === "setDistributors" ? "localDistributors" : "approvedRouters",
            [a],
          );
          current.push({
            label: `Current local permission: ${a}`,
            value: value ? "Granted" : "Revoked",
          });
        }
      }
      await tx.prepare({
        title,
        address: rt.addresses[name],
        abi: ABI[name],
        functionName: fn,
        args,
        ownerContract: name,
        details: [
          ...current,
          {
            label: "Arguments",
            value: JSON.stringify(args, (_, v) =>
              typeof v === "bigint" ? v.toString() : v,
            ),
          },
          { label: "Consequence", value: consequence },
        ],
        check: async (fresh) => {
          if (fn === "setDistributors" && args[1] === true) {
            for (const a of args[0] as Address[]) {
              const code = await rt.client.getCode({ address: a });
              if (!code || code === "0x")
                throw Error("A distributor grant requires a contract address.");
            }
          }
          if (fn === "setRouters" && args[1] === true) {
            for (const a of args[0] as Address[]) {
              const code = await rt.client.getCode({ address: a });
              if (!code || code === "0x")
                throw Error("An approved router must have deployed code.");
            }
          }
          if (fn === "enableTrading" && fresh.token.trading)
            throw Error("Trading is already enabled.");
        },
      });
    } catch (e) {
      setError((e as Error).message);
    }
  }
  const addr = (f: FormData, k: string) => {
    const a = String(f.get(k) || "").trim();
    if (!isAddress(a) || a === zeroAddress)
      throw Error(`${k}: enter a nonzero Ethereum address.`);
    return a;
  };
  const integer = (f: FormData, k: string, max = (1n << 256n) - 1n) => {
    const v = String(f.get(k) || "").trim();
    if (!/^[0-9]+$/.test(v) || v.length > 78 || BigInt(v) > max)
      throw Error(`${k}: enter an unsigned integer within range.`);
    return BigInt(v);
  };
  const addresses = (f: FormData) =>
    String(f.get("accounts") || "")
      .split(/[\s,]+/)
      .filter(Boolean)
      .map((a) => {
        if (!isAddress(a) || a === zeroAddress)
          throw Error("Enter complete nonzero addresses, separated by commas.");
        return a;
      });
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Contract management.</h1>
          <p>
            Settings available only to each contract’s current onchain owner.
          </p>
        </div>
        <Settings2 className="heading-icon" size={32} />
      </div>
      <section className="panel">
        <h2>Permission check</h2>
        <DataRow
          label="Connected wallet"
          value={
            wallet.address ? (
              <span className="address">{wallet.address}</span>
            ) : (
              "Not connected"
            )
          }
        />
        {(["token", "hook", "rewards"] as const).map((n) => (
          <DataRow
            key={n}
            label={`${n[0].toUpperCase() + n.slice(1)} owner`}
            value={
              s ? (
                <AddressLink
                  address={s[n].owner}
                  explorer={rt.d.network.explorer}
                />
              ) : state.isError ? (
                "Unavailable"
              ) : (
                "Reading…"
              )
            }
          />
        ))}
        {!owner && (
          <Notice>
            <LockKeyhole size={16} />{" "}
            {wallet.address
              ? "This wallet has no verified contract-owner role. Management controls are unavailable."
              : "Connect a wallet to check its current management permissions."}{" "}
            Project membership and creator status do not grant MAD
            administration.
          </Notice>
        )}
        {owner && !state.safe && (
          <Notice tone="warning">
            Fresh contract verification is required before changing any setting.
          </Notice>
        )}
      </section>
      {owner && s && (
        <>
          <Notice tone="warning">
            These settings affect live contracts on Ethereum. Every change is
            simulated, reviewed and confirmed separately. The owner cannot
            change the receiver, mint tokens, withdraw rewards or choose a round
            winner.
          </Notice>
          <div className="management-grid">
            {owns("token") && (
              <>
                <section className="panel">
                  <h2>Enable trading</h2>
                  <p>
                    Irreversibly opens trading, paid freezes and round one.
                    Starts the hook fee at 99% and its 30-minute decay.
                  </p>
                  <button
                    className="button primary"
                    disabled={!enabled || s.token.trading}
                    onClick={() =>
                      void tx.prepare({
                        title: "Irreversibly enable MAD trading",
                        address: rt.addresses.MadToken,
                        abi: ABI.MadToken,
                        functionName: "enableTrading",
                        ownerContract: "MadToken",
                        details: [
                          {
                            label: "Irreversible effect",
                            value:
                              "Starts trading, freezes, round one and the hook fee decay. There is no pause or undo function.",
                          },
                          {
                            label: "Current liquidity",
                            value:
                              s.liquidity > 0n
                                ? "Present"
                                : "No active liquidity. Confirm readiness independently.",
                          },
                        ],
                        check: (fresh) => {
                          if (fresh.token.trading)
                            throw Error("Trading is already enabled.");
                        },
                      })
                    }
                  >
                    {s.token.trading
                      ? "Trading already enabled"
                      : "Review trading enablement"}
                  </button>
                </section>
                <section className="panel">
                  <h2>Global custody registry</h2>
                  <DataRow
                    label="Current setting"
                    value={
                      s.token.useGlobalDistributors ? "Enabled" : "Disabled"
                    }
                  />
                  <p>
                    Disabling this can strand MAD in contracts exempt only
                    through the global registry. Mirror trusted custodians
                    locally first.
                  </p>
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadToken",
                        "setUseGlobalDistributors",
                        "Change global distributor policy",
                        (f) => [f.get("enabled") === "true"],
                        "Immediately accepts or rejects global registry custody exemptions. Existing freezes still apply.",
                      )
                    }
                  >
                    <label>
                      Global distributors
                      <select
                        name="enabled"
                        defaultValue={String(s.token.useGlobalDistributors)}
                      >
                        <option value="true">Enable registry exemptions</option>
                        <option value="false">
                          Disable registry exemptions
                        </option>
                      </select>
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review registry policy
                    </button>
                  </form>
                </section>
                <section className="panel">
                  <h2>Local distributors</h2>
                  <p>
                    Grant custody only to audited contracts. Core MAD contracts
                    cannot be exempted.
                  </p>
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadToken",
                        "setDistributors",
                        "Change local distributors",
                        (f) => {
                          const a = addresses(f);
                          if (!a.length)
                            throw Error("Enter at least one address.");
                          return [a, f.get("allowed") === "true"];
                        },
                        "Changes custody exemptions. Approvals can let MAD leave direct-wallet freeze exposure.",
                      )
                    }
                  >
                    <label>
                      Contract addresses
                      <textarea
                        name="accounts"
                        rows={3}
                        placeholder="0x… separated by commas"
                        required
                      />
                    </label>
                    <label>
                      Permission
                      <select name="allowed">
                        <option value="false">
                          Revoke distributor permission
                        </option>
                        <option value="true">
                          Grant distributor permission
                        </option>
                      </select>
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review distributors
                    </button>
                  </form>
                </section>
              </>
            )}
            {owns("hook") && (
              <>
                <section className="panel">
                  <h2>NFT conversion bounds</h2>
                  <DataRow
                    label="Current sqrt-price ceiling"
                    value={String(s.hook.conversionSqrtPriceLimitX96)}
                  />
                  <DataRow
                    label="Current minimum ETH/FWA × 10¹⁸"
                    value={String(s.hook.minEthPerFwaX18)}
                  />
                  <p>
                    Use independently assessed bounds for the official ETH/FWA
                    market. A loose floor exposes accumulated NFT claims to
                    price manipulation.
                  </p>
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadHook",
                        "setConversionBounds",
                        "Change NFT conversion bounds",
                        (f) => {
                          const sqrt = integer(
                              f,
                              "sqrtPriceLimitX96",
                              (1n << 160n) - 1n,
                            ),
                            min = integer(f, "minimumEthPerFwaX18");
                          if (
                            sqrt <= 4295128739n ||
                            sqrt >=
                              1461446703485210103287273052203988822378723970342n ||
                            min === 0n
                          )
                            throw Error(
                              "Use a valid tick sqrt-price and a nonzero minimum.",
                            );
                          return [sqrt, min];
                        },
                        "Enables or changes NFT-only FWA conversion during MAD swaps. Playground claims are not converted here.",
                      )
                    }
                  >
                    <label>
                      Sqrt-price ceiling (Q96 integer)
                      <input
                        name="sqrtPriceLimitX96"
                        inputMode="numeric"
                        required
                      />
                    </label>
                    <label>
                      Minimum ETH per FWA × 10¹⁸
                      <input
                        name="minimumEthPerFwaX18"
                        inputMode="numeric"
                        required
                      />
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review conversion bounds
                    </button>
                  </form>
                </section>
                <section className="panel">
                  <h2>Trusted routers</h2>
                  <p>
                    Only approve inspected take-only router code. Unsupported
                    claim minting or clearing can violate MAD’s transfer
                    accounting.
                  </p>
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadHook",
                        "setRouters",
                        "Change approved routers",
                        (f) => {
                          const a = addresses(f);
                          if (!a.length)
                            throw Error("Enter at least one router.");
                          return [a, f.get("approved") === "true"];
                        },
                        "Changes which routers can execute MAD buys. Verify deployed router behavior before granting.",
                      )
                    }
                  >
                    <label>
                      Router addresses
                      <textarea name="accounts" rows={3} required />
                    </label>
                    <label>
                      Permission
                      <select name="approved">
                        <option value="false">Revoke router permission</option>
                        <option value="true">Approve trusted router</option>
                      </select>
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review router permissions
                    </button>
                  </form>
                </section>
                <section className="panel">
                  <h2>Official ETH/FWA market</h2>
                  <p>
                    The current configured market is shown below. A replacement
                    must use native ETH as currency0 and the same FWA as
                    currency1.
                  </p>
                  <dl className="detail-list">
                    {[
                      "currency0",
                      "currency1",
                      "fee",
                      "tickSpacing",
                      "hooks",
                    ].map((k, i) => (
                      <div key={k}>
                        <dt>{k}</dt>
                        <dd className="address">
                          {String(s.hook.ethFwaPool[i])}
                        </dd>
                      </div>
                    ))}
                  </dl>
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadHook",
                        "setEthFwaPool",
                        "Change the ETH/FWA conversion market",
                        (f) => {
                          const fee = integer(f, "fee", 999999n),
                            spacing = integer(f, "tickSpacing", 32767n);
                          if (spacing === 0n)
                            throw Error("Tick spacing must be positive.");
                          return [
                            {
                              currency0: zeroAddress,
                              currency1: rt.d.poolKey.currency0,
                              fee: Number(fee),
                              tickSpacing: Number(spacing),
                              hooks: addr(f, "marketHook"),
                            },
                          ];
                        },
                        "Changes the NFT fee conversion market. Use only FWA’s verified official market; this does not create an ETH/MAD trade route.",
                      )
                    }
                  >
                    <label>
                      Verified market hook
                      <input name="marketHook" required />
                    </label>
                    <label>
                      Fee in millionths
                      <input name="fee" inputMode="numeric" required />
                    </label>
                    <label>
                      Tick spacing
                      <input name="tickSpacing" inputMode="numeric" required />
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review conversion market
                    </button>
                  </form>
                </section>
              </>
            )}
            {owns("rewards") && (
              <>
                <section className="panel">
                  <h2>FWA V2 source</h2>
                  <AddressLink
                    address={s.rewards.fwaV2}
                    explorer={rt.d.network.explorer}
                  />
                  <p>
                    Existing purchases retain their saved source. Use a verified
                    pool whose acquisition IDs never collide with previous
                    pools.
                  </p>
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadRewards",
                        "setFwaV2",
                        "Change the NFT acquisition source",
                        (f) => [addr(f, "pool")],
                        "Future draws use the new source. Historical sources remain eligible for refunds and recorded settlement.",
                      )
                    }
                  >
                    <label>
                      Verified FWA V2 pool
                      <input name="pool" required />
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review acquisition source
                    </button>
                  </form>
                </section>
                <section className="panel">
                  <h2>NFT acquisition limits</h2>
                  <DataRow
                    label="Current fee margin"
                    value={`${exact(s.rewards.acquisitionFeeMargin)} ETH`}
                  />
                  <DataRow
                    label="Current negative slippage"
                    value={`${Number(s.rewards.acquisitionSlippageBps) / 100}%`}
                  />
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadRewards",
                        "setAcquisitionBounds",
                        "Change NFT acquisition limits",
                        (f) => [
                          integer(f, "margin"),
                          integer(f, "slippageBps", 10000n),
                        ],
                        "Changes the quote fee margin and maximum negative slippage used by public NFT purchases.",
                      )
                    }
                  >
                    <label>
                      Acquisition fee margin (wei)
                      <input name="margin" inputMode="numeric" required />
                    </label>
                    <label>
                      Negative slippage (basis points, 0–10000)
                      <input name="slippageBps" inputMode="numeric" required />
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review acquisition limits
                    </button>
                  </form>
                </section>
                <section className="panel">
                  <h2>Oracle configuration</h2>
                  <dl className="detail-list">
                    {["intake", "imd", "action", "oracleSigner"].map((k) => (
                      <div key={k}>
                        <dt>{k}</dt>
                        <dd className="address">{String(s.rewards[k])}</dd>
                      </div>
                    ))}
                  </dl>
                  <p>
                    Future requests use the new intake, payment token and
                    signer. Outstanding requests retain their original
                    authority. An owner-chosen intake controls the fee spent
                    from donations.
                  </p>
                  <form
                    onSubmit={(e) =>
                      void submit(
                        e,
                        "MadRewards",
                        "setOracleSettings",
                        "Change oracle authority",
                        (f) => {
                          const a = String(f.get("action"));
                          if (!isHex(a) || a.length !== 66 || /^0x0+$/.test(a))
                            throw Error(
                              "Action must be a nonzero bytes32 hex value.",
                            );
                          return [
                            addr(f, "intake"),
                            addr(f, "paymentToken"),
                            a,
                            addr(f, "signer"),
                          ];
                        },
                        "Changes authority and payment settings for future winner requests. It cannot rewrite a closed round or saved winner.",
                      )
                    }
                  >
                    <label>
                      Verified intake contract
                      <input name="intake" required />
                    </label>
                    <label>
                      Payment token contract
                      <input name="paymentToken" required />
                    </label>
                    <label>
                      Action (bytes32)
                      <input name="action" required />
                    </label>
                    <label>
                      Attestation signer
                      <input name="signer" required />
                    </label>
                    <button className="button" disabled={!enabled}>
                      Review oracle configuration
                    </button>
                  </form>
                </section>
              </>
            )}
          </div>
        </>
      )}
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </>
  );
}
