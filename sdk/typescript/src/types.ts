import type { Address, Hash, Hex } from "viem";

// ─────────────────────────────────────────────────────────────────────────────
// ERC-8183 Core Types
// ─────────────────────────────────────────────────────────────────────────────

export enum JobStatus {
  Open = 0,
  Funded = 1,
  Submitted = 2,
  Completed = 3,
  Rejected = 4,
  Expired = 5,
}

export const JOB_STATUS_LABELS: Record<JobStatus, string> = {
  [JobStatus.Open]: "Open",
  [JobStatus.Funded]: "Funded",
  [JobStatus.Submitted]: "Submitted",
  [JobStatus.Completed]: "Completed",
  [JobStatus.Rejected]: "Rejected",
  [JobStatus.Expired]: "Expired",
};

export interface Job {
  client: Address;
  provider: Address;
  evaluator: Address;
  hook: Address;
  token: Address;
  budget: bigint;
  expiredAt: bigint;
  status: JobStatus;
}

export interface CreateJobParams {
  provider: Address;      // address(0) for open assignment
  evaluator: Address;
  expiredAt: bigint;      // Unix timestamp
  description: string;    // Will be stored on-chain; keep short or use IPFS CID
  hook?: Address;         // address(0) to disable hooks
}

export interface FundParams {
  jobId: bigint;
  expectedBudget: bigint; // Slippage protection — must match current job.budget
}

export interface SubmitParams {
  jobId: bigint;
  deliverable: Hex;       // IPFS CID bytes — NOT raw content
}

export interface CompleteParams {
  jobId: bigint;
  reason: Hex;            // IPFS CID of evaluation report
}

export interface RejectParams {
  jobId: bigint;
  reason: Hex;
}

// ─────────────────────────────────────────────────────────────────────────────
// Network Config
// ─────────────────────────────────────────────────────────────────────────────

export interface NetworkConfig {
  acpCoreAddress: Address;
  usdcAddress: Address;
  chainId: number;
}

// Base Mainnet
export const BASE_MAINNET: NetworkConfig = {
  acpCoreAddress: "0x16213AB6a660A24f36d4F8DdACA7a3d0856A8AF5", // TODO: fill after deploy
  usdcAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  chainId: 8453,
};
