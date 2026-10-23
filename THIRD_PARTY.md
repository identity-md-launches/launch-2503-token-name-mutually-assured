# Website third-party material

Frontend packages are installed normally from the committed `web/package-lock.json`; no package archive or dependency directory is part of the deliverable. Their upstream licenses apply: React/React DOM, wagmi, viem and TanStack Query (MIT), Coinbase Wallet SDK (Apache-2.0), and Lucide icons (ISC).

The MetaMask, Coinbase, Rabby and Phantom wallet marks are copied from RainbowKit’s wallet connector assets. Their bundled license is `web/public/wallets/LICENSE`, also included in the static export. The marks identify the supported wallet apps.

`web/src/ticks.ts` ports Uniswap TickMath’s integer calculation, with the MIT notice included in that file. `web/tests/quote-vectors.json` records independent reference values from the unmodified `@uniswap/v3-sdk` 3.31.7 TickMath and SwapMath, including its npm integrity and source URL. That SDK is not a frontend dependency.

The pinned Better Interface and design-documentation notices are retained in `docs/licenses/website-guides.txt`.

Wallet links follow the pinned connector reference. The Rabby link additionally follows the vendor’s current handler: `_cmd=open-dapp` and `dapp` under `/mobile/`, in [Rabby’s handler source](https://github.com/RabbyHub/rabby-mobile/blob/develop/apps/mobile/src/hooks/universalLink.ts). Actual app handoffs were not tested on physical phones.

The favicon and share artwork are local SVG compositions. The share PNG is a browser rendering of `web/public/share.svg`; `web/scripts/render-share.mjs` reproduces it using the supplied Chromium tooling.
