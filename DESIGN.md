# MAD website design

MAD is a control room for paid wallet freezes and NFT prize rounds. A forest-green navigation rail, pale green action color and restrained snowflake motif connect the interface to the 24-hour freeze mechanic. The working form precedes the explanatory content.

## Implemented tokens

Values are from `web/src/style.css`.

| Role | Value |
| --- | --- |
| Page background | `#f4f5ef` |
| Main surface | `#ffffff` |
| Primary text | `#172c27` |
| Secondary text | `#5d6e64` |
| Structural border | `#dfe5da` |
| Primary action / selected navigation | `#c9f6b8` |
| Action hover | `#b8e7a5` |
| Navigation / round surface | `#112c26` |
| Neutral notice | `#edf2e8` |
| Error text | `#a33332` |
| Warning text | `#775014` |
| Focus outline | `2px solid #2b6e48`, offset `4px` |

Warning and error notices also carry an icon and written explanation. Color alone does not indicate availability. Buttons have explicit disabled labels or adjacent explanations.

## Typography

The sans-serif stack is Inter if locally available, then system fonts, Segoe UI, Arial and sans-serif. No font download is required. Addresses and hashes use the system monospace stack and wrap rather than ellipsize. Inputs retain 16px text.

The six steps are 12, 14, 16, 20, 32 and 48px. The only weights are 400, 500 and 600. Body descriptions use 14px with 1.6 line height; the default line height is 1.5. Desktop page headings use 48px with -0.045em tracking; phone headings use 32px with -0.04em tracking. Data uses the same scale. Long transaction amounts and addresses wrap in review dialogs.

## Layout and spacing

Desktop uses a 236px navigation column and a flexible content column. The rail reduces to 204px below 1150px. Main content has 40px horizontal padding, reducing to 28px and then 20px. Panels use 28px padding, then 24px and 22px; 320px layouts use 18px panels and 16px page gutters.

The freeze form occupies the leading column. A decorative 24-hour graphic and current round summary occupy the other column. Metrics and wallet positions follow the working form. Other screens use paired panels, a sequential event feed or a long-form rules column with contract references. Normal gaps are 8, 12, 16, 20, 24 and 32px; larger section separations use 40 or 48px.

At 840px the rail becomes a compact header and six-item navigation row. Labels shorten to Rewards and Rules on mobile while retaining their destinations. At 620px paired content stacks, the decorative freeze graphic disappears and forms remain full width. At 359px paired form controls stack. The wallet chooser becomes a bottom sheet below 640px through the mobile dialog rules. The product and Inspect wallet action remain on the first 390px screen; the measured action starts at y=495px and is 48px tall.

## Components

- `WalletControl`: one connect control, discovered extension identities, local vendor marks, mobile wallet links, Coinbase Smart Wallet, network switching and disconnect. The connected header control opens the dialog on every network; a wrong-network label identifies the need to switch. Switch rejection stays inside the dialog alongside Disconnect, clears on close, and never floats over navigation. Native modal dialog provides background inertness and focus behavior.
- `FreezePage`: labeled target input, live inspection, exact freeze-cost breakdown, current lock and guarded transaction review.
- `TradePage`: buy/sell selection, amount, explicit slippage selection, deadline, quote details, exact spender approvals and swap review. Any form change cancels its pending quote generation and clears the displayed result. Approval/review requires the quote to match the current form, including during preflight; review assets come from that quote. Closed trading and missing liquidity have written unavailable states.
- `RoundsPage`: current round conditions, separate spendable budget and claims, NFT purchase/settlement, closed-round lookup, oracle request and award actions, NFT queue. Acquisition request ID and round number keep separate, adjacent errors associated with their input through `aria-invalid` and `aria-describedby`. Invalid submission focuses the field; editing clears only that field’s error. The round input/error share the existing inline form’s flexible field column.
- `Transactions`: shared simulation/review/confirmation sequence; exact contract, function, arguments and consequences; persistent pending status; receipt links and retryable unknown confirmation.
- `Notice`, `DataRow`, `Empty`, `AddressLink`: consistent status, exact data and recovery patterns.
- `ManagePage`: permission summary for everyone; settings only for verified owners. Current values and consequences precede confirmation.

Panels use 12px radii and structural borders without shadows. Controls use 6–8px radii and at least 44px height for primary actions. Secondary mobile navigation uses 56px targets. The design probe confirms its 24px-or-spacing target threshold; some utility links remain smaller than the preferred 44px target.

## Interaction and motion

Links retain normal browser behavior. Forms use native labels, inputs, selects and buttons. The first focusable element is Skip to content. Dialogs close with Escape or their close control and return focus. Reverts and wallet rejections stay visible until dismissed. Pending transactions prevent another submission.

Only background, color and pressed-scale transitions are used, at 120ms. Pressed buttons scale to 0.96. Motion is enabled only under `prefers-reduced-motion: no-preference`; no perpetual animation is present.

## Verified behavior and constraints

Chromium checks covered 320, 390 and 1440px, all six pages at 390px, wallet dialogs, actual reads, owner-role changes and transaction states with a mock signing provider. The pinned taste probe passed all 16 checks, including measured text contrast, overflow, type scale, reduced motion and share metadata. See `VALIDATION.md` for exact scope and limitations. Native screen-reader testing, physical phone wallet apps, browser-native 200% zoom and WebKit are not claimed.

Retain the exact deployment data and transaction checks when changing presentation. Keep failed reads unavailable, claims separate from spendable funds, and costly actions behind explicit review. Do not replace real contract state with sample activity, balances, NFT artwork or an always-enabled swap button.

Design knowledge: Jakub Krehel’s Better Interface (MIT), with documentation guidance adapted from Paul Bakaus’s Impeccable (Apache-2.0). The supplied notices are preserved in `docs/licenses/website-guides.txt`.
