import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const outDir = resolve(root, "..", "frontend", "src", "abi");

const contracts = [
  { name: "standardErc20", file: "StandardERC20.sol", contract: "StandardERC20" },
  { name: "tokenFactory", file: "TokenFactory.sol", contract: "TokenFactory" },
  { name: "liquidityLocker", file: "LiquidityAndTokenLocker.sol", contract: "LiquidityAndTokenLocker" },
  { name: "tokenVesting", file: "TokenVesting.sol", contract: "TokenVesting" },
  { name: "v3LiquidityLocker", file: "V3LiquidityLocker.sol", contract: "V3LiquidityLocker" },
  { name: "lazuriteMultisender", file: "LazuriteMultisender.sol", contract: "LazuriteMultisender" }
];

mkdirSync(outDir, { recursive: true });

for (const entry of contracts) {
  const artifactPath = resolve(root, "out", entry.file, entry.contract + ".json");
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  if (!Array.isArray(artifact.abi)) throw new Error("Missing ABI in " + artifactPath);
  const content =
    "// Auto-generated from contracts/out. Do not edit by hand.\n" +
    "// Regenerate with: node scripts/export-abis.mjs (inside contracts/)\n" +
    "export const " + entry.name + "Abi = " + JSON.stringify(artifact.abi, null, 2) + " as const;\n";
  writeFileSync(resolve(outDir, entry.name + ".ts"), content);
  console.log("wrote", entry.name + ".ts", "(" + artifact.abi.length + " entries)");
}