(** Tool_shard_types_enum_mirrors — hand-mirrored enum string lists
    consumed by tool schema JSON producers in Tool_shard_types.

    These lists each mirror a [valid_*_strings] SSOT owned by a
    downstream keeper/board module. The schema layer remains a leaf, so each
    value is hand-kept in lock-step and protected by a sync regression test in
    [test/test_enum_mirror_sync.ml].

    Canonical owners (single source of truth per enum):
      - [sort_order_enum_strings]
          mirrors [Board_dispatch.valid_sort_order_strings] (#8513)
      - [memory_search_source_enum_strings]
          mirrors [Keeper_tool_memory_runtime.valid_memory_search_source_strings] (#8484)
      - [fs_write_mode_enum_strings]
          mirrors [Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings] (#8490)
      - [vote_direction_enum_strings]
          mirrors [Board_votes.valid_vote_direction_strings] (#8506)
      - [comment_id_pattern]
          mirrors [Board_types.Comment_id.json_schema_pattern] (#29457)

    Adding a new enum value MUST be done in the canonical owner first;
    the sync test then forces the edit here — it compares each owner's list
    against the [enum] arrays the schemas actually publish.

    Stage 11 (docs/audit/2026-05-18-godfile-decomposition-build-plan.html)
    consolidated these mirrors into this single module so future
    work can address the architectural cycle as one unit (RFC candidate:
    generated SSOT via dune rule or lazy late-binding registration). *)

let memory_search_source_enum_strings = [ "memory"; "history"; "all" ]

let fs_write_mode_enum_strings = [ "overwrite"; "append"; "patch" ]
let sort_order_enum_strings = [ "hot"; "trending"; "recent"; "updated"; "discussed" ]
let vote_direction_enum_strings = [ "up"; "down" ]

(* JSON Schema [pattern] for a Board comment id: the shape
   [Board_types.Comment_id.generate] mints and [of_string] accepts. *)
let comment_id_pattern = "^c-[0-9a-f]{32}$"
