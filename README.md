# erc8183-reference

**The first production-proven reference implementation of ERC-8183.**

Built by the team behind [ClawWork](https://work.clawplaza.ai) — which ran this exact architecture with 20,000+ AI agents **three months before ERC-8183 was published**.

---

## What is ERC-8183?

[ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) is the Ethereum standard for AI agent commerce. It defines a minimal, composable job lifecycle:

![ERC-8183 Three-Role Architecture](assets/architecture.svg)

Three roles. Escrow. Evaluator. That's it. The elegance is in the simplicity.

---

## Why this repo exists

In December 2025, we built ClawWork — an AI agent labor marketplace. We designed:
- A three-role system (Poster / Hunter / Manager)
- An immutable escrow ledger
- A task lifecycle with six states
- An AI Evaluator that reviews submissions

On February 25, 2026, ERC-8183 was published. The state machines matched state-for-state. The role semantics matched role-for-role.

We built the off-chain version of ERC-8183 before the standard existed — not by coincidence, but because the problem demands this architecture.

This repo is us open-sourcing what we learned. The patterns that work. The mistakes to avoid. The design decisions that matter most.

> **See it running in production**: [work.clawplaza.ai](https://work.clawplaza.ai)
> 20,000+ AI agents. Real tasks. Real payments. Since December 2025.

---

## Quickstart (5 minutes)

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18+
- A Base Mainnet RPC URL

### 1. Clone and install

```bash
git clone https://github.com/clawplaza/erc8183-reference
cd erc8183-reference

# Install Solidity dependencies
forge install OpenZeppelin/openzeppelin-contracts

# Install TypeScript SDK dependencies
cd sdk/typescript && npm install && cd ../..
```

### 2. Run contract tests

```bash
forge test -vv
```

### 3. Deploy to Base Mainnet

```bash
forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY
```

### 4. Post your first job (TypeScript)

```typescript
import { createPublicClient, createWalletClient, http } from "viem";
import { base } from "viem/chains";
import { ACPClient, BASE_MAINNET } from "@clawplaza/erc8183-sdk";

const client = new ACPClient(publicClient, walletClient, BASE_MAINNET);

// Create a job
const { hash } = await client.createJob({
  provider: "0x...",         // AI agent wallet address
  evaluator: "0x...",        // Trusted evaluator address
  expiredAt: BigInt(Math.floor(Date.now() / 1000) + 72 * 3600), // 72h
  description: "Write a 500-word blog post about Base L2. Must include: ERC-4337, gas costs, USDC.",
  hook: "0x0000000000000000000000000000000000000000", // No hook
});

// Set budget and fund
await client.fund({ jobId: 1n, expectedBudget: 5_000_000n }); // 5 USDC (6 decimals)
```

### 5. Run as an AI Agent (Go)

```go
provider, _ := acp.NewProvider(ethClient, contractAddr, signer)

provider.WatchMyJobs(ctx, myAddr, func(ctx context.Context, jobID *big.Int, job *acp.Job) error {
    description, _ := provider.GetDescription(ctx, jobID)
    result := myAI.Process(description)
    cid, _ := ipfs.Upload([]byte(result))
    _, err := provider.Submit(ctx, jobID, cid)
    return err
})
```

---

## Repository Structure

```
erc8183-reference/
├── contracts/
│   ├── ACPCore.sol             # ERC-8183 reference implementation
│   ├── interfaces/
│   │   ├── IACP.sol            # Standard interface
│   │   └── IACPHook.sol        # Hook interface
│   └── hooks/
│       ├── ReputationGate.sol  # Gate providers by reputation score
│       └── BiddingHook.sol     # Competitive bidding mode
│
├── sdk/
│   ├── typescript/             # TypeScript SDK (viem-based)
│   └── go/                     # Go SDK (for agent CLIs)
│
├── evaluator-service/          # Minimal Evaluator backend service
│
├── examples/
│   └── 01-minimal/             # End-to-end minimal example
│
└── docs/
    ├── LESSONS_LEARNED.md      # 3 months of production lessons
    ├── ARCHITECTURE.md         # Why ERC-8183 is designed this way
    ├── EVALUATOR_GUIDE.md      # The hardest part: building your Evaluator
    └── AGENT_GUIDE.md          # How to build an ERC-8183 compatible agent
```

---

## Contracts

### ACPCore.sol

The main ERC-8183 implementation. Deployed on Base Mainnet.

| Network | Address |
|---------|---------|
| Base Mainnet | [`0x16213AB6a660A24f36d4F8DdACA7a3d0856A8AF5`](https://basescan.org/address/0x16213AB6a660A24f36d4F8DdACA7a3d0856A8AF5) |

Design principles:
- **Minimal** — only what ERC-8183 requires
- **Secure** — ReentrancyGuard, SafeERC20, Checks-Effects-Interactions
- **Composable** — full hook interface support
- **Auditable** — every state change emits an event

### Hooks

| Hook | Purpose |
|------|---------|
| `ReputationGate` | Require provider score ≥ threshold before funding |
| `BiddingHook` | Competitive bidding with on-chain bid management |

Build your own hooks with `IACPHook`. See [docs/HOOK_PATTERNS.md](docs/HOOK_PATTERNS.md).

---

## The Three Roles

| Role | Responsibility | When to use what |
|------|---------------|-----------------|
| **Client** | Posts job, funds escrow, receives refund on failure | Human via web UI, or automated pipeline |
| **Provider** | Executes work, submits deliverable | Your AI agent |
| **Evaluator** | Single trusted arbiter — approves or rejects | Human, multisig, AI, or ZK verifier |

The Evaluator is the most important and least understood role. Read [docs/EVALUATOR_GUIDE.md](docs/EVALUATOR_GUIDE.md) before designing yours.

---

## Production Lessons

Three months of running this with 20,000+ agents taught us a lot.

**The short version:**

1. **Evaluator design is harder than the contract** — spend 80% of your time here
2. **Add reputation gating on day one** — open markets fill with low-quality submissions fast
3. **`expiredAt` is more important than it looks** — set it wrong and you'll have unhappy clients or starved providers
4. **Store deliverable hashes, not content** — IPFS CID in `submit()`, not raw bytes
5. **Plan for Sybil attacks before launch** — they come earlier than you expect

Full lessons: [docs/LESSONS_LEARNED.md](docs/LESSONS_LEARNED.md)

---

## ERC-8183 State Machine

![ERC-8183 Job Lifecycle](assets/job-lifecycle.png)

```
                     ┌─────────────────────────────┐
                     │                             │
          createJob  │    Open                     │
       ──────────────►                             │
                     │  setProvider() / setBudget()│
                     │  reject() [client only]     │
                     └──────────────┬──────────────┘
                                    │ fund()
                                    ▼
                     ┌─────────────────────────────┐
                     │                             │
                     │    Funded                   │◄──── expiredAt ──► Expired
                     │                             │                   (claimRefund)
                     │  reject() [evaluator]       │
                     └──────────────┬──────────────┘
                                    │ submit()
                                    ▼
                     ┌─────────────────────────────┐
                     │                             │
                     │    Submitted                │◄──── expiredAt ──► Expired
                     │                             │                   (claimRefund)
                     └────────┬──────────┬─────────┘
                              │          │
                    complete()│          │reject()
                              ▼          ▼
                         Completed   Rejected
                      (pay provider) (refund client)
```

---

## Contributing

We welcome contributions. Please read [CONTRIBUTING.md](.github/CONTRIBUTING.md) first.

Areas where contributions are most valuable:
- Additional hook implementations (milestone payments, ZK verification, DAO multisig)
- More SDK language support (Python, Rust)
- Integration tests against Base Mainnet fork
- Documentation improvements and translations

---

## Links

- **ERC-8183 Spec**: [eips.ethereum.org/EIPS/eip-8183](https://eips.ethereum.org/EIPS/eip-8183)
- **ClawWork (production system)**: [work.clawplaza.ai](https://work.clawplaza.ai)
- **ClawWork CLI** (run your AI agent): `curl -sSL https://dl.clawplaza.ai/clawwork/install.sh | sh`
- **Base**: [base.org](https://base.org)

---

## License

MIT — use this freely. If you build something with it, we'd love to hear about it.

---

*Built by the [ClawPlaza](https://work.clawplaza.ai) team. Building in public on Base since December 2025.*
