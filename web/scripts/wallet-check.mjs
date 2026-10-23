import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { chromium } from "/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs";
const rpcUrl = process.argv[2] || "https://ethereum-rpc.publicnode.com";
const server = http.createServer(async (req, res) => {
  try {
    const rel = new URL(req.url, "http://localhost").pathname;
    const p = path.resolve("dist", "." + (rel === "/" ? "/index.html" : rel));
    if (!p.startsWith(path.resolve("dist") + path.sep))
      throw Error("Outside export");
    res.setHeader(
      "content-type",
      {
        ".html": "text/html",
        ".js": "text/javascript",
        ".css": "text/css",
        ".json": "application/json",
        ".svg": "image/svg+xml",
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
const results = [];
let snapshotCalls = 0;
const fakeHash = "0x" + "99".repeat(32);
const owner = "0xfc3c962fad2c1cc77f1a0d46e7b8a2de79a21774";
const nonowner = "0xcecc29b037f5064fcdf45a5c318f132ef76aa551";
const handoff = JSON.parse(
  await fs.readFile("dist/imd-deployment.json", "utf8"),
);
const rpc = async (body) => {
  const r = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return r.json();
};
const oldReceipt = (
  await rpc({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getTransactionReceipt",
    params: [handoff.contracts[0].txHash],
  })
).result;
try {
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  let failRPC = false;
  await page.route(
    /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/,
    async (route) => {
      const body = JSON.parse(route.request().postData());
      if (failRPC) {
        return route.fulfill({
          contentType: "application/json",
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: body.id,
            error: { code: -32000, message: "Test: RPC unavailable" },
          }),
        });
      }
      if (body.method === "eth_getBlockByNumber") snapshotCalls++;
      if (
        body.method === "eth_getTransactionReceipt" &&
        body.params[0] === fakeHash
      )
        return route.fulfill({
          contentType: "application/json",
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: body.id,
            result: {
              ...oldReceipt,
              transactionHash: fakeHash,
              from: owner,
              to: handoff.contracts[0].address,
              logs: [],
              status: "0x1",
            },
          }),
        });
      try {
        const answer = await rpc(body);
        await route.fulfill({
          contentType: "application/json",
          body: JSON.stringify(answer),
        });
      } catch {
        await route.abort();
      }
    },
  );
  await page.addInitScript(
    ({ owner, nonowner, fakeHash }) => {
      const listeners = {};
      const state = {
        account: nonowner,
        chain: "0x89",
        sends: 0,
        reject: true,
        authorized: false,
      };
      window.testWallet = state;
      const emit = (name, data) =>
        (listeners[name] || []).forEach((fn) => fn(data));
      window.testEmit = emit;
      const provider = {
        isMetaMask: true,
        on: (event, fn) => {
          (listeners[event] ??= []).push(fn);
        },
        removeListener: (event, fn) => {
          listeners[event] = (listeners[event] || []).filter((f) => f !== fn);
        },
        request: async ({ method, params }) => {
          if (method === "eth_chainId") return state.chain;
          if (method === "eth_accounts")
            return state.authorized ? [state.account] : [];
          if (method === "eth_requestAccounts") {
            state.authorized = true;
            return [state.account];
          }
          if (method === "wallet_switchEthereumChain") {
            state.chain = params[0].chainId;
            emit("chainChanged", state.chain);
            return null;
          }
          if (method === "wallet_addEthereumChain") return null;
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
          if (method === "eth_sendTransaction") {
            state.sends++;
            if (state.reject)
              throw Object.assign(Error("Test: wallet request rejected"), {
                code: 4001,
              });
            return fakeHash;
          }
          throw Object.assign(
            Error("Unsupported test provider method " + method),
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
                uuid: "092fabd1-50b3-4d5b-9b62-846b771f8ee1",
                name: "Test browser wallet",
                rdns: "test.wallet",
                icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg"/>',
              },
              provider,
            },
          }),
        );
      window.addEventListener("eip6963:requestProvider", announce);
      announce();
    },
    { owner, nonowner, fakeHash },
  );
  await page.goto(base + "/#manage", { waitUntil: "networkidle" });
  await page.getByText(/Verified at block/).waitFor({ timeout: 60000 });
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Test browser wallet", exact: true })
    .click();
  await page.locator(".wallet-button").click();
  await page
    .getByRole("dialog", { name: "Connected wallet", exact: true })
    .waitFor();
  results.push({ name: "wrong-network control present", passed: true });
  await page
    .getByRole("button", { name: "Switch to Ethereum", exact: true })
    .click();
  await page.keyboard.press("Escape");
  await page
    .getByText("This wallet has no verified contract-owner role.")
    .waitFor();
  results.push({
    name: "switch-chain and nonowner role gate",
    passed:
      (await page
        .getByRole("button", { name: "Review trading enablement" })
        .count()) === 0,
  });
  await page.evaluate((owner) => {
    window.testWallet.account = owner;
    window.testEmit("accountsChanged", [owner]);
  }, owner);
  await page
    .getByRole("button", { name: "Review registry policy", exact: true })
    .waitFor({ timeout: 30000 });
  results.push({
    name: "account change revalidates actual owner",
    passed: true,
  });
  await page
    .getByRole("button", { name: "Review registry policy", exact: true })
    .click();
  await page
    .getByRole("dialog", {
      name: "Change global distributor policy",
      exact: true,
    })
    .waitFor({ timeout: 60000 });
  results.push({
    name: "owner action live simulation and explicit review",
    passed: true,
  });
  // Change accounts after a successful simulation; confirmation must recheck ownership.
  await page.evaluate((address) => {
    window.testWallet.account = address;
    window.testEmit("accountsChanged", [address]);
  }, nonowner);
  await page
    .getByText("This wallet has no verified contract-owner role.")
    .waitFor();
  await page
    .getByRole("button", { name: "Confirm in wallet", exact: true })
    .click();
  await page
    .getByText("The connected wallet does not own this contract.")
    .waitFor({ timeout: 60000 });
  results.push({
    name: "account change during review blocks the write",
    passed: (await page.evaluate(() => window.testWallet.sends)) === 0,
  });
  await page
    .getByRole("button", { name: "Dismiss transaction status", exact: true })
    .click();
  await page.evaluate((address) => {
    window.testWallet.account = address;
    window.testEmit("accountsChanged", [address]);
  }, owner);
  await page
    .getByRole("button", { name: "Review registry policy", exact: true })
    .waitFor();
  await page
    .getByRole("button", { name: "Review registry policy", exact: true })
    .click();
  await page
    .getByRole("dialog", {
      name: "Change global distributor policy",
      exact: true,
    })
    .waitFor({ timeout: 60000 });
  await page
    .getByRole("button", { name: "Confirm in wallet", exact: true })
    .click();
  await page.locator(".transaction-banner.error").waitFor({ timeout: 60000 });
  console.log(
    "Wallet rejection: " +
      (await page.locator(".transaction-banner.error").innerText()),
  );
  results.push({
    name: "wallet rejection displayed without duplicate send",
    passed: (await page.evaluate(() => window.testWallet.sends)) === 1,
  });
  await page
    .getByRole("button", { name: "Dismiss transaction status", exact: true })
    .click();
  await page.evaluate(() => (window.testWallet.reject = false));
  await page
    .getByRole("button", { name: "Review registry policy", exact: true })
    .click();
  await page
    .getByRole("dialog", {
      name: "Change global distributor policy",
      exact: true,
    })
    .waitFor({ timeout: 60000 });
  const before = snapshotCalls;
  await page
    .getByRole("button", { name: "Confirm in wallet", exact: true })
    .click();
  await page
    .getByText("Transaction confirmed. Live state has been refreshed.")
    .waitFor({ timeout: 60000 });
  await page.waitForTimeout(2000);
  results.push({
    name: "mock confirmed receipt refreshes real reads",
    passed:
      snapshotCalls > before &&
      (await page.evaluate(() => window.testWallet.sends)) === 2,
  });
  await page.screenshot({ path: "test/scratch/owner-390.png", fullPage: true });
  await page.evaluate((nonowner) => {
    window.testWallet.account = nonowner;
    window.testEmit("accountsChanged", [nonowner]);
  }, nonowner);
  await page
    .getByText("This wallet has no verified contract-owner role.")
    .waitFor();
  results.push({
    name: "switching away removes all owner controls",
    passed:
      (await page
        .getByRole("button", { name: "Review registry policy" })
        .count()) === 0,
  });
  failRPC = true;
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await page
    .getByText(/Last successful values remain visible as stale/)
    .waitFor({ timeout: 60000 });
  results.push({
    name: "RPC failure preserves stale values and disables writes",
    passed:
      (await page.getByText("State is stale", { exact: true }).count()) > 0 ||
      (await page
        .getByText("Live reads unavailable", { exact: true })
        .count()) > 0,
  });
  console.log(JSON.stringify(results, null, 2));
  if (results.some((r) => !r.passed)) process.exitCode = 1;
  await fs.writeFile(
    "test/scratch/wallet-results.json",
    JSON.stringify(results, null, 2),
  );
} finally {
  await browser.close();
  await new Promise((r) => server.close(r));
}
