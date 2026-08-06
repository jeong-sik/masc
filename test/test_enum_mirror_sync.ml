(** The sync guard [Tool_shard_types_enum_mirrors] says it already has.

    That module hand-copies four enum string lists that downstream keeper and
    board modules own, and its header states the copies are "protected by a sync
    regression test in [test/test_types.ml]" and that "the test suite then forces
    a sync edit here". No such module exists — twenty-five sites under [lib/]
    cite it. Until this file, nothing compared the copies against their owners,
    so a fifth enum value added to an owner would have shipped a schema that
    never offered it, and the tool would have rejected the value its own
    documentation advertised.

    The mirror module is private to [masc_tool_surface], so the comparison runs
    against the observable end of the copy: the [enum] arrays that reach the
    tool schemas an LLM is handed. That is the contract that actually matters —
    if a mirror drifts, no emitted enum matches its owner's [valid_*_strings]
    any more. *)

open Alcotest

(* Every schema the tool surface publishes, flattened. keeper_board_schema is
   keyed by board name rather than listed, so walk the board vocabulary too. *)
let all_schemas () =
  let board_schemas =
    Tool_name.Board_name.all
    |> List.filter_map Tool_shard_types.keeper_board_schema
  in
  Tool_shard_types.base_tools
  @ Tool_shard_types.filesystem_tools
  @ Tool_shard_types.search_files_tools
  @ Tool_shard_types.typed_execute_tools
  @ Tool_shard_types.voice_tools
  @ [ Tool_shard_types.tool_execute_schema ]
  @ board_schemas
;;

(* Collect every string list that appears under an "enum" key anywhere in a
   schema, at any nesting depth. *)
let rec enum_arrays (json : Yojson.Safe.t) : string list list =
  match json with
  | `Assoc fields ->
    List.concat_map
      (fun (key, value) ->
        match key, value with
        | "enum", `List items ->
          let strings =
            List.filter_map
              (function `String s -> Some s | _ -> None)
              items
          in
          if strings = [] then [] else [ strings ]
        | _ -> enum_arrays value)
      fields
  | `List items -> List.concat_map enum_arrays items
  | _ -> []
;;

let published_enums () =
  all_schemas ()
  |> List.concat_map (fun (t : Masc_domain.tool_schema) -> enum_arrays t.input_schema)
;;

let check_mirror_in_sync ~label ~owner =
  let published = published_enums () in
  let matched = List.exists (fun e -> e = owner) published in
  if not matched
  then
    failf
      "%s: no published schema enum equals its owner's list %s.\n\
       The hand-mirrored copy in Tool_shard_types_enum_mirrors has drifted.\n\
       Published enums seen: %s"
      label
      (String.concat "|" owner)
      (String.concat "  /  " (List.map (String.concat "|") published))
;;

let test_memory_search_source_mirror () =
  check_mirror_in_sync
    ~label:"memory_search_source_enum_strings"
    ~owner:Masc.Keeper_tool_memory_runtime.valid_memory_search_source_strings
;;

let test_fs_write_mode_mirror () =
  check_mirror_in_sync
    ~label:"fs_write_mode_enum_strings"
    ~owner:Masc.Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings
;;

let test_sort_order_mirror () =
  check_mirror_in_sync
    ~label:"sort_order_enum_strings"
    ~owner:Masc.Board_dispatch.valid_sort_order_strings
;;

let test_vote_direction_mirror () =
  check_mirror_in_sync
    ~label:"vote_direction_enum_strings"
    ~owner:Masc.Board_votes.valid_vote_direction_strings
;;

(* A guard that passes when the thing it guards is empty is not a guard. *)
let test_owners_are_non_empty () =
  List.iter
    (fun (label, owner) ->
      check bool (label ^ " is non-empty") true (owner <> []))
    [ "memory_search_source", Masc.Keeper_tool_memory_runtime.valid_memory_search_source_strings
    ; "fs_write_mode", Masc.Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings
    ; "sort_order", Masc.Board_dispatch.valid_sort_order_strings
    ; "vote_direction", Masc.Board_votes.valid_vote_direction_strings
    ]
;;

let test_schema_set_is_non_empty () =
  check bool "some schema publishes an enum" true (published_enums () <> [])
;;

let () =
  Alcotest.run
    "Enum mirror sync"
    [ ( "mirrors"
      , [ test_case "memory search source" `Quick test_memory_search_source_mirror
        ; test_case "fs write mode" `Quick test_fs_write_mode_mirror
        ; test_case "board sort order" `Quick test_sort_order_mirror
        ; test_case "board vote direction" `Quick test_vote_direction_mirror
        ; test_case "owner lists are non-empty" `Quick test_owners_are_non_empty
        ; test_case "schemas publish enums" `Quick test_schema_set_is_non_empty
        ] )
    ]
;;
