// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IACP} from "./interfaces/IACP.sol";
import {IACPHook} from "./interfaces/IACPHook.sol";

/// @title ACPCore — ERC-8183 Agentic Commerce Protocol Reference Implementation
/// @notice Minimal, production-proven implementation of the ERC-8183 job lifecycle.
///
/// Design principles:
///   1. MINIMAL — Only what ERC-8183 requires. Zero platform-specific logic.
///   2. SECURE — ReentrancyGuard + SafeERC20 + Checks-Effects-Interactions throughout.
///   3. COMPOSABLE — Hook interface lets you add any behavior without forking.
///   4. AUDITABLE — Every state change emits an event with the relevant data.
///
/// Production context:
///   This contract codifies the architecture that ClawWork has been running off-chain
///   with 20,000+ AI agents since December 2025 — three months before ERC-8183 was
///   published. The design decisions here reflect real-world lessons, not theory.
///
/// @dev Deployed on Base Mainnet. USDC address: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
contract ACPCore is IACP, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total jobs ever created (also serves as next job ID).
    uint256 private _jobCount;

    /// @notice Core job records.
    mapping(uint256 => Job) private _jobs;

    /// @notice Job descriptions stored separately (potentially long strings).
    mapping(uint256 => string) private _descriptions;

    /// @notice Default ERC-20 token for payment (USDC on Base).
    /// @dev Jobs use this token unless a future extension overrides it.
    address public immutable defaultToken;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _defaultToken ERC-20 token used for escrow (USDC on Base Mainnet).
    constructor(address _defaultToken) {
        require(_defaultToken != address(0), "ACPCore: zero token address");
        defaultToken = _defaultToken;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IACP
    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external override returns (uint256 jobId) {
        require(evaluator != address(0), "ACPCore: evaluator required");
        require(expiredAt > block.timestamp, "ACPCore: expiredAt in the past");

        // Why expiredAt matters: without a deadline, clients can lock provider
        // capacity indefinitely. In production we've seen jobs stall for days
        // because expiry wasn't enforced. The standard makes it non-optional.

        jobId = ++_jobCount;

        _jobs[jobId] = Job({
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            hook: hook,
            token: defaultToken,
            budget: 0,
            expiredAt: expiredAt,
            status: JobStatus.Open
        });

        _descriptions[jobId] = description;

        emit JobCreated(jobId, msg.sender, evaluator, provider, hook, expiredAt);
    }

    /// @inheritdoc IACP
    function setProvider(
        uint256 jobId,
        address provider,
        bytes calldata optParams
    ) external override {
        Job storage job = _jobs[jobId];
        require(job.client == msg.sender, "ACPCore: only client");
        require(job.status == JobStatus.Open, "ACPCore: job not Open");
        require(provider != address(0), "ACPCore: zero provider");

        _callBeforeHook(jobId, IACP.setProvider.selector, optParams);
        job.provider = provider;
        _callAfterHook(jobId, IACP.setProvider.selector, optParams);

        emit ProviderSet(jobId, provider);
    }

    /// @inheritdoc IACP
    function setBudget(
        uint256 jobId,
        uint256 amount,
        bytes calldata optParams
    ) external override {
        Job storage job = _jobs[jobId];
        require(job.status == JobStatus.Open, "ACPCore: job not Open");
        // Both client and provider can negotiate budget while Open.
        require(
            msg.sender == job.client || msg.sender == job.provider,
            "ACPCore: only client or provider"
        );
        require(amount > 0, "ACPCore: budget must be non-zero");

        _callBeforeHook(jobId, IACP.setBudget.selector, optParams);
        job.budget = amount;
        _callAfterHook(jobId, IACP.setBudget.selector, optParams);

        emit BudgetSet(jobId, amount);
    }

    /// @inheritdoc IACP
    /// @dev Checks-Effects-Interactions: update state BEFORE transferring tokens.
    function fund(
        uint256 jobId,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external override nonReentrant {
        Job storage job = _jobs[jobId];
        require(job.client == msg.sender, "ACPCore: only client");
        require(job.status == JobStatus.Open, "ACPCore: job not Open");
        require(job.budget > 0, "ACPCore: set budget first");
        require(job.budget == expectedBudget, "ACPCore: budget mismatch (slippage)");

        // Why slippage protection: provider could race to change budget between
        // client's approval and fund() tx confirmation. expectedBudget prevents
        // clients from accidentally funding a different amount.

        _callBeforeHook(jobId, IACP.fund.selector, optParams);

        // Effects before interactions
        job.status = JobStatus.Funded;

        // Interactions: pull payment from client
        IERC20(job.token).safeTransferFrom(msg.sender, address(this), job.budget);

        _callAfterHook(jobId, IACP.fund.selector, optParams);

        emit JobFunded(jobId, job.budget);
    }

    /// @inheritdoc IACP
    function submit(
        uint256 jobId,
        bytes calldata deliverable,
        bytes calldata optParams
    ) external override {
        Job storage job = _jobs[jobId];
        require(job.provider == msg.sender, "ACPCore: only provider");
        require(job.status == JobStatus.Funded, "ACPCore: job not Funded");
        require(!_isExpired(job), "ACPCore: job expired");

        // IMPORTANT: `deliverable` should be an IPFS CID or content hash.
        // Never store raw content on-chain — gas cost and privacy both suffer.
        // Pattern: bytes32 ipfsHash = keccak256(abi.encodePacked(cidString));

        _callBeforeHook(jobId, IACP.submit.selector, optParams);
        job.status = JobStatus.Submitted;
        _callAfterHook(jobId, IACP.submit.selector, optParams);

        emit JobSubmitted(jobId, deliverable);
    }

    /// @inheritdoc IACP
    function complete(
        uint256 jobId,
        bytes calldata reason,
        bytes calldata optParams
    ) external override nonReentrant {
        Job storage job = _jobs[jobId];
        require(job.evaluator == msg.sender, "ACPCore: only evaluator");
        require(job.status == JobStatus.Submitted, "ACPCore: job not Submitted");

        // Why evaluator-only: the Evaluator is the central trust primitive in
        // ERC-8183. It can be a human wallet, a multisig, an AI agent, or a
        // DAO. The key insight: the same complete() call works for a $1 image
        // generation verified by a ZK proof OR a $100k deal verified by a DAO.
        // The abstraction is the power.

        _callBeforeHook(jobId, IACP.complete.selector, optParams);

        // Effects before interactions
        job.status = JobStatus.Completed;
        uint256 payout = job.budget;

        // Interactions: release funds to provider
        IERC20(job.token).safeTransfer(job.provider, payout);

        _callAfterHook(jobId, IACP.complete.selector, optParams);

        emit JobCompleted(jobId, reason);
    }

    /// @inheritdoc IACP
    function reject(
        uint256 jobId,
        bytes calldata reason,
        bytes calldata optParams
    ) external override nonReentrant {
        Job storage job = _jobs[jobId];

        // Rejection rules by role:
        //   Client: may reject while Open (before funding — no refund needed)
        //   Evaluator: may reject while Funded or Submitted (triggers refund)
        if (msg.sender == job.client) {
            require(job.status == JobStatus.Open, "ACPCore: client can only reject Open jobs");
        } else if (msg.sender == job.evaluator) {
            require(
                job.status == JobStatus.Funded || job.status == JobStatus.Submitted,
                "ACPCore: evaluator can reject Funded or Submitted jobs"
            );
        } else {
            revert("ACPCore: only client or evaluator");
        }

        _callBeforeHook(jobId, IACP.reject.selector, optParams);

        // Effects before interactions
        JobStatus prevStatus = job.status;
        job.status = JobStatus.Rejected;

        // Refund escrowed funds if job was Funded or Submitted
        if (prevStatus == JobStatus.Funded || prevStatus == JobStatus.Submitted) {
            IERC20(job.token).safeTransfer(job.client, job.budget);
        }

        _callAfterHook(jobId, IACP.reject.selector, optParams);

        emit JobRejected(jobId, reason);
    }

    /// @inheritdoc IACP
    /// @dev Permissionless — anyone can trigger the refund after expiry.
    ///      Deliberately NOT hookable per ERC-8183 spec.
    function claimRefund(uint256 jobId) external override nonReentrant {
        Job storage job = _jobs[jobId];
        require(
            job.status == JobStatus.Funded || job.status == JobStatus.Submitted,
            "ACPCore: no escrowed funds to refund"
        );
        require(_isExpired(job), "ACPCore: job not yet expired");

        // Why not hookable: hooks MUST NOT be able to block refunds.
        // A malicious hook could otherwise hold client funds hostage forever.
        // The spec makes this an explicit design decision — we honor it.

        job.status = JobStatus.Expired;
        IERC20(job.token).safeTransfer(job.client, job.budget);

        emit JobExpired(jobId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IACP
    function getJob(uint256 jobId) external view override returns (Job memory) {
        return _jobs[jobId];
    }

    /// @inheritdoc IACP
    function jobCount() external view override returns (uint256) {
        return _jobCount;
    }

    /// @notice Get the description of a job (stored separately to save gas on reads).
    function getDescription(uint256 jobId) external view returns (string memory) {
        return _descriptions[jobId];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _isExpired(Job storage job) internal view returns (bool) {
        return block.timestamp >= job.expiredAt;
    }

    /// @notice Call the before-hook if configured. Reverts propagate to block the action.
    function _callBeforeHook(uint256 jobId, bytes4 selector, bytes calldata data) internal {
        address hook = _jobs[jobId].hook;
        if (hook != address(0)) {
            IACPHook(hook).beforeAction(jobId, selector, data);
        }
    }

    /// @notice Call the after-hook if configured.
    /// @dev We do NOT catch reverts here — if your afterAction reverts, the tx reverts.
    ///      Keep afterAction logic safe and non-blocking for critical paths like complete().
    function _callAfterHook(uint256 jobId, bytes4 selector, bytes calldata data) internal {
        address hook = _jobs[jobId].hook;
        if (hook != address(0)) {
            IACPHook(hook).afterAction(jobId, selector, data);
        }
    }
}
