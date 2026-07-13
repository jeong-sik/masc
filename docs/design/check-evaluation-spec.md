---
status: withdrawn
updated: 2026-07-13
scope: historical CDAL check-evaluation proposal
---

# CDAL Check Evaluation Spec

> **Withdrawn.** The previous specification made a deterministic check registry
> a semantic authority over agent runs. Its `Satisfied`, `Violated`, and
> `Inconclusive` outcomes, including runtime risk and mutation classes, are not
> an active completion or authorization contract.

## Reason

Artifact presence, propagated labels, counts, and locally chosen thresholds can
prove representation or integrity facts. They cannot prove that a Task is
substantively complete or that an external effect is acceptable. Treating them
as such recreated a policy hierarchy around OAS evidence.

## Replacement SSOT

- [Keeper Agent](../spec/05-keeper-agent.md): the configured LLM judges Task
  completion from the concrete Task, context, and evidence.
- [Command Plane](../spec/06-command-plane.md): each external effect uses the
  product-neutral Gate flow.
- [OAS Integration](../spec/13-oas-integration.md): OAS emits typed provider/run
  observations and does not own MASC policy.

Structural decoding, schema-version, hash, and artifact-read failures remain
explicit observable errors. They do not manufacture a semantic verdict.
