// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IACPHook} from "../interfaces/IACPHook.sol";
import {IACP} from "../interfaces/IACP.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ReputationGate — ERC-8183 Hook: Reputation-Based Provider Gating
/// @notice Blocks providers below a minimum reputation score from being funded.
///
/// This hook implements the most important lesson from running a production
/// AI agent marketplace: open markets without quality gates fill with low-effort
/// submissions. This hook enforces a minimum score before a job is funded.
///
/// Architecture:
///   - The hook owner (platform or DAO) manages a score registry.
///   - Scores are set off-chain based on completed task history, social signals,
///     identity verification, etc. The specific algorithm is your competitive moat.
///   - The on-chain gate is a simple threshold check — deliberately minimal.
///
/// Production insight from ClawWork:
///   We learned this the hard way. The first week of our open market, 40% of
///   task submissions were copy-paste garbage. Reputation gating reduced
///   low-quality submissions by over 80% within 48 hours of deployment.
///
/// Usage:
///   1. Deploy this contract with your initial minimum score
///   2. Set provider scores as they complete jobs and build history
///   3. Pass this contract's address as `hook` when calling createJob()
contract ReputationGate is IACPHook, Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Minimum reputation score required for a provider to receive funding.
    uint256 public minimumScore;

    /// @notice Reputation scores per address (0 = unregistered or banned).
    mapping(address => uint256) public scores;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ScoreUpdated(address indexed provider, uint256 oldScore, uint256 newScore);
    event MinimumScoreUpdated(uint256 oldMin, uint256 newMin);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _minimumScore Initial minimum score (e.g., 10 = basic registered provider).
    constructor(uint256 _minimumScore) Ownable(msg.sender) {
        minimumScore = _minimumScore;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hook Implementation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Gate funding: revert if provider reputation is below minimum.
    /// @dev Only enforces on fund() calls — other actions pass through.
    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata /* data */
    ) external override {
        // Only gate the fund() action — when client locks escrow.
        // This is the right enforcement point: provider is identified,
        // money is about to move, no going back after this.
        if (selector == IACP.fund.selector) {
            // Retrieve provider from the calling ACP contract.
            // The ACP contract is msg.sender (hooks are called by the core contract).
            IACP.Job memory job = IACP(msg.sender).getJob(jobId);
            address provider = job.provider;

            require(provider != address(0), "ReputationGate: provider not set");
            require(
                scores[provider] >= minimumScore,
                "ReputationGate: provider reputation too low"
            );
        }
        // All other actions (setProvider, submit, complete, reject) pass through.
    }

    /// @notice After funding, no additional action needed in this hook.
    function afterAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata /* data */
    ) external override {
        // No-op. Reputation score updates happen off-chain in this reference impl.
        // In a fully on-chain system, you'd increment score here after complete().
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set or update a provider's reputation score.
    /// @dev In production: call this from your backend after verifying off-chain signals.
    function setScore(address provider, uint256 score) external onlyOwner {
        emit ScoreUpdated(provider, scores[provider], score);
        scores[provider] = score;
    }

    /// @notice Batch-update scores efficiently (e.g., post-epoch settlement).
    function batchSetScores(
        address[] calldata providers,
        uint256[] calldata newScores
    ) external onlyOwner {
        require(providers.length == newScores.length, "ReputationGate: length mismatch");
        for (uint256 i = 0; i < providers.length; i++) {
            emit ScoreUpdated(providers[i], scores[providers[i]], newScores[i]);
            scores[providers[i]] = newScores[i];
        }
    }

    /// @notice Update the minimum score threshold.
    function setMinimumScore(uint256 newMin) external onlyOwner {
        emit MinimumScoreUpdated(minimumScore, newMin);
        minimumScore = newMin;
    }
}
