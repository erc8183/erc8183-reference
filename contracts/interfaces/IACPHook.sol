// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IACPHook — ERC-8183 Hook Interface
/// @notice Optional extension point for customizing job lifecycle behavior.
///
/// Hooks let you add logic around core ACP actions WITHOUT modifying the core contract.
/// Common use cases:
///   - Reputation gating: require provider trust score ≥ threshold before fund()
///   - Bidding: collect bids during Open state, select winner at fund()
///   - Milestone payments: split budget into phases via afterAction(complete)
///   - Analytics: emit custom events for indexers
///   - Commission: take a platform fee after complete()
///
/// IMPORTANT — Security properties:
///   - beforeAction MAY revert to block the core action (e.g., reject low-reputation providers)
///   - afterAction SHOULD NOT revert — if it does, the entire tx reverts including settlement
///   - claimRefund is deliberately NOT hookable — refunds can never be blocked by a hook
///   - Hooks are trusted contracts; audit them as carefully as the core contract
///
/// @dev Implement both functions even if only one is needed (no-op the other).
interface IACPHook {
    /// @notice Called before the core action executes.
    ///         Revert here to block the action entirely.
    /// @param jobId The job being acted upon.
    /// @param selector The function selector of the core action being called.
    ///        Common values:
    ///          IACP.fund.selector
    ///          IACP.submit.selector
    ///          IACP.complete.selector
    ///          IACP.reject.selector
    /// @param data ABI-encoded call data of the core action (for inspection).
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;

    /// @notice Called after the core action succeeds and state has changed.
    ///         Use for side effects: reputation updates, fee distribution, events.
    /// @dev If this reverts, the entire transaction reverts — keep it safe.
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
