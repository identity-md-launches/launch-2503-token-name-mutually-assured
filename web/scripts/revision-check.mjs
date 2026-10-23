// Regression checks against the production export. All signing is mocked;
// contract code/bindings are read from Ethereum, while trade state is a fixture.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import {
  decodeAbiParameters,
  decodeFunctionData,
  encodeFunctionResult,
  parseAbi,
} from "viem";
import { chromium } from "/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs";

const baseline = process.argv.includes("--baseline");
const rpcUrl =
  process.argv.slice(2).find((a) => !a.startsWith("--")) ||
  "https://ethereum-rpc.publicnode.com";
const handoff = JSON.parse(
  await fs.readFile("dist/imd-deployment.json", "utf8"),
);
const token = handoff.poolKey.currency1.toLowerCase();
const pair = handoff.poolKey.currency0.toLowerCase();
const hook = handoff.poolKey.hooks.toLowerCase();
const router = handoff.network.uniswapV4.universalRouter.toLowerCase();
const stateView = handoff.network.uniswapV4.stateView.toLowerCase();
const permit2 = handoff.network.uniswapV4.permit2.toLowerCase();
const caller = "0xcecc29b037f5064fcdf45a5c318f132ef76aa551";
const tradeAbi = parseAbi([
  "function trading() view returns(bool)",
  "function currentRound() view returns(uint256)",
  "function feeBps() view returns(uint256)",
  "function frozenUntil(address) view returns(uint64)",
  "function balanceOf(address) view returns(uint256)",
  "function allowance(address,address) view returns(uint256)",
  "function approve(address,uint256) returns(bool)",
  "function getSlot0(bytes32) view returns(uint160,int24,uint24,uint24)",
  "function getLiquidity(bytes32) view returns(uint128)",
]);
const permitAbi = parseAbi([
  "function allowance(address,address,address) view returns(uint160,uint48,uint48)",
  "function approve(address,address,uint160,uint48)",
]);
const routerAbi = parseAbi([
  "function execute(bytes commands,bytes[] inputs,uint256 deadline) payable",
]);
const cache = new Map();
const results = [];
const pageErrors = [];
await fs.mkdir("test/scratch/revision", { recursive: true });
const server = http.createServer(async (req, res) => {
  try {
    const rel = decodeURIComponent(
      new URL(req.url, "http://localhost").pathname,
    );
    const p = path.resolve("dist", "." + (rel === "/" ? "/index.html" : rel));
    assert(p.startsWith(path.resolve("dist") + path.sep));
    res.setHeader(
      "content-type",
      {
        ".html": "text/html",
        ".js": "text/javascript",
        ".css": "text/css",
        ".json": "application/json",
        ".svg": "image/svg+xml",
        ".png": "image/png",
      }[path.extname(p)] || "application/octet-stream",
    );
    res.end(await fs.readFile(p));
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ headless: true });
async function actual(body) {
  assert(!/send|sign/i.test(body.method), "Never forward a signing method");
  const key = JSON.stringify([body.method, body.params]);
  if (!cache.has(key)) {
    cache.set(
      key,
      (async () => {
        const response = await fetch(rpcUrl, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(body),
        });
        assert(response.ok, `RPC HTTP ${response.status}`);
        const answer = await response.json();
        assert(!answer.error, answer.error?.message);
        return answer.result;
      })(),
    );
  }
  return cache.get(key);
}
async function fixture(width = 390, chain = "0x1") {
  const context = await browser.newContext({
    viewport: { width, height: 844 },
  });
  const page = await context.newPage();
  page.setDefaultTimeout(15000);
  page.on("pageerror", (e) => pageErrors.push(e.message));
  const f = {
    page,
    context,
    hold: undefined,
    simulations: [],
    allowances: true,
    permitAllowance: true,
  };
  f.delayBlock = (stale = false) => {
    let release, started;
    const hold = {
      stale,
      gate: new Promise((r) => {
        release = r;
      }),
      started: new Promise((r) => {
        started = r;
      }),
      release: () => release(),
      markStarted: () => started(),
    };
    f.hold = hold;
    return hold;
  };
  await page.route(
    /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/,
    async (route) => {
      const body = JSON.parse(route.request().postData());
      try {
        let result;
        if (body.method === "eth_getBlockByNumber") {
          const hold = f.hold;
          f.hold = undefined;
          if (hold) {
            hold.markStarted();
            await hold.gate;
          }
          const block = await actual(body);
          result = {
            ...block,
            timestamp: hold?.stale
              ? "0x1"
              : `0x${Math.floor(Date.now() / 1000).toString(16)}`,
          };
        } else if (
          body.method === "eth_getCode" &&
          body.params[0].toLowerCase() === caller
        ) {
          result = "0x";
        } else if (
          body.method === "eth_getBalance" &&
          body.params[0].toLowerCase() === caller
        ) {
          result = "0xde0b6b3a7640000";
        } else if (body.method === "eth_call") {
          const call = body.params[0],
            to = call.to.toLowerCase();
          if (to === router) {
            const decoded = decodeFunctionData({
              abi: routerAbi,
              data: call.data,
            });
            f.simulations.push({ to, ...decoded });
            result = "0x";
          } else {
            const abi = to === permit2 ? permitAbi : tradeAbi;
            let decoded;
            try {
              decoded = decodeFunctionData({ abi, data: call.data });
            } catch {}
            const name = decoded?.functionName,
              args = decoded?.args;
            let value;
            if (to === token && name === "trading") value = true;
            if (to === token && name === "currentRound") value = 1n;
            if (to === token && name === "frozenUntil") value = 0n;
            if (to === hook && name === "feeBps") value = 100n;
            if (to === stateView && name === "getSlot0")
              value = [79347087983666005045280518415n, 30, 0, 12500];
            if (to === stateView && name === "getLiquidity") value = 10n ** 24n;
            if (
              (to === token || to === pair) &&
              name === "balanceOf" &&
              args[0].toLowerCase() === caller
            )
              value = 100000n * 10n ** 18n;
            if ((to === token || to === pair) && name === "allowance")
              value = f.allowances ? 10n ** 30n : 0n;
            if (to === permit2 && name === "allowance")
              value = [
                f.allowances && f.permitAllowance ? 10n ** 30n : 0n,
                Math.floor(Date.now() / 1000) + 3600,
                0,
              ];
            if (
              (to === token || to === pair || to === permit2) &&
              name === "approve"
            ) {
              f.simulations.push({ to, ...decoded });
              value = to === permit2 ? undefined : true;
              result =
                to === permit2
                  ? "0x"
                  : encodeFunctionResult({
                      abi,
                      functionName: name,
                      result: value,
                    });
            } else if (value !== undefined) {
              result = encodeFunctionResult({
                abi,
                functionName: name,
                result: value,
              });
            }
          }
        }
        if (result === undefined) result = await actual(body);
        await route.fulfill({
          contentType: "application/json",
          body: JSON.stringify({ jsonrpc: "2.0", id: body.id, result }),
        });
      } catch (e) {
        await route.fulfill({
          contentType: "application/json",
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: body.id,
            error: { code: -32000, message: String(e.message) },
          }),
        });
      }
    },
  );
  await page.addInitScript(
    ({ caller, chain }) => {
      const listeners = {};
      const state = {
        account: caller,
        chain,
        authorized: false,
        switches: 0,
        sends: 0,
      };
      window.revisionWallet = state;
      const provider = {
        on: (event, fn) => (listeners[event] ??= []).push(fn),
        removeListener: (event, fn) => {
          listeners[event] = (listeners[event] || []).filter((f) => f !== fn);
        },
        request: async ({ method }) => {
          if (method === "eth_chainId") return state.chain;
          if (method === "eth_accounts")
            return state.authorized ? [state.account] : [];
          if (method === "eth_requestAccounts") {
            state.authorized = true;
            return [state.account];
          }
          if (method === "wallet_switchEthereumChain") {
            state.switches++;
            throw Object.assign(Error("User rejected the request."), {
              code: 4001,
            });
          }
          if (
            method === "wallet_getPermissions" ||
            method === "wallet_requestPermissions"
          )
            return [
              {
                parentCapability: "eth_accounts",
                caveats: [
                  { type: "restrictReturnedAccounts", value: [state.account] },
                ],
              },
            ];
          if (method === "wallet_getCapabilities") return {};
          if (/send|sign/i.test(method)) {
            state.sends++;
            throw Error("Test prohibits signing and sending");
          }
          throw Object.assign(
            Error("Unsupported mock wallet method " + method),
            { code: -32601 },
          );
        },
      };
      window.ethereum = provider;
      const announce = () =>
        window.dispatchEvent(
          new CustomEvent("eip6963:announceProvider", {
            detail: {
              info: {
                uuid: "ac0061de-2d00-4ec0-a0b1-fa7f19cae78b",
                name: "Revision test wallet",
                rdns: "test.revision",
                icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg"/>',
              },
              provider,
            },
          }),
        );
      window.addEventListener("eip6963:requestProvider", announce);
      announce();
    },
    { caller, chain },
  );
  return f;
}
async function connect(page) {
  await page.locator(".wallet-button").click();
  await page
    .getByRole("button", { name: "Revision test wallet", exact: true })
    .click();
  await page.getByText("100,000 MAD", { exact: false }).first().waitFor();
}
async function tradeForm(page) {
  await page.goto(base + "/#trade");
  await page.getByText(/Verified at block/).waitFor({ timeout: 60000 });
  await connect(page);
  await page.getByLabel("You pay in FWA").fill("1");
  await page.getByLabel("Slippage").selectOption("50");
}
function swapLegs(sim) {
  const [, commands] = decodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes[]" }],
    sim.args[1][0],
  );
  const settle = decodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    commands[1],
  );
  const take = decodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }],
    commands[2],
  );
  return {
    input: settle[0].toLowerCase(),
    amount: settle[1],
    output: take[0].toLowerCase(),
    minimum: take[1],
  };
}
try {
  // Reproduce the exact pending-buy-to-sell race, then cover every form input.
  for (const change of ["direction", "amount", "slippage", "deadline"]) {
    const f = await fixture(),
      { page } = f;
    try {
      await tradeForm(page);
      const pending = f.delayBlock();
      await page
        .getByRole("button", { name: "Get quote", exact: true })
        .click();
      await pending.started;
      if (change === "direction")
        await page
          .getByRole("button", { name: "Sell MAD", exact: true })
          .click();
      if (change === "amount")
        await page.getByLabel("You pay in FWA").fill("2");
      if (change === "slippage")
        await page.getByLabel("Slippage").selectOption("100");
      if (change === "deadline")
        await page.getByLabel("Deadline").selectOption("10");
      pending.release();
      // Wait for the fixture quote's snapshot (including code checks) to finish.
      await page
        .getByRole("button", { name: "Get quote", exact: true })
        .waitFor();
      await page.waitForLoadState("networkidle");
      const published =
        (await page
          .getByRole("button", { name: "Review swap", exact: true })
          .count()) > 0;
      assert.equal(
        published,
        baseline,
        `${change}: obsolete quote must not be published`,
      );
      const evidence = { change, obsoleteQuotePublished: published };
      if (baseline && change === "direction") {
        await page
          .getByRole("button", { name: "Review swap", exact: true })
          .click();
        const review = page.getByRole("dialog", {
          name: "Swap MAD for FWA",
          exact: true,
        });
        await review.waitFor({ timeout: 60000 });
        const legs = swapLegs(f.simulations.at(-1));
        assert.equal(legs.input, pair);
        assert.equal(legs.output, token);
        evidence.review = await review.innerText();
        evidence.encodedInput = legs.input;
        evidence.encodedOutput = legs.output;
        await page.screenshot({
          path: "test/scratch/revision/baseline-opposite-swap.png",
        });
      }
      if (!baseline)
        assert.equal(
          await page.locator("#swap-output").innerText(),
          "Awaiting quote",
        );
      results.push({
        name: `${change} invalidates pending quote`,
        ...evidence,
      });
      assert.equal(await page.evaluate(() => window.revisionWallet.sends), 0);
    } finally {
      await f.context.close();
    }
  }
  if (!baseline) {
    for (const kind of ["swap", "erc20", "permit"]) {
      const f = await fixture(),
        { page } = f;
      try {
        f.allowances = kind !== "erc20";
        f.permitAllowance = kind === "swap";
        await tradeForm(page);
        await page
          .getByRole("button", { name: "Get quote", exact: true })
          .click();
        const actionName =
          kind === "swap"
            ? "Review swap"
            : kind === "erc20"
              ? "Review token approval"
              : "Review router allowance";
        await page
          .getByRole("button", { name: actionName, exact: true })
          .waitFor();
        const pending = f.delayBlock();
        await page
          .getByRole("button", { name: actionName, exact: true })
          .click();
        await pending.started;
        await page
          .getByRole("button", { name: "Sell MAD", exact: true })
          .click();
        pending.release();
        await page
          .getByText("Trade changed. Get a fresh quote before continuing.", {
            exact: true,
          })
          .waitFor();
        assert.equal(f.simulations.length, 0);
        assert.equal(await page.getByRole("dialog").isVisible(), false);
        assert.equal(await page.evaluate(() => window.revisionWallet.sends), 0);
        results.push({
          name: `${kind} preflight rejects a form change before simulation or review`,
        });
      } finally {
        await f.context.close();
      }
    }
    for (const scenario of ["round-trip edit", "old error", "unmount"]) {
      const f = await fixture(),
        { page } = f;
      try {
        await tradeForm(page);
        const pending = f.delayBlock(scenario === "old error");
        await page
          .getByRole("button", { name: "Get quote", exact: true })
          .click();
        await pending.started;
        if (scenario === "unmount") {
          await page.locator('nav a[href="#rounds"]').click();
          await page.locator('nav a[href="#trade"]').click();
        } else {
          await page.getByLabel("You pay in FWA").fill("2");
          if (scenario === "round-trip edit")
            await page.getByLabel("You pay in FWA").fill("1");
          if (scenario === "old error") {
            await page
              .getByRole("button", { name: "Get quote", exact: true })
              .click();
            await page
              .getByRole("button", { name: "Review swap", exact: true })
              .waitFor();
          }
        }
        pending.release();
        await page.waitForLoadState("networkidle");
        assert.equal(
          await page
            .getByRole("button", { name: "Review swap", exact: true })
            .count(),
          scenario === "old error" ? 1 : 0,
        );
        assert.equal(await page.locator(".trade-panel > .error").count(), 0);
        assert.equal(await page.evaluate(() => window.revisionWallet.sends), 0);
        results.push({
          name: `${scenario} cannot revive a cancelled quote or overwrite current feedback`,
        });
      } finally {
        await f.context.close();
      }
    }
  }
  if (!baseline) {
    // Fresh reviews must describe exactly the same assets and bounds as execute().
    for (const buy of [true, false]) {
      const f = await fixture(),
        { page } = f;
      try {
        await tradeForm(page);
        if (!buy)
          await page
            .getByRole("button", { name: "Sell MAD", exact: true })
            .click();
        await page
          .getByRole("button", { name: "Get quote", exact: true })
          .click();
        await page
          .getByRole("button", { name: "Review swap", exact: true })
          .click();
        const input = buy ? "FWA" : "MAD",
          output = buy ? "MAD" : "FWA";
        const review = page.getByRole("dialog", {
          name: `Swap ${input} for ${output}`,
          exact: true,
        });
        await review.waitFor({ timeout: 60000 });
        const legs = swapLegs(f.simulations.at(-1));
        assert.equal(legs.input, buy ? pair : token);
        assert.equal(legs.output, buy ? token : pair);
        assert.equal(legs.amount, 10n ** 18n);
        assert(legs.minimum > 0n);
        assert.equal(
          await review
            .getByText("Input", { exact: true })
            .locator("..")
            .locator("dd")
            .innerText(),
          `1 ${input}`,
        );
        assert(
          (
            await review
              .getByText("Minimum output", { exact: true })
              .locator("..")
              .locator("dd")
              .innerText()
          ).endsWith(`${output} (${legs.minimum} base units)`),
        );
        await page.screenshot({
          path: `test/scratch/revision/${buy ? "buy" : "sell"}-review.png`,
        });
        assert.equal(await page.evaluate(() => window.revisionWallet.sends), 0);
        results.push({
          name: `fresh ${buy ? "buy" : "sell"} review matches decoded execute assets and exact bounds`,
        });
      } finally {
        await f.context.close();
      }
    }
    for (const buy of [true, false])
      for (const kind of ["erc20", "permit"]) {
        const f = await fixture(),
          { page } = f;
        try {
          f.allowances = kind !== "erc20";
          f.permitAllowance = false;
          await tradeForm(page);
          if (!buy)
            await page
              .getByRole("button", { name: "Sell MAD", exact: true })
              .click();
          await page
            .getByRole("button", { name: "Get quote", exact: true })
            .click();
          await page
            .getByRole("button", {
              name:
                kind === "erc20"
                  ? "Review token approval"
                  : "Review router allowance",
              exact: true,
            })
            .click();
          const review = page.getByRole("dialog", {
            name: `Approve 1 ${buy ? "FWA" : "MAD"}`,
            exact: true,
          });
          await review.waitFor({ timeout: 60000 });
          const sim = f.simulations.at(-1),
            asset = buy ? pair : token;
          assert.equal(sim.functionName, "approve");
          assert.equal(sim.to, kind === "erc20" ? asset : permit2);
          assert.equal(sim.args[kind === "erc20" ? 1 : 2], 10n ** 18n);
          assert.equal(
            sim.args[kind === "erc20" ? 0 : 1].toLowerCase(),
            kind === "erc20" ? permit2 : router,
          );
          if (kind === "permit") assert.equal(sim.args[0].toLowerCase(), asset);
          assert.equal(
            (
              await review
                .getByText("Token", { exact: true })
                .locator("..")
                .locator("dd")
                .innerText()
            ).toLowerCase(),
            asset,
          );
          assert.equal(
            await page.evaluate(() => window.revisionWallet.sends),
            0,
          );
          results.push({
            name: `${buy ? "buy" : "sell"} ${kind} review matches simulated token, exact amount and spender`,
          });
        } finally {
          await f.context.close();
        }
      }
    const f = await fixture(),
      { page } = f;
    try {
      await tradeForm(page);
      const older = f.delayBlock();
      await page
        .getByRole("button", { name: "Get quote", exact: true })
        .click();
      await older.started;
      await page.getByLabel("You pay in FWA").fill("2");
      await page
        .getByRole("button", { name: "Get quote", exact: true })
        .click();
      await page
        .getByRole("button", { name: "Review swap", exact: true })
        .waitFor();
      const newOutput = await page.locator("#swap-output").innerText();
      older.release();
      await page.waitForLoadState("networkidle");
      assert.equal(await page.locator("#swap-output").innerText(), newOutput);
      await page
        .getByRole("button", { name: "Review swap", exact: true })
        .click();
      const review = page.getByRole("dialog", {
        name: "Swap FWA for MAD",
        exact: true,
      });
      await review.waitFor({ timeout: 60000 });
      assert.equal(swapLegs(f.simulations.at(-1)).amount, 2n * 10n ** 18n);
      assert.equal(await page.evaluate(() => window.revisionWallet.sends), 0);
      results.push({
        name: "older quote finishing last cannot replace a new quote",
      });
    } finally {
      await f.context.close();
    }
  }
  // Wrong network: rejection must leave both wallet management and navigation usable.
  for (const width of [320, 390, 1440]) {
    const f = await fixture(width, "0x89"),
      { page } = f;
    try {
      await page.goto(base + "/#trade");
      await page.getByText(/Verified at block/).waitFor({ timeout: 60000 });
      await connect(page);
      await page.locator(".wallet-button").click();
      if (!baseline) {
        await page
          .getByRole("dialog", { name: "Connected wallet", exact: true })
          .waitFor();
        await page
          .getByRole("button", { name: "Switch to Ethereum", exact: true })
          .click();
      }
      await page
        .locator(baseline ? ".wallet-error" : ".wallet-dialog .error")
        .waitFor();
      const disconnectVisible = await page
        .getByRole("button", { name: "Disconnect", exact: true })
        .isVisible();
      assert.equal(disconnectVisible, !baseline);
      if (!baseline) {
        await page.screenshot({
          path: `test/scratch/revision/wallet-rejected-${width}.png`,
        });
        await page.keyboard.press("Escape");
        assert.equal(
          await page
            .locator(".wallet-button")
            .evaluate((el) => document.activeElement === el),
          true,
        );
        assert.equal(
          await page
            .getByText("User rejected the request.", { exact: true })
            .count(),
          0,
        );
      }
      const nav = await page
        .locator('nav[aria-label="Main navigation"] a')
        .evaluateAll((links) =>
          links.map((a) => {
            const r = a.getBoundingClientRect();
            const hit = document.elementFromPoint(
              r.x + r.width / 2,
              r.y + r.height / 2,
            );
            return {
              href: a.hash,
              hit: a.contains(hit),
              interceptedBy: hit?.className?.baseVal ?? hit?.className,
            };
          }),
        );
      assert.equal(
        nav.filter((n) => !n.hit).length,
        baseline && width < 840 ? 5 : 0,
      );
      if (!baseline) {
        for (const n of nav) {
          await page.locator(`nav a[href="${n.href}"]`).click();
          assert.equal(new URL(page.url()).hash, n.href);
        }
        await page.locator(".wallet-button").click();
        const dialog = page.getByRole("dialog", {
          name: "Connected wallet",
          exact: true,
        });
        await dialog.waitFor();
        assert.equal(await dialog.locator(".error").count(), 0);
        await page
          .getByRole("button", { name: "Disconnect", exact: true })
          .click();
        await page
          .locator(".wallet-button")
          .filter({ hasText: /Connect/ })
          .waitFor();
      }
      assert.equal(await page.evaluate(() => window.revisionWallet.sends), 0);
      results.push({
        name: `wrong network rejection/disconnect/navigation at ${width}`,
        disconnectVisible,
        nav,
      });
    } finally {
      await f.context.close();
    }
  }
  const f = await fixture(),
    { page } = f;
  try {
    await page.goto(base + "/#rounds");
    await page.getByText(/Verified at block/).waitFor({ timeout: 60000 });
    for (const [field, button, noun] of [
      [
        "Acquisition request ID",
        "Inspect acquisition",
        "acquisition request ID",
      ],
      ["Round number", "Inspect round", "round number"],
    ]) {
      const input = page.getByLabel(field, { exact: true });
      await input.fill("0");
      await page.getByRole("button", { name: button, exact: true }).click();
      const attrs = await input.evaluate((el) => {
        const describedBy = el.getAttribute("aria-describedby");
        const error = describedBy && document.getElementById(describedBy);
        const r = el.getBoundingClientRect(),
          e = error && error.getBoundingClientRect();
        return {
          invalid: el.getAttribute("aria-invalid"),
          describedBy,
          text: error?.textContent,
          inputBottom: r.bottom,
          errorTop: e?.top,
          errorBottom: e?.bottom,
          focused: document.activeElement === el,
        };
      });
      assert.equal(attrs.invalid, baseline ? null : "true");
      if (!baseline) {
        assert.equal(attrs.text, `Enter a positive decimal ${noun}.`);
        assert(
          attrs.errorTop >= attrs.inputBottom &&
            attrs.errorTop - attrs.inputBottom < 35,
        );
        assert(attrs.errorBottom <= 844);
        assert(attrs.focused);
        await page.screenshot({
          path: `test/scratch/revision/${noun.replaceAll(" ", "-")}-error.png`,
        });
      }
      results.push({ name: `${field} adjacent accessible error`, ...attrs });
    }
    if (!baseline) {
      const request = page.getByLabel("Acquisition request ID", {
        exact: true,
      });
      const round = page.getByLabel("Round number", { exact: true });
      await request.fill("1");
      assert.equal(await request.getAttribute("aria-invalid"), "false");
      assert.equal(await round.getAttribute("aria-invalid"), "true");
      await round.fill("1");
      assert.equal(await round.getAttribute("aria-invalid"), "false");
      for (const [field, button, noun] of [
        [
          "Acquisition request ID",
          "Inspect acquisition",
          "Acquisition request ID",
        ],
        ["Round number", "Inspect round", "Round number"],
      ]) {
        await page
          .getByLabel(field, { exact: true })
          .fill((1n << 256n).toString());
        await page.getByRole("button", { name: button, exact: true }).click();
        await page
          .getByText(`${noun} must be smaller than 2^256.`, { exact: true })
          .waitFor();
      }
      results.push({
        name: "field errors clear independently; uint256 overflow stays field-specific",
      });
    }
  } finally {
    await f.context.close();
  }
  assert.deepEqual(pageErrors, []);
  results.push({
    name: "no uncaught browser errors; all wallet sends prohibited",
  });
  await fs.writeFile(
    `test/scratch/revision/${baseline ? "baseline" : "fixed"}-results.json`,
    JSON.stringify(results, null, 2),
  );
  console.log(JSON.stringify({ baseline, results }, null, 2));
} finally {
  await fs.writeFile(
    `test/scratch/revision/${baseline ? "baseline" : "fixed"}-results.json`,
    JSON.stringify(results, null, 2),
  );
  await browser.close();
  await new Promise((r) => server.close(r));
}
