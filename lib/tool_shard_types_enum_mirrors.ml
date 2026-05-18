(** Tool_shard_types_enum_mirrors — hand-mirrored enum string lists
    consumed by tool schema JSON producers in Tool_shard_types.

    These seven lists each mirror a [valid_*_strings] SSOT owned by a
    downstream keeper/board module. A direct dependency would form a
    cycle (Tool_shard -> Keeper_alerting -> Tool_shard via
    [keeper_model_tools]), so each value is hand-kept in lock-step
    and protected by a sync regression test in [test/test_types.ml].

    Canonical owners (single source of truth per enum):
      - [pr_review_event_enum_strings]
          mirrors [Keeper_tool_pr_review.valid_pr_review_event_strings] (#8480)
      - [sort_order_enum_strings]
          mirrors [Board_dispatch.valid_sort_order_strings] (#8513)
      - [keeper_shell_op_enum_strings]
          mirrors [Keeper_exec_shell.valid_shell_op_strings] (#8524)
      - [memory_search_source_enum_strings]
          mirrors [Keeper_exec_memory.valid_memory_search_source_strings] (#8484)
      - [memory_kind_enum_strings]
          mirrors [Keeper_memory_policy.valid_memory_kind_strings] (#8527)
      - [fs_write_mode_enum_strings]
          mirrors [Keeper_exec_fs.valid_fs_write_mode_strings] (#8490)
      - [vote_direction_enum_strings]
          mirrors [Board_votes.valid_vote_direction_strings] (#8506)

    Adding a new enum value MUST be done in the canonical owner first;
    the test suite then forces a sync edit here.

    Stage 11 (docs/audit/2026-05-18-godfile-decomposition-build-plan.html)
    consolidated these seven mirrors into this single module so future
    work can address the architectural cycle as one unit (RFC candidate:
    generated SSOT via dune rule or lazy late-binding registration). *)

let pr_review_event_enum_strings = [ "COMMENT"; "APPROVE"; "REQUEST_CHANGES" ]
let memory_search_source_enum_strings = [ "memory"; "history"; "all" ]

let memory_kind_enum_strings =
  [ "constraints"
  ; "decision"
  ; "next"
  ; "goal"
  ; "progress"
  ; "open_question"
  ; "long_term"
  ]
;;

let fs_write_mode_enum_strings = [ "overwrite"; "append"; "patch" ]
let sort_order_enum_strings = [ "hot"; "trending"; "recent"; "updated"; "discussed" ]
let vote_direction_enum_strings = [ "up"; "down" ]

let keeper_shell_op_enum_strings =
  [ "pwd"
  ; "ls"
  ; "cat"
  ; "rg"
  ; "git_status"
  ; "find"
  ; "head"
  ; "tail"
  ; "wc"
  ; "tree"
  ; "git_log"
  ; "git_diff"
  ; "git_worktree"
  ; "git_clone"
  ; "gh"
  ]
;;
