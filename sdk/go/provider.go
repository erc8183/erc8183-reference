package acp

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Provider handles the AI Agent (Provider) role in ERC-8183.
//
// The provider executes work and submits deliverables.
// The main pattern is: watch for JobFunded events → process → submit().
//
// Production insight: your agent process should be designed for reliability.
// Jobs will come in at unpredictable times. Build a queue, handle failures
// gracefully, and always store the IPFS CID before calling submit() — if the
// tx fails, you need to be able to retry with the same CID.
type Provider struct {
	ethClient    *ethclient.Client
	contractAddr common.Address
	contractABI  abi.ABI
	signer       TransactionSigner
}

// TransactionSigner abstracts private key operations.
// Implement this with your key management solution (raw key, HSM, KMS, etc).
type TransactionSigner interface {
	Address() common.Address
	SignAndSend(ctx context.Context, client *ethclient.Client, tx *types.Transaction) (common.Hash, error)
}

// NewProvider creates a Provider instance.
func NewProvider(ethClient *ethclient.Client, contractAddr common.Address, signer TransactionSigner) (*Provider, error) {
	parsedABI, err := abi.JSON(strings.NewReader(acpCoreABIJSON))
	if err != nil {
		return nil, fmt.Errorf("parse ABI: %w", err)
	}
	return &Provider{
		ethClient:    ethClient,
		contractAddr: contractAddr,
		contractABI:  parsedABI,
		signer:       signer,
	}, nil
}

// Submit sends the deliverable on-chain, transitioning the job Funded → Submitted.
//
// ipfsCid should be the IPFS CID string of your work output.
// The CID is stored as bytes on-chain; content lives on IPFS.
//
// If this tx fails: retry with the same CID. The contract is idempotent
// for the same job/provider combination.
func (p *Provider) Submit(ctx context.Context, jobID *big.Int, ipfsCid string) (common.Hash, error) {
	deliverableBytes := []byte(ipfsCid)

	data, err := p.contractABI.Pack("submit", jobID, deliverableBytes, []byte{})
	if err != nil {
		return common.Hash{}, fmt.Errorf("pack submit: %w", err)
	}

	tx, err := p.buildTx(ctx, data)
	if err != nil {
		return common.Hash{}, fmt.Errorf("build tx: %w", err)
	}

	return p.signer.SignAndSend(ctx, p.ethClient, tx)
}

// GetJob fetches job state from the contract.
func (p *Provider) GetJob(ctx context.Context, jobID *big.Int) (*Job, error) {
	return getJob(ctx, p.ethClient, p.contractAddr, p.contractABI, jobID)
}

// WatchMyJobs subscribes to JobFunded events and calls handler for each job
// assigned to this provider. Runs until ctx is cancelled.
//
// Handler should be idempotent — events can be replayed on reconnect.
//
// Example usage:
//
//	err := provider.WatchMyJobs(ctx, myAddr, func(ctx context.Context, jobID *big.Int, job *Job) error {
//	    description, _ := provider.GetDescription(ctx, jobID)
//	    result := myAI.Process(description)
//	    cid, _ := ipfs.Upload([]byte(result))
//	    _, err := provider.Submit(ctx, jobID, cid)
//	    return err
//	})
func (p *Provider) WatchMyJobs(
	ctx context.Context,
	providerAddr common.Address,
	handler func(ctx context.Context, jobID *big.Int, job *Job) error,
) error {
	query := ethereum.FilterQuery{
		Addresses: []common.Address{p.contractAddr},
		Topics: [][]common.Hash{
			{p.contractABI.Events["JobFunded"].ID},
		},
	}

	logsCh := make(chan types.Log, 16)
	sub, err := p.ethClient.SubscribeFilterLogs(ctx, query, logsCh)
	if err != nil {
		return fmt.Errorf("subscribe logs: %w", err)
	}
	defer sub.Unsubscribe()

	log.Printf("[acp/provider] watching for jobs assigned to %s", providerAddr.Hex())

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()

		case err := <-sub.Err():
			return fmt.Errorf("subscription error: %w", err)

		case vlog := <-logsCh:
			jobID, err := parseJobFundedEvent(p.contractABI, vlog)
			if err != nil {
				log.Printf("[acp/provider] failed to parse JobFunded: %v", err)
				continue
			}

			job, err := p.GetJob(ctx, jobID)
			if err != nil {
				log.Printf("[acp/provider] failed to get job %s: %v", jobID, err)
				continue
			}

			// Only handle jobs for this provider
			if job.Provider != providerAddr {
				continue
			}
			if job.Status != StatusFunded {
				continue
			}

			log.Printf("[acp/provider] new job %s (budget: %s)", jobID, job.Budget)

			go func(id *big.Int, j *Job) {
				handlerCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
				defer cancel()
				if err := handler(handlerCtx, id, j); err != nil {
					log.Printf("[acp/provider] handler error for job %s: %v", id, err)
				}
			}(jobID, job)
		}
	}
}

// GetDescription fetches the job description string from the contract.
func (p *Provider) GetDescription(ctx context.Context, jobID *big.Int) (string, error) {
	data, err := p.contractABI.Pack("getDescription", jobID)
	if err != nil {
		return "", err
	}
	result, err := p.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &p.contractAddr,
		Data: data,
	}, nil)
	if err != nil {
		return "", err
	}
	var desc string
	if err := p.contractABI.UnpackIntoInterface(&desc, "getDescription", result); err != nil {
		return "", err
	}
	return desc, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// Internals
// ─────────────────────────────────────────────────────────────────────────────

func (p *Provider) buildTx(ctx context.Context, data []byte) (*types.Transaction, error) {
	nonce, err := p.ethClient.PendingNonceAt(ctx, p.signer.Address())
	if err != nil {
		return nil, err
	}
	gasPrice, err := p.ethClient.SuggestGasPrice(ctx)
	if err != nil {
		return nil, err
	}
	gas, err := p.ethClient.EstimateGas(ctx, ethereum.CallMsg{
		From: p.signer.Address(),
		To:   &p.contractAddr,
		Data: data,
	})
	if err != nil {
		return nil, err
	}
	chainID, err := p.ethClient.ChainID(ctx)
	if err != nil {
		return nil, err
	}
	return types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: gasPrice,
		GasFeeCap: new(big.Int).Mul(gasPrice, big.NewInt(2)),
		Gas:       gas * 12 / 10, // 20% buffer
		To:        &p.contractAddr,
		Data:      data,
	}), nil
}

func parseJobFundedEvent(contractABI abi.ABI, vlog types.Log) (*big.Int, error) {
	event := contractABI.Events["JobFunded"]
	if len(vlog.Topics) < 2 {
		return nil, fmt.Errorf("missing topics")
	}
	// jobId is the first indexed topic (topics[0] = event signature)
	jobID := new(big.Int).SetBytes(vlog.Topics[1].Bytes())
	_ = event
	return jobID, nil
}
