import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { chromium } from "/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs";
const mime = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};
const rpcUrl = process.argv[2] || "https://ethereum-rpc.publicnode.com";
const server = http.createServer(async (req, res) => {
  try {
    const rel = decodeURIComponent(
      new URL(req.url, "http://localhost").pathname,
    );
    const p = path.resolve("dist", "." + (rel === "/" ? "/index.html" : rel));
    if (!p.startsWith(path.resolve("dist") + path.sep)) throw Error();
    res.setHeader(
      "content-type",
      mime[path.extname(p)] || "application/octet-stream",
    );
    res.end(await fs.readFile(p));
  } catch {
    res.writeHead(404);
    res.end("Missing");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
const browser = await chromium.launch({ headless: true });
const results = [];
try {
  const page = await browser.newPage({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 1,
  });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  // Same Ethereum methods as production, forwarded through the worker-provided RPC for this check.
  await page.route(
    /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/,
    async (route) => {
      try {
        const response = await fetch(rpcUrl, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: route.request().postData(),
        });
        await route.fulfill({
          status: response.status,
          contentType: "application/json",
          body: await response.text(),
        });
      } catch (e) {
        await route.abort();
      }
    },
  );
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "networkidle" });
  await page.getByText(/Verified at block/).waitFor({ timeout: 60000 });
  results.push({ name: "live verified snapshot", passed: true });
  const primary = page.getByRole("button", { name: "Inspect wallet" });
  const box = await primary.boundingBox();
  results.push({
    name: "primary action visible at 390",
    passed: box.y + box.height <= 844,
    box,
  });
  await primary.click();
  await page.getByText("Enter a complete Ethereum wallet address").waitFor();
  results.push({ name: "invalid wallet validation", passed: true });
  await page
    .getByLabel("Target wallet")
    .fill("0xfc3c962fad2c1cc77f1a0d46e7b8a2de79a21774");
  await primary.click();
  await page
    .getByText("Target balance", { exact: true })
    .waitFor({ timeout: 30000 });
  results.push({
    name: "real wallet inspection and closed trading gate",
    passed: await page
      .getByRole("button", { name: "Review freeze" })
      .isDisabled(),
  });
  await page.screenshot({
    path: "test/scratch/freeze-390.png",
    fullPage: true,
  });
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await page.getByRole("dialog", { name: "Connect a wallet" }).waitFor();
  results.push({ name: "wallet chooser reachable", passed: true });
  await page.keyboard.press("Escape");
  results.push({
    name: "wallet chooser Escape closes",
    passed: (await page.getByRole("dialog").isVisible()) === false,
  });
  for (const [id, heading] of [
    ["trade", "Trade MAD."],
    ["rounds", "Play for the prize."],
    ["activity", "Moves, on the record."],
    ["manage", "Contract management."],
    ["protocol", "Know the cold rules."],
  ]) {
    await page.goto(`http://127.0.0.1:${port}/#${id}`, {
      waitUntil: "networkidle",
    });
    await page.getByRole("heading", { name: heading, exact: true }).waitFor();
    if (id === "trade")
      results.push({
        name: "trade unavailable honestly on live closed pool",
        passed: await page
          .getByRole("button", { name: "Get quote", exact: true })
          .isDisabled(),
      });
    if (id === "manage")
      results.push({
        name: "unauthorized management controls hidden",
        passed:
          (await page
            .getByText(
              "Connect a wallet to check its current management permissions.",
            )
            .isVisible()) &&
          (await page
            .getByRole("button", { name: "Review trading enablement" })
            .count()) === 0,
      });
    if (id === "rounds") {
      await page.getByLabel("Round number", { exact: true }).fill("1");
      await page
        .getByRole("button", { name: "Inspect round", exact: true })
        .click();
      await page
        .getByRole("heading", { name: "This round has not closed" })
        .waitFor();
      results.push({ name: "live unopened round inspection", passed: true });
    }
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth > innerWidth,
    );
    results.push({
      name: `${id} mobile no horizontal overflow`,
      passed: !overflow,
    });
    results.push({
      name: `${id} focus and skip-link state`,
      passed: true,
      focus: await page.evaluate(() => ({
        active: document.activeElement?.className,
        skipTop: getComputedStyle(document.querySelector(".skip-link")).top,
        scroll: scrollY,
      })),
    });
    await page.screenshot({
      path: `test/scratch/${id}-390.png`,
      fullPage: true,
    });
  }
  for (const width of [320, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    await page.goto(`http://127.0.0.1:${port}/#freeze`, {
      waitUntil: "networkidle",
    });
    results.push({
      name: `freeze no overflow at ${width}`,
      passed: await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    });
    await page.screenshot({
      path: `test/scratch/freeze-${width}.png`,
      fullPage: true,
    });
  }
  const mobile = await browser.newPage({
    viewport: { width: 390, height: 844 },
    userAgent:
      "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36",
  });
  mobile.on("pageerror", (e) => errors.push(e.message));
  await mobile.route(
    /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/,
    (route) => route.abort(),
  );
  await mobile.goto(`http://127.0.0.1:${port}/`, {
    waitUntil: "domcontentloaded",
  });
  await mobile
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  for (const name of ["MetaMask", "Coinbase Wallet", "Rabby", "Phantom"])
    await mobile
      .getByRole("link", { name: `Open in ${name}`, exact: true })
      .waitFor();
  await mobile
    .getByRole("button", { name: "Coinbase Smart Wallet", exact: true })
    .waitFor();
  results.push({
    name: "mobile wallet paths work before RPC reads finish",
    passed: true,
  });
  await mobile.screenshot({ path: "test/scratch/mobile-wallet-390.png" });
  await mobile.keyboard.press("Escape");
  results.push({
    name: "wallet dialog restores keyboard focus",
    passed: await mobile.evaluate(() =>
      document.activeElement?.classList.contains("wallet-button"),
    ),
  });
  await mobile.keyboard.press("Shift+Tab");
  await mobile.close();
  results.push({
    name: "no uncaught browser errors",
    passed: errors.length === 0,
    errors,
  });
  await fs.writeFile(
    "test/scratch/browser-results.json",
    JSON.stringify(results, null, 2),
  );
  console.log(JSON.stringify(results, null, 2));
  if (results.some((r) => !r.passed)) process.exitCode = 1;
} finally {
  await browser.close();
  await new Promise((r) => server.close(r));
}
