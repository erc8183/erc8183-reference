/**
 * Reviewer — Rule-Based Evaluation Logic
 *
 * This is the rule-based reference implementation. In production, you'll
 * replace or extend this with your own evaluation logic — LLM-based,
 * ZK-verified, multisig, or hybrid.
 *
 * The key insight from ClawWork:
 *   Evaluation criteria must be decided at job creation time, not at review time.
 *   If your job description is vague, your evaluator will produce inconsistent
 *   verdicts. Good job descriptions have:
 *     - Explicit acceptance criteria (numbered list)
 *     - Measurable outputs (word count, test coverage, format requirements)
 *     - Clear rejection conditions
 */

export interface EvaluationInput {
  jobId: bigint;
  description: string;    // Job description (acceptance criteria)
  deliverableCid: string; // IPFS CID of the submission
  content: string;        // Raw content fetched from IPFS
}

export interface EvaluationVerdict {
  approved: boolean;
  score: number;          // 0-100
  comments: string;
  checklist: string[];    // Item-by-item assessment
}

export class Reviewer {
  /**
   * Evaluate a submission against its job description.
   *
   * This reference implementation uses simple heuristics.
   * Replace with your LLM call, ZK verifier, or custom logic.
   *
   * Production lesson: Log every evaluation decision with its input.
   * You will need this audit trail to resolve disputes and improve your evaluator.
   */
  async evaluate(input: EvaluationInput): Promise<EvaluationVerdict> {
    const checklist: string[] = [];
    let score = 0;
    let maxScore = 0;

    // ── Rule 1: Non-empty submission ──────────────────────────────────────
    maxScore += 20;
    if (input.content && input.content.trim().length > 0) {
      score += 20;
      checklist.push("✓ Submission is non-empty");
    } else {
      checklist.push("✗ Submission is empty — automatic rejection");
      return {
        approved: false,
        score: 0,
        comments: "Submission is empty.",
        checklist,
      };
    }

    // ── Rule 2: Minimum length ────────────────────────────────────────────
    maxScore += 20;
    const minLength = this.extractMinLength(input.description);
    if (input.content.length >= minLength) {
      score += 20;
      checklist.push(`✓ Content length (${input.content.length}) meets minimum (${minLength})`);
    } else {
      checklist.push(`✗ Content length (${input.content.length}) below minimum (${minLength})`);
    }

    // ── Rule 3: Required keywords ─────────────────────────────────────────
    maxScore += 30;
    const requiredKeywords = this.extractRequiredKeywords(input.description);
    if (requiredKeywords.length === 0) {
      score += 30; // No keyword requirements
      checklist.push("✓ No keyword requirements specified");
    } else {
      const missing = requiredKeywords.filter(
        (kw) => !input.content.toLowerCase().includes(kw.toLowerCase())
      );
      if (missing.length === 0) {
        score += 30;
        checklist.push(`✓ All required keywords present: ${requiredKeywords.join(", ")}`);
      } else {
        const partial = ((requiredKeywords.length - missing.length) / requiredKeywords.length) * 30;
        score += Math.round(partial);
        checklist.push(`⚠ Missing keywords: ${missing.join(", ")}`);
      }
    }

    // ── Rule 4: Format compliance ─────────────────────────────────────────
    maxScore += 30;
    const requiredFormat = this.extractFormat(input.description);
    if (requiredFormat === "none" || this.checkFormat(input.content, requiredFormat)) {
      score += 30;
      checklist.push(`✓ Format requirement met (${requiredFormat})`);
    } else {
      checklist.push(`✗ Format requirement not met: expected ${requiredFormat}`);
    }

    const normalizedScore = Math.round((score / maxScore) * 100);
    const approved = normalizedScore >= 60; // 60% threshold — adjust for your use case

    return {
      approved,
      score: normalizedScore,
      comments: approved
        ? `Submission meets acceptance criteria (score: ${normalizedScore}/100).`
        : `Submission does not meet acceptance criteria (score: ${normalizedScore}/100). See checklist.`,
      checklist,
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers — extend these for your domain
  // ─────────────────────────────────────────────────────────────────────────

  private extractMinLength(description: string): number {
    const match = description.match(/minimum (\d+) (words|characters)/i);
    if (!match) return 50; // Default minimum
    const count = parseInt(match[1]);
    return match[2].toLowerCase() === "words" ? count * 5 : count; // Rough word-to-char conversion
  }

  private extractRequiredKeywords(description: string): string[] {
    // Look for patterns like "must include: X, Y, Z" or "required keywords: X, Y"
    const match = description.match(/(?:must include|required keywords?)[:\s]+([^\n.]+)/i);
    if (!match) return [];
    return match[1].split(/[,;]/).map((k) => k.trim()).filter(Boolean);
  }

  private extractFormat(description: string): string {
    if (/\bjson\b/i.test(description)) return "json";
    if (/\bmarkdown\b/i.test(description)) return "markdown";
    if (/\bhtml\b/i.test(description)) return "html";
    return "none";
  }

  private checkFormat(content: string, format: string): boolean {
    switch (format) {
      case "json":
        try { JSON.parse(content); return true; } catch { return false; }
      case "markdown":
        return /^#{1,6}\s/.test(content) || /\*\*/.test(content);
      case "html":
        return /<[a-z][\s\S]*>/i.test(content);
      default:
        return true;
    }
  }
}
