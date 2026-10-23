import { encodeAbiParameters, type Address } from "viem";
import { tickSqrt } from "./ticks";
export const Q96 = 1n << 96n;
export type PoolState = {
  sqrt: bigint;
  tick: number;
  liquidity: bigint;
  lpFee: number;
  protocolFee: number;
  hookBps: number;
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};
export function quoteWithinTick(
  p: PoolState,
  amount: bigint,
  buy: boolean,
  slippageBps: number,
) {
  if (amount <= 0n || amount >= 1n << 127n)
    throw Error("Enter a positive amount smaller than 2^127 base units.");
  if (p.liquidity === 0n || p.sqrt === 0n)
    throw Error("This pool has no active liquidity. A quote is unavailable.");
  if (p.protocolFee !== 0)
    throw Error(
      "A protocol fee is active. This site cannot safely quote this route.",
    );
  if (p.hookBps < 100 || p.hookBps > 9900)
    throw Error("Hook fee is outside the verified range.");
  if (!Number.isInteger(slippageBps) || slippageBps < 1 || slippageBps > 500)
    throw Error("Select slippage between 0.01% and 5%.");
  const zeroForOne = buy; // The verified ordering is FWA (currency0), MAD (currency1).
  const hookBuy = buy ? (amount * BigInt(p.hookBps)) / 10000n : 0n;
  const poolInput = amount - hookBuy;
  const lessFee = (poolInput * BigInt(1000000 - p.lpFee)) / 1000000n;
  if (lessFee === 0n) throw Error("The amount is too small after fees.");
  const L = p.liquidity;
  const next = zeroForOne
    ? (L * Q96 * p.sqrt + (L * Q96 + lessFee * p.sqrt) - 1n) /
      (L * Q96 + lessFee * p.sqrt)
    : p.sqrt + (lessFee * Q96) / L;
  const lower = Math.max(
    -887272,
    Math.floor(p.tick / p.tickSpacing) * p.tickSpacing,
  );
  const lowerSqrt = tickSqrt(lower);
  const upperSqrt = tickSqrt(
    Math.min(
      887272,
      Math.floor(p.tick / p.tickSpacing) * p.tickSpacing + p.tickSpacing,
    ),
  );
  if (next <= lowerSqrt || next >= upperSqrt)
    throw Error(
      "This amount crosses a price interval. Reduce the amount; this site only quotes swaps within the current interval.",
    );
  const grossOut = zeroForOne
    ? (L * (p.sqrt - next)) / Q96
    : (L * Q96 * (next - p.sqrt)) / (next * p.sqrt);
  const hookSell = buy ? 0n : (grossOut * BigInt(p.hookBps)) / 10000n;
  const output = grossOut - hookSell;
  const minimum = (output * BigInt(10000 - slippageBps)) / 10000n;
  if (minimum <= 0n)
    throw Error("Minimum output rounds to zero. Increase the amount.");
  const spot = buy
    ? (lessFee * p.sqrt * p.sqrt) / (Q96 * Q96)
    : (lessFee * Q96 * Q96) / (p.sqrt * p.sqrt);
  const impactBps =
    spot > grossOut ? Number(((spot - grossOut) * 10000n) / spot) : 0;
  return {
    amount,
    output,
    minimum,
    zeroForOne,
    hookFee: hookBuy + hookSell,
    lpInputFee: poolInput - lessFee,
    impactBps,
    sqrtAfter: next,
  };
}
export type Quote = ReturnType<typeof quoteWithinTick> & {
  createdAt: number;
  block: bigint;
  buy: boolean;
  slippageBps: number;
  deadline: bigint;
};
export const poolTuple = {
  type: "tuple",
  components: [
    { name: "currency0", type: "address" },
    { name: "currency1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
} as const;
export function routerArguments(key: Record<string, unknown>, q: Quote) {
  if (q.minimum <= 0n || q.deadline <= BigInt(Math.floor(Date.now() / 1000)))
    throw Error(
      "The quote has expired or has no protected output. Request another quote.",
    );
  const params = [
    encodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { ...poolTuple, name: "poolKey" },
            { name: "zeroForOne", type: "bool" },
            { name: "amountIn", type: "uint128" },
            { name: "amountOutMinimum", type: "uint128" },
            { name: "hookData", type: "bytes" },
          ],
        },
      ],
      [
        {
          poolKey: key,
          zeroForOne: q.zeroForOne,
          amountIn: q.amount,
          amountOutMinimum: q.minimum,
          hookData: "0x",
        },
      ] as any,
    ),
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [
        q.buy ? (key.currency0 as Address) : (key.currency1 as Address),
        q.amount,
      ],
    ),
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [
        q.buy ? (key.currency1 as Address) : (key.currency0 as Address),
        q.minimum,
      ],
    ),
  ];
  return [
    "0x10",
    [
      encodeAbiParameters(
        [{ type: "bytes" }, { type: "bytes[]" }],
        ["0x060c0f", params],
      ),
    ],
    q.deadline,
  ] as const;
}
export function assertFreshQuote(q: Quote, now = Date.now()) {
  if (
    now - q.createdAt > 30000 ||
    now < q.createdAt ||
    q.deadline <= BigInt(Math.floor(now / 1000))
  )
    throw Error("Quote expired. Request a fresh quote before continuing.");
}
