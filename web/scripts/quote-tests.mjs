import assert from "node:assert/strict";
import {
  quoteWithinTick,
  routerArguments,
  assertFreshQuote,
  Q96,
} from "../src/trade.ts";
import { tickSqrt } from "../src/ticks.ts";
import vectors from "../tests/quote-vectors.json" with { type: "json" };
import { decodeAbiParameters } from "viem";
let checks = 0;
const test = (name, fn) => {
  fn();
  checks++;
  console.log("PASS " + name);
};
const p = {
  sqrt: tickSqrt(30),
  tick: 30,
  liquidity: 1000000n * 10n ** 18n,
  lpFee: 12500,
  protocolFee: 0,
  hookBps: 100,
  currency0: "0xa0df17b5ac76ababa36e1450e2cbcd18a620c845",
  currency1: "0xc1da7dc8c0e340e5cfb13a739f3cfc057dab8f16",
  fee: 12500,
  tickSpacing: 60,
  hooks: "0x21f193a486861a5ce45f83802f3c4b993110a0cc",
};
for (const vector of vectors.swaps) {
  test(`Uniswap reference: ${vector.buy ? "buy" : "sell"} fee ${vector.hookBps} input ${vector.amount}`, () => {
    const q = quoteWithinTick(
      { ...p, hookBps: vector.hookBps },
      BigInt(vector.amount),
      vector.buy,
      50,
    );
    assert.equal(q.sqrtAfter.toString(), vector.sqrtAfter);
    assert.equal(q.output.toString(), vector.output);
    assert.equal(q.lpInputFee.toString(), vector.lpInputFee);
    assert(q.minimum > 0n);
  });
}
for (const vector of vectors.ticks)
  test(`canonical tick ${vector.tick}`, () =>
    assert.equal(tickSqrt(vector.tick).toString(), vector.sqrtPriceX96));
test("reject no active liquidity", () =>
  assert.throws(
    () => quoteWithinTick({ ...p, liquidity: 0n }, 1000000n, true, 50),
    /no active liquidity/,
  ));
test("reject zero amount", () =>
  assert.throws(() => quoteWithinTick(p, 0n, true, 50), /positive amount/));
test("reject unsigned input overflow", () =>
  assert.throws(
    () => quoteWithinTick(p, 1n << 128n, true, 50),
    /positive amount/,
  ));
test("reject missing selected slippage", () =>
  assert.throws(
    () => quoteWithinTick(p, 1000000n, true, 0),
    /Select slippage/,
  ));
test("reject excessive slippage", () =>
  assert.throws(
    () => quoteWithinTick(p, 1000000n, true, 501),
    /Select slippage/,
  ));
test("reject cross interval rather than invent output", () =>
  assert.throws(
    () => quoteWithinTick(p, 1000000n * 10n ** 18n, true, 50),
    /crosses/,
  ));
test("reject unsupported protocol fee", () =>
  assert.throws(
    () => quoteWithinTick({ ...p, protocolFee: 100 }, 1000000n, true, 50),
    /protocol fee/,
  ));
const q = {
  ...quoteWithinTick(p, 10n ** 18n, true, 50),
  createdAt: Date.now(),
  deadline: BigInt(Math.floor(Date.now() / 1000) + 300),
  block: 1n,
  buy: true,
  slippageBps: 50,
};
test("freshness expires at 30 seconds", () =>
  assert.throws(() => assertFreshQuote(q, q.createdAt + 30001), /expired/));
test("deadline rejects expired quote", () =>
  assert.throws(() => routerArguments(p, { ...q, deadline: 1n }), /expired/));
test("router encoding uses V4_SWAP and exact input settlement/take bounds", () => {
  const args = routerArguments(p, q);
  assert.equal(args[0], "0x10");
  assert.equal(args[2], q.deadline);
  const [actions, params] = decodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes[]" }],
    args[1][0],
  );
  assert.equal(actions, "0x060c0f");
  const [token, max] = decodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    params[1],
  );
  assert.equal(token.toLowerCase(), p.currency0);
  assert.equal(max, q.amount);
  const [out, min] = decodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    params[2],
  );
  assert.equal(out.toLowerCase(), p.currency1);
  assert.equal(min, q.minimum);
});
console.log(`${checks} quote/transaction-encoding checks passed.`);
