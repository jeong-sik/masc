# Isolated collaboration multimodal candidate

This integration branch combines current main `87fa4ad8c6` with binary write references (#35158), Keeper artifact handoff (#35155), complete binary evidence (#35170), typed tool images (#35159), provider image projection (#35162), and Goal/Task image lookup (#35171).

The complete-read conflict was resolved as one filesystem helper accepting both optional cwd and a frozen turn sandbox factory. Peer export supplies the factory; a standalone verifier has none. Both resolve the same Keeper path and containment before calling the backend full-read API. The runner's verifier-only backend binding explicitly omits the optional factory. An active turn that cannot provide authoritative complete output fails instead of substituting a different sandbox.

The prior runtime remains source `9cc33feff4917a1ae91804771a708d4a0e75e152` in the isolated collaboration base. This branch is not a deployment receipt. Preserve its original Goal criterion, task records, artifacts and queued work during any later owned replacement.

Validation boundary: source parsing/diff checks, parallel source review, then exact-commit targeted Test and Release workflow artifacts. No local build. A downloadable Release artifact alone is not behavioral validation or full release acceptance.

Next live checks: retry the original refuted publication Goal with actual image payloads; inspect the verifier's durable request/result and original criterion binding; transfer and materialize the designer's exact poster bytes through the existing two Keeper conversations. Human Goal confirmation remains a separate final step after proven criteria.
