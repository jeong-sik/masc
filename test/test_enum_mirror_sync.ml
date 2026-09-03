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
(* The three Goal tool schemas moved into config/tools/masc_goal_*.toml, where
   the enum arrays are literals: nothing in TOML can read an OCaml variant. The
   variants stay the owners, so check each property directly rather than
   accepting any matching enum elsewhere — a constructor added to either one
   without editing its file would otherwise ship a schema that never offers the
   value, and the tool would reject what its own documentation advertised. *)
(* masc_library_add's [source] vocabulary. [Masc.Tool_library] owns it,
   deriving the strings from its variant; the schema wrote the same four by
   hand and now writes them in config/tools/masc_library_add.toml, where
   nothing can read an OCaml value. Nothing compared the two until this: a
   fifth source added to the variant would have shipped a schema that never
   offered it. *)
let test_library_source_mirrors_its_owner () =
  check
    (list string)
    "masc_library_add source matches Tool_library.valid_source_strings"
    (List.sort_uniq String.compare Masc.Tool_library.valid_source_strings)
    (advertised_values_for_schemas Tool_schemas_library.schemas ~property:"source")
;;

(* The keeper sandbox and status vocabularies. Their owners are
   [Keeper_types_profile_sandbox], [Keeper_sandbox_control_contract] and
   [Masc.Keeper_status_options_defaults]; the schemas write the strings in
   config/tools/masc_keeper_*.toml, where nothing reads an OCaml value. *)
let test_keeper_tool_enum_mirrors () =
  List.iter
    (fun (property, owner) ->
      check (list string)
        (Printf.sprintf "Keeper property %s matches its typed owner" property)
        (List.sort_uniq String.compare owner)
        (advertised_values_for_schemas Masc.Keeper_schema.schemas ~property))
    [ "network_mode", Keeper_types_profile_sandbox.valid_network_mode_strings
    ; "container_kind", Masc.Keeper_sandbox_control_contract.stop_scope_strings
    ; "tail_order", Masc.Keeper_status_options_defaults.valid_tail_order_strings
    ]
;;

(* masc_keeper_status states its bounds twice -- once as minimum/maximum and
   once inside the sentence a model reads -- and both were built from
   [Masc.Keeper_status_options_defaults] by Printf. In TOML they are literals, so
   check the numbers rather than trusting them to agree. *)
let test_keeper_status_bounds_match_their_owner () =
  let status =
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name "masc_keeper_status")
        Masc.Keeper_schema.schemas
    with
    | Some s -> s
    | None -> failf "masc_keeper_status is absent"
  in
  let bound property key =
    match status.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) ->
         (match List.assoc_opt property props with
          | Some (`Assoc p) ->
            (match List.assoc_opt key p with
             | Some (`Int v) -> v
             | _ -> failf "%s.%s is absent or not an integer" property key)
          | _ -> failf "property %s is absent" property)
       | _ -> failf "no properties")
    | _ -> failf "input_schema is not an object"
  in
  let open Masc.Keeper_status_options_defaults in
  List.iter
    (fun (property, lo, hi) ->
      check int (property ^ " minimum") lo (bound property "minimum");
      check int (property ^ " maximum") hi (bound property "maximum"))
    [ Argument.tail_turns, min_tail_turns, max_tail_turns
    ; Argument.tail_messages, min_tail_messages, max_tail_messages
    ; Argument.tail_bytes, min_tail_bytes, max_tail_bytes
    ]
;;

(* keeper_artifact_read states its max_bytes bounds and default, and
   keeper_analyze_image its media-type vocabulary. [Keeper_artifact_read] and
   [Keeper_vision_tool] own them; in config/tools/*.toml they are literals. *)
let test_runtime_tool_owners_match () =
  check
    (list string)
    "keeper_analyze_image media types match Keeper_vision_tool"
    (List.sort_uniq String.compare Masc.Keeper_vision_tool.supported_image_media_types)
    (advertised_values_for_schemas
       Masc.Keeper_runtime_schemas_toml.schemas
       ~property:"media_type");
  let artifact =
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name "keeper_artifact_read")
        Masc.Keeper_runtime_schemas_toml.schemas
    with
    | Some s -> s
    | None -> failf "keeper_artifact_read is absent"
  in
  let field key =
    match artifact.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) ->
         (match List.assoc_opt "max_bytes" props with
          | Some (`Assoc p) ->
            (match List.assoc_opt key p with
             | Some (`Int v) -> v
             | _ -> failf "max_bytes.%s is absent or not an integer" key)
          | _ -> failf "max_bytes is absent")
       | _ -> failf "no properties")
    | _ -> failf "input_schema is not an object"
  in
  check int "max_bytes minimum" Masc.Keeper_artifact_read.minimum_max_bytes (field "minimum");
  check int "max_bytes maximum" Masc.Keeper_artifact_read.maximum_max_bytes (field "maximum");
  check int "max_bytes default" Masc.Keeper_artifact_read.default_max_bytes (field "default")
;;

(* keeper_surface_post caps two arrays, and [Keeper_surface_post] owns both
   numbers. The descriptor used to build the mentions cap from the constant;
   that copy is gone, so the file states it and this compares the two. The
   block cap already had a check in the registry-integrity suite. *)
let test_surface_post_caps_match_their_owner () =
  let post =
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name "keeper_surface_post")
        Tool_shard_types.surface_tools
    with
    | Some s -> s
    | None -> failf "keeper_surface_post is absent"
  in
  let cap property =
    match post.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) ->
         (match List.assoc_opt property props with
          | Some (`Assoc p) ->
            (match List.assoc_opt "maxItems" p with
             | Some (`Int v) -> v
             | _ -> failf "%s has no maxItems" property)
          | _ -> failf "property %s is absent" property)
       | _ -> failf "no properties")
    | _ -> failf "input_schema is not an object"
  in
  check int "mention_user_ids cap" Masc.Keeper_surface_post.max_user_mentions
    (cap "mention_user_ids");
  check int "blocks cap" Masc.Keeper_surface_post.max_rich_blocks (cap "blocks")
;;

(* tool_read_file states its default byte ceiling inside the sentence a client
   reads. [Tool_shard_limits] owns the number; the declaration used to render
   it through a pre-made string, and in TOML it is a literal. Nothing else
   compares the two. *)
let test_read_file_default_appears_in_its_description () =
  let read_file =
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name "tool_read_file")
        Tool_shard_types.filesystem_tools
    with
    | Some s -> s
    | None -> failf "tool_read_file is absent"
  in
  let description =
    match read_file.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) ->
         (match List.assoc_opt "max_bytes" props with
          | Some (`Assoc p) ->
            (match List.assoc_opt "description" p with
             | Some (`String d) -> d
             | _ -> failf "max_bytes has no description")
          | _ -> failf "max_bytes is absent")
       | _ -> failf "no properties")
    | _ -> failf "input_schema is not an object"
  in
  let needle = string_of_int Tool_shard_limits.read_file_default_max_bytes in
  let n = String.length needle
  and h = String.length description in
  let rec probe i =
    i + n <= h && (String.equal (String.sub description i n) needle || probe (i + 1))
  in
  check bool
    (Printf.sprintf "max_bytes description names %s" needle)
    true
    (probe 0)
;;

let test_goal_tool_enum_mirrors () =
  List.iter
    (fun (property, owner) ->
      check (list string)
        (Printf.sprintf "Goal property %s matches its variant" property)
        (List.sort_uniq String.compare owner)
        (advertised_values_for_schemas Tool_schemas_workspace_extra.schemas ~property))
    [ "phase", List.map Goal_phase.to_string Goal_phase.all
    ; ( "action"
      , List.map Goal_phase.Public_action.to_string Goal_phase.Public_action.all )
    ]
;;

(* masc_operator_snapshot, masc_operator_digest and masc_operator_action moved
   to config/tools/masc_operator_*.toml, where the enum arrays are literals:
   nothing in TOML can read an OCaml value. The owners are
   [Operator_control_snapshot], [Masc.Operator_action_constants] and
   [Masc.Operator_action_catalog]. Each property is checked on its own tool's
   schema -- digest and action both declare [target_type] with different
   vocabularies, so a combined walk could let one hide the other's drift. *)
let test_operator_tool_enum_mirrors () =
  let schema name =
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
        Operator_tool.schemas
    with
    | Some s -> s
    | None -> failf "%s is absent from Operator_tool.schemas" name
  in
  List.iter
    (fun (tool, property, owner) ->
       check
         (list string)
         (Printf.sprintf "%s %s matches its typed owner" tool property)
         (List.sort_uniq String.compare owner)
         (advertised_values_for_schemas [ schema tool ] ~property))
    [ ( "masc_operator_snapshot"
      , "view"
      , Operator_control_snapshot.valid_snapshot_view_strings )
    ; ( "masc_operator_digest"
      , "target_type"
      , [ Masc.Operator_action_constants.workspace_target_type ] )
    ; ( "masc_operator_action"
      , "target_type"
      , Masc.Operator_action_constants.valid_target_type_strings )
    ; "masc_operator_action", "action_type", Masc.Operator_action_catalog.strings
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
        ; test_case "library source enum" `Quick test_library_source_mirrors_its_owner
        ; test_case "runtime tool owners" `Quick test_runtime_tool_owners_match
        ; test_case "keeper tool enums" `Quick test_keeper_tool_enum_mirrors
        ; test_case
            "keeper status bounds"
            `Quick
            test_keeper_status_bounds_match_their_owner
        ; test_case
            "surface post caps"
            `Quick
            test_surface_post_caps_match_their_owner
        ; test_case
            "read_file default in its description"
            `Quick
            test_read_file_default_appears_in_its_description
        ; test_case "goal tool enums" `Quick test_goal_tool_enum_mirrors
        ; test_case "operator tool enums" `Quick test_operator_tool_enum_mirrors
        ; test_case "sub_board access values decode" `Quick
            test_sub_board_access_advertised_values_decode
        ; test_case "reclaim_policy values decode" `Quick
            test_reclaim_policy_advertised_values_decode
        ; test_case "owner lists are non-empty" `Quick test_owners_are_non_empty
        ; test_case "schemas publish enums" `Quick test_schema_set_is_non_empty
        ] )
    ]
;;
