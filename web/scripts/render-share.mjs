import { chromium } from "/opt/imd-tools/playwright-mcp/node_modules/playwright/index.mjs";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({
    viewport: { width: 1200, height: 630 },
    deviceScaleFactor: 1,
  });
  const source = await fs.readFile(
    new URL("../public/share.svg", import.meta.url),
    "utf8",
  );
  await page.setContent(`<html><body style="margin:0">${source}</body></html>`);
  await page.screenshot({
    path: fileURLToPath(new URL("../public/share.png", import.meta.url)),
  });
} finally {
  await browser.close();
}
