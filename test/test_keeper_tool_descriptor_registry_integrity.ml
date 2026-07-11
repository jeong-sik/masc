(** Registry integrity checks that the OCaml type system cannot enforce.

    [Keeper_tool_descriptor.runtime_handler] is a closed variant and
    every in-process dispatch site pattern-matches against it
    exhaustively, so the "descriptor registered without a dispatch
    handler" case is already caught at compile time. What is NOT
    caught:

    - duplicate [public_name] strings across descriptors
    - duplicate [internal_name] strings across descriptors
    - empty / whitespace-only name fields
    - [internal_name] format drift (non-snake_case, embedded spaces,
      etc.)

    These are exactly the failures a big-bang descriptor-add merge
    (e.g., RFC-0179 #18710, 38 descriptors) is most likely to
    introduce: typos in name fields propagate silently until a caller
    looks them up by string. *)

open Alcotest
module Descriptor = Masc.Keeper_tool_descriptor
module Policy = Masc.Keeper_tool_policy
module Exec = Masc.Keeper_tool_dispatch_runtime
module Registry = Masc.Keeper_tool_registry
module Resolution = Masc.Keeper_tool_descriptor_resolution
module Surface = Masc.Keeper_agent_tool_surface
module Board = Tool_shard_types
module Board_tool_registry = Board_tool_registry
module Keeper_dispatch_ref = Masc.Keeper_dispatch_ref
module Workspace = Masc.Workspace
module Task = Masc.Task
module Keeper_tool_surface = Masc.Keeper_tool_surface
module Capability_registry = Masc.Capability_registry

(* Force-link [Keeper_tool_surface] so its module-load registration of
   keeper tools into [Keeper_dispatch_ref.dispatch] runs before the
   dispatch gap test. *)
let () = ignore Masc.Keeper_tool_surface.schemas

let all_descriptors () : Descriptor.t list = Descriptor.all_descriptors ()

(* RFC-0190 — Descriptor as Visibility/Metadata SSOT.

   [Tool_catalog_surfaces.public_mcp_surface_tools] is the operator-facing
   MCP surface set. Its end-state under RFC-0190 P4 is to be computed as
   [filter (visibility = Public_mcp) all_descriptors], deleting the hand
   list entirely.

   Some surface entries intentionally have no descriptor at all because their
   handlers live outside the keeper descriptor spine. These entries are
   enumerated below as the [public_mcp_non_descriptor] allowlist.

   This invariant test exists to ratchet that allowlist toward empty:
   - Adding a new surface entry without a descriptor fails the test.
   - Adding a descriptor for any allowlist entry fails the
     test (allowlist must shrink), forcing the allowlist edit to live in
     the same PR as the descriptor add.

   When the allowlist hits zero, RFC-0190 P4 lands [public_mcp_surface_tools]
   as a function over [all_descriptors] and this test is rewritten to
   forbid any pending entries. *)
let public_mcp_non_descriptor =
  Keeper_tool_name.public_mcp_non_descriptor_names
;;

let descriptor_internal_name_set () =
  let tbl = Hashtbl.create 256 in
  List.iter
    (fun d -> Hashtbl.replace tbl d.Descriptor.internal_name ())
    (all_descriptors ());
  tbl
;;

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0
  then true
  else
    let rec loop i =
      i + needle_len <= haystack_len
      &&
      (String.equal (String.sub haystack i needle_len) needle || loop (i + 1))
    in
    loop 0
;;

let source_path rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  Filename.concat source_root rel
;;

let find_duplicates ~key (xs : Descriptor.t list) : (string * int) list =
  let counts = Hashtbl.create 64 in
  List.iter
    (fun d ->
      let k = key d in
      let prev = Option.value (Hashtbl.find_opt counts k) ~default:0 in
      Hashtbl.replace counts k (prev + 1))
    xs;
  Hashtbl.fold
    (fun k count acc -> if count > 1 then (k, count) :: acc else acc)
    counts
    []

let test_public_name_uniqueness () =
  let dups = find_duplicates ~key:(fun d -> d.Descriptor.public_name) (all_descriptors ()) in
  if dups <> []
  then
    Alcotest.failf
      "duplicate public_name(s) across Keeper_tool_descriptor.all_descriptors: %s"
      (String.concat ", "
         (List.map (fun (n, c) -> Printf.sprintf "%S×%d" n c) dups))

let test_internal_name_uniqueness () =
  let dups = find_duplicates ~key:(fun d -> d.Descriptor.internal_name) (all_descriptors ()) in
  if dups <> []
  then
    Alcotest.failf
      "duplicate internal_name(s) across Keeper_tool_descriptor.all_descriptors: %s"
      (String.concat ", "
         (List.map (fun (n, c) -> Printf.sprintf "%S×%d" n c) dups))

let test_keeper_model_projection_is_single_and_unique () =
  let model_names =
    all_descriptors () |> List.concat_map Descriptor.keeper_model_names
  in
  let unique_names = List.sort_uniq String.compare model_names in
  Alcotest.(check int)
    "one descriptor owns each Keeper model name"
    (List.length model_names)
    (List.length unique_names);
  List.iter
    (fun (descriptor : Descriptor.t) ->
       let projected = Descriptor.keeper_model_names descriptor in
       let candidates = Descriptor.keeper_candidate_names descriptor in
       match descriptor.keeper_model_projection with
       | Descriptor.Preferred_public_name ->
         Alcotest.(check (list string))
           (descriptor.id ^ " preferred model projection")
           [ descriptor.public_name ]
           projected;
         Alcotest.(check bool)
           (descriptor.id ^ " keeps internal dispatch candidate")
           true
           (List.mem descriptor.internal_name candidates);
         descriptor.public_aliases
         |> List.iter (fun alias ->
           Alcotest.(check bool)
             (descriptor.id ^ " keeps compatibility dispatch alias " ^ alias)
             true
             (List.mem alias candidates))
       | Descriptor.Internal_name ->
         Alcotest.(check (list string))
           (descriptor.id ^ " internal model projection")
           [ descriptor.internal_name ]
           projected
       | Descriptor.Dispatch_only ->
         Alcotest.(check (list string))
           (descriptor.id ^ " has no model projection")
           []
           projected;
         Alcotest.(check (list string))
           (descriptor.id ^ " has no Keeper candidates")
           []
           candidates)
    (all_descriptors ())
;;

let test_semantic_capability_has_at_most_one_keeper_model_projection () =
  Capability_registry.all_capabilities_from Masc.Config.raw_all_tool_schemas
  |> List.iter (fun (capability : Capability_registry.capability_def) ->
    let descriptors =
      capability.projections
      |> List.filter_map (fun (projection : Capability_registry.projection) ->
        Resolution.descriptor_for_tool_name projection.tool_name)
      |> List.sort_uniq
           (fun (left : Descriptor.t) (right : Descriptor.t) ->
              String.compare left.id right.id)
    in
    let model_names =
      descriptors
      |> List.concat_map Descriptor.keeper_model_names
      |> List.sort_uniq String.compare
    in
    if List.length model_names > 1
    then
      Alcotest.failf
        "semantic capability %S has multiple Keeper model projections: %s"
        capability.capability_id
        (String.concat ", " model_names))
;;

let test_model_visible_descriptors_have_canonical_input_schemas () =
  Descriptor.model_visible_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    match descriptor.input_schema_source with
    | Descriptor.Descriptor_owned | Descriptor.Canonical_registry -> ()
    | Descriptor.Missing_canonical_registry ->
      Alcotest.failf
        "model-visible descriptor %S is missing its canonical input schema"
        descriptor.id)
;;

let test_cluster_descriptors_have_no_missing_canonical_schemas () =
  all_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    match descriptor.input_schema_source with
    | Descriptor.Descriptor_owned | Descriptor.Canonical_registry -> ()
    | Descriptor.Missing_canonical_registry ->
      Alcotest.failf
        "descriptor %S (%s) is missing its canonical input schema"
        descriptor.id
        descriptor.internal_name)
;;

let test_missing_canonical_schema_is_fail_closed () =
  let base = required_internal_descriptor "masc_transition" in
  let missing =
    { base with
      input_schema_source = Descriptor.Missing_canonical_registry
    ; keeper_model_projection = Descriptor.Internal_name
    }
  in
  Alcotest.(check (list string))
    "missing schema has no model names"
    []
    (Descriptor.keeper_model_names missing);
  Alcotest.(check (list string))
    "missing schema has no execution candidates"
    []
    (Descriptor.keeper_candidate_names missing);
  Alcotest.(check (list string))
    "startup diagnostic reports missing canonical schema"
    [ missing.internal_name ]
    (Policy.missing_canonical_schema_names [ missing ])
;;

let test_registered_cluster_model_projections_are_explicit () =
  let check_projection internal_name expected =
    let descriptor = required_internal_descriptor internal_name in
    Alcotest.(check bool)
      (internal_name ^ " model projection")
      true
      (descriptor.keeper_model_projection = expected)
  in
  List.iter
    (fun name -> check_projection name Descriptor.Internal_name)
    [ "masc_library_list"
    ; "masc_library_add"
    ; "masc_library_promote"
    ; "masc_recurring_add"
    ; "masc_recurring_list"
    ; "masc_recurring_remove"
    ; "masc_runtime_verify"
    ; "masc_runtime_ollama_probe"
    ; "masc_goal_hygiene_review"
    ; "masc_gc"
    ];
  List.iter
    (fun name -> check_projection name Descriptor.Dispatch_only)
    [ "masc_library_read"; "masc_library_search" ];
  List.iter
    (fun name -> check_projection name Descriptor.Internal_name)
    [ "keeper_library_read"; "keeper_library_search" ]
;;

let test_dynamic_model_description_projection_is_explicit () =
  all_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    let expected =
      if String.equal descriptor.internal_name "masc_transition"
      then Descriptor.Current_task_state
      else Descriptor.Static_description
    in
    Alcotest.(check bool)
      (descriptor.id ^ " model description projection")
      true
      (descriptor.model_description_projection = expected))
;;

let test_all_keeper_shard_schemas_are_descriptor_backed () =
  Tool_shard.all_keeper_tool_schemas
  |> List.iter (fun (schema : Masc_domain.tool_schema) ->
    match Descriptor.descriptors_for_internal schema.name with
    | [ _ ] -> ()
    | [] -> Alcotest.failf "Keeper shard schema %S has no descriptor" schema.name
    | descriptors ->
      Alcotest.failf
        "Keeper shard schema %S has %d descriptors"
        schema.name
        (List.length descriptors))
;;

let test_supported_masc_schemas_are_descriptor_backed () =
  Masc_test_deps.init_keeper_tool_registry ();
  Policy.keeper_supported_masc_schemas Masc.Config.raw_all_tool_schemas
  |> List.iter (fun (schema : Masc_domain.tool_schema) ->
    match Descriptor.descriptors_for_internal schema.name with
    | [ _ ] -> ()
    | [] ->
      Alcotest.failf
        "supported MASC schema %S has no descriptor"
        schema.name
    | descriptors ->
      Alcotest.failf
        "supported MASC schema %S has %d descriptors"
        schema.name
        (List.length descriptors))
;;

let test_maintenance_descriptors_are_dispatch_only () =
  all_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    if descriptor.policy.maintenance_only
    then
      match descriptor.keeper_model_projection with
      | Descriptor.Dispatch_only -> ()
      | Descriptor.Preferred_public_name | Descriptor.Internal_name ->
        Alcotest.failf
          "maintenance descriptor %S is model-visible"
          descriptor.internal_name)
;;

let is_blank s = String.trim s = ""

let string_contains ~sub text =
  let text_len = String.length text in
  let sub_len = String.length sub in
  let rec loop idx =
    if idx + sub_len > text_len
    then false
    else if String.sub text idx sub_len = sub
    then true
    else loop (idx + 1)
  in
  sub_len = 0 || loop 0
;;

let test_no_blank_names () =
  List.iter
    (fun d ->
      if is_blank d.Descriptor.public_name
      then
        Alcotest.failf
          "descriptor with internal_name=%S has blank public_name"
          d.Descriptor.internal_name;
      if is_blank d.Descriptor.internal_name
      then
        Alcotest.failf
          "descriptor with public_name=%S has blank internal_name"
          d.Descriptor.public_name)
    (all_descriptors ())

let eval_tag_charset_ok c =
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'

let assert_eval_tags_unique descriptor =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun tag ->
      if Hashtbl.mem seen tag
      then
        Alcotest.failf
          "descriptor %S has duplicate eval_tag %S"
          descriptor.Descriptor.internal_name
          tag;
      Hashtbl.replace seen tag ())
    descriptor.Descriptor.eval_tags
;;

let test_eval_tags_are_normalized () =
  List.iter
    (fun d ->
      assert_eval_tags_unique d;
      List.iter
        (fun tag ->
          if is_blank tag
          then
            Alcotest.failf
              "descriptor %S has blank eval_tag"
              d.Descriptor.internal_name;
          if not (String.equal tag (String.trim tag))
          then
            Alcotest.failf
              "descriptor %S has untrimmed eval_tag %S"
              d.Descriptor.internal_name
              tag;
          String.iter
            (fun c ->
              if not (eval_tag_charset_ok c)
              then
                Alcotest.failf
                  "descriptor %S eval_tag %S contains invalid character %C \
                   (allowed: a-z, 0-9, _)"
                  d.Descriptor.internal_name
                  tag
                  c)
            tag)
        d.Descriptor.eval_tags)
    (all_descriptors ())

let test_seed_eval_tags_are_registered () =
  let check tool_name expected =
    let descriptor =
      match Descriptor.descriptors_for_internal tool_name with
      | descriptor :: _ -> descriptor
      | [] -> Alcotest.failf "missing internal descriptor: %s" tool_name
    in
    Alcotest.(check (list string))
      (tool_name ^ " eval_tags")
      expected
      descriptor.Descriptor.eval_tags
  in
  check "keeper_tools_list" [ "capability_introspection" ];
  check "keeper_tool_search" [ "capability_introspection" ];
  check "keeper_surface_read" [ "surface_context_read" ];
  check "masc_agent_card" [ "agent_profile_lookup" ];
  check "keeper_time_now" []
;;

let internal_name_charset_ok c =
  (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'

let test_internal_name_snake_case () =
  List.iter
    (fun d ->
      let n = d.Descriptor.internal_name in
      String.iter
        (fun c ->
          if not (internal_name_charset_ok c)
          then
            Alcotest.failf
              "internal_name %S contains non-snake_case character %C \
               (allowed: a-z, 0-9, _)"
              n
              c)
        n)
    (all_descriptors ())

let test_registry_not_empty () =
  if all_descriptors () = []
  then Alcotest.failf "Keeper_tool_descriptor.all_descriptors () returned []"

let required_public_descriptor name =
  match Descriptor.find_public name with
  | Some descriptor -> descriptor
  | None -> Alcotest.failf "missing public descriptor: %s" name
;;

let required_internal_descriptor name =
  match Descriptor.descriptors_for_internal name with
  | descriptor :: _ -> descriptor
  | [] -> Alcotest.failf "missing internal descriptor: %s" name
;;

let schema_property_description schema name =
  let open Yojson.Safe.Util in
  schema |> member "properties" |> member name |> member "description"
  |> to_string_option
;;

let schema_property_int schema name field =
  let open Yojson.Safe.Util in
  schema |> member "properties" |> member name |> member field |> to_int_option
;;

let schema_required_fields schema =
  match schema with
  | `Assoc fields ->
    (match List.assoc_opt "required" fields with
     | Some (`List values) ->
       List.map
         (function
           | `String value -> value
           | other ->
             Alcotest.failf
               "required contains non-string: %s"
               (Yojson.Safe.to_string other))
         values
     | Some other ->
       Alcotest.failf "required is not a list: %s" (Yojson.Safe.to_string other)
     | None -> [])
  | other -> Alcotest.failf "input_schema is not an object: %s" (Yojson.Safe.to_string other)
;;

let schema_property_names schema =
  match schema with
  | `Assoc fields ->
    (match List.assoc_opt "properties" fields with
     | Some (`Assoc properties) -> List.map fst properties
     | Some other ->
       Alcotest.failf
         "input_schema properties is not an object: %s"
         (Yojson.Safe.to_string other)
     | None -> [])
  | other ->
    Alcotest.failf
      "input_schema is not an object: %s"
      (Yojson.Safe.to_string other)
;;

let schema_forbids_additional_properties schema =
  match schema with
  | `Assoc fields ->
    (match List.assoc_opt "additionalProperties" fields with
     | Some (`Bool false) -> true
     | _ -> false)
  | other -> Alcotest.failf "input_schema is not an object: %s" (Yojson.Safe.to_string other)
;;

let required_board_schema name =
  match List.find_opt (fun (s : Masc_domain.tool_schema) -> s.name = name) Board.board_tools with
  | Some schema -> schema
  | None -> Alcotest.failf "missing board schema: %s" name
;;

let required_masc_board_schema name =
  match
    List.find_opt
      (fun (s : Masc_domain.tool_schema) -> s.name = name)
      Board_tool_registry.tools
  with
  | Some schema -> schema
  | None -> Alcotest.failf "missing masc board schema: %s" name
;;

let check_contains label ~sub text =
  Alcotest.(check bool) label true (string_contains ~sub text)
;;

let test_read_public_descriptor_schema_is_closed () =
  let descriptor = required_public_descriptor "Read" in
  Alcotest.(check bool)
    "Read schema forbids additional properties"
    true
    (schema_forbids_additional_properties descriptor.input_schema)
;;

let test_read_public_validation_rejects_line_fields () =
  let input =
    `Assoc
      [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
      ; "start_line", `Int 255
      ; "end_line", `Int 280
      ]
  in
  match Resolution.validate_public_input_for_tool_call ~tool_name:"Read" ~input with
  | Some (Error validation_result) ->
    let data = Tool_result.data validation_result |> Yojson.Safe.to_string in
    check_contains
      "Read validation reports unsupported start_line"
      ~sub:"start_line"
      data;
    check_contains
      "Read validation reports unsupported end_line"
      ~sub:"end_line"
      data;
    check_contains
      "Read validation is policy rejection"
      ~sub:"policy_rejection"
      data
  | Some (Ok _) -> Alcotest.fail "Read public validation unexpectedly accepted line fields"
  | None -> Alcotest.fail "Read public descriptor did not resolve"
;;

let test_read_public_validation_translates_supported_fields () =
  let input =
    `Assoc
      [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
      ; "cwd", `String "repos/masc"
      ; "limit", `Int 4096
      ]
  in
  match
    Resolution.validated_descriptor_and_input_for_tool_call
      ~tool_name:"Read"
      ~input
  with
  | Some (Ok (descriptor, `Assoc fields)) ->
    Alcotest.(check string)
      "Read resolves to tool_read_file"
      "tool_read_file"
      descriptor.internal_name;
    Alcotest.(check (option string))
      "file_path translates to path"
      (Some "lib/keeper/keeper_transition_audit.ml")
      (match List.assoc_opt "path" fields with
       | Some (`String path) -> Some path
       | _ -> None);
    Alcotest.(check (option string))
      "cwd passes through"
      (Some "repos/masc")
      (match List.assoc_opt "cwd" fields with
       | Some (`String cwd) -> Some cwd
       | _ -> None);
    Alcotest.(check (option int))
      "limit translates to max_bytes"
      (Some 4096)
      (match List.assoc_opt "max_bytes" fields with
       | Some (`Int max_bytes) -> Some max_bytes
       | _ -> None)
  | Some (Ok (_, other)) ->
    Alcotest.failf "Read translated input is not an object: %s" (Yojson.Safe.to_string other)
  | Some (Error validation_result) ->
    Alcotest.failf
      "Read public validation unexpectedly failed: %s"
      (Tool_result.data validation_result |> Yojson.Safe.to_string)
  | None -> Alcotest.fail "Read public descriptor did not resolve"
;;

let test_read_descriptor_spells_out_path_basis () =
  let descriptor = required_public_descriptor "Read" in
  let file_path_description =
    schema_property_description descriptor.input_schema "file_path"
    |> Option.value ~default:""
  in
  Alcotest.(check bool)
    "Read description says it has no implicit cwd"
    true
    (string_contains ~sub:"no implicit cwd" descriptor.description);
  Alcotest.(check bool)
    "Read file_path schema says it does not inherit Execute cwd"
    true
    (string_contains ~sub:"does not inherit Execute cwd" file_path_description)
;;

let test_execute_descriptor_spells_out_argv_and_filesystem_basis () =
  let descriptor = required_public_descriptor "Execute" in
  let argv_description =
    schema_property_description descriptor.input_schema "argv"
    |> Option.value ~default:""
  in
  check_contains
    "Execute description says filesystem access is policy-scoped"
    ~sub:"sandbox/policy-scoped filesystem access"
    descriptor.description;
  check_contains
    "Execute description says argv follows executable"
    ~sub:"argv arguments after the executable"
    descriptor.description;
  check_contains
    "Execute description forbids duplicate argv0"
    ~sub:"Do not repeat executable as argv[0]"
    descriptor.description;
  check_contains
    "Execute description includes git example"
    ~sub:"executable='git' argv=['status', '--short']"
    descriptor.description;
  check_contains
    "Execute argv schema repeats argv0 warning"
    ~sub:"Do not repeat executable as argv[0]"
    argv_description;
  check_contains
    "Execute argv schema includes grep example"
    ~sub:"executable='grep', argv=['-rn', 'pattern', 'lib']"
    argv_description
;;

let test_grep_descriptor_documents_multiline () =
  (* Keepers passed a literal newline in `pattern` (11 rejects); the runtime
     error referenced a --multiline flag Grep does not expose. Document single-
     line matching and route cross-line matches to the working Execute rg -U. *)
  let descriptor = required_public_descriptor "Grep" in
  check_contains
    "Grep description says patterns match within a single line"
    ~sub:"match within a single line"
    descriptor.description;
  check_contains
    "Grep description routes cross-line matches to rg -U"
    ~sub:"rg -U"
    descriptor.description
;;

let test_edit_descriptor_requires_read_first () =
  (* old_string mismatch (31 rejects): keepers edited without Read or blind-
     retried a non-matching string. Document byte-sensitivity + re-Read. *)
  let descriptor = required_public_descriptor "Edit" in
  check_contains
    "Edit description says the match is byte-sensitive"
    ~sub:"byte-sensitive"
    descriptor.description;
  check_contains
    "Edit description directs re-Read on a missed match"
    ~sub:"re-Read the file"
    descriptor.description
;;

let test_board_descriptors_steer_concise_content () =
  (* board_post/comment content-length rejects (53/day): keepers pasted full
     logs/analyses (up to 8186 chars) past the max_content_length limit. The
     descriptors now steer concise summaries + links. No hardcoded number —
     the limit is env-configurable (Board_types.Limits.max_content_length),
     and the rejection error already reports the actual count. *)
  let post = required_internal_descriptor "keeper_board_post" in
  let comment = required_internal_descriptor "keeper_board_comment" in
  check_contains
    "board_post description names the length limit"
    ~sub:"maximum length"
    post.description;
  check_contains
    "board_post description steers summary + link"
    ~sub:"reference a file path, PR, or issue link"
    post.description;
  check_contains
    "board_comment description names the length limit"
    ~sub:"maximum length"
    comment.description
;;

let test_board_descriptions_disambiguate_post_id_flow () =
  let get_descriptor = required_internal_descriptor "keeper_board_post_get" in
  let get_schema = required_board_schema "keeper_board_post_get" in
  let list_schema = required_board_schema "keeper_board_list" in
  let search_schema = required_board_schema "keeper_board_search" in
  let comment_schema = required_board_schema "keeper_board_comment" in
  let vote_schema = required_board_schema "keeper_board_vote" in
  let get_post_id_description =
    schema_property_description get_schema.input_schema "post_id"
    |> Option.value ~default:""
  in
  check_contains
    "board_post_get descriptor points to list/search first"
    ~sub:"Use keeper_board_list or keeper_board_search first"
    get_descriptor.description;
  check_contains
    "board_post_get schema forbids empty args"
    ~sub:"never call this tool with empty arguments"
    get_schema.description;
  check_contains
    "board_post_get post_id field says exact ID is required"
    ~sub:"Required exact board post ID"
    get_post_id_description;
  check_contains
    "board_list schema says it discovers post_id"
    ~sub:"discover post_id values"
    list_schema.description;
  check_contains
    "board_search schema says it discovers post_id"
    ~sub:"discover post_id values"
    search_schema.description;
  List.iter
    (fun ((label, schema) : string * Masc_domain.tool_schema) ->
       let post_id_description =
         schema_property_description schema.input_schema "post_id"
         |> Option.value ~default:""
       in
       check_contains
         (label ^ " post_id field says exact ID is required")
         ~sub:"Required exact board post ID"
         post_id_description)
    [ "board_comment", comment_schema; "board_vote", vote_schema ];
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       if string_contains ~sub:"BoardList" schema.description
       then
         Alcotest.failf
           "%s description references non-canonical BoardList"
           schema.name)
    Board.board_tools
;;

let test_masc_board_descriptions_disambiguate_post_id_flow () =
  let get_schema = required_masc_board_schema "masc_board_post_get" in
  let list_schema = required_masc_board_schema "masc_board_list" in
  let search_schema = required_masc_board_schema "masc_board_search" in
  let comment_schema = required_masc_board_schema "masc_board_comment" in
  let vote_schema = required_masc_board_schema "masc_board_vote" in
  let get_post_id_description =
    schema_property_description get_schema.input_schema "post_id"
    |> Option.value ~default:""
  in
  let comment_offset_description =
    schema_property_description get_schema.input_schema "comment_offset"
    |> Option.value ~default:""
  in
  let comment_limit_description =
    schema_property_description get_schema.input_schema "comment_limit"
    |> Option.value ~default:""
  in
  check_contains
    "masc_board_post_get schema points to list/search first"
    ~sub:"masc_board_list or masc_board_search first"
    get_schema.description;
  check_contains
    "masc_board_post_get schema advertises pagination"
    ~sub:"Comments are paginated by default"
    get_schema.description;
  check_contains
    "masc_board_post_get schema forbids empty args"
    ~sub:"never call this tool with empty arguments"
    get_schema.description;
  check_contains
    "masc_board_post_get post_id field says exact ID is required"
    ~sub:"Required exact board post ID"
    get_post_id_description;
  check_contains
    "masc_board_post_get offset description mentions default"
    ~sub:"default: 0"
    comment_offset_description;
  check_contains
    "masc_board_post_get limit description mentions bounds"
    ~sub:"default: 50, max: 100"
    comment_limit_description;
  Alcotest.(check (option int))
    "masc_board_post_get offset minimum"
    (Some 0)
    (schema_property_int get_schema.input_schema "comment_offset" "minimum");
  Alcotest.(check (option int))
    "masc_board_post_get limit minimum"
    (Some 1)
    (schema_property_int get_schema.input_schema "comment_limit" "minimum");
  Alcotest.(check (option int))
    "masc_board_post_get limit maximum"
    (Some Board_types.Limits.max_comment_page_limit)
    (schema_property_int get_schema.input_schema "comment_limit" "maximum");
  check_contains
    "masc_board_list schema says it returns post_id"
    ~sub:"return post_id values"
    list_schema.description;
  check_contains
    "masc_board_search schema says it returns post_id"
    ~sub:"return post_id values"
    search_schema.description;
  List.iter
    (fun ((label, schema) : string * Masc_domain.tool_schema) ->
       let post_id_description =
         schema_property_description schema.input_schema "post_id"
         |> Option.value ~default:""
       in
       check_contains
         (label ^ " post_id field says exact ID is required")
         ~sub:"Required exact board post ID"
         post_id_description)
    [ "masc_board_comment", comment_schema; "masc_board_vote", vote_schema ]
;;

let test_masc_board_registry_has_descriptor_projection () =
  let wire_names =
    List.map Tool_name.Board_name.to_string Tool_name.Board_name.all
  in
  Alcotest.(check int)
    "generated Board wire names are unique"
    (List.length wire_names)
    (List.length (List.sort_uniq String.compare wire_names));
  let keeper_model_names =
    Tool_name.Board_name.all
    |> List.filter_map (fun board_name ->
      match Keeper_tool_name.board_projection_of_masc_board_name board_name with
      | Keeper_tool_name.Keeper_wrapper keeper_tool ->
        Some (Keeper_tool_name.to_string keeper_tool)
      | Keeper_tool_name.Direct_masc ->
        Some (Tool_name.Board_name.to_string board_name)
      | Keeper_tool_name.External_only -> None)
  in
  Alcotest.(check int)
    "Board Keeper projections are injective"
    (List.length keeper_model_names)
    (List.length (List.sort_uniq String.compare keeper_model_names));
  List.iter
    (fun board_name ->
       let schema = Board_tool_registry.schema_for_board_name board_name in
       Alcotest.(check string)
         (schema.name ^ " typed registry name")
         (Tool_name.Board_name.to_string board_name)
         schema.name;
       Alcotest.(check bool)
         (schema.name ^ " typed round-trip")
         true
         (Tool_name.Board_name.of_string schema.name = Some board_name);
       (match Keeper_tool_name.board_projection_of_masc_board_name board_name with
        | Keeper_tool_name.Keeper_wrapper keeper_tool ->
          let keeper_name = Keeper_tool_name.to_string keeper_tool in
          Alcotest.(check bool)
            (keeper_name ^ " reverse projection is exact")
            true
            (Keeper_tool_name.masc_board_name_of_keeper_tool keeper_tool
             = Some board_name);
          Alcotest.(check int)
            (keeper_name ^ " has exactly one descriptor")
            1
            (List.length (Descriptor.descriptors_for_internal keeper_name));
          let wrapper_descriptor = required_internal_descriptor keeper_name in
          Alcotest.(check bool)
            (keeper_name ^ " is the model projection")
            true
            (wrapper_descriptor.keeper_model_projection = Descriptor.Internal_name)
        | Keeper_tool_name.Direct_masc | Keeper_tool_name.External_only -> ());
       match Descriptor.descriptors_for_internal schema.name with
       | [ descriptor ] ->
         Alcotest.(check string)
           (schema.name ^ " descriptor id")
           ("masc.board." ^ Tool_name.Board_name.operation_name board_name)
           descriptor.Descriptor.id;
         Alcotest.(check string)
           (schema.name ^ " runtime handler")
           "tool_masc_board_dispatch"
           (Descriptor.runtime_handler_to_string descriptor.runtime_handler);
         let descriptor_properties = schema_property_names descriptor.input_schema in
         Board_tool_registry.identity_fields_for_board_name board_name
         |> List.iter (fun identity_field ->
           Alcotest.(check bool)
             (schema.name ^ " hides runtime-owned " ^ identity_field)
             false
             (List.mem identity_field descriptor_properties));
         let expected_visibility =
           match Keeper_tool_name.board_projection_of_masc_board_name board_name with
           | Keeper_tool_name.Direct_masc -> Tool_catalog.Default
           | Keeper_tool_name.Keeper_wrapper _ | Keeper_tool_name.External_only ->
             Tool_catalog.Hidden
         in
         Alcotest.(check bool)
           (schema.name ^ " descriptor visibility follows typed projection")
           true
           (descriptor.policy.visibility = expected_visibility);
         let expected_readonly =
           not (Tool_name.Board_name.is_resource_write board_name)
         in
         Alcotest.(check (option bool))
           (schema.name ^ " descriptor readonly follows typed resource projection")
           (Some expected_readonly)
           descriptor.policy.readonly_hint;
         let expected_effect_domain =
           if expected_readonly
           then Some Tool_catalog.Read_only
           else Some Tool_catalog.Masc_workspace
         in
         Alcotest.(check bool)
           (schema.name ^ " descriptor effect domain follows typed resource projection")
           true
           (descriptor.policy.effect_domain = expected_effect_domain);
         let expected_model_projection =
           match Keeper_tool_name.board_projection_of_masc_board_name board_name with
           | Keeper_tool_name.Direct_masc -> Descriptor.Internal_name
           | Keeper_tool_name.Keeper_wrapper _ | Keeper_tool_name.External_only ->
             Descriptor.Dispatch_only
         in
         Alcotest.(check bool)
           (schema.name ^ " descriptor model projection follows typed projection")
           true
           (descriptor.keeper_model_projection = expected_model_projection)
       | [] -> Alcotest.failf "missing descriptor for %s" schema.name
       | _ :: _ :: _ -> Alcotest.failf "duplicate descriptor for %s" schema.name)
    Tool_name.Board_name.all

let test_library_search_descriptor_has_recoverable_query_schema () =
  let descriptor = required_internal_descriptor "keeper_library_search" in
  let query_description =
    schema_property_description descriptor.Descriptor.input_schema "query"
    |> Option.value ~default:""
  in
  check_contains
    "keeper_library_search descriptor documents query"
    ~sub:"Search query"
    query_description;
  Alcotest.(check bool)
    "keeper_library_search query is not validation-required"
    false
    (List.mem "query" (schema_required_fields descriptor.input_schema))
;;

let test_readonly_policy_projects_to_registry () =
  let projected = Descriptor.readonly_internal_names () in
  List.iter
    (fun d ->
      match Descriptor.readonly_static_hint d with
      | Some true ->
        Alcotest.(check bool)
          (d.Descriptor.internal_name ^ " is in descriptor readonly projection")
          true
          (List.mem d.Descriptor.internal_name projected);
        Alcotest.(check bool)
          (d.Descriptor.internal_name ^ " is effectively read-only")
          true
          (Registry.is_effectively_read_only_tool d.Descriptor.internal_name)
      | Some false | None -> ())
    (all_descriptors ());
  Alcotest.(check bool)
    "tool_write_file is not descriptor read-only"
    false
    (List.mem "tool_write_file" projected)

let test_readonly_policy_is_descriptor_input_aware () =
  let public_input =
    `Assoc [ "pattern", `String "Keeper_tool_descriptor"; "op", `String "rm" ]
  in
  let internal_input = `Assoc [ "op", `String "rm"; "pattern", `String "x" ] in
  let descriptor =
    match Descriptor.find_public "Grep" with
    | Some descriptor -> descriptor
    | None -> Alcotest.fail "missing Grep descriptor"
  in
  Alcotest.(check (option bool))
    "static readonly hint stays available for schema/evidence"
    (Some true)
    (Descriptor.readonly_static_hint descriptor);
  Alcotest.(check (option bool))
    "raw public-shaped search input remains read-only"
    (Some true)
    (Descriptor.readonly_for_input descriptor ~input:public_input);
  Alcotest.(check (option bool))
    "public input is translated before readonly policy evaluation"
    (Some true)
    (Resolution.readonly_for_tool_call ~tool_name:"Grep" ~input:public_input);
  Alcotest.(check (option bool))
    "secondary Search alias follows the same readonly policy"
    (Some true)
    (Resolution.readonly_for_tool_call ~tool_name:"Search" ~input:public_input);
  Alcotest.(check (option bool))
    "MCP-prefixed public input follows the same descriptor policy"
    (Some true)
    (Resolution.readonly_for_tool_call
       ~tool_name:"mcp__masc__Grep"
       ~input:public_input);
  Alcotest.(check (option bool))
    "unknown internal op falls back to static read-only hint"
    (Some true)
    (Resolution.readonly_for_tool_call
       ~tool_name:"tool_search_files"
       ~input:internal_input)

let test_readonly_policy_projects_to_input_aware_registry () =
  let search_input = `Assoc [ "pattern", `String "Keeper_tool_descriptor" ] in
  Alcotest.(check bool)
    "Grep public alias is input-aware read-only"
    true
    (Registry.is_read_only_with_input ~tool_name:"Grep" ~input:search_input);
  Alcotest.(check bool)
    "Search public alias is input-aware read-only"
    true
    (Registry.is_read_only_with_input ~tool_name:"Search" ~input:search_input);
  Alcotest.(check bool)
    "MCP-prefixed Grep is input-aware read-only"
    true
    (Registry.is_read_only_with_input
       ~tool_name:"mcp__masc__Grep"
       ~input:search_input);
  Alcotest.(check bool)
    "tool_search_files is descriptor read-only without legacy op"
    true
    (Registry.is_read_only_with_input ~tool_name:"tool_search_files" ~input:search_input);
  Alcotest.(check bool)
    "Read public alias is input-aware read-only"
    true
    (Registry.is_read_only_with_input
       ~tool_name:"Read"
       ~input:(`Assoc [ "file_path", `String "lib/keeper/keeper_tool_registry.ml" ]));
  Alcotest.(check bool)
    "Write public alias remains mutating"
    false
    (Registry.is_read_only_with_input
       ~tool_name:"Write"
       ~input:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]));
  Alcotest.(check bool)
    "tool_write_file remains mutating"
    false
    (Registry.is_read_only_with_input
       ~tool_name:"tool_write_file"
       ~input:(`Assoc [ "path", `String "x"; "content", `String "y" ]))

let test_strict_readonly_policy_excludes_workspace_mutations () =
  let search_input = `Assoc [ "pattern", `String "Keeper_tool_descriptor" ] in
  Alcotest.(check bool)
    "Grep public alias is strict read-only"
    true
    (Registry.is_strictly_read_only_with_input ~tool_name:"Grep" ~input:search_input);
  Alcotest.(check bool)
    "Read public alias is strict read-only"
    true
    (Registry.is_strictly_read_only_with_input
       ~tool_name:"Read"
       ~input:(`Assoc [ "file_path", `String "lib/keeper/keeper_tool_registry.ml" ]));
  Alcotest.(check bool)
    "WebFetch public alias is strict read-only"
    true
    (Registry.is_strictly_read_only_with_input
       ~tool_name:"WebFetch"
       ~input:(`Assoc [ "url", `String "https://example.com" ]));
  Alcotest.(check bool)
    "keeper_board_post remains mutating for no-side-effect retry"
    false
    (Registry.is_strictly_read_only_with_input
       ~tool_name:"keeper_board_post"
       ~input:(`Assoc [ "title", `String "t"; "body", `String "b" ]));
  Alcotest.(check bool)
    "keeper_broadcast remains mutating for no-side-effect retry"
    false
    (Registry.is_strictly_read_only_with_input
       ~tool_name:"keeper_broadcast"
       ~input:(`Assoc [ "message", `String "hello" ]));
  Alcotest.(check bool)
    "masc_transition remains mutating for no-side-effect retry"
    false
    (Registry.is_strictly_read_only_with_input
       ~tool_name:"masc_transition"
       ~input:(`Assoc [ "task_id", `String "t1"; "status", `String "done" ]))

let test_mcp_context_policy_uses_descriptor_resolution () =
  Alcotest.(check (list string))
    "safe inline tools project from descriptors"
    []
    (Descriptor.keeper_safe_inline_names ());
  Alcotest.(check (list string))
    "maintenance-only tools project from descriptors"
    [ "masc_heartbeat" ]
    (Descriptor.keeper_maintenance_only_names ());
  ()
;;

let test_public_name_projection_uses_descriptor_resolution () =
  Alcotest.(check (list string))
    "tool_execute public projection"
    [ "Execute" ]
    (Resolution.public_names_for_internal "tool_execute");
  Alcotest.(check (list string))
    "tool_search_files public projections"
    [ "Grep"; "Search"; "search_files" ]
    (Resolution.public_names_for_internal "tool_search_files");
  Alcotest.(check (option string))
    "tool_search_files preferred public projection"
    (Some "Grep")
    (Resolution.public_name_for_internal "tool_search_files");
  Alcotest.(check (option string))
    "tool_write_file preferred public projection"
    (Some "Write")
    (Resolution.public_name_for_internal "tool_write_file");
  Alcotest.(check (list string))
    "allowed internal routes project to public names"
    [ "Execute"; "Grep"; "Search"; "search_files" ]
    (Resolution.public_names_for_allowed_internal_names
       [ "tool_execute"; "tool_search_files" ])
;;

let test_run_tools_setup_has_no_direct_public_mcp_catalog_read () =
  let ic = open_in (source_path "lib/keeper/keeper_run_tools_setup.ml") in
  let source =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  Alcotest.(check bool)
    "keeper_run_tools_setup does not classify with Tool_catalog.is_public_mcp"
    false
    (contains_substring source "Tool_catalog.is_public_mcp")
;;

let test_mutation_boundary_delegates_to_descriptor_policy () =
  let search_input = `Assoc [ "pattern", `String "Keeper_tool_descriptor" ] in
  Alcotest.(check bool)
    "Grep public alias is not mutating"
    false
    (Exec.has_mutating_side_effect_with_input ~tool_name:"Grep" ~input:search_input);
  Alcotest.(check bool)
    "Search public alias is not mutating"
    false
    (Exec.has_mutating_side_effect_with_input ~tool_name:"Search" ~input:search_input);
  Alcotest.(check bool)
    "MCP-prefixed Grep is not mutating"
    false
    (Exec.has_mutating_side_effect_with_input
       ~tool_name:"mcp__masc__Grep"
       ~input:search_input);
  Alcotest.(check bool)
    "tool_search_files without legacy op is not mutating"
    false
    (Exec.has_mutating_side_effect_with_input
       ~tool_name:"tool_search_files"
       ~input:search_input);
  Alcotest.(check bool)
    "Write public alias remains mutating"
    true
    (Exec.has_mutating_side_effect_with_input
       ~tool_name:"Write"
       ~input:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]));
  Alcotest.(check bool)
    "Write public alias follows descriptor checkpoint policy"
    true
    (Registry.is_main_worktree_boundary_exempt_with_input
       ~tool_name:"Write"
       ~input:(`Assoc [ "file_path", `String "x"; "content", `String "y" ]));
  Alcotest.(check bool)
    "Execute public alias follows descriptor checkpoint policy"
    true
    (Registry.is_main_worktree_boundary_exempt_with_input
       ~tool_name:"Execute"
       ~input:(`Assoc [ "executable", `String "git"; "argv", `List [ `String "status" ] ]))

(* RFC-0182 §3.1 — verify keeper / surface_audit descriptors project from name
   → descriptor
   via [descriptors_for_internal] with the expected [runtime_handler].

   This catches future typos in the [~name:"masc_X"] strings (which the
   compiler cannot see) and missing cluster builder calls in
   [internal_descriptors]. *)
let cluster_projection_table =
  [ "masc_keeper_list", "tool_masc_keeper_dispatch"
  ; "masc_keeper_msg_result", "tool_masc_keeper_dispatch"
  ; "masc_keeper_msg_cancel", "tool_masc_keeper_dispatch"
  ; "masc_keeper_msg_queue", "tool_masc_keeper_dispatch"
  ; "masc_keeper_compact", "tool_masc_keeper_dispatch"
  ; "masc_keeper_clear", "tool_masc_keeper_dispatch"
  ; "masc_keeper_sandbox_start", "tool_masc_keeper_dispatch"
  ; "masc_keeper_sandbox_stop", "tool_masc_keeper_dispatch"
  ; "masc_keeper_reset", "tool_masc_keeper_dispatch"
  ; "masc_keeper_persona_audit", "tool_masc_keeper_dispatch"
  ; "masc_keeper_status", "tool_masc_keeper_dispatch"
  ; "masc_keeper_down", "tool_masc_keeper_dispatch"
  ; "masc_keeper_msg", "tool_masc_keeper_dispatch"
  ; "masc_keeper_up", "tool_masc_keeper_dispatch"
  ; "masc_surface_audit", "tool_masc_surface_audit"
  ]
;;

let test_rfc_0182_clusters_have_descriptor_projection () =
  List.iter
    (fun (tool_name, expected_handler) ->
       match Descriptor.descriptors_for_internal tool_name with
       | [ descriptor ] ->
         Alcotest.(check string)
           (tool_name ^ " runtime handler")
           expected_handler
           (Descriptor.runtime_handler_to_string descriptor.runtime_handler)
       | [] -> Alcotest.failf "missing descriptor for %s" tool_name
       | _ :: _ :: _ -> Alcotest.failf "duplicate descriptor for %s" tool_name)
    cluster_projection_table
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path
        then
          if Sys.is_directory path
          then begin
            Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
            Unix.rmdir path
          end else Unix.unlink path
      in
      try rm dir with _ -> ())
    (fun () -> f dir)
;;

(* RFC-0267 Phase 2 — [masc_task_set_goal] must have a descriptor that
   projects from the task schema registry and must actually dispatch
   through [Task.Tool.dispatch]. The descriptor makes the tool visible
   to the keeper surface; the dispatch check proves the runtime handler
   wiring is not stale. *)
let test_masc_task_set_goal_is_described_and_dispatched () =
  let descriptor = required_internal_descriptor "masc_task_set_goal" in
  Alcotest.(check string)
    "masc_task_set_goal descriptor id"
    "masc.task.set_goal"
    descriptor.Descriptor.id;
  Alcotest.(check string)
    "masc_task_set_goal runtime handler"
    "tool_masc_task_dispatch"
    (Descriptor.runtime_handler_to_string descriptor.runtime_handler);
  let expected_schema =
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name "masc_task_set_goal")
        Task.Schemas.schemas
    with
    | Some schema -> schema.input_schema
    | None -> Alcotest.fail "missing Task.Schemas schema for masc_task_set_goal"
  in
  Alcotest.(check bool)
    "masc_task_set_goal schema projected from Task.Schemas"
    true
    (descriptor.Descriptor.input_schema = expected_schema);
  with_temp_dir "masc_task_set_goal_dispatch" (fun dir ->
    let config = Workspace.default_config dir in
    ignore (Workspace.init config ~agent_name:(Some "test-agent"));
    let ctx : Task.Tool.context =
      { config; agent_name = "test-agent"; sw = None }
    in
    let args =
      `Assoc [ "task_id", `String "task-001"; "goal_id", `String "goal-001" ]
    in
    match Task.Tool.dispatch ctx ~name:"masc_task_set_goal" ~args with
    | Some _ -> ()
    | None -> Alcotest.fail "masc_task_set_goal dispatch returned None")
;;

(* Dispatch gap integrity: every descriptor backed by the keeper
   dispatch cluster must be reachable through [Keeper_dispatch_ref.dispatch].
   This catches the common failure mode where a descriptor is added to
   [internal_descriptors] but its ctx-free registration in
   [Keeper_tool_surface] is forgotten. *)
let test_keeper_dispatch_ref_reaches_every_keeper_descriptor () =
  with_temp_dir "keeper_dispatch_gap" (fun dir ->
    let config = Workspace.default_config dir in
    let agent_name = "test-agent" in
    let keeper_descriptors =
      Descriptor.all_descriptors ()
      |> List.filter (fun d ->
        match d.Descriptor.runtime_handler with
        | Descriptor.Tool_masc_keeper_dispatch -> true
        | _ -> false)
    in
    let unreachable =
      List.filter_map
        (fun d ->
           let name = d.Descriptor.internal_name in
           match
             !Keeper_dispatch_ref.dispatch ~config ~agent_name ~name ~args:(`Assoc []) ()
           with
           | Some _ -> None
           | None -> Some name)
        keeper_descriptors
    in
    if unreachable <> []
    then
      Alcotest.failf
        "Keeper_dispatch_ref.dispatch returned None for %d keeper descriptor(s): %s"
        (List.length unreachable)
        (String.concat ", " unreachable))
;;

(* RFC-0190 — every entry of [public_mcp_surface_tools] must either have
   a descriptor or be on the [public_mcp_non_descriptor]
   allowlist. New surface additions without a descriptor are rejected. *)
let test_rfc_0190_surface_covered_by_descriptor_or_allowlist () =
  let descriptor_names = descriptor_internal_name_set () in
  let allowlist =
    let tbl = Hashtbl.create 16 in
    List.iter (fun n -> Hashtbl.replace tbl n ()) public_mcp_non_descriptor;
    tbl
  in
  let surface = Tool_catalog_surfaces.public_mcp_surface_tools in
  let missing =
    List.filter
      (fun name ->
         (not (Hashtbl.mem descriptor_names name))
         && not (Hashtbl.mem allowlist name))
      surface
  in
  if missing <> []
  then
    Alcotest.failf
      "public_mcp_surface_tools has %d entries with no descriptor and no \
       RFC-0190 allowlist slot: %s. Either add a descriptor or extend \
       [public_mcp_non_descriptor] with explicit justification."
      (List.length missing)
      (String.concat ", " missing)
;;

(* RFC-0190 — the allowlist is the *missing* set, not a permanent
   carve-out.  When a descriptor lands for an allowlist entry, the
   allowlist edit must land in the same PR.  This test catches the
   stale-allowlist case. *)
let test_rfc_0190_allowlist_has_no_descriptor () =
  let descriptor_names = descriptor_internal_name_set () in
  let stale =
    List.filter (Hashtbl.mem descriptor_names) public_mcp_non_descriptor
  in
  if stale <> []
  then
    Alcotest.failf
      "public_mcp_non_descriptor lists %d entries that now have \
       descriptors and must be removed from the allowlist: %s"
      (List.length stale)
      (String.concat ", " stale)
;;

(* ── effective_core_tools universe-aware behaviour ─────────────── *)

let with_masc_schemas schemas f =
  let prior = Registry.masc_schemas_snapshot () in
  Fun.protect
    ~finally:(fun () -> Registry.set_masc_schemas prior)
    (fun () ->
       Registry.set_masc_schemas schemas;
       f ())
;;

let test_effective_core_tools_is_subset_of_discovery () =
  let effective = Registry.effective_core_tools () in
  let discovery = Registry.core_discovery_tools in
  List.iter
    (fun name ->
       if not (List.mem name discovery)
       then
         Alcotest.failf
           "effective_core_tools contains %S not in core_discovery_tools"
           name)
    effective
;;

let test_effective_core_tools_without_universe_keeps_only_native_executor_publics () =
  (* With an empty masc universe, effective_core_tools must still expose the
     native-executor code tools (Execute/Grep/Read/Edit/Write): they run through
     the in-process execution gates and do not depend on masc schema injection.
     Regression guard for #23440 (the shadowed universe-only definition
     structurally excluded them from the per-turn core surface). In_process
     descriptors (WebSearch/WebFetch) are masc-backed and must be pruned when
     their backend schema is not injected, preserving #20455 universe-awareness.

     Partition by the typed [executor] variant so the assertion mirrors the
     production discriminator rather than a hardcoded name list.

     Mcp_server_eio's module-load bootstrap can inject the full schema universe
     when linked into this executable, and earlier tests may mutate it, so
     bracket the assertion with a save/reset to keep following tests isolated. *)
  with_masc_schemas [] (fun () ->
    let effective = Registry.effective_core_tools () in
    List.iter
      (fun (d : Descriptor.t) ->
         let model_names = Descriptor.keeper_model_names d in
         match d.Descriptor.executor with
         | Descriptor.Shell_ir | Descriptor.Filesystem ->
           List.iter
             (fun name ->
                if not (List.mem name effective)
                then
                  Alcotest.failf
                    "native-executor public %S missing from effective_core_tools \
                     with empty universe"
                    name)
             model_names
         | Descriptor.In_process ->
           List.iter
             (fun name ->
                if List.mem name effective
                then
                  Alcotest.failf
                    "in-process (masc-backed) public %S present in \
                     effective_core_tools when universe is empty"
                    name)
             model_names)
      Descriptor.public_descriptors)
;;

let test_effective_core_tools_with_full_universe_matches_discovery () =
  let all_schemas =
    List.map
      (fun d ->
         { Masc_domain.name = d.Descriptor.internal_name
         ; description = d.Descriptor.description
         ; input_schema = d.Descriptor.input_schema
         })
      (all_descriptors ())
  in
  with_masc_schemas all_schemas (fun () ->
    let effective = Registry.effective_core_tools () in
    let discovery = Registry.core_discovery_tools in
    Alcotest.(check (list string))
      "effective_core_tools with full universe matches core_discovery_tools"
      (List.sort String.compare discovery)
      (List.sort String.compare effective))
;;

let () =
  Alcotest.run
    "keeper_tool_descriptor_registry_integrity"
    [ ( "uniqueness"
      , [ test_case "registry not empty" `Quick test_registry_not_empty
        ; test_case "public_name is unique" `Quick test_public_name_uniqueness
        ; test_case "internal_name is unique" `Quick test_internal_name_uniqueness
        ; test_case
            "Keeper model projection is single and unique"
            `Quick
            test_keeper_model_projection_is_single_and_unique
        ; test_case
            "semantic capability has at most one Keeper model projection"
            `Quick
            test_semantic_capability_has_at_most_one_keeper_model_projection
        ; test_case
            "model-visible descriptors have canonical input schemas"
            `Quick
            test_model_visible_descriptors_have_canonical_input_schemas
        ; test_case
            "cluster descriptors have no missing canonical schemas"
            `Quick
            test_cluster_descriptors_have_no_missing_canonical_schemas
        ; test_case
            "missing canonical schema is fail-closed"
            `Quick
            test_missing_canonical_schema_is_fail_closed
        ; test_case
            "registered cluster model projections are explicit"
            `Quick
            test_registered_cluster_model_projections_are_explicit
        ; test_case
            "dynamic model description projection is explicit"
            `Quick
            test_dynamic_model_description_projection_is_explicit
        ; test_case
            "all Keeper shard schemas are descriptor-backed"
            `Quick
            test_all_keeper_shard_schemas_are_descriptor_backed
        ; test_case
            "supported MASC schemas are descriptor-backed"
            `Quick
            test_supported_masc_schemas_are_descriptor_backed
        ; test_case
            "maintenance descriptors are dispatch-only"
            `Quick
            test_maintenance_descriptors_are_dispatch_only
        ] )
    ; ( "format"
      , [ test_case "no blank name fields" `Quick test_no_blank_names
        ; test_case "internal_name is snake_case" `Quick test_internal_name_snake_case
        ; test_case "eval_tags are normalized" `Quick test_eval_tags_are_normalized
        ; test_case
            "seed eval_tags are registered"
            `Quick
            test_seed_eval_tags_are_registered
        ] )
    ; ( "agent-contract"
      , [ test_case
            "Read public descriptor schema is closed"
            `Quick
            test_read_public_descriptor_schema_is_closed
        ; test_case
            "Read rejects unsupported line fields before translation"
            `Quick
            test_read_public_validation_rejects_line_fields
        ; test_case
            "Read validates then translates supported public fields"
            `Quick
            test_read_public_validation_translates_supported_fields
        ; test_case
            "Read path basis is explicit"
            `Quick
            test_read_descriptor_spells_out_path_basis
        ; test_case
            "Execute argv/filesystem basis is explicit"
            `Quick
            test_execute_descriptor_spells_out_argv_and_filesystem_basis
        ; test_case
            "Grep documents single-line match and rg -U"
            `Quick
            test_grep_descriptor_documents_multiline
        ; test_case
            "Edit requires Read-first and byte-exact old_string"
            `Quick
            test_edit_descriptor_requires_read_first
        ; test_case
            "Board post/comment steer concise content"
            `Quick
            test_board_descriptors_steer_concise_content
        ; test_case
            "Board get/list descriptions disambiguate post_id flow"
            `Quick
            test_board_descriptions_disambiguate_post_id_flow
        ; test_case
            "MASC board descriptions disambiguate post_id flow"
            `Quick
            test_masc_board_descriptions_disambiguate_post_id_flow
        ; test_case
            "Library search query is runtime-recoverable"
            `Quick
            test_library_search_descriptor_has_recoverable_query_schema
        ] )
    ; ( "masc-board"
      , [ test_case
            "Board_tool_registry has descriptor projection"
            `Quick
            test_masc_board_registry_has_descriptor_projection
        ] )
    ; ( "rfc-0182-clusters"
      , [ test_case
            "keeper/surface_audit project to descriptors"
            `Quick
            test_rfc_0182_clusters_have_descriptor_projection
        ] )
    ; ( "dispatch-gap"
      , [ test_case
            "masc_task_set_goal is described and dispatched"
            `Quick
            test_masc_task_set_goal_is_described_and_dispatched
        ; test_case
            "every keeper descriptor is reachable via Keeper_dispatch_ref.dispatch"
            `Quick
            test_keeper_dispatch_ref_reaches_every_keeper_descriptor
        ] )
    ; ( "rfc-0190-surface-projection"
      , [ test_case
            "public_mcp_surface_tools is descriptor-backed or allowlisted"
            `Quick
            test_rfc_0190_surface_covered_by_descriptor_or_allowlist
        ; test_case
            "public_mcp_non_descriptor shrinks when a descriptor lands"
            `Quick
            test_rfc_0190_allowlist_has_no_descriptor
        ] )
    ; ( "policy-projection"
      , [ test_case
            "descriptor read-only policy projects to registry"
            `Quick
            test_readonly_policy_projects_to_registry
        ; test_case
            "descriptor read-only policy evaluates tool input"
            `Quick
            test_readonly_policy_is_descriptor_input_aware
        ; test_case
            "descriptor read-only policy projects to input-aware registry"
            `Quick
            test_readonly_policy_projects_to_input_aware_registry
        ; test_case
            "strict read-only policy excludes workspace mutations"
            `Quick
            test_strict_readonly_policy_excludes_workspace_mutations
        ; test_case
            "MCP context policy uses descriptor resolution"
            `Quick
            test_mcp_context_policy_uses_descriptor_resolution
        ; test_case
            "public names project through descriptor resolution"
            `Quick
            test_public_name_projection_uses_descriptor_resolution
        ; test_case
            "keeper_run_tools_setup avoids public MCP catalog classifier"
            `Quick
            test_run_tools_setup_has_no_direct_public_mcp_catalog_read
        ; test_case
            "mutation boundary delegates to descriptor policy"
            `Quick
            test_mutation_boundary_delegates_to_descriptor_policy
        ] )
    ; ( "universe-aware-effective-core"
      , [ test_case
            "effective_core_tools is subset of core_discovery_tools"
            `Quick
            test_effective_core_tools_is_subset_of_discovery
        ; test_case
            "effective_core_tools without universe keeps only native-executor publics"
            `Quick
            test_effective_core_tools_without_universe_keeps_only_native_executor_publics
        ; test_case
            "effective_core_tools with full universe matches discovery"
            `Quick
            test_effective_core_tools_with_full_universe_matches_discovery
        ] )
    ]
