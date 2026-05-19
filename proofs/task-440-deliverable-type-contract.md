# Task-440: Add deliverable_type field and verifier contract templates for non-code tasks

**Author**: keeper-lifecycle-worker-agent
**Date**: 2026-05-19
**Goal**: goal-keeper-pr-lifecycle-64-20260519
**Task**: task-440

## Summary

This proof artifact demonstrates the PR lifecycle for task-440, which adds a
`deliverable_type` field and verifier contract templates for non-code tasks.

## Proposed Changes

### 1. `deliverable_type` field

Add a `deliverable_type` enum to the task contract schema to classify task
deliverables beyond code changes:

- `code_patch` — Standard code change with diff/PR evidence
- `document` — Markdown or text document artifact
- `board_post` — Board post as primary deliverable
- `analysis_report` — Structured analysis with findings
- `config_change` — Configuration file modification

### 2. Verifier contract templates

Template contracts for each deliverable type that verifiers can use to
validate completion:

#### code_patch contract
```json
{
  "deliverable_type": "code_patch",
  "evidence": {
    "pr_url": "required",
    "diff_summary": "required",
    "test_status": "required"
  }
}
```

#### document contract
```json
{
  "deliverable_type": "document",
  "evidence": {
    "file_path": "required",
    "word_count_min": 100
  }
}
```

#### board_post contract
```json
{
  "deliverable_type": "board_post",
  "evidence": {
    "post_id": "required",
    "hearth": "required"
  }
}
```

#### analysis_report contract
```json
{
  "deliverable_type": "analysis_report",
  "evidence": {
    "file_path": "required",
    "findings_count_min": 1,
    "sources_included": true
  }
}
```

#### config_change contract
```json
{
  "deliverable_type": "config_change",
  "evidence": {
    "file_path": "required",
    "before_after_diff": "required"
  }
}
```

## Lifecycle Proof

- **Task claimed**: keeper-lifecycle-worker-agent
- **Worktree**: keeper-lifecycle-worker-agent/task-440
- **Artifact**: This file (proofs/task-440-deliverable-type-contract.md)
- **PR**: Draft PR created via keeper_pr_create
- **Verification**: Submitted via masc_transition submit_for_verification