(** Tool_shard_types — facade re-exporting the split sub-modules.

    Stage 11 (docs/audit/2026-05-18-godfile-decomposition-build-plan.html):
    the original 1750 LOC file was split into cohesive sub-modules so that
    each schema family and the hand-mirrored enum strings can evolve in
    isolation while [Tool_shard_types]'s public API stays byte-identical
    for [Tool_shard.include Tool_shard_types]. *)

include Tool_shard_types_enum_mirrors
include Tool_shard_types_core
include Tool_shard_types_schemas_base
include Tool_shard_types_schemas_board
include Tool_shard_types_schemas_filesystem
include Tool_shard_types_schemas_shell
include Tool_shard_types_schemas_bash
include Tool_shard_types_schemas_pr_review
include Tool_shard_types_schemas_coding_workspace
include Tool_shard_types_schemas_voice
include Tool_shard_types_schemas_library
include Tool_shard_types_schemas_taskboard
include Tool_shard_types_schemas_preflight
include Tool_shard_types_schemas_github_pr
