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
  (* The Schedule tools publish from their own library rather than the keeper
     shard. Include them so the typed contract's schema projection is observed
     by the same boundary test. *)
  @ Tool_schemas_schedule.schemas
  (* [board_schemas] above is the eight curated Keeper projections. The other
     thirteen Board tools reach a Keeper through the canonical registry, which
     was outside this walk, and so were the Task schemas. *)
  @ Board_tool_registry.tools
  @ Masc.Task.Schemas.schemas
;;

(* Every value a schema advertises has to be one the handler takes -- the
   failure this file's header describes, "the tool would have rejected the value
   its own documentation advertised". Unlike [check_mirror_in_sync] this needs
   no enumeration on the owner's side, which is what the two owners below do not
   export.

   It catches the harmful direction only. A domain value missing from the schema
   is invisible here; seeing that needs an [all_*] list, and adding one purely so
   a test could reach it is the surface the dead-export ratchet refuses. *)
let check_every_advertised_value_decodes ~label ~decodes ~advertised =
  check bool
    (Printf.sprintf "%s is advertised somewhere" label)
    true
    (advertised <> []);
  match List.filter (fun value -> not (decodes value)) advertised with
  | [] -> ()
  | rejected ->
    failf
      "%s: the schema advertises %s, which the handler refuses.\n\
       Advertised: %s"
      label
      (String.concat ", " rejected)
      (String.concat ", " advertised)
;;

(* The enum declared for one property name, across every schema that declares
   it, so a second copy of the same property is compared too. *)
let advertised_values_for_schemas schemas ~property =
  let rec walk (json : Yojson.Safe.t) =
    match json with
    | `Assoc fields ->
      List.concat_map
        (fun (key, value) ->
          match value with
          | `Assoc inner when String.equal key property ->
            (match List.assoc_opt "enum" inner with
             | Some (`List items) ->
               List.filter_map (function `String v -> Some v | _ -> None) items
             | _ -> walk value)
          | _ -> walk value)
        fields
    | `List items -> List.concat_map walk items
    | _ -> []
  in
  schemas
  |> List.concat_map (fun (t : Masc_domain.tool_schema) -> walk t.input_schema)
  |> List.sort_uniq String.compare
;;

let advertised_values_for ~property =
  advertised_values_for_schemas (all_schemas ()) ~property
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

let check_mirror_in_sync ?(copy_lives_in = "Tool_shard_types_enum_mirrors") ~label ~owner () =
  let published = published_enums () in
  let matched = List.exists (fun e -> e = owner) published in
  if not matched
  then
    failf
      "%s: no published schema enum equals its owner's list %s.\n\
       The published enum contract in %s has drifted.\n\
       Published enums seen: %s"
      label
      (String.concat "|" owner)
      copy_lives_in
      (String.concat "  /  " (List.map (String.concat "|") published))
;;

(* The typed schedule contract projects each tool-facing vocabulary into named
   properties on the Schedule schemas. Check each property directly so one
   matching enum elsewhere cannot hide a drifted Schedule field. *)
let test_schedule_contract_mirrors () =
  List.iter
    (fun (property, owner) ->
      check (list string)
        (Printf.sprintf "Schedule property %s matches its typed owner" property)
        (List.sort_uniq String.compare owner)
        (advertised_values_for_schemas Tool_schemas_schedule.schemas ~property))
    [ "status", Schedule_contract_values.schedule_status_strings
    ; "requested_by_kind", Schedule_contract_values.actor_kind_strings
    ; "scheduled_by_kind", Schedule_contract_values.actor_kind_strings
    ; "cancelled_by_kind", Schedule_contract_values.actor_kind_strings
    ; "source", Schedule_contract_values.schedule_source_strings
    ; "recurrence_kind", Schedule_contract_values.recurrence_kind_strings
    ]
;;
(* Board sub-board access. [Masc.Board] owns the vocabulary through
   [sub_board_access_of_string_opt]; the schema writes the three strings by
   hand, in two places. *)
let test_sub_board_access_advertised_values_decode () =
  check_every_advertised_value_decodes
    ~label:"sub_board access"
    ~decodes:(fun v ->
      Option.is_some (Masc.Board.sub_board_access_of_string_opt v))
    ~advertised:(advertised_values_for ~property:"access")
;;

(* Task reclaim policy. Same shape: [Masc_domain.task_reclaim_policy_of_string]
   owns it and the schema writes the two strings by hand. *)
let test_reclaim_policy_advertised_values_decode () =
  check_every_advertised_value_decodes
    ~label:"task reclaim_policy"
    ~decodes:(fun v -> Result.is_ok (Masc_domain.task_reclaim_policy_of_string v))
    ~advertised:(advertised_values_for ~property:"reclaim_policy")
;;

let test_memory_search_source_mirror () =
  check_mirror_in_sync
    ~label:"memory_search_source_enum_strings"
    ~owner:Masc.Keeper_tool_memory_runtime.valid_memory_search_source_strings
    ()
;;

let test_fs_write_mode_mirror () =
  check_mirror_in_sync
    ~label:"fs_write_mode_enum_strings"
    ~owner:Masc.Keeper_tool_filesystem_runtime.valid_fs_write_mode_strings
    ()
;;

let test_sort_order_mirror () =
  check_mirror_in_sync
    ~label:"sort_order_enum_strings"
    ~owner:Masc.Board_dispatch.valid_sort_order_strings
    ()
;;

let test_vote_direction_mirror () =
  check_mirror_in_sync
    ~label:"vote_direction_enum_strings"
    ~owner:Masc.Board_votes.valid_vote_direction_strings
    ()
;;

(* The [pattern] declared for one property name across every schema that
   declares it, mirroring [advertised_values_for_schemas] for enums. *)
let declared_patterns_for_schemas schemas ~property =
  let rec walk (json : Yojson.Safe.t) =
    match json with
    | `Assoc fields ->
      List.concat_map
        (fun (key, value) ->
          match value with
          | `Assoc inner when String.equal key property ->
            (match List.assoc_opt "pattern" inner with
             | Some (`String pattern) -> [ pattern ]
             | _ -> walk value)
          | _ -> walk value)
        fields
    | `List items -> List.concat_map walk items
    | _ -> []
  in
  schemas
  |> List.concat_map (fun (t : Masc_domain.tool_schema) -> walk t.input_schema)
  |> List.sort_uniq String.compare
;;

(* Board comment id. [Masc.Board.Comment_id] owns the shape; the canonical
   comment_vote / comment schemas read it directly and the Keeper projection of
   masc_board_comment hand-copies it as [comment_id_pattern]. Both property
   names carry a comment id, so each is compared on its own. *)
let test_comment_id_pattern_mirror () =
  List.iter
    (fun property ->
      check (list string)
        (Printf.sprintf "%s pattern matches Board.Comment_id" property)
        [ Masc.Board.Comment_id.json_schema_pattern ]
        (declared_patterns_for_schemas (all_schemas ()) ~property))
    [ "comment_id"; "parent_id" ]
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
        ; test_case "board comment id pattern" `Quick test_comment_id_pattern_mirror
        ; test_case "schedule contract enums" `Quick test_schedule_contract_mirrors
        ; test_case "sub_board access values decode" `Quick
            test_sub_board_access_advertised_values_decode
        ; test_case "reclaim_policy values decode" `Quick
            test_reclaim_policy_advertised_values_decode
        ; test_case "owner lists are non-empty" `Quick test_owners_are_non_empty
        ; test_case "schemas publish enums" `Quick test_schema_set_is_non_empty
        ] )
    ]
;;
