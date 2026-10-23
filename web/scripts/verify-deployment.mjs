import fs from "node:fs";
import {
  createPublicClient,
  http,
  keccak256,
  toBytes,
  encodeAbiParameters,
  parseAbi,
  decodeAbiParameters,
} from "viem";
const root = new URL("../../", import.meta.url);
const read = (p) => JSON.parse(fs.readFileSync(new URL(p, root), "utf8"));
const handedOff = read("web/public/imd-deployment.json");
const deployment = fs.existsSync(new URL(".imd/reads/deployment.json", root))
  ? read(".imd/reads/deployment.json")
  : handedOff;
const network = fs.existsSync(new URL(".imd/reads/network.json", root))
  ? read(".imd/reads/network.json")
  : { network: handedOff.network, walletAddChain: handedOff.walletAddChain };
// The optional argument is a build-time relay. It is never copied into the website or evidence.
const client = createPublicClient({
  transport: http(process.argv[2] || network.network.rpcUrls[0], {
    timeout: 20000,
    retryCount: 2,
  }),
});
const canonical = (v) =>
  Array.isArray(v)
    ? v.map(canonical)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, canonical(v[k])]),
        )
      : v;
const abis = Object.fromEntries(
  ["MadToken", "MadHook", "MadRewards"].map((n) => [
    n,
    read(`out/${n}.sol/${n}.json`).abi,
  ]),
);
const contracts = Object.fromEntries(
  deployment.contracts.map((c) => [c.name, c.address]),
);
const block = await client.getBlock();
const call = (a, abi, f, args = []) =>
  client.readContract({
    address: a,
    abi,
    functionName: f,
    args,
    blockNumber: block.number,
  });
const hashes = {};
for (const c of deployment.contracts) {
  const hash = keccak256(toBytes(JSON.stringify(canonical(abis[c.name]))));
  hashes[c.name] = {
    expected: "0x" + c.abiHash,
    actual: hash,
    match: hash === "0x" + c.abiHash,
  };
  if (!hashes[c.name].match)
    throw Error("Compiled ABI hash mismatch: " + c.name);
}
const rewards = await call(contracts.MadHook, abis.MadHook, "rewards");
contracts.MadRewards = rewards;
const pool = deployment.manifest.pool;
const currencies = [contracts.MadToken, pool.pairedCurrency].sort((a, b) =>
  a.toLowerCase().localeCompare(b.toLowerCase()),
);
const poolKey = {
  currency0: currencies[0],
  currency1: currencies[1],
  fee: pool.fee,
  tickSpacing: pool.tickSpacing,
  hooks: contracts.MadHook,
};
const poolId = keccak256(
  encodeAbiParameters(
    [
      { type: "address" },
      { type: "address" },
      { type: "uint24" },
      { type: "int24" },
      { type: "address" },
    ],
    Object.values(poolKey),
  ),
);
const receiver = "0x04454514ad6dc4c01d7064c308f8853183fdd39c",
  hub = "0xdd4a83daf532778c55f8806c9adf9a0f0ebb62de";
const receiverAbi = parseAbi([
  "function playground() view returns(address)",
  "function projectId() view returns(uint256)",
]);
const projectsAbi = parseAbi([
  "function projects(uint256) view returns(address creator,address receiver)",
]);
const [pg, pid, project] = await Promise.all([
  call(receiver, receiverAbi, "playground"),
  call(receiver, receiverAbi, "projectId"),
  call(hub, projectsAbi, "projects", [3n]),
]);
if (
  pg.toLowerCase() !== hub ||
  pid !== 3n ||
  project[1].toLowerCase() !== receiver
)
  throw Error("Receiver registration mismatch");
const observations = {};
for (const [name, address] of Object.entries(contracts)) {
  const code = await client.getCode({ address, blockNumber: block.number });
  if (!code || code === "0x") throw Error("No deployed code: " + name);
  const abi = abis[name];
  const artifact = read(`out/${name}.sol/${name}.json`);
  const compiled = artifact.deployedBytecode.object;
  const mask = (hex) => {
    let bytes = Buffer.from(hex.replace(/^0x/, ""), "hex");
    for (const ranges of Object.values(
      artifact.deployedBytecode.immutableReferences || {},
    ))
      for (const r of ranges) bytes.fill(0, r.start, r.start + r.length);
    return bytes.toString("hex");
  };
  const codeMatchesSource = mask(code) === mask(compiled);
  const o = {
    address,
    codeHash: keccak256(code),
    codeBytes: (code.length - 2) / 2,
    codeMatchesSource,
  };
  if (!codeMatchesSource)
    throw Error("Deployed runtime differs from compiled source: " + name);
  const fns =
    name === "MadToken"
      ? [
          "owner",
          "factory",
          "trading",
          "currentRound",
          "poolId",
          "hook",
          "helper",
          "swarm",
          "decimals",
          "totalSupply",
          "useGlobalDistributors",
        ]
      : name === "MadHook"
        ? [
            "owner",
            "factory",
            "token",
            "poolId",
            "initialized",
            "PLAYGROUND",
            "poolManager",
            "feeBps",
            "conversionSqrtPriceLimitX96",
            "minEthPerFwaX18",
            "playgroundFwaClaims",
            "nftFwaClaims",
            "nftEthClaims",
            "pendingBurnClaims",
            "totalBurned",
            "ethFwaPool",
          ]
        : [
            "owner",
            "hook",
            "token",
            "budget",
            "prizeCount",
            "nextPrize",
            "fwaV2",
            "imd",
            "intake",
            "oracleSigner",
            "action",
            "acquisitionFeeMargin",
            "acquisitionSlippageBps",
          ];
  for (const f of fns) o[f] = await call(address, abi, f);
  observations[name] = o;
}
if (
  observations.MadToken.factory &&
  observations.MadHook.factory &&
  observations.MadToken.factory.toLowerCase() !==
    observations.MadHook.factory.toLowerCase()
)
  throw Error("Factory mismatch");
if (
  observations.MadToken.poolId !== poolId ||
  observations.MadHook.poolId !== poolId
)
  throw Error("Pool mismatch");
if (
  observations.MadToken.helper.toLowerCase() !== rewards.toLowerCase() ||
  observations.MadRewards.hook.toLowerCase() !== contracts.MadHook.toLowerCase()
)
  throw Error("Helper binding mismatch");
const stateAbi = parseAbi([
  "function getSlot0(bytes32) view returns(uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
  "function getLiquidity(bytes32) view returns(uint128)",
]);
const state = {
  slot0: await call(network.network.uniswapV4.stateView, stateAbi, "getSlot0", [
    poolId,
  ]),
  liquidity: await call(
    network.network.uniswapV4.stateView,
    stateAbi,
    "getLiquidity",
    [poolId],
  ),
  routerApproved: await call(
    contracts.MadHook,
    abis.MadHook,
    "approvedRouters",
    [network.network.uniswapV4.universalRouter],
  ),
};
const routeCode = {};
for (const [name, address] of Object.entries(network.network.uniswapV4)) {
  const code = await client.getCode({ address, blockNumber: block.number });
  if (!code || code === "0x") throw Error("Route component missing: " + name);
  routeCode[name] = {
    address,
    codeHash: keccak256(code),
    codeBytes: (code.length - 2) / 2,
  };
}
for (const [name, file] of [
  ["universalRouter", "UniversalRouter"],
  ["permit2", "Permit2"],
]) {
  const fixture = read(`test/fixtures/${file}.json`);
  const expected = keccak256(fixture.deployedBytecode.object);
  if (routeCode[name].codeHash !== expected)
    throw Error("Router fixture mismatch: " + name);
  routeCode[name].matchesPinnedRuntime = true;
}
const launchTx = await client.getTransaction({
  hash: deployment.contracts[0].txHash,
});
const report = {
  verifiedAt: new Date().toISOString(),
  blockNumber: block.number,
  blockHash: block.hash,
  chainId: await client.getChainId(),
  source: network.network.rpcUrls[0],
  sourceCommit: deployment.sourceCommit,
  abiHashes: hashes,
  contracts: observations,
  routeCode,
  pool: { poolKey, poolId, ...state },
  revenue: {
    hub,
    receiver,
    projectId: pid,
    creator: project[0],
    registeredReceiver: project[1],
    receiverPlayground: pg,
    launchTransactionFrom: launchTx.from,
    parentPaidBy: receiver,
    parentPaidByEvidence: {
      source:
        "https://github.com/identity-md-launches/launch-2503-token-name-mutually-assured/pull/1",
      statement:
        "The complete original objective explicitly identifies project 3’s receiver as the IMD payer.",
      limit:
        "No separate protocol payment receipt was supplied. Receiver identity and project registration are independently checked onchain.",
    },
  },
};
const stringify = (v) =>
  JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x), 2) +
  "\n";
fs.writeFileSync(
  new URL("docs/website-deployment-check.json", root),
  stringify(report),
);
const handoff = {
  ...deployment,
  network: network.network,
  walletAddChain: network.walletAddChain,
  poolKey,
  poolId,
  derivedContracts: { MadRewards: rewards },
  revenue: { hub, receiver, projectId: 3 },
  verification: {
    abiHashes: hashes,
    routeCodeHashes: Object.fromEntries(
      Object.entries(routeCode).map(([n, v]) => [n, v.codeHash]),
    ),
    codeHashes: Object.fromEntries(
      Object.entries(observations).map(([n, v]) => [n, v.codeHash]),
    ),
    blockNumber: block.number.toString(),
  },
};
fs.writeFileSync(
  new URL("web/public/imd-deployment.json", root),
  stringify(handoff),
);
fs.mkdirSync(new URL("web/src/abi", root), { recursive: true });
for (const name of Object.keys(abis)) {
  fs.writeFileSync(
    new URL(`web/src/abi/${name}.json`, root),
    stringify(abis[name]),
  );
  fs.writeFileSync(
    new URL(`docs/abi/${name}.json`, root),
    stringify(abis[name]),
  );
}
console.log(
  stringify({
    block: report.blockNumber,
    hashes,
    contracts,
    trading: observations.MadToken.trading,
    pool: state,
    revenueRegistration: true,
  }),
);
