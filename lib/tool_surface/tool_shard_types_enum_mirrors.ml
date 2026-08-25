(** Tool_shard_types_enum_mirrors — hand-mirrored enum string lists
    consumed by tool schema JSON producers in Tool_shard_types.

    These lists each mirror a [valid_*_strings] SSOT owned by a
    downstream keeper module. The schema layer remains a leaf, so each
    value is hand-kept in lock-step and protected by a sync regression test in
    [test/test_enum_mirror_sync.ml].

    Canonical owners (single source of truth per enum):
      - [memory_search_source_enum_strings]
          mirrors [Keeper_tool_memory_runtime.valid_memory_search_source_strings] (#8484)
      - [fs_write_mode_enum_strings]
          mirrors [Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings] (#8490)

    Adding a new enum value MUST be done in the canonical owner first;
    the sync test then forces the edit here — it compares each owner's list
    against the [enum] arrays the schemas actually publish. The Board-owned
    mirrors (sort order, vote direction, comment id pattern) left with the
    board keeper projections, whose enum values now live in the
    [config/tools/masc_board_*.toml] declarations under the same sync test.

    Stage 11 (docs/audit/2026-05-18-godfile-decomposition-build-plan.html)
    consolidated these mirrors into this single module so future
    work can address the architectural cycle as one unit (RFC candidate:
    generated SSOT via dune rule or lazy late-binding registration). *)

let memory_search_source_enum_strings = [ "memory"; "history"; "all" ]

let fs_write_mode_enum_strings = [ "overwrite"; "append"; "patch" ]
