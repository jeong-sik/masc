(** Tool_shard_types_enum_mirrors — hand-mirrored enum string lists
    consumed by tool schema JSON producers in Tool_shard_types.

    These six lists each mirror a [valid_*_strings] SSOT owned by a
    downstream keeper/board module. A direct dependency would form a
    cycle (Tool_shard -> Keeper_alerting -> Tool_shard via
    [keeper_model_tools]), so each value is hand-kept in lock-step
    and protected by a sync regression test in [test/test_types.ml].

    Canonical owners (single source of truth per enum):
      - [sort_order_enum_strings]
          mirrors [Board_dispatch.valid_sort_order_strings] (#8513)
      - [memory_search_source_enum_strings]
          mirrors [Keeper_tool_memory_runtime.valid_memory_search_source_strings] (#8484)
      - [memory_kind_enum_strings]
          mirrors [Keeper_memory_policy.valid_memory_kind_strings] (#8527)
      - [writable_memory_kind_enum_strings]
          mirrors [Keeper_memory_policy.writable_memory_kind_strings]
      - [fs_write_mode_enum_strings]
          mirrors [Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings] (#8490)
      - [vote_direction_enum_strings]
          mirrors [Board_votes.valid_vote_direction_strings] (#8506)

    Adding a new enum value MUST be done in the canonical owner first;
    the test suite then forces a sync edit here.

    Stage 11 (docs/audit/2026-05-18-godfile-decomposition-build-plan.html)
    consolidated these mirrors into this single module so future
    work can address the architectural cycle as one unit (RFC candidate:
    generated SSOT via dune rule or lazy late-binding registration). *)

let memory_search_source_enum_strings = [ "memory"; "history"; "all" ]

let memory_kind_enum_strings =
  [ "decision"
  ; "goal"
  ; "progress"
  ; "open_question"
  ; "long_term"
  ]
;;

let writable_memory_kind_enum_strings =
  [ "decision"; "goal"; "progress"; "open_question" ]
;;

let fs_write_mode_enum_strings = [ "overwrite"; "append"; "patch" ]
let sort_order_enum_strings = [ "hot"; "trending"; "recent"; "updated"; "discussed" ]
let vote_direction_enum_strings = [ "up"; "down" ]
