import { build } from "vite";
import { fileURLToPath } from "node:url";
await build({
  configFile: false,
  root: fileURLToPath(new URL("../", import.meta.url)),
  ssr: { noExternal: true },
  build: {
    ssr: "scripts/quote-tests.mjs",
    outDir: "../test/scratch/quote-tests",
    emptyOutDir: true,
    minify: false,
  },
});
await import("../../test/scratch/quote-tests/quote-tests.js");
