// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IACP — ERC-8183 Agentic Commerce Protocol Interface
/// @notice Standard interface for AI agent job lifecycle management on-chain.
///
/// ERC-8183 defines a minimal, composable primitive for AI agent commerce:
///   - Client posts a job and locks funds in escrow
///   - Provider (AI agent) executes the work and submits a deliverable
///   - Evaluator (trusted address) approves or rejects the deliverable
///   - Settlement is automatic and trustless
///
/// State machine:
///
///   Open → Funded → Submitted → Completed (terminal, funds → provider)
///             ↓          ↓
///          Rejected   Rejected  (terminal, funds → client)
///             ↓
///          Expired               (terminal, funds → client)
///
/// @dev Reference: https://eips.ethereum.org/EIPS/eip-8183
interface IACP {
    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Six lifecycle states of a job.
    enum JobStatus {
        Open,       // Created, budget not yet funded
        Funded,     // Budget escrowed; awaiting provider submission
        Submitted,  // Deliverable submitted; awaiting evaluator decision
        Completed,  // Terminal: funds released to provider
        Rejected,   // Terminal: funds refunded to client
        Expired     // Terminal: expiredAt passed without completion, funds refunded
    }

    /// @notice Core job record stored on-chain.
    struct Job {
        address client;     // Creator; funds the job and receives refunds on failure
        address provider;   // Executes the work; receives payment on completion
        address evaluator;  // Single trusted address with approve/reject authority
        address hook;       // Optional IACPHook contract (address(0) = no hook)
        address token;      // ERC-20 payment token (USDC on Base)
        uint256 budget;     // Escrowed amount in token units
        uint256 expiredAt;  // Unix timestamp; job auto-expires if not completed
        JobStatus status;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed evaluator,
        address provider,
        address hook,
        uint256 expiredAt
    );

    /// @notice Emitted when a job transitions to Funded state.
    event JobFunded(uint256 indexed jobId, uint256 amount);

    /// @notice Emitted when provider submits their deliverable.
    /// @param deliverable Hash or IPFS CID of the deliverable — NOT the raw content.
    event JobSubmitted(uint256 indexed jobId, bytes deliverable);

    /// @notice Emitted when evaluator approves — funds released to provider.
    /// @param reason Hash or IPFS CID of the evaluation report.
    event JobCompleted(uint256 indexed jobId, bytes reason);

    /// @notice Emitted when job is rejected — funds refunded to client.
    event JobRejected(uint256 indexed jobId, bytes reason);

    /// @notice Emitted when claimRefund is called after expiry.
    event JobExpired(uint256 indexed jobId);

    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Core Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Create a new job in Open state.
    /// @param provider Initial provider address (address(0) = open to anyone).
    /// @param evaluator Trusted address that may call complete() or reject().
    /// @param expiredAt Unix timestamp after which claimRefund() becomes callable.
    /// @param description Human-readable task description (stored off-chain via IPFS hash).
    /// @param hook Optional IACPHook contract address; address(0) disables hooks.
    /// @return jobId Incrementing job identifier.
    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256 jobId);

    /// @notice Set or change the provider before the job is funded.
    /// @dev Only callable by client. Reverts if job is not Open.
    function setProvider(uint256 jobId, address provider, bytes calldata optParams) external;

    /// @notice Negotiate the budget amount.
    /// @dev Callable by client (to set) or provider (to counter-propose) while Open.
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external;

    /// @notice Lock funds in escrow, transitioning job from Open → Funded.
    /// @param expectedBudget Caller's expected budget — reverts if budget was changed (slippage protection).
    /// @dev Requires prior ERC-20 approval. Calls beforeAction hook if configured.
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external;

    /// @notice Submit deliverable, transitioning job from Funded → Submitted.
    /// @param deliverable IPFS CID / hash of the deliverable — store content off-chain.
    /// @dev Only callable by provider.
    function submit(uint256 jobId, bytes calldata deliverable, bytes calldata optParams) external;

    /// @notice Approve deliverable, releasing funds to provider. Funded or Submitted → Completed.
    /// @param reason IPFS CID / hash of evaluation report.
    /// @dev Only callable by evaluator.
    function complete(uint256 jobId, bytes calldata reason, bytes calldata optParams) external;

    /// @notice Reject job, refunding funds to client.
    ///         Client may reject when Open; evaluator may reject when Funded or Submitted.
    /// @dev Note: claimRefund is the permissionless path after expiry.
    function reject(uint256 jobId, bytes calldata reason, bytes calldata optParams) external;

    /// @notice Permissionless refund trigger after expiredAt has passed.
    /// @dev Deliberately NOT hookable — refunds cannot be blocked by malicious hooks.
    function claimRefund(uint256 jobId) external;

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory);
    function jobCount() external view returns (uint256);
}
