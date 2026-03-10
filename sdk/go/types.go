// Package acp provides a Go SDK for ERC-8183 Agentic Commerce Protocol.
//
// This SDK is designed for AI agent CLIs and backend services that need to
// interact with the ACP smart contract on Base.
//
// Quick start:
//
//	client, _ := acp.NewClient(rpcURL, privateKey, contractAddr)
//	provider := acp.NewProvider(client)
//
//	// Watch for funded jobs and submit work
//	provider.WatchMyJobs(ctx, myAddr, func(jobID *big.Int, job acp.Job) error {
//	    result := myAI.Process(job.Description)
//	    cid, _ := ipfs.Upload(result)
//	    return provider.Submit(ctx, jobID, cid)
//	})
package acp

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// JobStatus mirrors the on-chain enum.
type JobStatus uint8

const (
	StatusOpen      JobStatus = 0
	StatusFunded    JobStatus = 1
	StatusSubmitted JobStatus = 2
	StatusCompleted JobStatus = 3
	StatusRejected  JobStatus = 4
	StatusExpired   JobStatus = 5
)

func (s JobStatus) String() string {
	switch s {
	case StatusOpen:
		return "Open"
	case StatusFunded:
		return "Funded"
	case StatusSubmitted:
		return "Submitted"
	case StatusCompleted:
		return "Completed"
	case StatusRejected:
		return "Rejected"
	case StatusExpired:
		return "Expired"
	default:
		return "Unknown"
	}
}

// Job mirrors the on-chain Job struct.
type Job struct {
	Client    common.Address
	Provider  common.Address
	Evaluator common.Address
	Hook      common.Address
	Token     common.Address
	Budget    *big.Int
	ExpiredAt *big.Int
	Status    JobStatus
}

// IsExpired returns true if the job's expiry has passed.
// Note: this is a local check using the provided current time;
// the on-chain check uses block.timestamp.
func (j *Job) IsExpired(nowUnix int64) bool {
	return j.ExpiredAt.Int64() <= nowUnix
}

// CreateJobParams holds parameters for createJob().
type CreateJobParams struct {
	Provider    common.Address // Zero address for open assignment
	Evaluator   common.Address
	ExpiredAt   *big.Int // Unix timestamp
	Description string   // Short description or IPFS CID
	Hook        common.Address // Zero address to disable hooks
}

// Base Mainnet contract addresses
var (
	// USDC on Base Mainnet
	USDCBase = common.HexToAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")

	// ACPCore deployed address (filled after deployment)
	ACPCoreBase = common.HexToAddress("0x16213AB6a660A24f36d4F8DdACA7a3d0856A8AF5")
)
