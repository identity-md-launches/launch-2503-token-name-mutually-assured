import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { zeroAddress, type Address } from "viem";
import { Trophy, ArrowRight, ArrowUpRight, Clock3 } from "lucide-react";
import type { PageProps } from "./App";
import { ABI, type ContractName } from "./config";
import { read, ext, FWA_V2, nonzero, errText } from "./chain";
import { useTransactions, type Action } from "./Transactions";
import { exact, amount, date, DataRow, Notice, Empty, AddressLink } from "./ui";
export function RoundsPage({ rt, state, wallet }: PageProps) {
  const s = state.data;
  const tx = useTransactions();
  const [requestInput, setRequestInput] = useState(""),
    [request, setRequest] = useState<bigint>(),
    [roundInput, setRoundInput] = useState(""),
    [selectedRound, setSelectedRound] = useState<bigint>(),
    [requestError, setRequestError] = useState(""),
    [roundError, setRoundError] = useState("");
  const canWrite =
    state.safe && wallet.chainId === 1 && !!wallet.address && !tx.busy;
  const queue = useQuery({
    queryKey: [
      "prizes",
      s?.rewards.prizeCount.toString(),
      s?.rewards.nextPrize.toString(),
    ],
    enabled: !!s,
    queryFn: async () => {
      const ids = [];
      for (
        let i = BigInt(s!.rewards.nextPrize);
        i < BigInt(s!.rewards.prizeCount) && ids.length < 8;
        i++
      )
        ids.push(i);
      return Promise.all(
        ids.map(async (i) => ({
          index: i,
          prize: (await read(rt, "MadRewards", "keptNFTs", [i])) as [
            Address,
            bigint,
          ],
        })),
      );
    },
    retry: 1,
  });
  const draw = useQuery({
    queryKey: ["draw", request?.toString()],
    enabled: request !== undefined && !!s,
    queryFn: async () => {
      const purchase = await read(rt, "MadRewards", "purchases", [request]);
      const source = nonzero(purchase[0]) ? purchase[0] : s!.rewards.fwaV2;
      const [a, window] = await Promise.all([
        ext(rt, source, FWA_V2, "acquisitions", [request]),
        ext(rt, source, FWA_V2, "settlementWindow"),
      ]);
      const listing =
        a.listingId > 0n
          ? await ext(rt, source, FWA_V2, "listings", [a.listingId])
          : undefined;
      return { purchase, source, a, listing, window: BigInt(window) };
    },
    refetchInterval: 25000,
    retry: 1,
  });
  const round = useQuery({
    queryKey: ["round", selectedRound?.toString()],
    enabled: selectedRound !== undefined,
    queryFn: async () => {
      const r = await read(rt, "MadRewards", "rounds", [selectedRound]);
      const beneficiary = await read(rt, "MadRewards", "beneficiaryOf", [
        selectedRound,
      ]);
      const req = await read(rt, "MadRewards", "requests", [r[9]]);
      return { r, beneficiary, req };
    },
    refetchInterval: 25000,
    retry: 1,
  });
  const rd = round.data;
  const closed = rd && nonzero(rd.r[3]);
  const now = s?.block.timestamp || 0n;
  const closeReason = !s
    ? "Reading round state…"
    : !s.token.trading
      ? "Trading has not started."
      : BigInt(s.rewards.nextPrize) >= BigInt(s.rewards.prizeCount)
        ? "A kept NFT is required before a round can close."
        : s.block.number < s.blocks[0] + 7200n
          ? `Needs ${s.blocks[0] + 7200n - s.block.number} more blocks.`
          : s.leaderSpent < 1000n * 10n ** 18n
            ? "The leader must spend at least 1,000 MAD."
            : "";
  async function preparePublic(
    name: ContractName,
    fn: string,
    title: string,
    details: Action["details"],
    args: readonly unknown[] = [],
    check?: Action["check"],
  ) {
    await tx.prepare({
      title,
      address: rt.addresses[name],
      abi: ABI[name],
      functionName: fn,
      args,
      details: [
        {
          label: "Wallet cost",
          value:
            "Network gas only. Any protocol spend comes from its existing budget.",
        },
        ...details,
      ],
      check,
    });
  }
  function parseId(
    v: string,
    set: (n: bigint) => void,
    setError: (message: string) => void,
    field: "acquisition request ID" | "round number",
  ) {
    setError("");
    if (!/^[1-9][0-9]*$/.test(v) || v.length > 78) {
      setError(`Enter a positive decimal ${field}.`);
      return false;
    }
    const n = BigInt(v);
    if (n >= 1n << 256n) {
      setError(
        `${field[0].toUpperCase()}${field.slice(1)} must be smaller than 2^256.`,
      );
      return false;
    }
    set(n);
    return true;
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <h1>Play for the prize.</h1>
          <p>Freeze spending leads the round. Kept NFTs become prizes.</p>
        </div>
        <Trophy className="heading-icon" size={34} />
      </div>
      <div className="round-summary panel">
        <div>
          <span className="muted">Current round</span>
          <strong className="round-number">
            {s?.round ? String(s.round) : "Not started"}
          </strong>
          <span>
            {s?.token.trading
              ? "Open for freeze spending"
              : "Awaiting trading enablement"}
          </span>
        </div>
        <div>
          <DataRow
            label="Leader"
            value={
              s && nonzero(s.leader) ? (
                <AddressLink
                  address={s.leader}
                  explorer={rt.d.network.explorer}
                  label={`${s.leader.slice(0, 6)}…${s.leader.slice(-4)}`}
                />
              ) : s ? (
                "No leader yet"
              ) : (
                "Unavailable"
              )
            }
          />
          <DataRow
            label="Leader spending"
            value={s ? `${amount(s.leaderSpent)} MAD` : "Unavailable"}
          />
          <DataRow
            label="First block"
            value={s?.blocks[0] ? String(s.blocks[0]) : "Not started"}
          />
          <DataRow
            label="Queued NFTs"
            value={
              s
                ? String(
                    BigInt(s.rewards.prizeCount) - BigInt(s.rewards.nextPrize),
                  )
                : "Unavailable"
            }
          />
        </div>
        <div>
          <button
            className="button primary full"
            disabled={!canWrite || !!closeReason}
            onClick={() =>
              void preparePublic(
                "MadRewards",
                "closeRound",
                "Close the current round",
                [
                  { label: "Current round", value: String(s!.round) },
                  { label: "Saved leader", value: s!.leader },
                  {
                    label: "Consequence",
                    value:
                      "Permanently closes the block range, assigns the oldest kept NFT and saves the spending leader.",
                  },
                ],
                [],
                (fresh) => {
                  if (
                    fresh.round !== s!.round ||
                    fresh.leader.toLowerCase() !== s!.leader.toLowerCase() ||
                    fresh.rewards.nextPrize !== s!.rewards.nextPrize
                  )
                    throw Error(
                      "Round or prize assignment changed. Refresh and review the new state.",
                    );
                  if (
                    !fresh.token.trading ||
                    fresh.block.number < fresh.blocks[0] + 7200n ||
                    fresh.leaderSpent < 1000n * 10n ** 18n ||
                    BigInt(fresh.rewards.nextPrize) >=
                      BigInt(fresh.rewards.prizeCount)
                  )
                    throw Error("Round closure conditions are not met.");
                },
              )
            }
          >
            Review round closure <ArrowRight size={16} />
          </button>
          <p className="field-help">
            {closeReason ||
              (!wallet.address
                ? "Connect to close this eligible round."
                : "Closing starts the next round in the next block.")}
          </p>
        </div>
      </div>
      <div className="two-column">
        <section className="panel">
          <h2>Reward budget</h2>
          <DataRow
            label="Spendable ETH"
            value={s ? `${exact(s.rewards.budget)} ETH` : "Unavailable"}
          />
          <DataRow
            label="NFT FWA claims"
            value={s ? `${amount(s.hook.nftFwaClaims)} FWA` : "Unavailable"}
          />
          <DataRow
            label="NFT ETH claims"
            value={s ? `${exact(s.hook.nftEthClaims)} ETH` : "Unavailable"}
          />
          <DataRow
            label="Acquisition quote"
            value={
              s?.acquisitionQuote
                ? `${exact(s.acquisitionQuote[2])} ETH`
                : "Unavailable"
            }
          />
          <DataRow
            label="Purchase blackout"
            value={
              s?.blackout === undefined
                ? "Unavailable"
                : s.blackout
                  ? "Active"
                  : "Inactive"
            }
          />
          <DataRow
            label="Conversion protection"
            value={
              s
                ? s.hook.conversionSqrtPriceLimitX96 > 0n &&
                  s.hook.minEthPerFwaX18 > 0n
                  ? "Configured"
                  : "Unset"
                : "Unavailable"
            }
          />
          <p className="field-help">
            Claims are not spendable ETH. FWA converts only during a MAD swap
            after the owner sets conversion bounds.
          </p>
          <div className="button-stack">
            <button
              className="button primary"
              disabled={
                !canWrite ||
                !s?.token.trading ||
                s?.blackout !== false ||
                !s.acquisitionQuote ||
                s.rewards.budget < s.acquisitionQuote[2]
              }
              onClick={() => {
                const quoted = s!.acquisitionQuote![2];
                void preparePublic(
                  "MadRewards",
                  "buy",
                  "Buy an NFT draw",
                  [
                    {
                      label: "Current acquisition quote",
                      value: `${exact(quoted)} ETH from the reward budget`,
                    },
                    {
                      label: "Slippage setting",
                      value: `${Number(s!.rewards.acquisitionSlippageBps) / 100}%`,
                    },
                    {
                      label: "Budget risk",
                      value:
                        "Selection and settlement depend on FWA V2. Keeper settlement is required; charges may not all be refundable.",
                    },
                  ],
                  [],
                  (fresh) => {
                    if (
                      !fresh.token.trading ||
                      fresh.blackout !== false ||
                      !fresh.acquisitionQuote ||
                      fresh.acquisitionQuote[2] !== quoted ||
                      fresh.rewards.fwaV2.toLowerCase() !==
                        s!.rewards.fwaV2.toLowerCase() ||
                      fresh.rewards.acquisitionFeeMargin !==
                        s!.rewards.acquisitionFeeMargin ||
                      fresh.rewards.acquisitionSlippageBps !==
                        s!.rewards.acquisitionSlippageBps
                    )
                      throw Error(
                        "Acquisition state or price changed. Refresh and review again.",
                      );
                  },
                );
              }}
            >
              Review NFT purchase
            </button>
            <button
              className="button"
              disabled={!canWrite || !s || s.hook.nftEthClaims === 0n}
              onClick={() =>
                void preparePublic(
                  "MadHook",
                  "redeemNFTBudget",
                  "Redeem NFT ETH claims",
                  [
                    { label: "Destination", value: rt.addresses.MadRewards },
                    {
                      label: "Requested claims",
                      value: `${exact(s!.hook.nftEthClaims)} ETH`,
                    },
                    {
                      label: "Liquidity",
                      value:
                        "Only the amount backed by available physical ETH can be redeemed.",
                    },
                  ],
                )
              }
            >
              Redeem ETH claims
            </button>
            <button
              className="button"
              disabled={!canWrite || !s}
              onClick={() =>
                void preparePublic(
                  "MadRewards",
                  "recoverRefund",
                  "Recover an acquisition refund",
                  [
                    { label: "Source", value: s!.rewards.fwaV2 },
                    {
                      label: "Destination",
                      value: "The same NFT reward budget.",
                    },
                  ],
                  [s!.rewards.fwaV2],
                )
              }
            >
              Review refund recovery
            </button>
          </div>
          {!wallet.address && (
            <p className="field-help">
              Connect to run public keeper actions. Your wallet pays gas only.
            </p>
          )}
        </section>
        <section className="panel">
          <h2>Settle an NFT draw</h2>
          <p>
            Enter a FWA request ID to inspect its allocation. Settlement sends
            the NFT to the reward helper, not your wallet.
          </p>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (
                !parseId(
                  requestInput,
                  setRequest,
                  setRequestError,
                  "acquisition request ID",
                )
              )
                e.currentTarget.querySelector("input")?.focus();
            }}
          >
            <label htmlFor="request-id">Acquisition request ID</label>
            <input
              id="request-id"
              aria-invalid={!!requestError}
              aria-describedby={requestError ? "request-id-error" : undefined}
              inputMode="numeric"
              value={requestInput}
              onChange={(e) => {
                setRequestInput(e.target.value);
                setRequestError("");
              }}
              placeholder="Decimal request ID"
            />
            {requestError && (
              <p id="request-id-error" className="error">
                {requestError}
              </p>
            )}
            <button className="button full" type="submit">
              Inspect acquisition
            </button>
          </form>
          {draw.isFetching && <p role="status">Reading acquisition…</p>}
          {draw.isError && (
            <Notice tone="error">
              {errText(draw.error)}
              <button className="button" onClick={() => void draw.refetch()}>
                Retry acquisition
              </button>
            </Notice>
          )}
          {draw.data && (
            <>
              <DataRow
                label="Source"
                value={
                  <AddressLink
                    address={draw.data.source}
                    explorer={rt.d.network.explorer}
                    label="FWA V2 source"
                  />
                }
              />
              <DataRow
                label="Purchaser"
                value={<span className="address">{draw.data.a.purchaser}</span>}
              />
              <DataRow
                label="Allocation status code"
                value={String(draw.data.a.status)}
              />
              <DataRow
                label="Already registered"
                value={draw.data.purchase[1] ? "Yes" : "No"}
              />
              {draw.data.listing && (
                <>
                  <DataRow
                    label="NFT token ID"
                    value={String(draw.data.listing.tokenId)}
                  />
                  <DataRow
                    label="Window ends"
                    value={
                      draw.data.listing.allocatedAt
                        ? date(
                            BigInt(draw.data.listing.allocatedAt) +
                              draw.data.window,
                          )
                        : "Not allocated"
                    }
                  />
                </>
              )}
              <button
                className="button primary full"
                disabled={
                  !canWrite ||
                  draw.data.purchase[1] ||
                  draw.data.a.purchaser.toLowerCase() !==
                    rt.addresses.MadRewards.toLowerCase() ||
                  draw.data.a.listingId === 0n
                }
                onClick={() =>
                  void preparePublic(
                    "MadRewards",
                    "claim",
                    "Settle an NFT allocation",
                    [
                      { label: "Request ID", value: String(request) },
                      { label: "Recipient", value: rt.addresses.MadRewards },
                      {
                        label: "Window",
                        value:
                          "A fulfilled allocation must settle inside its window, unless its NFT has already been delivered to this helper.",
                      },
                    ],
                    [request],
                  )
                }
              >
                Review NFT settlement
              </button>
              <p className="field-help">
                {!wallet.address
                  ? "Connect to settle this helper’s allocation."
                  : draw.data.purchase[1]
                    ? "This draw is already registered in the prize queue."
                    : draw.data.a.purchaser.toLowerCase() !==
                        rt.addresses.MadRewards.toLowerCase()
                      ? "This request does not belong to the MAD reward helper."
                      : draw.data.a.listingId === 0n
                        ? "No NFT is allocated to this request. Check the FWA source and refresh after processing."
                        : "Simulation verifies fulfillment, ownership and the source’s settlement window before your wallet opens."}
              </p>
            </>
          )}
        </section>
      </div>
      <section className="panel spaced">
        <div className="section-heading">
          <h2>Closed round & award</h2>
          <Clock3 size={20} />
        </div>
        <form
          className="inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            if (
              !parseId(
                roundInput,
                setSelectedRound,
                setRoundError,
                "round number",
              )
            )
              e.currentTarget.querySelector("input")?.focus();
          }}
        >
          <div className="id-field">
            <label htmlFor="round-id">Round number</label>
            <input
              id="round-id"
              aria-invalid={!!roundError}
              aria-describedby={roundError ? "round-id-error" : undefined}
              inputMode="numeric"
              value={roundInput}
              onChange={(e) => {
                setRoundInput(e.target.value);
                setRoundError("");
              }}
              placeholder="1"
            />
            {roundError && (
              <p id="round-id-error" className="error">
                {roundError}
              </p>
            )}
          </div>
          <button className="button" type="submit">
            Inspect round
          </button>
        </form>
        {round.isFetching && <p role="status">Reading round…</p>}
        {round.isError && (
          <Notice tone="error">
            {errText(round.error)}
            <button className="button" onClick={() => void round.refetch()}>
              Retry round
            </button>
          </Notice>
        )}
        {rd && !closed && (
          <Empty title="This round has not closed">
            A closed round requires a kept NFT, 7,200 blocks and at least 1,000
            MAD of leader spending.
          </Empty>
        )}
        {rd && closed && (
          <>
            <div className="form-grid">
              <div>
                <DataRow label="Block window" value={`${rd.r[0]}–${rd.r[1]}`} />
                <DataRow
                  label="Saved leader"
                  value={
                    <AddressLink
                      address={rd.r[3]}
                      explorer={rt.d.network.explorer}
                      label="View saved leader"
                    />
                  }
                />
                <DataRow
                  label="NFT"
                  value={
                    <a
                      href={`${rt.d.network.explorer}/nft/${rd.r[4]}/${rd.r[5]}`}
                      target="_blank"
                      rel="noreferrer"
                    >
                      Token #{String(rd.r[5])} <ArrowUpRight size={14} />
                    </a>
                  }
                />
              </div>
              <div>
                <DataRow
                  label="Fallback time"
                  value={date(BigInt(rd.r[2]) + 259200n)}
                />
                <DataRow
                  label="Beneficiary"
                  value={
                    nonzero(rd.beneficiary) ? (
                      <AddressLink
                        address={rd.beneficiary}
                        explorer={rt.d.network.explorer}
                        label="View beneficiary"
                      />
                    ) : (
                      "Waiting for oracle or fallback"
                    )
                  }
                />
                <DataRow
                  label="Award status"
                  value={rd.r[8] ? "Delivered" : "Not delivered"}
                />
              </div>
            </div>
            <DataRow
              label="Oracle request state"
              value={
                nonzero(rd.r[6])
                  ? "Winner accepted"
                  : rd.req[5]
                    ? `Live request; retry from ${date(BigInt(rd.req[4]) + 21600n)}`
                    : "No active request"
              }
            />
            <DataRow
              label="Oracle payment"
              value={
                s?.oraclePrice === undefined
                  ? "Unavailable"
                  : `${s.oraclePrice} payment-token base units`
              }
            />
            <DataRow
              label="Donated oracle funds"
              value={
                s?.oracleFunds === undefined
                  ? "Unavailable"
                  : `${s.oracleFunds} payment-token base units`
              }
            />
            <p>
              The helper spends donated oracle tokens at the intake’s live
              price. No wallet tokens or NFT ETH budget are used. A retry may
              spend again.
            </p>
            <div className="button-row">
              <button
                className="button"
                disabled={
                  !canWrite ||
                  rd.r[8] ||
                  nonzero(rd.r[6]) ||
                  nonzero(rd.r[7]) ||
                  s!.block.number < BigInt(rd.r[1]) + 8n ||
                  now >= BigInt(rd.r[2]) + 259200n ||
                  (rd.req[5] && now < BigInt(rd.req[4]) + 21600n) ||
                  s?.oraclePrice === undefined ||
                  s.oracleFunds === undefined ||
                  s.oracleFunds < s.oraclePrice
                }
                onClick={() => {
                  const price = s!.oraclePrice;
                  void preparePublic(
                    "MadRewards",
                    "askWinner",
                    "Request the round winner",
                    [
                      { label: "Round", value: String(selectedRound) },
                      {
                        label: "Payment",
                        value: `${price} base units from donated oracle tokens`,
                      },
                      { label: "Payment token", value: s!.rewards.imd },
                      {
                        label: "Retry",
                        value:
                          "Retries can spend another intake fee. The saved leader becomes the fallback after 72 hours.",
                      },
                    ],
                    [selectedRound],
                    (fresh) => {
                      if (
                        fresh.oraclePrice !== price ||
                        fresh.rewards.imd.toLowerCase() !==
                          s!.rewards.imd.toLowerCase() ||
                        fresh.rewards.intake.toLowerCase() !==
                          s!.rewards.intake.toLowerCase() ||
                        fresh.rewards.action !== s!.rewards.action
                      )
                        throw Error(
                          "Oracle price changed. Refresh before reviewing.",
                        );
                    },
                  );
                }}
              >
                Review oracle request
              </button>
              <button
                className="button primary"
                disabled={!canWrite || rd.r[8] || !nonzero(rd.beneficiary)}
                onClick={() =>
                  void preparePublic(
                    "MadRewards",
                    "award",
                    "Deliver the round prize",
                    [
                      { label: "Round", value: String(selectedRound) },
                      { label: "Beneficiary", value: rd.beneficiary },
                      {
                        label: "Retry behavior",
                        value:
                          "If the recipient rejects delivery, the beneficiary remains fixed and delivery can be retried.",
                      },
                    ],
                    [selectedRound],
                  )
                }
              >
                Review prize delivery
              </button>
            </div>
            <p className="field-help">
              Oracle requests open 8 blocks after closure, retry after 6 hours,
              and close at 72 hours. Awards open when a winner or timeout
              fallback is available.
            </p>
          </>
        )}
      </section>
      <section className="spaced">
        <div className="section-heading">
          <h2>Kept NFT queue</h2>
          <span>Oldest first · up to 8 upcoming prizes</span>
        </div>
        {queue.isPending ? (
          <p>Reading NFT queue…</p>
        ) : queue.isError ? (
          <Notice tone="error">
            NFT queue unavailable. {errText(queue.error)}
            <button className="button" onClick={() => void queue.refetch()}>
              Retry queue
            </button>
          </Notice>
        ) : queue.data?.length ? (
          <div className="nft-list">
            {queue.data.map((p) => (
              <a
                key={String(p.index)}
                href={`${rt.d.network.explorer}/nft/${p.prize[0]}/${p.prize[1]}`}
                target="_blank"
                rel="noreferrer"
              >
                <Trophy size={24} />
                <div>
                  <strong>NFT #{String(p.prize[1])}</strong>
                  <span className="address">{p.prize[0]}</span>
                </div>
                <ArrowUpRight size={16} />
              </a>
            ))}
          </div>
        ) : (
          <Empty title="No NFT prizes queued">
            NFT fee revenue must convert to ETH, fund a FWA V2 purchase and
            settle before a prize can join the queue.
          </Empty>
        )}
      </section>
    </>
  );
}
