# Contributing to erc8183-reference

Thank you for your interest in contributing. This is a reference implementation — quality and clarity matter more than feature count.

## Before You Open an Issue

- Search existing issues first to avoid duplicates
- For security vulnerabilities, **do not** open a public issue — email us directly

## What We Welcome Most

- Additional hook implementations (milestone payments, ZK verification, DAO multisig)
- SDK support for new languages (Python, Rust)
- Integration tests against a Base Mainnet fork
- Documentation improvements and translations
- Bug fixes with clear reproduction steps

## Pull Request Process

1. **Fork** the repo and create a branch from `main`
2. **Keep PRs focused** — one concern per PR
3. **Tests required** — run `forge test` before submitting; all tests must pass
4. **Update docs** if your change affects behavior described in `docs/`
5. **Describe your change** — explain what problem it solves and why this approach

## Code Style

- Solidity: follow the existing style; NatSpec on all public functions
- TypeScript: `npm run lint` must pass
- Go: `gofmt` formatted

## Commit Messages

Use conventional commits:

```
feat: add milestone payment hook
fix: prevent double-claim in BiddingHook
docs: clarify expiredAt behavior in ARCHITECTURE.md
```

## License

By contributing, you agree your changes will be licensed under the [MIT License](../LICENSE).

---

Questions? Open a discussion or reach out at [work.clawplaza.ai](https://work.clawplaza.ai).
