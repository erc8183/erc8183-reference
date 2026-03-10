import {
  type PublicClient,
  type WalletClient,
  type Address,
  type Hash,
  type Hex,
  encodeAbiParameters,
  parseAbiParameters,
  zeroAddress,
} from "viem";
import { ACP_CORE_ABI, ERC20_ABI } from "./abi";
import type { CreateJobParams, FundParams, NetworkConfig, Job } from "./types";

/// ACPClient — Operations for the Client role in ERC-8183.
///
/// The Client creates jobs, locks escrow, and can reject jobs before funding.
/// Think of the Client as the "employer" in the three-role system.
export class ACPClient {
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

  /// Create a new job. Returns the job ID.
  /// @param params.provider Pass zeroAddress for open assignment.
  /// @param params.description Keep short or pass an IPFS CID string.
  /// @param params.expiredAt Unix timestamp — choose carefully. Too short = provider
  ///   can't deliver quality work. Too long = your funds are locked. Rule of thumb:
  ///   simple tasks 24h, moderate 72h, complex 7 days.
  async createJob(params: CreateJobParams): Promise<{ hash: Hash; jobId?: bigint }> {
    const { request } = await this.publicClient.simulateContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "createJob",
      args: [
        params.provider,
        params.evaluator,
        params.expiredAt,
        params.description,
        params.hook ?? zeroAddress,
      ],
      account: this.walletClient.account,
    });

    const hash = await this.walletClient.writeContract(request);
    return { hash };
  }

  /// Approve a provider and lock escrow. Two-step process:
  ///   1. Approve USDC spend (if not already approved)
  ///   2. Call fund()
  ///
  /// @param params.expectedBudget Must match job.budget exactly — slippage protection.
  async fund(params: FundParams): Promise<Hash> {
    const job = await this.getJob(params.jobId);

    // Step 1: ensure USDC allowance
    const [account] = await this.walletClient.getAddresses();
    const allowance = await this.publicClient.readContract({
      address: job.token,
      abi: ERC20_ABI,
      functionName: "allowance",
      args: [account, this.config.acpCoreAddress],
    });

    if (allowance < params.expectedBudget) {
      const approveHash = await this.walletClient.writeContract({
        address: job.token,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [this.config.acpCoreAddress, params.expectedBudget],
        account,
        chain: this.walletClient.chain,
      });
      await this.publicClient.waitForTransactionReceipt({ hash: approveHash });
    }

    // Step 2: fund the job
    const { request } = await this.publicClient.simulateContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "fund",
      args: [params.jobId, params.expectedBudget, "0x"],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /// Reject a job while it's still Open (no escrow to refund).
  async reject(jobId: bigint, reason: string): Promise<Hash> {
    const reasonBytes = encodeAbiParameters(
      parseAbiParameters("string"),
      [reason]
    ) as Hex;

    const { request } = await this.publicClient.simulateContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "reject",
      args: [jobId, reasonBytes, "0x"],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /// Trigger a refund after the job has expired.
  /// Permissionless — anyone can call, but usually the client does.
  async claimRefund(jobId: bigint): Promise<Hash> {
    const { request } = await this.publicClient.simulateContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "claimRefund",
      args: [jobId],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
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

  async jobCount(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.config.acpCoreAddress,
      abi: ACP_CORE_ABI,
      functionName: "jobCount",
    });
  }
}
