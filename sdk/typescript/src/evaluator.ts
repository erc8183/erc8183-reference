import {
  type PublicClient,
  type WalletClient,
  type Hash,
  type Hex,
  toBytes,
  toHex,
} from "viem";
import { ACP_CORE_ABI } from "./abi";
import type { Job, NetworkConfig } from "./types";
import { JobStatus } from "./types";

/// ACPEvaluator — Operations for the Evaluator role in ERC-8183.
///
/// The Evaluator is the most important and least understood role in ERC-8183.
/// It is the single trusted address that decides whether work is complete.
///
/// The Evaluator abstraction is what makes ERC-8183 universal:
///   - A human wallet reviewing creative work manually
///   - A multisig committee for high-stakes decisions
///   - An AI agent verifying objective outputs (code tests, math)
///   - A DAO governance contract for community-verified work
///   - A ZK verifier for cryptographically provable outputs
///
/// All use the same complete() / reject() interface. The contract doesn't care.
///
/// Production insight from ClawWork:
///   We built an AI Evaluator (Clawdia) that reviews task submissions.
///   The hardest part was not the contract — it was deciding what "done"
///   means for subjective tasks. Lock evaluation criteria into the job
///   description at creation time. Vague criteria = disputes at evaluation.
export class ACPEvaluator {
  private publicClient: PublicClient;
  private walletClient: WalletClient;
  private config: NetworkConfig;

  constructor(
    publicClient: PublicClient,
    walletClient: WalletClient,
    config: NetworkConfig
  ) {
    this.publicClient = publicClient;
    this.walletClient = walletClient;
    this.config = config;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Core Actions
  // ─────────────────────────────────────────────────────────────────────────

  /// Approve a submitted deliverable and release funds to provider.
  ///
  /// @param jobId The job to approve.
  /// @param evaluationCid IPFS CID of your evaluation report.
  ///   Best practice: structured JSON with { verdict, score, comments, checklist }.
  ///   Store it on IPFS, put the CID here. Creates a permanent, auditable record.
  async complete(jobId: bigint, evaluationCid: string): Promise<Hash> {
    const reasonBytes = toHex(toBytes(evaluationCid));

    const { request } = await this.publicClient.simulateContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "complete",
      args: [jobId, reasonBytes, "0x"],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /// Reject a submitted or funded job and refund the client.
  ///
  /// @param jobId The job to reject.
  /// @param rejectionCid IPFS CID of your rejection report.
  ///   Include specific reasons — vague rejections create disputes and damage
  ///   your reputation as a fair evaluator.
  async reject(jobId: bigint, rejectionCid: string): Promise<Hash> {
    const reasonBytes = toHex(toBytes(rejectionCid));

    const { request } = await this.publicClient.simulateContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "reject",
      args: [jobId, reasonBytes, "0x"],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Event Subscription (Evaluator's review queue)
  // ─────────────────────────────────────────────────────────────────────────

  /// Watch for submitted jobs assigned to this evaluator.
  ///
  /// Usage:
  ///   const unwatch = evaluator.watchSubmissions(myAddress, async (jobId, job, deliverable) => {
  ///     const verdict = await myReviewer.evaluate(job, deliverable);
  ///     if (verdict.approved) {
  ///       const cid = await ipfs.upload(verdict.report);
  ///       await evaluator.complete(jobId, cid);
  ///     } else {
  ///       const cid = await ipfs.upload(verdict.rejectionReport);
  ///       await evaluator.reject(jobId, cid);
  ///     }
  ///   });
  watchSubmissions(
    evaluatorAddress: `0x${string}`,
    onSubmitted: (jobId: bigint, job: Job, deliverableHex: Hex) => Promise<void>
  ): () => void {
    return this.publicClient.watchContractEvent({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      eventName: "JobSubmitted",
      onLogs: async (logs) => {
        for (const log of logs) {
          const args = (log as any).args;
          const jobId = args.jobId as bigint;
          const deliverable = args.deliverable as Hex;

          const job = await this.getJob(jobId);

          if (
            job.evaluator.toLowerCase() === evaluatorAddress.toLowerCase() &&
            job.status === JobStatus.Submitted
          ) {
            await onSubmitted(jobId, job, deliverable);
          }
        }
      },
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Read
  // ─────────────────────────────────────────────────────────────────────────

  async getJob(jobId: bigint): Promise<Job> {
    return this.publicClient.readContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "getJob",
      args: [jobId],
    }) as Promise<Job>;
  }
}
