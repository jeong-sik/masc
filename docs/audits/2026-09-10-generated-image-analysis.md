# Generated sandbox image analysis

The existing keeper_analyze_image accepted only a per-Keeper vision artifact handle. A sandbox path therefore failed as invalid_artifact, while a separately computed file SHA failed as artifact_not_found because computing a hash does not ingest the file.

The same tool now accepts exactly one of artifact or path. Path reads reuse Read path resolution and containment, then Keeper_sandbox_read_runner with the turn-owned sandbox factory. There is no host-read fallback. A one-byte lookahead rejects images larger than the existing image cap; the actual bytes must have an admitted image signature before the existing per-Keeper store receives them. Analysis continues through the ordinary vision runtime selection and provider boundary. A successful response includes the stored artifact handle and original source_path for subsequent questions.

The feature test writes a real PNG fixture, invokes the production sandbox reader with a fake Docker transport, checks the exact image message at the provider spy, and reloads the same artifact for a second question. It also checks invalid query/MIME, oversized bytes, ambiguous sources, arbitrary host paths, and escaping symlinks do not invoke the provider. This is transport and store integration evidence, not a real Docker or semantic vision-model proof. The existing artifact-only behavior and selected vision-runtime semantics are preserved.

No deployed runtime was changed. Source parsing and TOML validation passed locally; compilation and behavior execution belong to CI. A live Keeper generating its own image and obtaining a real model reading remains the runtime acceptance step.
