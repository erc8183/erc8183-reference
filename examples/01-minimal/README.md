# Example 01: Minimal End-to-End

The simplest possible ERC-8183 job lifecycle, with no hooks and no frills.

**What this demonstrates:**
1. Client creates a job and funds escrow
2. Provider submits a deliverable
3. Evaluator approves and funds are released

---

## Run It

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install deps
cd ../..
forge install OpenZeppelin/openzeppelin-contracts
cd examples/01-minimal
npm install
```

### Configure

```bash
cp .env.example .env
# Fill in your private keys and RPC URL
```

### Execute

```bash
# 1. Deploy a fresh ACPCore (or use the deployed one)
forge script DeployLocal.s.sol --rpc-url $BASE_RPC --broadcast

# 2. Run the full lifecycle
npx ts-node scenario.ts
```

---

## Code Walkthrough

`scenario.ts`:

```typescript
import { createPublicClient, createWalletClient, http, zeroAddress } from "viem";
import { base } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { ACPClient, ACPProvider, ACPEvaluator } from "@clawplaza/erc8183-sdk";

const rpcUrl = process.env.BASE_RPC_URL!;
const clientKey = process.env.CLIENT_PRIVATE_KEY! as `0x${string}`;
const providerKey = process.env.PROVIDER_PRIVATE_KEY! as `0x${string}`;
const evaluatorKey = process.env.EVALUATOR_PRIVATE_KEY! as `0x${string}`;
const contractAddr = process.env.ACP_CONTRACT_ADDRESS! as `0x${string}`;
const usdcAddr = process.env.USDC_ADDRESS! as `0x${string}`;

const publicClient = createPublicClient({ chain: base, transport: http(rpcUrl) });

const clientAccount = privateKeyToAccount(clientKey);
const providerAccount = privateKeyToAccount(providerKey);
const evaluatorAccount = privateKeyToAccount(evaluatorKey);

const networkConfig = { acpCoreAddress: contractAddr, usdcAddress: usdcAddr, chainId: 8453 };

const acpClient = new ACPClient(
    publicClient,
    createWalletClient({ account: clientAccount, chain: base, transport: http(rpcUrl) }),
    networkConfig
);
const acpProvider = new ACPProvider(
    publicClient,
    createWalletClient({ account: providerAccount, chain: base, transport: http(rpcUrl) }),
    networkConfig
);
const acpEvaluator = new ACPEvaluator(
    publicClient,
    createWalletClient({ account: evaluatorAccount, chain: base, transport: http(rpcUrl) }),
    networkConfig
);

async function runScenario() {
    const budget = 1_000_000n; // 1 USDC (6 decimals)
    const expiredAt = BigInt(Math.floor(Date.now() / 1000) + 72 * 3600);

    // ── Step 1: Client creates job ────────────────────────────────────────
    console.log("1. Creating job...");
    const { hash: createHash } = await acpClient.createJob({
        provider: providerAccount.address,
        evaluator: evaluatorAccount.address,
        expiredAt,
        description: "Write a 100-word summary of what Base L2 is.",
        hook: zeroAddress,
    });
    const createReceipt = await publicClient.waitForTransactionReceipt({ hash: createHash });
    const jobId = 1n; // In production: parse from createReceipt logs
    console.log(`   Job created. tx: ${createHash}`);

    // ── Step 2: Client sets budget and funds ──────────────────────────────
    console.log("2. Setting budget and funding...");
    // setBudget first
    await (acpClient as any).publicClient.simulateContract; // type hint

    // Fund (handles USDC approval internally)
    const fundHash = await acpClient.fund({ jobId, expectedBudget: budget });
    await publicClient.waitForTransactionReceipt({ hash: fundHash });
    console.log(`   Job funded. tx: ${fundHash}`);

    // ── Step 3: Provider submits deliverable ──────────────────────────────
    console.log("3. Provider submitting...");
    // In production: fetch the IPFS CID of your actual deliverable
    const deliverableCid = "bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi";
    const submitHash = await acpProvider.submit(jobId, deliverableCid);
    await publicClient.waitForTransactionReceipt({ hash: submitHash });
    console.log(`   Submitted. tx: ${submitHash}`);

    // ── Step 4: Evaluator approves ────────────────────────────────────────
    console.log("4. Evaluator approving...");
    const evaluationCid = "bafybeihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
    const completeHash = await acpEvaluator.complete(jobId, evaluationCid);
    await publicClient.waitForTransactionReceipt({ hash: completeHash });
    console.log(`   Approved. tx: ${completeHash}`);

    // ── Verify final state ────────────────────────────────────────────────
    const job = await acpClient.getJob(jobId);
    console.log(`\nFinal job status: ${job.status}`); // Should be 3 (Completed)
    console.log("Done! Check provider wallet for USDC payment.");
}

runScenario().catch(console.error);
```

---

## What To Look For

After running, verify on [Basescan](https://basescan.org):
- `JobCreated` event emitted
- `JobFunded` event — USDC transferred to contract
- `JobSubmitted` event
- `JobCompleted` event — USDC transferred to provider

This is ERC-8183 working end-to-end on Base.
