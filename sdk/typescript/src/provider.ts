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

/// ACPProvider — Operations for the Provider (AI Agent) role in ERC-8183.
///
/// The Provider executes work and submits deliverables.
/// In production: your AI agent calls these methods after completing tasks.
///
/// Key pattern: subscribe to JobFunded events → execute work → submit().
/// Never store deliverable content on-chain — always use IPFS CID bytes.
export class ACPProvider {
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
  // Core Action
  // ─────────────────────────────────────────────────────────────────────────

  /// Submit your deliverable, transitioning the job from Funded → Submitted.
  ///
  /// @param jobId The job you've completed.
  /// @param ipfsCid The IPFS CID string of your deliverable (e.g., "bafybeig...").
  ///   The SDK converts it to bytes — content lives on IPFS, hash lives on-chain.
  ///
  /// Production lesson: submit() should be idempotent in your application logic.
  /// If the tx fails (gas spike, network issue), your agent needs to retry safely.
  async submit(jobId: bigint, ipfsCid: string): Promise<Hash> {
    // Store IPFS CID as bytes — cheap, immutable, content-addressable
    const deliverableBytes = toHex(toBytes(ipfsCid));

    const { request } = await this.publicClient.simulateContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "submit",
      args: [jobId, deliverableBytes, "0x"],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Event Subscription (Provider's main loop)
  // ─────────────────────────────────────────────────────────────────────────

  /// Watch for jobs funded to this provider's address.
  ///
  /// Usage:
  ///   const unwatch = provider.watchMyJobs(myAddress, async (jobId, job) => {
  ///     const result = await myAI.process(job.description);
  ///     const cid = await ipfs.upload(result);
  ///     await provider.submit(jobId, cid);
  ///   });
  ///
  /// Call unwatch() when shutting down.
  watchMyJobs(
    providerAddress: `0x${string}`,
    onJobFunded: (jobId: bigint, job: Job) => Promise<void>
  ): () => void {
    return this.publicClient.watchContractEvent({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      eventName: "JobFunded",
      onLogs: async (logs) => {
        for (const log of logs) {
          const jobId = (log as any).args.jobId as bigint;
          const job = await this.getJob(jobId);

          // Only process jobs assigned to this provider
          if (
            job.provider.toLowerCase() === providerAddress.toLowerCase() &&
            job.status === JobStatus.Funded
          ) {
            await onJobFunded(jobId, job);
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

  async getDescription(jobId: bigint): Promise<string> {
    return this.publicClient.readContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "getDescription",
      args: [jobId],
    });
  }
}
