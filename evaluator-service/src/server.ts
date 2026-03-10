/**
 * ERC-8183 Evaluator Service — Minimal Reference Implementation
 *
 * This service listens for JobSubmitted events on-chain and automatically
 * calls complete() or reject() based on rule-based evaluation.
 *
 * Production insight from ClawWork:
 *   The Evaluator service is where most of your engineering effort will go.
 *   The smart contract is simple; the evaluation logic is not. This reference
 *   implementation uses rule-based evaluation (deterministic, auditable).
 *   Your production system will likely use LLM-based evaluation for complex tasks.
 *
 * Architecture:
 *   - Express HTTP server (health check + manual override endpoints)
 *   - Viem subscriber watching JobSubmitted events
 *   - Simple rule-based reviewer (extend with your own logic)
 *   - IPFS uploader for evaluation reports
 */

import express from "express";
import { createPublicClient, createWalletClient, http, webSocket } from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { ACPEvaluator } from "@clawplaza/erc8183-sdk";
import { BASE_MAINNET } from "@clawplaza/erc8183-sdk";
import { Reviewer } from "./reviewer";
import { IPFSUploader } from "./ipfs";

// ─────────────────────────────────────────────────────────────────────────────
// Config
// ─────────────────────────────────────────────────────────────────────────────

const config = {
  evaluatorPrivateKey: process.env.EVALUATOR_PRIVATE_KEY as `0x${string}`,
  rpcWsUrl: process.env.BASE_RPC_WS_URL ?? "wss://mainnet.base.org",
  rpcHttpUrl: process.env.BASE_RPC_HTTP_URL ?? "https://mainnet.base.org",
  ipfsGateway: process.env.IPFS_GATEWAY_URL ?? "https://ipfs.io/ipfs/",
  port: parseInt(process.env.PORT ?? "3000"),
};

if (!config.evaluatorPrivateKey) {
  throw new Error("EVALUATOR_PRIVATE_KEY env var required");
}

// ─────────────────────────────────────────────────────────────────────────────
// Clients
// ─────────────────────────────────────────────────────────────────────────────

const account = privateKeyToAccount(config.evaluatorPrivateKey);

const publicClient = createPublicClient({
  chain: base,
  transport: webSocket(config.rpcWsUrl),
});

const walletClient = createWalletClient({
  chain: base,
  transport: http(config.rpcHttpUrl),
  account,
});

const evaluator = new ACPEvaluator(publicClient, walletClient, BASE_MAINNET);
const reviewer = new Reviewer();
const ipfs = new IPFSUploader(config.ipfsGateway);

// ─────────────────────────────────────────────────────────────────────────────
// Main evaluation loop
// ─────────────────────────────────────────────────────────────────────────────

async function startEvaluationLoop() {
  console.log(`[evaluator] Starting. Address: ${account.address}`);

  const unwatch = evaluator.watchSubmissions(
    account.address,
    async (jobId, job, deliverableHex) => {
      console.log(`[evaluator] Reviewing job ${jobId}`);

      try {
        // 1. Fetch deliverable content from IPFS
        const deliverableCid = Buffer.from(deliverableHex.slice(2), "hex").toString("utf8");
        const content = await fetchFromIPFS(deliverableCid, config.ipfsGateway);

        // 2. Evaluate the submission
        const verdict = await reviewer.evaluate({
          jobId,
          description: "", // TODO: fetch from getDescription()
          deliverableCid,
          content,
        });

        // 3. Upload evaluation report to IPFS
        const report = {
          verdict: verdict.approved ? "approved" : "rejected",
          score: verdict.score,
          comments: verdict.comments,
          checklist: verdict.checklist,
          jobId: jobId.toString(),
          evaluatedAt: new Date().toISOString(),
          evaluator: account.address,
        };
        const reportCid = await ipfs.upload(JSON.stringify(report, null, 2));

        // 4. Call complete() or reject() on-chain
        if (verdict.approved) {
          const hash = await evaluator.complete(jobId, reportCid);
          console.log(`[evaluator] Approved job ${jobId} → ${hash}`);
        } else {
          const hash = await evaluator.reject(jobId, reportCid);
          console.log(`[evaluator] Rejected job ${jobId} → ${hash}`);
        }
      } catch (err) {
        console.error(`[evaluator] Error processing job ${jobId}:`, err);
        // Don't rethrow — other jobs should continue processing
      }
    }
  );

  // Cleanup on process exit
  process.on("SIGTERM", () => {
    unwatch();
    process.exit(0);
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP server (health check + manual override)
// ─────────────────────────────────────────────────────────────────────────────

const app = express();
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({ status: "ok", evaluator: account.address });
});

// Manual override endpoint — useful for human review of edge cases
app.post("/manual/complete", async (req, res) => {
  const { jobId, evaluationCid, adminSecret } = req.body;
  if (adminSecret !== process.env.ADMIN_SECRET) {
    return res.status(403).json({ error: "unauthorized" });
  }
  try {
    const hash = await evaluator.complete(BigInt(jobId), evaluationCid);
    res.json({ hash });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

app.post("/manual/reject", async (req, res) => {
  const { jobId, rejectionCid, adminSecret } = req.body;
  if (adminSecret !== process.env.ADMIN_SECRET) {
    return res.status(403).json({ error: "unauthorized" });
  }
  try {
    const hash = await evaluator.reject(BigInt(jobId), rejectionCid);
    res.json({ hash });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Startup
// ─────────────────────────────────────────────────────────────────────────────

async function fetchFromIPFS(cid: string, gateway: string): Promise<string> {
  const url = `${gateway}${cid}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`IPFS fetch failed: ${res.status}`);
  return res.text();
}

app.listen(config.port, () => {
  console.log(`[evaluator] HTTP server on port ${config.port}`);
});

startEvaluationLoop().catch((err) => {
  console.error("[evaluator] Fatal error:", err);
  process.exit(1);
});
