import {
  createPublicClient,
  defineChain,
  fallback,
  http,
  keccak256,
  toBytes,
  type Abi,
  type Address,
} from "viem";
import { createConfig } from "wagmi";
import { coinbaseWallet, injected } from "wagmi/connectors";
import tokenAbi from "./abi/MadToken.json";
import hookAbi from "./abi/MadHook.json";
import rewardsAbi from "./abi/MadRewards.json";
export const ABI = {
  MadToken: tokenAbi as Abi,
  MadHook: hookAbi as Abi,
  MadRewards: rewardsAbi as Abi,
};
export type ContractName = keyof typeof ABI;
export type Handoff = {
  network: {
    chainId: number;
    name: string;
    rpcUrls: string[];
    explorer: string;
    nativeCurrency: { name: string; symbol: string; decimals: number };
    uniswapV4: {
      poolManager: Address;
      universalRouter: Address;
      quoter: Address;
      stateView: Address;
      permit2: Address;
    };
    otherPairTokens: { address: Address; symbol: string; decimals: number }[];
  };
  walletAddChain: unknown;
  contracts: { name: string; address: Address; blockNumber: number }[];
  sourceCommit: string;
  poolKey: {
    currency0: Address;
    currency1: Address;
    fee: number;
    tickSpacing: number;
    hooks: Address;
  };
  poolId: `0x${string}`;
  derivedContracts: { MadRewards: Address };
  revenue: { hub: Address; receiver: Address; projectId: number };
  verification: {
    routeCodeHashes: Record<string, `0x${string}`>;
    abiHashes: Record<
      string,
      { expected: string; actual: string; match: boolean }
    >;
    codeHashes: Record<string, `0x${string}`>;
    blockNumber: string;
  };
};
export async function loadConfig() {
  const r = await fetch(`${import.meta.env.BASE_URL}imd-deployment.json`);
  if (!r.ok)
    throw Error("Deployment handoff could not be loaded. Reload to retry.");
  const d = (await r.json()) as Handoff;
  if (d.network.chainId !== 1 || !d.poolKey || !d.contracts.length)
    throw Error("Invalid deployment handoff. Transactions are unavailable.");
  const n = d.network;
  const chain = defineChain({
    id: n.chainId,
    name: n.name,
    nativeCurrency: n.nativeCurrency,
    rpcUrls: { default: { http: n.rpcUrls } },
    blockExplorers: { default: { name: "Etherscan", url: n.explorer } },
  });
  const transport = () =>
    fallback(
      n.rpcUrls.map((url) => http(url, { timeout: 12000, retryCount: 1 })),
      { rank: false },
    );
  const client = createPublicClient({ chain, transport: transport() });
  const wagmi = createConfig({
    chains: [chain],
    multiInjectedProviderDiscovery: true,
    connectors: [
      injected(),
      coinbaseWallet({ appName: "MAD · Mutually Assured Destruction" }),
    ],
    transports: { [chain.id]: transport() },
  });
  const addresses = {
    MadToken: d.contracts.find((c) => c.name === "MadToken")!.address,
    MadHook: d.contracts.find((c) => c.name === "MadHook")!.address,
    MadRewards: d.derivedContracts.MadRewards,
  };
  return { d, client, wagmi, addresses };
}
export type Runtime = Awaited<ReturnType<typeof loadConfig>>;
export const canonical = (v: unknown): unknown =>
  Array.isArray(v)
    ? v.map(canonical)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, canonical((v as Record<string, unknown>)[k])]),
        )
      : v;
export const abiDigest = (abi: Abi) =>
  keccak256(toBytes(JSON.stringify(canonical(abi))));
