import {
  decodeEventLog,
  keccak256,
  parseAbi,
  zeroAddress,
  type Address,
  type Abi,
} from "viem";
import { ABI, abiDigest, type Runtime, type ContractName } from "./config";
export const ERC20 = parseAbi([
  "function balanceOf(address) view returns(uint256)",
  "function allowance(address,address) view returns(uint256)",
  "function approve(address,uint256) returns(bool)",
  "function decimals() view returns(uint8)",
  "function symbol() view returns(string)",
]);
export const STATE = parseAbi([
  "function getSlot0(bytes32) view returns(uint160,int24,uint24,uint24)",
  "function getLiquidity(bytes32) view returns(uint128)",
  "function poolManager() view returns(address)",
]);
export const RECEIVER = parseAbi([
  "function playground() view returns(address)",
  "function projectId() view returns(uint256)",
]);
export const HUB = parseAbi([
  "function projects(uint256) view returns(address creator,address receiver)",
]);
export const FWA_V2 = parseAbi([
  "function isPurchaseBlackout() view returns(bool)",
  "function quoteAcquisitionPrice() view returns(uint256 fee,uint256 vrf,uint256 total)",
  "function settlementWindow() view returns(uint256)",
  "function acquisitions(uint256) view returns((address purchaser,uint256 requestBlock,uint256 priceEscrowed,uint256 listingId,uint8 status))",
  "function listings(uint256) view returns((address collection,address depositor,address purchaser,uint256 tokenId,uint256 weight,uint256 value,uint256 feeShare,uint256 feeDebt,uint256 slot,uint64 allocatedAt,uint8 status))",
]);
export const INTAKE = parseAbi([
  "function priceOf(bytes32,address) view returns(uint256)",
]);
export const PERMIT2 = parseAbi([
  "function allowance(address,address,address) view returns(uint160 amount,uint48 expiration,uint48 nonce)",
  "function approve(address token,address spender,uint160 amount,uint48 expiration)",
]);
export const ROUTER = parseAbi([
  "function execute(bytes commands,bytes[] inputs,uint256 deadline) payable",
]);
export async function read(
  rt: Runtime,
  name: ContractName,
  fn: string,
  args: readonly unknown[] = [],
  block?: bigint,
): Promise<any> {
  return rt.client.readContract({
    address: rt.addresses[name],
    abi: ABI[name],
    functionName: fn,
    args,
    blockNumber: block,
  });
}
export async function ext(
  rt: Runtime,
  address: Address,
  abi: Abi,
  fn: string,
  args: readonly unknown[] = [],
  block?: bigint,
): Promise<any> {
  return rt.client.readContract({
    address,
    abi,
    functionName: fn,
    args,
    blockNumber: block,
  });
}
export type Snapshot = Awaited<ReturnType<typeof snapshot>>;
export async function snapshot(rt: Runtime) {
  const block = await rt.client.getBlock();
  const b = block.number;
  if (
    Date.now() - Number(block.timestamp) * 1000 > 180000 ||
    Number(block.timestamp) * 1000 - Date.now() > 30000
  )
    throw Error(
      "The RPC block is stale or has an unexpected timestamp. Retry another fresh read.",
    );
  const get = async (name: ContractName, fns: string[]) =>
    Object.fromEntries(
      await Promise.all(
        fns.map(async (fn) => [fn, await read(rt, name, fn, [], b)]),
      ),
    );
  const [
    token,
    hook,
    rewards,
    codes,
    receiverHub,
    receiverId,
    project,
    slot,
    liquidity,
    approved,
    pairDecimals,
    pairSymbol,
    stateManager,
  ] = await Promise.all([
    get("MadToken", [
      "owner",
      "trading",
      "currentRound",
      "poolId",
      "hook",
      "helper",
      "factory",
      "swarm",
      "totalSupply",
      "decimals",
      "useGlobalDistributors",
      "enabledAt",
    ]),
    get("MadHook", [
      "owner",
      "token",
      "poolId",
      "poolManager",
      "rewards",
      "PLAYGROUND",
      "feeBps",
      "conversionSqrtPriceLimitX96",
      "minEthPerFwaX18",
      "playgroundFwaClaims",
      "nftFwaClaims",
      "nftEthClaims",
      "pendingBurnClaims",
      "totalBurned",
      "ethFwaPool",
    ]),
    get("MadRewards", [
      "owner",
      "token",
      "hook",
      "budget",
      "prizeCount",
      "nextPrize",
      "fwaV2",
      "imd",
      "intake",
      "action",
      "oracleSigner",
      "acquisitionFeeMargin",
      "acquisitionSlippageBps",
    ]),
    Promise.all(
      Object.entries(rt.addresses).map(
        async ([n, address]) =>
          [n, await rt.client.getCode({ address, blockNumber: b })] as const,
      ),
    ),
    ext(rt, rt.d.revenue.receiver, RECEIVER, "playground", [], b),
    ext(rt, rt.d.revenue.receiver, RECEIVER, "projectId", [], b),
    ext(
      rt,
      rt.d.revenue.hub,
      HUB,
      "projects",
      [BigInt(rt.d.revenue.projectId)],
      b,
    ),
    ext(
      rt,
      rt.d.network.uniswapV4.stateView,
      STATE,
      "getSlot0",
      [rt.d.poolId],
      b,
    ),
    ext(
      rt,
      rt.d.network.uniswapV4.stateView,
      STATE,
      "getLiquidity",
      [rt.d.poolId],
      b,
    ),
    read(
      rt,
      "MadHook",
      "approvedRouters",
      [rt.d.network.uniswapV4.universalRouter],
      b,
    ),
    ext(rt, rt.d.poolKey.currency0, ERC20, "decimals", [], b),
    ext(rt, rt.d.poolKey.currency0, ERC20, "symbol", [], b),
    ext(rt, rt.d.network.uniswapV4.stateView, STATE, "poolManager", [], b),
  ]);
  const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  const routeCodes = await Promise.all(
    ["universalRouter", "permit2", "stateView", "poolManager"].map(
      async (name) => {
        const address = (rt.d.network.uniswapV4 as any)[name] as Address;
        const code = await rt.client.getCode({ address, blockNumber: b });
        return (
          !!code &&
          code !== "0x" &&
          keccak256(code) === rt.d.verification.routeCodeHashes[name]
        );
      },
    ),
  );
  const integrity =
    routeCodes.every(Boolean) &&
    codes.every(
      ([n, code]) =>
        code &&
        code !== "0x" &&
        keccak256(code) === rt.d.verification.codeHashes[n],
    ) &&
    Object.entries(rt.d.verification.abiHashes).every(
      ([name, v]) =>
        v.match && abiDigest(ABI[name as ContractName]) === v.expected,
    ) &&
    same(token.hook, rt.addresses.MadHook) &&
    same(token.helper, rt.addresses.MadRewards) &&
    same(hook.token, rt.addresses.MadToken) &&
    same(hook.rewards, rt.addresses.MadRewards) &&
    same(rewards.hook, rt.addresses.MadHook) &&
    same(rewards.token, rt.addresses.MadToken) &&
    token.poolId === rt.d.poolId &&
    hook.poolId === rt.d.poolId &&
    Number(token.decimals) === 18 &&
    same(hook.poolManager, rt.d.network.uniswapV4.poolManager) &&
    same(stateManager, rt.d.network.uniswapV4.poolManager);
  const revenueVerified =
    same(receiverHub, rt.d.revenue.hub) &&
    receiverId === BigInt(rt.d.revenue.projectId) &&
    same(project[1], rt.d.revenue.receiver) &&
    same(hook.PLAYGROUND, rt.d.revenue.receiver);
  const round = token.currentRound as bigint;
  const [blocks, leader] = await Promise.all([
    read(rt, "MadToken", "roundBlocks", [round], b),
    read(rt, "MadToken", "leader", [round], b),
  ]);
  const leaderSpent = await read(rt, "MadToken", "spent", [round, leader], b);
  const receiverHeld = await ext(
    rt,
    rt.d.poolKey.currency0,
    ERC20,
    "balanceOf",
    [rt.d.revenue.receiver],
    b,
  );
  const acquisitions = await Promise.allSettled([
    ext(rt, rewards.fwaV2, FWA_V2, "quoteAcquisitionPrice", [], b),
    ext(rt, rewards.fwaV2, FWA_V2, "isPurchaseBlackout", [], b),
    ext(rt, rewards.fwaV2, FWA_V2, "settlementWindow", [], b),
    ext(
      rt,
      rewards.intake,
      INTAKE,
      "priceOf",
      [rewards.action, rewards.imd],
      b,
    ),
    ext(rt, rewards.imd, ERC20, "balanceOf", [rt.addresses.MadRewards], b),
  ]);
  const optional = (i: number) =>
    acquisitions[i].status === "fulfilled" ? acquisitions[i].value : undefined;
  return {
    block,
    token,
    hook,
    rewards,
    integrity,
    revenueVerified,
    slot: slot as [bigint, number, number, number],
    liquidity: liquidity as bigint,
    routerApproved: approved as boolean,
    pairDecimals: Number(pairDecimals),
    pairSymbol: String(pairSymbol),
    round,
    blocks: blocks as [bigint, bigint],
    leader: leader as Address,
    leaderSpent: leaderSpent as bigint,
    receiverHeld: receiverHeld as bigint,
    acquisitionQuote: optional(0) as [bigint, bigint, bigint] | undefined,
    blackout: optional(1) as boolean | undefined,
    settlementWindow: optional(2) as bigint | undefined,
    oraclePrice: optional(3) as bigint | undefined,
    oracleFunds: optional(4) as bigint | undefined,
    receivedAt: Date.now(),
  };
}
export async function walletState(
  rt: Runtime,
  address: Address,
  round: bigint,
) {
  const b = await rt.client.getBlockNumber();
  const [mad, fwa, eth, frozenUntil, spent, code] = await Promise.all([
    read(rt, "MadToken", "balanceOf", [address], b),
    ext(rt, rt.d.poolKey.currency0, ERC20, "balanceOf", [address], b),
    rt.client.getBalance({ address, blockNumber: b }),
    read(rt, "MadToken", "frozenUntil", [address], b),
    read(rt, "MadToken", "spent", [round, address], b),
    rt.client.getCode({ address, blockNumber: b }),
  ]);
  return {
    mad: mad as bigint,
    fwa: fwa as bigint,
    eth,
    frozenUntil: BigInt(frozenUntil),
    spent: spent as bigint,
    isEOA: !code || code === "0x",
  };
}
export async function targetState(rt: Runtime, address: Address) {
  const b = await rt.client.getBlockNumber();
  const [balance, cost, until, distributor] = await Promise.all([
    read(rt, "MadToken", "balanceOf", [address], b),
    read(rt, "MadToken", "freezeCost", [address], b),
    read(rt, "MadToken", "frozenUntil", [address], b),
    read(rt, "MadToken", "isDistributor", [address], b),
  ]);
  return {
    address,
    balance: balance as bigint,
    cost: cost as bigint,
    until: BigInt(until),
    distributor: distributor as boolean,
    block: b,
    receivedAt: Date.now(),
  };
}
export const PUBLIC_EVENTS = new Set([
  "Bound",
  "SwarmCaptured",
  "Initialized",
  "Fees",
  "EthFwaPoolSet",
  "FwaV2Set",
  "AcquisitionBoundsSet",
  "OracleSettingsSet",
  "Frozen",
  "TradingEnabled",
  "RoundClosed",
  "PlaygroundPaid",
  "NFTBudgetRedeemed",
  "ExcessBurned",
  "Bought",
  "Kept",
  "Closed",
  "Asked",
  "WinnerAccepted",
  "Awarded",
  "AwardDeferred",
  "ConversionBoundsSet",
  "RouterSet",
  "GlobalDistributorsSet",
  "DistributorSet",
  "NFTConverted",
  "BurnDeferred",
  "RefundRecovered",
]);
export async function activity(rt: Runtime) {
  const latest = await rt.client.getBlockNumber();
  const deployed = BigInt(rt.d.contracts[0].blockNumber);
  const first = latest - 2000n > deployed ? latest - 2000n : deployed;
  const logs = [];
  for (let from = first; from <= latest; from += 400n) {
    const to = from + 399n < latest ? from + 399n : latest;
    logs.push(
      ...(await rt.client.getLogs({
        address: Object.values(rt.addresses),
        fromBlock: from,
        toBlock: to,
      })),
    );
  }
  const events = logs
    .flatMap((l) => {
      for (const abi of Object.values(ABI)) {
        try {
          const decoded = decodeEventLog({
            abi,
            data: l.data,
            topics: l.topics,
          });
          const eventName = decoded.eventName;
          if (!eventName || !PUBLIC_EVENTS.has(eventName)) continue;
          return [{ ...l, ...decoded, eventName }];
        } catch {
          /* The log belongs to a different contract ABI. */
        }
      }
      return [];
    })
    .sort(
      (a, b) =>
        Number(b.blockNumber! - a.blockNumber!) || b.logIndex! - a.logIndex!,
    )
    .slice(0, 40);
  return { events, first, latest };
}
export const nonzero = (address?: string) =>
  !!address && address !== zeroAddress;
export function errText(error: unknown) {
  const e = error as { shortMessage?: string; message?: string };
  const text =
    e.shortMessage || e.message || "Read failed. Retry to request fresh state.";
  return text.length > 450 ? text.slice(0, 450) + "…" : text;
}
