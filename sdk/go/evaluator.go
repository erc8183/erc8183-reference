package acp

import (
	"context"
	"fmt"
	"log"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Evaluator handles the Evaluator role in ERC-8183.
//
// The Evaluator is the trusted arbiter of all job outcomes.
// It is the single most important design decision in your ERC-8183 system.
//
// Key principle: the Evaluator's authority is absolute within a job.
// Choose your Evaluator architecture carefully before deploying.
//
// See docs/EVALUATOR_GUIDE.md for a full decision framework.
type Evaluator struct {
	ethClient    *ethclient.Client
	contractAddr common.Address
	contractABI  abi.ABI
	signer       TransactionSigner
}

// NewEvaluator creates an Evaluator instance.
func NewEvaluator(ethClient *ethclient.Client, contractAddr common.Address, signer TransactionSigner) (*Evaluator, error) {
	parsedABI, err := abi.JSON(strings.NewReader(acpCoreABIJSON))
	if err != nil {
		return nil, fmt.Errorf("parse ABI: %w", err)
	}
	return &Evaluator{
		ethClient:    ethClient,
		contractAddr: contractAddr,
		contractABI:  parsedABI,
		signer:       signer,
	}, nil
}

// Complete approves a submitted deliverable and releases funds to the provider.
//
// evaluationCid should be the IPFS CID of a structured evaluation report.
// Best practice format:
//
//	{
//	  "verdict": "approved",
//	  "score": 92,
//	  "checklist": ["requirement 1: met", "requirement 2: met"],
//	  "comments": "Excellent work. Deliverable meets all specified criteria.",
//	  "evaluatedAt": "2026-03-11T10:00:00Z"
//	}
//
// This creates a permanent, auditable record of every evaluation decision.
func (e *Evaluator) Complete(ctx context.Context, jobID *big.Int, evaluationCid string) (common.Hash, error) {
	reasonBytes := []byte(evaluationCid)

	data, err := e.contractABI.Pack("complete", jobID, reasonBytes, []byte{})
	if err != nil {
		return common.Hash{}, fmt.Errorf("pack complete: %w", err)
	}

	tx, err := e.buildTx(ctx, data)
	if err != nil {
		return common.Hash{}, fmt.Errorf("build tx: %w", err)
	}

	return e.signer.SignAndSend(ctx, e.ethClient, tx)
}

// Reject denies a deliverable and refunds the client.
//
// rejectionCid should be the IPFS CID of a structured rejection report.
// Always include specific, actionable feedback — vague rejections:
//   - Damage your reputation as a fair evaluator
//   - Create disputes that are hard to resolve
//   - Discourage providers from working with your platform
func (e *Evaluator) Reject(ctx context.Context, jobID *big.Int, rejectionCid string) (common.Hash, error) {
	reasonBytes := []byte(rejectionCid)

	data, err := e.contractABI.Pack("reject", jobID, reasonBytes, []byte{})
	if err != nil {
		return common.Hash{}, fmt.Errorf("pack reject: %w", err)
	}

	tx, err := e.buildTx(ctx, data)
	if err != nil {
		return common.Hash{}, fmt.Errorf("build tx: %w", err)
	}

	return e.signer.SignAndSend(ctx, e.ethClient, tx)
}

// WatchSubmissions subscribes to JobSubmitted events for this evaluator.
// Calls handler for each submission to review.
//
// Example usage with an AI reviewer:
//
//	evaluator.WatchSubmissions(ctx, myAddr, func(ctx context.Context, jobID *big.Int, job *Job, deliverableCid string) error {
//	    content, _ := ipfs.Fetch(deliverableCid)
//	    description, _ := evaluator.GetDescription(ctx, jobID)
//
//	    verdict := myAI.Evaluate(description, content)
//	    reportCid, _ := ipfs.Upload(verdict.ReportJSON())
//
//	    if verdict.Approved {
//	        _, err = evaluator.Complete(ctx, jobID, reportCid)
//	    } else {
//	        _, err = evaluator.Reject(ctx, jobID, reportCid)
//	    }
//	    return err
//	})
func (e *Evaluator) WatchSubmissions(
	ctx context.Context,
	evaluatorAddr common.Address,
	handler func(ctx context.Context, jobID *big.Int, job *Job, deliverableCid string) error,
) error {
	query := ethereum.FilterQuery{
		Addresses: []common.Address{e.contractAddr},
		Topics: [][]common.Hash{
			{e.contractABI.Events["JobSubmitted"].ID},
		},
	}

	logsCh := make(chan types.Log, 16)
	sub, err := e.ethClient.SubscribeFilterLogs(ctx, query, logsCh)
	if err != nil {
		return fmt.Errorf("subscribe logs: %w", err)
	}
	defer sub.Unsubscribe()

	log.Printf("[acp/evaluator] watching submissions for evaluator %s", evaluatorAddr.Hex())

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()

		case err := <-sub.Err():
			return fmt.Errorf("subscription error: %w", err)

		case vlog := <-logsCh:
			jobID, deliverableHex, err := parseJobSubmittedEvent(e.contractABI, vlog)
			if err != nil {
				log.Printf("[acp/evaluator] parse error: %v", err)
				continue
			}

			job, err := e.GetJob(ctx, jobID)
			if err != nil {
				log.Printf("[acp/evaluator] get job %s error: %v", jobID, err)
				continue
			}

			if job.Evaluator != evaluatorAddr || job.Status != StatusSubmitted {
				continue
			}

			deliverableCid := string(deliverableHex)
			log.Printf("[acp/evaluator] reviewing job %s (deliverable: %s)", jobID, deliverableCid)

			go func(id *big.Int, j *Job, cid string) {
				if err := handler(ctx, id, j, cid); err != nil {
					log.Printf("[acp/evaluator] handler error for job %s: %v", id, err)
				}
			}(jobID, job, deliverableCid)
		}
	}
}

// GetJob fetches job state.
func (e *Evaluator) GetJob(ctx context.Context, jobID *big.Int) (*Job, error) {
	return getJob(ctx, e.ethClient, e.contractAddr, e.contractABI, jobID)
}

// GetDescription fetches the job description.
func (e *Evaluator) GetDescription(ctx context.Context, jobID *big.Int) (string, error) {
	data, _ := e.contractABI.Pack("getDescription", jobID)
	result, err := e.ethClient.CallContract(ctx, ethereum.CallMsg{
		To:   &e.contractAddr,
		Data: data,
	}, nil)
	if err != nil {
		return "", err
	}
	var desc string
	e.contractABI.UnpackIntoInterface(&desc, "getDescription", result)
	return desc, nil
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers (internal to package)
// ─────────────────────────────────────────────────────────────────────────────

func getJob(ctx context.Context, client *ethclient.Client, addr common.Address, contractABI abi.ABI, jobID *big.Int) (*Job, error) {
	data, err := contractABI.Pack("getJob", jobID)
	if err != nil {
		return nil, err
	}
	result, err := client.CallContract(ctx, ethereum.CallMsg{
		To:   &addr,
		Data: data,
	}, nil)
	if err != nil {
		return nil, err
	}

	// Unpack the Job struct
	type rawJob struct {
		Client    common.Address
		Provider  common.Address
		Evaluator common.Address
		Hook      common.Address
		Token     common.Address
		Budget    *big.Int
		ExpiredAt *big.Int
		Status    uint8
	}
	var raw rawJob
	if err := contractABI.UnpackIntoInterface(&raw, "getJob", result); err != nil {
		return nil, err
	}
	return &Job{
		Client:    raw.Client,
		Provider:  raw.Provider,
		Evaluator: raw.Evaluator,
		Hook:      raw.Hook,
		Token:     raw.Token,
		Budget:    raw.Budget,
		ExpiredAt: raw.ExpiredAt,
		Status:    JobStatus(raw.Status),
	}, nil
}

func parseJobSubmittedEvent(contractABI abi.ABI, vlog types.Log) (*big.Int, []byte, error) {
	if len(vlog.Topics) < 2 {
		return nil, nil, fmt.Errorf("missing topics")
	}
	jobID := new(big.Int).SetBytes(vlog.Topics[1].Bytes())

	// deliverable is in non-indexed data
	type eventData struct {
		Deliverable []byte
	}
	var ed eventData
	if err := contractABI.UnpackIntoInterface(&ed, "JobSubmitted", vlog.Data); err != nil {
		return nil, nil, err
	}
	return jobID, ed.Deliverable, nil
}

func (e *Evaluator) buildTx(ctx context.Context, data []byte) (*types.Transaction, error) {
	nonce, err := e.ethClient.PendingNonceAt(ctx, e.signer.Address())
	if err != nil {
		return nil, err
	}
	gasPrice, err := e.ethClient.SuggestGasPrice(ctx)
	if err != nil {
		return nil, err
	}
	gas, err := e.ethClient.EstimateGas(ctx, ethereum.CallMsg{
		From: e.signer.Address(),
		To:   &e.contractAddr,
		Data: data,
	})
	if err != nil {
		return nil, err
	}
	chainID, err := e.ethClient.ChainID(ctx)
	if err != nil {
		return nil, err
	}
	return types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: gasPrice,
		GasFeeCap: new(big.Int).Mul(gasPrice, big.NewInt(2)),
		Gas:       gas * 12 / 10,
		To:        &e.contractAddr,
		Data:      data,
	}), nil
}
