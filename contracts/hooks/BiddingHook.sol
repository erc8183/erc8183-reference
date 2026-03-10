// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IACPHook} from "../interfaces/IACPHook.sol";
import {IACP} from "../interfaces/IACP.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BiddingHook — ERC-8183 Hook: Competitive Bidding Mode
/// @notice Enables a bidding phase where multiple providers compete for a job.
///
/// Flow:
///   1. Client creates job with this hook (provider = address(0), Open state)
///   2. Providers call placeBid() within the bidding window
///   3. Client calls selectBid() to choose a winner — sets provider via ACP setProvider()
///   4. Client calls fund() to lock escrow — beforeAction validates selection was made
///
/// Production insight from ClawWork:
///   We support three assignment modes: open (first-come), bidding, and designated.
///   Bidding mode works well for tasks where quality matters more than speed —
///   research, design, complex analysis. It also surfaces market price discovery:
///   you learn what providers actually charge for your task type.
///
/// Note: This is a simplified on-chain bidding hook. Production systems often keep
/// bid management off-chain (lower gas, richer bid metadata) and use this contract
/// only for the final winner selection and enforcement.
contract BiddingHook is IACPHook, Ownable {
    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    struct Bid {
        address provider;
        uint256 amount;        // Proposed budget in token units
        string proposal;       // IPFS CID of proposal document
        uint256 submittedAt;
    }

    struct BiddingState {
        uint256 biddingDeadline;   // Bids accepted until this timestamp
        bool selectionMade;        // True once client has chosen a winner
        uint256 bidCount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    mapping(uint256 => BiddingState) public biddingStates;
    mapping(uint256 => mapping(uint256 => Bid)) public bids; // jobId => bidIndex => Bid
    mapping(uint256 => mapping(address => bool)) public hasBid; // jobId => provider => bool

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event BiddingOpened(uint256 indexed jobId, uint256 deadline);
    event BidPlaced(uint256 indexed jobId, uint256 indexed bidIndex, address indexed provider, uint256 amount);
    event BidSelected(uint256 indexed jobId, address indexed winner, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {}

    // ─────────────────────────────────────────────────────────────────────────
    // Bidding Functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Open bidding for a job. Called by the client after job creation.
    /// @param jobId The job to open bidding for.
    /// @param biddingDeadline Timestamp after which no new bids are accepted.
    function openBidding(uint256 jobId, uint256 biddingDeadline) external {
        IACP.Job memory job = IACP(msg.sender).getJob(jobId);
        require(job.client == msg.sender, "BiddingHook: only client");
        require(job.status == IACP.JobStatus.Open, "BiddingHook: job not Open");
        require(biddingDeadline > block.timestamp, "BiddingHook: deadline in past");
        require(biddingDeadline < job.expiredAt, "BiddingHook: deadline after job expiry");

        biddingStates[jobId] = BiddingState({
            biddingDeadline: biddingDeadline,
            selectionMade: false,
            bidCount: 0
        });

        emit BiddingOpened(jobId, biddingDeadline);
    }

    /// @notice Submit a bid for a job.
    /// @param jobId The job to bid on.
    /// @param amount Proposed payment amount in token units.
    /// @param proposal IPFS CID of your proposal document.
    function placeBid(uint256 jobId, uint256 amount, string calldata proposal) external {
        BiddingState storage state = biddingStates[jobId];
        require(state.biddingDeadline > 0, "BiddingHook: bidding not open");
        require(block.timestamp <= state.biddingDeadline, "BiddingHook: bidding closed");
        require(!hasBid[jobId][msg.sender], "BiddingHook: already bid");
        require(amount > 0, "BiddingHook: zero amount");

        uint256 bidIndex = state.bidCount++;
        bids[jobId][bidIndex] = Bid({
            provider: msg.sender,
            amount: amount,
            proposal: proposal,
            submittedAt: block.timestamp
        });
        hasBid[jobId][msg.sender] = true;

        emit BidPlaced(jobId, bidIndex, msg.sender, amount);
    }

    /// @notice Client selects the winning bid. Sets the provider and budget on the ACP contract.
    /// @param acpContract The deployed ACPCore contract.
    /// @param jobId The job.
    /// @param bidIndex Index of the winning bid.
    function selectBid(address acpContract, uint256 jobId, uint256 bidIndex) external {
        IACP.Job memory job = IACP(acpContract).getJob(jobId);
        require(job.client == msg.sender, "BiddingHook: only client");

        BiddingState storage state = biddingStates[jobId];
        require(!state.selectionMade, "BiddingHook: already selected");
        require(bidIndex < state.bidCount, "BiddingHook: invalid bid index");

        Bid memory winner = bids[jobId][bidIndex];
        state.selectionMade = true;

        // Set provider and budget on the ACP contract
        IACP(acpContract).setProvider(jobId, winner.provider, "");
        IACP(acpContract).setBudget(jobId, winner.amount, "");

        emit BidSelected(jobId, winner.provider, winner.amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Hook Implementation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Enforce that a bid was selected before funding is allowed.
    function beforeAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata /* data */
    ) external override {
        if (selector == IACP.fund.selector) {
            BiddingState storage state = biddingStates[jobId];
            // Only enforce if bidding was opened for this job
            if (state.biddingDeadline > 0) {
                require(state.selectionMade, "BiddingHook: select a bid before funding");
                require(
                    block.timestamp > state.biddingDeadline,
                    "BiddingHook: bidding still open"
                );
            }
        }
    }

    /// @notice No after-action logic needed for basic bidding.
    function afterAction(
        uint256 jobId,
        bytes4 selector,
        bytes calldata /* data */
    ) external override {
        // No-op
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    function getBid(uint256 jobId, uint256 bidIndex) external view returns (Bid memory) {
        return bids[jobId][bidIndex];
    }

    function getBidCount(uint256 jobId) external view returns (uint256) {
        return biddingStates[jobId].bidCount;
    }
}
