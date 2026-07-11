(** Sync regression test for [Tool_shard_types_enum_mirrors].

    [lib/tool_surface/tool_shard_types_enum_mirrors.ml] hand-mirrors six
    [valid_*_strings] SSOT lists owned by downstream keeper/board modules.
    A direct dependency would form a dune cycle (the tool_surface layer may
    not reference keeper/board — see [lib/tool_surface/dune]), so each value
    is kept in lock-step by hand.

    This test — living in [test/] where both sides are reachable — asserts
    each mirror equals its canonical owner, so any future edit to an owner
    enum forces a matching edit here (or the suite goes red). Before this
    test existed the module docstring cited a [test/test_types.ml] that was
    never created (#24096), leaving all six mirrors unprotected. *)

let check label ~owner ~mirror =
  Alcotest.(check (list string)) label owner mirror
;;

let test_sort_order () =
  check "sort_order_enum_strings"
    ~owner:Masc.Board_dispatch.valid_sort_order_strings
    ~mirror:Tool_shard_types.sort_order_enum_strings
;;

let test_memory_search_source () =
  check "memory_search_source_enum_strings"
    ~owner:Masc.Keeper_tool_memory_runtime.valid_memory_search_source_strings
    ~mirror:Tool_shard_types.memory_search_source_enum_strings
;;

let test_memory_kind () =
  check "memory_kind_enum_strings"
    ~owner:Masc.Keeper_memory_policy.valid_memory_kind_strings
    ~mirror:Tool_shard_types.memory_kind_enum_strings
;;

let test_writable_memory_kind () =
  check "writable_memory_kind_enum_strings"
    ~owner:Masc.Keeper_memory_policy.writable_memory_kind_strings
    ~mirror:Tool_shard_types.writable_memory_kind_enum_strings
;;

let test_fs_write_mode () =
  check "fs_write_mode_enum_strings"
    ~owner:Masc.Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings
    ~mirror:Tool_shard_types.fs_write_mode_enum_strings
;;

let test_vote_direction () =
  check "vote_direction_enum_strings"
    ~owner:Masc.Board_votes.valid_vote_direction_strings
    ~mirror:Tool_shard_types.vote_direction_enum_strings
;;

let () =
  Alcotest.run "tool_shard_enum_mirror_sync"
    [ ( "mirrors match SSOT owners"
      , [ Alcotest.test_case "sort_order" `Quick test_sort_order
        ; Alcotest.test_case "memory_search_source" `Quick test_memory_search_source
        ; Alcotest.test_case "memory_kind" `Quick test_memory_kind
        ; Alcotest.test_case "writable_memory_kind" `Quick test_writable_memory_kind
        ; Alcotest.test_case "fs_write_mode" `Quick test_fs_write_mode
        ; Alcotest.test_case "vote_direction" `Quick test_vote_direction
        ] )
    ]
;;
