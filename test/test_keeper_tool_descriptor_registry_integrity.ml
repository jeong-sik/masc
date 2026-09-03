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
module Resolution = Masc.Keeper_tool_descriptor_resolution
module Surface = Masc.Keeper_agent_tool_surface
module Board_tool_registry = Board_tool_registry
module Keeper_dispatch_ref = Masc.Keeper_dispatch_ref
module Workspace = Masc.Workspace
module Task = Masc.Task
module Keeper_tool_surface = Masc.Keeper_tool_surface
module Keeper_schema = Masc.Keeper_schema
module Capability_registry = Masc.Capability_registry
module Tool_shard = Masc.Tool_shard

(* Force-link [Keeper_tool_surface] so its module-load registration of
   keeper tools into [Keeper_dispatch_ref.dispatch] runs before the
   dispatch gap test. *)
let () = ignore Masc.Keeper_tool_surface.schemas

let all_descriptors () : Descriptor.t list = Descriptor.all_descriptors ()

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

let descriptor_internal_name_set () =
  let tbl = Hashtbl.create 256 in
  List.iter
    (fun d -> Hashtbl.replace tbl d.Descriptor.internal_name ())
    (all_descriptors ());
  tbl
;;

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
       match descriptor.keeper_model_projection with
       | Descriptor.Preferred_public_name ->
         Alcotest.(check (list string))
           (descriptor.id ^ " preferred model projection")
           [ descriptor.public_name ]
           projected;
         (* The internal name stays owned by this descriptor even though the
            model is never shown it. [registered_names] is the name-integrity
            axis; [keeper_model_names] is the admission axis. Keeping both here
            is what stops a rename from freeing the internal name for another
            descriptor to claim. *)
         Alcotest.(check bool)
           (descriptor.id ^ " still owns its internal handler route")
           true
           (List.mem descriptor.internal_name (Descriptor.registered_names descriptor))
       | Descriptor.Internal_name ->
         Alcotest.(check (list string))
           (descriptor.id ^ " internal model projection")
           [ descriptor.internal_name ]
           projected
       | Descriptor.Operator_only ->
         Alcotest.(check (list string))
           (descriptor.id ^ " operator-only control has no model projection")
           []
           projected
       | Descriptor.Transport_alias _ ->
         Alcotest.(check (list string))
           (descriptor.id ^ " transport alias has no duplicate model projection")
           []
           projected)
    (all_descriptors ())
;;

let test_transport_aliases_name_exact_visible_projection () =
  all_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    match descriptor.keeper_model_projection with
    | Descriptor.Preferred_public_name
    | Descriptor.Internal_name
    | Descriptor.Operator_only -> ()
    | Descriptor.Transport_alias { projected_by } ->
      let owners =
        all_descriptors ()
        |> List.filter (fun candidate ->
          List.mem projected_by (Descriptor.keeper_model_names candidate))
      in
      Alcotest.(check int)
        (descriptor.id ^ " transport alias has one visible projection owner")
        1
        (List.length owners))
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

let test_model_visible_descriptors_own_capability_identity () =
  Descriptor.model_visible_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    if String.equal (String.trim descriptor.capability_id) ""
    then
      Alcotest.failf
        "model-visible descriptor %S has a blank capability_id"
        descriptor.id)
;;

(* [Keeper_schema_toml] decodes each file in a module-level [let] and fails
   the boot on a bad one, which is the contract its .mli states. That makes
   the loop below unreachable: a schema that would fail it kills the process
   before any test function starts, so it can only ever run against schemas
   that already pass (#29354).

   Keeping the loop and adding a case that drives the same parser the loader
   uses. [Tool_definition_toml.load] is what [schema_of_name] calls, and it
   returns a result, so the rejection is observable here rather than only as
   a boot trace. *)
let test_model_visible_descriptors_have_canonical_input_schemas () =
  Descriptor.model_visible_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    (match Descriptor.model_schema_errors descriptor with
     | [] -> ()
     | errors ->
       Alcotest.failf
         "model-visible descriptor %S has invalid schema: %s"
         descriptor.id
         (String.concat "; " errors));
    ignore descriptor.input_schema_source)
;;

let test_the_loader_refuses_a_malformed_declaration () =
  let malformed =
    {|name = "masc_keeper_up"
description = "probe"

[[params]]
name = "keeper_name"
type = "nonsense"
|}
  in
  match
    Tool_definition_toml.load ~name:"masc_keeper_up" ~contents:malformed
  with
  | Ok _ ->
    Alcotest.fail
      "a param type outside the schema vocabulary must not load; the boot \
       depends on this refusal"
  | Error _ -> ()
;;

(* The other half: the refusal has to be about the malformed part, not about
   the loader rejecting everything. *)
let test_the_loader_accepts_the_same_declaration_repaired () =
  let repaired =
    {|name = "masc_keeper_up"
description = "probe"

[[params]]
name = "keeper_name"
type = "string"
|}
  in
  match
    Tool_definition_toml.load ~name:"masc_keeper_up" ~contents:repaired
  with
  | Ok _ -> ()
  | Error detail ->
    Alcotest.failf "the repaired declaration must load: %s" detail
;;

let test_all_resolved_descriptor_schemas_are_structurally_valid () =
  all_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    match Descriptor.model_schema_errors descriptor with
    | [] -> ()
    | errors ->
      Alcotest.failf
        "descriptor %S (%s) has invalid model schema: %s"
        descriptor.id
        descriptor.internal_name
        (String.concat "; " errors))
;;

let test_structurally_invalid_schema_is_excluded () =
  let base = required_internal_descriptor "masc_transition" in
  let malformed =
    { base with input_schema = `Assoc [ "properties", `List [] ] }
  in
  Alcotest.(check bool)
    "malformed schema reports objective errors"
    true
    (Descriptor.model_schema_errors malformed <> []);
  Alcotest.(check (list string))
    "malformed schema has no model names"
    []
    (Descriptor.keeper_model_names malformed)
;;

(* The description a Keeper reads and the description in the canonical registry
   used to be two strings. [cluster_descriptor] looked the tool up for its
   input_schema and then took a second description from an inline argument, and
   nothing compared them: 66 of 98 model-visible descriptors disagreed, and in
   57 the model saw the shorter one — including every Goal tool and
   [masc_transition], whose canonical text is the only place [release] is
   named.

   That seam is closed: [cluster_descriptor] takes both fields from the one
   lookup. This pins it. The exceptions below reach the model through other
   constructors and keep their own text on purpose — the Board projection
   narrows the canonical schema for the Keeper surface (its description is
   usually the longer, more specific one), [masc_library_list] reads its
   file's [keeper_projection] the same way (#32561), and the shard and
   individually-declared keeper tools are declared with
   [in_process_descriptor] rather than the cluster path. Adding an inline
   description back onto a cluster tool fails here. *)
let descriptions_owned_elsewhere =
  [ (* Board: [masc_board_descriptor] carries the Keeper projection's own text *)
    "masc_board_comment"
  ; "masc_board_curation_read"
  ; "masc_board_curation_submit"
  ; "masc_board_list"
  ; "masc_board_post"
  ; "masc_board_search"
  ; "masc_board_vote"
    (* Shard runtime tools: declared directly, not through the cluster path *)
  ; "tool_edit_file"
  ; "tool_execute"
  ; "tool_read_file"
  ; "tool_search_files"
  ; "tool_write_file"
    (* Library and individually-declared keeper tools *)
  ; "keeper_library_read"
  ; "keeper_library_search"
  ; "masc_library_list"
  ; "keeper_context_status"
  ; "keeper_ide_annotate"
  ; "keeper_memory_search"
  ; "keeper_memory_write"
  ; "keeper_person_note_set"
  ; "keeper_time_now"
  ; "keeper_tools_list"
  ; "keeper_capability_search"
  ]
;;

let test_cluster_descriptions_come_from_the_registry () =
  let canonical = Hashtbl.create 512 in
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       if not (Hashtbl.mem canonical schema.name)
       then Hashtbl.add canonical schema.name schema.description)
    Masc.Config.raw_all_tool_schemas;
  let drifted =
    Descriptor.model_visible_descriptors ()
    |> List.filter_map (fun (d : Descriptor.t) ->
         if List.mem d.internal_name descriptions_owned_elsewhere
         then None
         else
           match Hashtbl.find_opt canonical d.internal_name with
           | None -> None
           | Some canon ->
             if String.equal canon d.description then None else Some d.internal_name)
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "every cluster tool's description is the registry's"
    []
    drifted
;;

let test_registered_cluster_model_projections_are_explicit () =
  let check_projection internal_name expected =
    let descriptor = required_internal_descriptor internal_name in
    Alcotest.(check bool)
      (internal_name ^ " model projection")
      true
      (descriptor.keeper_model_projection = expected)
  in
  let keeper_model_names = Policy.keeper_model_tool_names () in
  List.iter
    (fun name -> check_projection name Descriptor.Internal_name)
    [ "keeper_library_read"
    ; "keeper_library_search"
    ; "masc_library_add"
    ; "masc_library_list"
    ; "masc_gc"
    ; "masc_get_metrics"
    ];
  List.iter
    (fun name ->
       check_projection name Descriptor.Operator_only;
       Alcotest.(check bool)
         (name ^ " is absent from the autonomous Keeper model bundle")
         false
         (List.mem name keeper_model_names))
    [ (* Operator status screen, not a Keeper observation: the world-state frame
         already carries the backlog counts and fiber count as typed context,
         and the screen's only Keeper-specific line is a false "session is not
         bound" warning. The tool stays registered for MCP/HTTP consumers. *)
      "masc_status"
    ; "masc_pause"
    ; "masc_resume"
      (* Completion-backed runtime verification and the native Ollama timing
         probe are explicit Admin diagnostics, distinct from
         [/api/v1/dashboard/runtime-probe], which reads metadata only. Both can
         load a model or change warm/cache state. Registration is unchanged;
         the metadata-only dashboard route owns separate [CanReadState]
         authority. *)
    ; "masc_runtime_verify"
    ; "masc_runtime_ollama_probe"
      (* #29681 took these off the model surface after two months of zero
         Keeper calls. Pinned here so the surface cannot quietly regrow: the
         plan tools are an operator's editing surface, and heartbeat, check,
         tool_help, and the agent screens answer questions the world-state
         frame already carries. All stay registered for MCP/HTTP. *)
    ; "masc_heartbeat"
    ; "masc_check"
    ; "masc_tool_help"
    ; "masc_agent_card"
    ; "masc_agent_timeline"
    ; "masc_plan_set_task"
    ];
  List.iter
    (fun (name, projected_by) ->
       check_projection name (Descriptor.Transport_alias { projected_by }))
    [ "masc_library_read", "keeper_library_read"
    ; "masc_library_search", "keeper_library_search"
    ; "masc_tasks", "keeper_tasks_list"
      (* #29681: the keeper_* twin is what the model sees. *)
    ; "masc_add_task", "keeper_task_create"
    ; "masc_batch_add_tasks", "keeper_task_create"
    ; "masc_transition", "keeper_task_claim"
    ; "masc_update_priority", "keeper_task_claim"
    ]
;;

let test_local_runtime_effect_metadata_is_explicit () =
  let verify = required_internal_descriptor "masc_runtime_verify" in
  Alcotest.(check (option bool))
    "verify is not read-only"
    (Some false)
    verify.policy.readonly_hint;
  let probe = required_internal_descriptor "masc_runtime_ollama_probe" in
  Alcotest.(check (option bool))
    "native probe is not read-only"
    (Some false)
    probe.policy.readonly_hint
;;

let test_keeper_management_projection_is_explicit () =
  let check_projection internal_name expected =
    let descriptor = required_internal_descriptor internal_name in
    Alcotest.(check bool)
      (internal_name ^ " model projection")
      true
      (descriptor.keeper_model_projection = expected)
  in
  List.iter
    (fun name -> check_projection name Descriptor.Internal_name)
    [ "masc_keeper_delegate"
    ; "masc_keeper_delegate_status"
    ; "masc_keeper_delegate_cancel"
    ];
  List.iter
    (fun name -> check_projection name Descriptor.Operator_only)
    [ "masc_keeper_waiting_inventory"
    ; "masc_keeper_list"
    ; "masc_keeper_delegate_list"
    ; "masc_keeper_clear"
    ; "masc_keeper_sandbox_start"
    ; "masc_keeper_sandbox_stop"
    ; "masc_keeper_reset"
    ; "masc_keeper_audit"
    ; "masc_keeper_status"
    ; "masc_keeper_down"
    ; "masc_keeper_up"
    ]
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

let test_keeper_surface_schemas_are_descriptor_backed () =
  Keeper_schema.schemas
  |> List.iter (fun (schema : Masc_domain.tool_schema) ->
    match Descriptor.descriptors_for_internal schema.name with
    | [ _ ] -> ()
    | [] -> Alcotest.failf "Keeper surface schema %S has no descriptor" schema.name
    | descriptors ->
      Alcotest.failf
        "Keeper surface schema %S has %d descriptors"
        schema.name
        (List.length descriptors))
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
  check "keeper_capability_search" [ "capability_introspection" ];
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

let object_schema = `Assoc [ "type", `String "object" ]

let schema_named name : Masc_domain.tool_schema =
  { name; description = "one line"; input_schema = object_schema }
;;

let rejects_with what schemas =
  match Masc.Config.validate_schemas schemas with
  | () -> Alcotest.failf "validate_schemas accepted %s" what
  | exception Invalid_argument _ -> ()
;;

(* The disjointness that [Keeper_tool_descriptor.find_cluster_schema_opt] relies
   on is enforced here and nowhere else: the six registries it falls through are
   all concatenated into [Config.raw_all_tool_schemas]. *)
let test_duplicate_schema_name_is_rejected () =
  rejects_with
    "a repeated tool name"
    [ schema_named "masc_status"; schema_named "masc_status" ]
;;

let test_distinct_schema_names_are_accepted () =
  Masc.Config.validate_schemas
    [ schema_named "masc_status"; schema_named "masc_tasks" ]
;;

let test_blank_schema_description_is_rejected () =
  rejects_with
    "a blank description"
    [ { name = "masc_status"; description = ""; input_schema = object_schema } ]
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

let schema_property_field schema property field =
  let open Yojson.Safe.Util in
  schema |> member "properties" |> member property |> member field
;;

let schema_property_enum_strings schema property =
  let open Yojson.Safe.Util in
  schema |> member "properties" |> member property |> member "enum" |> to_list
  |> List.map to_string
;;

let schema_forbids_additional_properties schema =
  match schema with
  | `Assoc fields ->
    (match List.assoc_opt "additionalProperties" fields with
     | Some (`Bool false) -> true
     | _ -> false)
  | other -> Alcotest.failf "input_schema is not an object: %s" (Yojson.Safe.to_string other)
;;

let required_keeper_schema name =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      Masc.Keeper_schema.schemas
  with
  | Some schema -> schema
  | None -> Alcotest.failf "missing keeper schema: %s" name
;;

let test_sandbox_control_descriptors_use_exact_canonical_schemas () =
  let check_json label expected actual =
    Alcotest.(check bool) label true (Yojson.Safe.equal expected actual)
  in
  let check_descriptor name expected_properties expected_required =
    let descriptor = required_internal_descriptor name in
    let canonical = required_keeper_schema name in
    Alcotest.(check bool)
      (name ^ " uses the canonical registry")
      true
      (descriptor.input_schema_source = Descriptor.Canonical_registry);
    check_json
      (name ^ " descriptor preserves the owning schema")
      canonical.input_schema
      descriptor.input_schema;
    Alcotest.(check (list string))
      (name ^ " exposes exactly the handler arguments")
      (List.sort String.compare expected_properties)
      (List.sort String.compare (schema_property_names descriptor.input_schema));
    Alcotest.(check (list string))
      (name ^ " required arguments match the handler")
      expected_required
      (schema_required_fields descriptor.input_schema);
    Alcotest.(check bool)
      (name ^ " rejects unknown arguments")
      true
      (schema_forbids_additional_properties descriptor.input_schema);
    descriptor.input_schema
  in
  let start_schema =
    check_descriptor
      "masc_keeper_sandbox_start"
      [ "name"; "network_mode"; "ttl_sec"; "timeout_sec" ]
      [ "name"; "timeout_sec" ]
  in
  Alcotest.(check (list string))
    "sandbox start network modes match the owning keeper contract"
    Masc.Keeper_schema.network_mode_enum_strings
    (schema_property_enum_strings start_schema "network_mode");
  check_json
    "sandbox start ttl has no default"
    `Null
    (schema_property_field start_schema "ttl_sec" "default");
  check_json
    "sandbox start ttl minimum"
    (`Float 0.0)
    (schema_property_field start_schema "ttl_sec" "minimum");
  check_json
    "sandbox start ttl has no maximum"
    `Null
    (schema_property_field start_schema "ttl_sec" "maximum");
  check_json
    "sandbox start timeout is positive"
    (`Float 0.0)
    (schema_property_field start_schema "timeout_sec" "exclusiveMinimum");
  let stop_schema =
    check_descriptor
      "masc_keeper_sandbox_stop"
      [ "container_kind"; "name"; "prune_stale"; "timeout_sec" ]
      [ "timeout_sec" ]
  in
  let runtime_stop_scopes =
    Masc.Keeper_sandbox_control_contract.stop_scope_strings
  in
  Alcotest.(check (list string))
    "sandbox stop enum matches the runtime parser"
    runtime_stop_scopes
    (schema_property_enum_strings stop_schema "container_kind");
  check_json
    "sandbox stop scope default"
    (`String
      (Masc.Keeper_sandbox_control_contract.stop_scope_to_string
         Masc.Keeper_sandbox_control_contract.default_stop_scope))
    (schema_property_field stop_schema "container_kind" "default");
  check_json
    "sandbox stop prune default"
    (`Bool false)
    (schema_property_field stop_schema "prune_stale" "default");
  check_json
    "sandbox stop timeout is positive"
    (`Float 0.0)
    (schema_property_field stop_schema "timeout_sec" "exclusiveMinimum")
;;

let required_board_schema name =
  let descriptor = required_internal_descriptor name in
  { Masc_domain.name = name
  ; description = descriptor.description
  ; input_schema = descriptor.input_schema
  }
;;

let keeper_board_schemas =
  List.map
    (fun board_name ->
       required_board_schema (Tool_name.Board_name.to_string board_name))
    Tool_name.Board_name.all
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

let test_translation_validation_policy_is_typed_for_all_descriptors () =
  let probe = `Assoc [ "probe", `String "byte-identical" ] in
  List.iter
    (fun (descriptor : Descriptor.t) ->
       match descriptor.input_translation with
       | Descriptor.Identity _ ->
         Alcotest.(check bool)
           (descriptor.id ^ " identity translation is byte-identical")
           true
           (Yojson.Safe.equal
              probe
              (Descriptor.translate_input_for_descriptor descriptor probe))
       | Descriptor.Shape_changing _ ->
         ignore (Descriptor.translate_input_for_descriptor descriptor probe))
    (Descriptor.all_descriptors ())
;;

let test_shape_changing_post_validation_is_executed () =
  let descriptor = required_public_descriptor "Grep" in
  let descriptor =
    { descriptor with
      input_translation =
        Descriptor.Shape_changing
          { translate = (fun _ -> `Assoc [])
          ; validation = Descriptor.Validate_before_and_after_translation
          }
    }
  in
  match
    Resolution.prepare_model_input_for_descriptor
      ~tool_name:"Grep"
      descriptor
      ~input:(`Assoc [ "pattern", `String "needle" ])
  with
  | Error validation_result ->
    check_contains
      "translated payload is validated"
      ~sub:"pattern"
      (Tool_result.data validation_result |> Yojson.Safe.to_string)
  | Ok _ -> Alcotest.fail "translated payload skipped descriptor validation"
;;

let test_memory_write_descriptor_schema_is_closed () =
  let descriptor = required_internal_descriptor "keeper_memory_write" in
  Alcotest.(check bool)
    "keeper_memory_write schema forbids additional properties"
    true
    (schema_forbids_additional_properties descriptor.input_schema)
;;

let test_memory_retract_descriptor_schema_is_closed () =
  let descriptor = required_internal_descriptor "keeper_memory_retract" in
  Alcotest.(check bool)
    "keeper_memory_retract schema forbids additional properties"
    true
    (schema_forbids_additional_properties descriptor.input_schema)
;;

let test_memory_write_descriptor_is_terminal () =
  let descriptor = required_internal_descriptor "keeper_memory_write" in
  match descriptor.execution with
  | Descriptor.Direct_terminal -> ()
  | Descriptor.Ordinary _ | Descriptor.Terminal ->
    Alcotest.fail "keeper_memory_write lost its direct-only terminal boundary"
;;

let test_memory_retract_descriptor_is_terminal () =
  let descriptor = required_internal_descriptor "keeper_memory_retract" in
  match descriptor.execution with
  | Descriptor.Direct_terminal -> ()
  | Descriptor.Ordinary _ | Descriptor.Terminal ->
    Alcotest.fail "keeper_memory_retract lost its direct-only terminal boundary"
;;

let test_memory_write_rejects_retired_lifetime_argument () =
  let descriptor = required_internal_descriptor "keeper_memory_write" in
  match
    Resolution.prepare_model_input_for_descriptor
      ~tool_name:"keeper_memory_write"
      descriptor
      ~input:
        (`Assoc
            [ "content", `String "durable conclusion"
            ; "valid_for_days", `Int 2
            ])
  with
  | Error validation_result ->
    check_contains
      "retired lifetime argument is rejected at descriptor admission"
      ~sub:"valid_for_days"
      (Tool_result.data validation_result |> Yojson.Safe.to_string)
  | Ok _ -> Alcotest.fail "retired lifetime argument bypassed descriptor admission"
;;

let test_read_public_validation_rejects_line_fields () =
  let input =
    `Assoc
      [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
      ; "start_line", `Int 255
      ; "end_line", `Int 280
      ]
  in
  match
    Resolution.validated_descriptor_and_input_for_tool_call
      ~tool_name:"Read"
      ~input
  with
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

(* masc#31573: the production resolution order (validate, then translate)
   is what stops an undeclared 'content' key before any effect. The
   validator unit test and the runtime test each cover their own layer;
   this one walks the wiring itself. *)
let test_edit_public_validation_rejects_content () =
  let input =
    `Assoc
      [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
      ; "old_string", `String "let x = 1"
      ; "new_string", `String "let x = 2"
      ; "content", `String "let clobbered = true"
      ]
  in
  match
    Resolution.validated_descriptor_and_input_for_tool_call
      ~tool_name:"Edit"
      ~input
  with
  | Some (Error validation_result) ->
    let data = Tool_result.data validation_result |> Yojson.Safe.to_string in
    check_contains
      "Edit validation reports unsupported content"
      ~sub:"content"
      data;
    check_contains
      "Edit validation is policy rejection"
      ~sub:"policy_rejection"
      data
  | Some (Ok _) ->
    Alcotest.fail "Edit public validation unexpectedly accepted a content key"
  | None -> Alcotest.fail "Edit public descriptor did not resolve"
;;

let test_read_public_validation_translates_supported_fields () =
  let input =
    `Assoc
      [ "file_path", `String "lib/keeper/keeper_transition_audit.ml"
      ; "cwd", `String "repos/masc"
      ; "offset", `Int 100
      ; "limit", `Int 200
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
    (* The line window passes through untouched: the runtime owns line
       semantics. Renaming limit to max_bytes here is what turned "200
       lines" into "512 bytes" and starved every code read (2026-07-21
       executor loop). *)
    Alcotest.(check (option int))
      "limit passes through as a line cap"
      (Some 200)
      (match List.assoc_opt "limit" fields with
       | Some (`Int limit) -> Some limit
       | _ -> None);
    Alcotest.(check (option int))
      "offset passes through as a line offset"
      (Some 100)
      (match List.assoc_opt "offset" fields with
       | Some (`Int offset) -> Some offset
       | _ -> None);
    Alcotest.(check bool)
      "no max_bytes is synthesized from limit"
      true
      (List.assoc_opt "max_bytes" fields = None)
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
    "Execute description states argv is the sole process vector"
    ~sub:"one non-empty argv process vector"
    descriptor.description;
  check_contains
    "Execute description treats invocation as opaque"
    ~sub:"never interprets program or subcommand meaning"
    descriptor.description;
  check_contains
    "Execute description says a call has no background lifecycle"
    ~sub:"there is no background task lifecycle"
    descriptor.description;
  Alcotest.(check bool)
    "Execute description has no forge-specific product knowledge"
    false
    (string_contains ~sub:"git" (String.lowercase_ascii descriptor.description));
  check_contains
    "Execute argv schema defines argv[0] as the executable"
    ~sub:"argv[0] is the executable"
    argv_description;
  check_contains
    "Execute argv schema preserves opaque arguments"
    ~sub:"passed verbatim"
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

let test_board_descriptions_disambiguate_post_id_flow () =
  let get_descriptor = required_internal_descriptor "masc_board_post_get" in
  let get_schema = required_board_schema "masc_board_post_get" in
  let list_schema = required_board_schema "masc_board_list" in
  let search_schema = required_board_schema "masc_board_search" in
  let comment_schema = required_board_schema "masc_board_comment" in
  let vote_schema = required_board_schema "masc_board_vote" in
  let get_post_id_description =
    schema_property_description get_schema.input_schema "post_id"
    |> Option.value ~default:""
  in
  check_contains
    "board_post_get descriptor points to list/search first"
    ~sub:"masc_board_list or masc_board_search first"
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
    keeper_board_schemas
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
  let expected_resource_writes =
    let open Tool_name.Board_name in
    [ Board_post
    ; Board_post_update
    ; Board_comment
    ; Board_vote
    ; Board_comment_vote
    ; Board_reaction
    ; Board_curation_submit
    ; Board_delete
    ; Board_cleanup
    ; Board_sub_board_create
    ; Board_sub_board_update
    ; Board_sub_board_delete
    ]
  in
  let wire_names =
    List.map Tool_name.Board_name.to_string Tool_name.Board_name.all
  in
  Alcotest.(check int)
    "generated Board wire names are unique"
    (List.length wire_names)
    (List.length (List.sort_uniq String.compare wire_names));
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
       match Descriptor.descriptors_for_internal schema.name with
       | [ descriptor ] ->
         Alcotest.(check string)
           (schema.name ^ " descriptor id")
           ("masc.board." ^ Tool_name.Board_name.operation_name board_name)
           descriptor.Descriptor.id;
         Alcotest.(check string)
           (schema.name ^ " runtime handler")
           "tool_board_dispatch"
           (Descriptor.runtime_handler_to_string descriptor.runtime_handler);
         let descriptor_properties = schema_property_names descriptor.input_schema in
         Board_tool_registry.identity_fields_for_board_name board_name
         |> List.iter (fun identity_field ->
           Alcotest.(check bool)
             (schema.name ^ " hides runtime-owned " ^ identity_field)
             false
             (List.mem identity_field descriptor_properties));
         let expected_readonly =
           not (List.mem board_name expected_resource_writes)
         in
         Alcotest.(check bool)
           (schema.name ^ " typed resource classification follows Board contract")
           (not expected_readonly)
           (Tool_name.Board_name.is_resource_write board_name);
         Alcotest.(check (option bool))
           (schema.name ^ " descriptor readonly follows typed resource projection")
           (Some expected_readonly)
           descriptor.policy.readonly_hint;
         Alcotest.(check bool)
           (schema.name ^ " is the single Keeper model projection")
           true
           (descriptor.keeper_model_projection = Descriptor.Internal_name);
         let expected_schema_source =
           match Tool_shard_types.keeper_board_schema board_name with
           | Some _ -> Descriptor.Keeper_projection
           | None -> Descriptor.Canonical_registry
         in
         Alcotest.(check bool)
           (schema.name ^ " schema source is truthful")
           true
           (descriptor.input_schema_source = expected_schema_source)
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

let test_readonly_policy_projection_is_descriptor_owned () =
  let projected = Descriptor.readonly_internal_names () in
  List.iter
    (fun d ->
      match Descriptor.readonly_static_hint d with
      | Some true ->
        Alcotest.(check bool)
          (d.Descriptor.internal_name ^ " is in descriptor readonly projection")
          true
          (List.mem d.Descriptor.internal_name projected)
      | Some false | None -> ())
    (all_descriptors ());
  Alcotest.(check bool)
    "tool_write_file is not descriptor read-only"
    false
    (List.mem "tool_write_file" projected)

let test_concurrent_execution_opt_ins_are_exact () =
  let concurrent_internal_names =
    all_descriptors ()
    |> List.filter_map (fun (descriptor : Descriptor.t) ->
      match descriptor.execution with
      | Descriptor.Ordinary Descriptor.Concurrent -> Some descriptor.internal_name
      | Descriptor.Ordinary Descriptor.Serial
      | Descriptor.Direct_terminal
      | Descriptor.Terminal -> None)
    |> List.sort_uniq String.compare
  in
  Alcotest.(check (list string))
    "only explicitly audited handlers opt into concurrent batches"
    [ "keeper_artifact_read"
    ; "keeper_capability_search"
    ; "keeper_library_read"
    ; "keeper_library_search"
    ; "keeper_surface_read"
    ; "keeper_tasks_audit"
    ; "keeper_tasks_list"
    ; "keeper_time_now"
    ; "keeper_tools_list"
    ; "masc_agent_card"
    ; "masc_agent_fitness"
    ; "masc_agent_timeline"
    ; "masc_board_curation_read"
    ; "masc_board_hearths"
    ; "masc_board_list"
    ; "masc_board_post_get"
    ; "masc_board_profile"
    ; "masc_board_search"
    ; "masc_board_stats"
    ; "masc_board_sub_board_get"
    ; "masc_board_sub_board_list"
    ; "masc_config"
    ; "masc_fusion_status"
    ; "masc_get_metrics"
    ; "masc_goal_list"
    ; "masc_plan_get_task"
    ; "masc_run_list"
    ; "masc_task_history"
    ; "masc_tasks"
    ; "masc_tool_help"
    ; "masc_web_fetch"
    ; "masc_web_search"
    ; "tool_read_file"
    ; "tool_search_files"
    ]
    concurrent_internal_names

let test_concurrent_opt_ins_are_statically_read_only () =
  (* Property mirror of the fail-closed admission rule enforced by the
     [Descriptor.descriptor] constructor: a Concurrent descriptor without a
     static read-only hint cannot be constructed, so the registry must never
     contain one. *)
  all_descriptors ()
  |> List.iter (fun (descriptor : Descriptor.t) ->
    match descriptor.execution, Descriptor.readonly_static_hint descriptor with
    | Descriptor.Ordinary Descriptor.Concurrent, Some true -> ()
    | Descriptor.Ordinary Descriptor.Concurrent, (Some false | None) ->
      Alcotest.fail
        (descriptor.internal_name
         ^ " opts into concurrent batches without a static read-only hint")
    | ( Descriptor.Ordinary Descriptor.Serial
      | Descriptor.Direct_terminal
      | Descriptor.Terminal ), _ -> ())

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

let test_public_name_projection_uses_descriptor_resolution () =
  Alcotest.(check (list string))
    "tool_execute public projection"
    [ "Execute" ]
    (Resolution.public_names_for_internal "tool_execute");
  Alcotest.(check (list string))
    "tool_search_files public projections"
    [ "Grep" ]
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
    [ "Execute"; "Grep" ]
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
    (String_util.contains_substring source "Tool_catalog.is_public_mcp")
;;

(* RFC-0182 §3.1 — verify keeper descriptors project from name → descriptor
   via [descriptors_for_internal] with the expected [runtime_handler].

   This catches future typos in the [~name:"masc_X"] strings (which the
   compiler cannot see) and missing cluster builder calls in
   [internal_descriptors]. *)
let cluster_projection_table =
  [ "masc_keeper_list", "tool_masc_keeper_dispatch"
  ; "masc_keeper_delegate_status", "tool_masc_keeper_dispatch"
  ; "masc_keeper_delegate_cancel", "tool_masc_keeper_dispatch"
  ; "masc_keeper_delegate_list", "tool_masc_keeper_dispatch"
  ; "masc_keeper_clear", "tool_masc_keeper_dispatch"
  ; "masc_keeper_sandbox_start", "tool_masc_keeper_dispatch"
  ; "masc_keeper_sandbox_stop", "tool_masc_keeper_dispatch"
  ; "masc_keeper_reset", "tool_masc_keeper_dispatch"
  ; "masc_keeper_audit", "tool_masc_keeper_dispatch"
  ; "masc_keeper_status", "tool_masc_keeper_dispatch"
  ; "masc_keeper_down", "tool_masc_keeper_dispatch"
  ; "masc_keeper_delegate", "tool_masc_keeper_dispatch"
  ; "masc_keeper_up", "tool_masc_keeper_dispatch"
    (* The ask family rides the misc dispatcher: its schemas live in
       [Tool_schemas_misc.schemas], so the descriptor and the in-process route
       are the misc cluster's. *)
  ; "masc_ask", "tool_masc_misc_dispatch"
  ; "masc_ask_status", "tool_masc_misc_dispatch"
  ; "masc_ask_withdraw", "tool_masc_misc_dispatch"
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
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let config = Workspace.default_config dir in
    let agent_name = "test-agent" in
    Masc_test_deps.with_publication_recovery_registry
      ~sw
      ~fs:(Eio.Stdenv.fs env)
      ~registry_root:dir
    @@ fun publication_recovery_registry ->
    let publication_recovery =
      Masc.Keeper_publication_recovery_availability.
        { provider =
            Masc_test_deps.publication_recovery_provider
              publication_recovery_registry
        ; keeper_name = agent_name
        }
    in
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
             !Keeper_dispatch_ref.dispatch
               ~config
               ~agent_name
               ~publication_recovery_provider:publication_recovery.provider
               ~name
               ~args:(`Assoc [])
               ()
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
        (String.concat ", " unreachable);
    let surface_ctx : _ Keeper_tool_surface.context =
      { config
      ; agent_name
      ; sw
      ; clock = Eio.Stdenv.clock env
      ; proc_mgr = None
      ; net = None
      ; publication_recovery_provider = publication_recovery.provider
      }
    in
    let unreachable_surface_schemas =
      Keeper_schema.schemas
      |> List.filter_map (fun (schema : Masc_domain.tool_schema) ->
        match
          Keeper_tool_surface.dispatch
            surface_ctx
            ~name:schema.name
            ~args:(`Assoc [])
        with
        | Some _ -> None
        | None -> Some schema.name)
    in
    if unreachable_surface_schemas <> []
    then
      Alcotest.failf
        "Keeper_tool_surface.dispatch returned None for %d Keeper schema(s): %s"
        (List.length unreachable_surface_schemas)
        (String.concat ", " unreachable_surface_schemas))
;;

let test_public_mcp_surface_has_exact_dispatch_owner () =
  let descriptor_names = descriptor_internal_name_set () in
  let runtime_names =
    Tool_schemas_misc.mcp_runtime_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  in
  let surface = Tool_catalog_surfaces.public_mcp_surface_tools in
  let missing =
    List.filter
      (fun name ->
         (not (Hashtbl.mem descriptor_names name))
         && not (List.mem name runtime_names))
      surface
  in
  if missing <> []
  then
    Alcotest.failf
      "public_mcp_surface_tools has %d entries with no exact descriptor or inline \
       runtime owner: %s"
      (List.length missing)
      (String.concat ", " missing)
;;

let test_public_mcp_membership_matches_surface_ssot () =
  let surface = Tool_catalog_surfaces.public_mcp_surface_tools in
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
       Alcotest.(check bool)
         (schema.name ^ " public membership matches the canonical surface")
         (List.mem schema.name surface)
         (Tool_catalog.is_public_mcp schema.name))
    Masc.Config.raw_all_tool_schemas
;;

(* keeper_surface_post is described in three places: the MCP tool schema
   (tool_surface layer), the keeper descriptor's input schema, and the executor
   that validates the call. Nothing made them agree, and two descriptions had
   already drifted into saying a dashboard/discord target is "ignored" when the
   executor rejects it. RFC-0056 forbids the tool_surface layer from importing
   keeper, so the block cap exists as two constants; this pins them equal and
   pins the parameter sets equal, which is the check that was missing. *)
let surface_post_schema_properties (schema : Yojson.Safe.t) =
  match schema with
  | `Assoc fields -> (
    match List.assoc_opt "properties" fields with
    | Some (`Assoc props) -> List.map fst props |> List.sort String.compare
    | Some _ | None -> Alcotest.fail "keeper_surface_post schema has no properties")
  | _ -> Alcotest.fail "keeper_surface_post schema is not an object"
;;

let surface_post_block_cap (schema : Yojson.Safe.t) =
  match schema with
  | `Assoc fields -> (
    match List.assoc_opt "properties" fields with
    | Some (`Assoc props) -> (
      match List.assoc_opt "blocks" props with
      | Some (`Assoc block_fields) -> List.assoc_opt "maxItems" block_fields
      | Some _ | None -> None)
    | Some _ | None -> None)
  | _ -> None
;;

let tool_schema_for name =
  match
    List.find_opt
      (fun (t : Masc_domain.tool_schema) -> String.equal t.name name)
      Tool_shard_types.surface_tools
  with
  | Some tool -> tool.input_schema
  | None -> Alcotest.failf "tool schema %s is not registered" name
;;

let descriptor_schema_for name =
  (* Registered with [~keeper_model_projection:Internal_name], so
     [public_input_schema] does not resolve it. *)
  match Descriptor.descriptors_for_internal name with
  | descriptor :: _ -> descriptor.Descriptor.input_schema
  | [] -> Alcotest.failf "descriptor %s is not registered" name
;;

let test_surface_post_schema_copies_agree () =
  let tool_schema = tool_schema_for "keeper_surface_post" in
  let descriptor_schema = descriptor_schema_for "keeper_surface_post" in
  check
    (list string)
    "the two keeper_surface_post schemas declare the same parameters"
    (surface_post_schema_properties descriptor_schema)
    (surface_post_schema_properties tool_schema);
  let expected = `Int Masc.Keeper_surface_post.max_rich_blocks in
  check
    bool
    "the tool schema's block cap equals the executor's"
    true
    (surface_post_block_cap tool_schema = Some expected);
  check
    bool
    "the descriptor's block cap equals the executor's"
    true
    (surface_post_block_cap descriptor_schema = Some expected)
;;

(* The executor refuses these two parameters outside Slack. A description that
   says "ignored" sends the model into a call that fails. *)
let test_surface_post_descriptions_do_not_promise_ignoring () =
  let contains needle haystack =
    let n = String.length needle in
    let rec scan i =
      i + n <= String.length haystack
      && (String.equal (String.sub haystack i n) needle || scan (i + 1))
    in
    n > 0 && scan 0
  in
  let descriptions schema =
    match schema with
    | `Assoc fields -> (
      match List.assoc_opt "properties" fields with
      | Some (`Assoc props) ->
        List.filter_map
          (fun (name, value) ->
             match value with
             | `Assoc value_fields -> (
               match List.assoc_opt "description" value_fields with
               | Some (`String text) -> Some (name, text)
               | Some _ | None -> None)
             | _ -> None)
          props
      | Some _ | None -> [])
    | _ -> []
  in
  List.iter
    (fun schema ->
       List.iter
         (fun (name, text) ->
            match name with
            | "thread_ts" | "blocks" ->
              check
                bool
                (name ^ " does not describe a rejected target as ignored")
                false
                (contains "ignored for dashboard" text
                 || contains "ignored for discord" text)
            | _ -> ())
         (descriptions schema))
    [ tool_schema_for "keeper_surface_post"
    ; descriptor_schema_for "keeper_surface_post"
    ]
;;

let test_probe_schema_declares_the_bounds_it_enforces () =
  (* The probe refuses probe_runs/max_tokens/ps_timeout_sec outside their
     ranges (#25006). A caller that cannot read those ranges off the schema
     learns them from a rejection instead, one wasted round trip per knob,
     and nothing in the type system ties the two together. *)
  (* Not [tool_schema_for]: the probe is an Operator_diagnostic, so it is
     registered but withheld from the keeper model projection that
     [surface_tools] is. Read it where it is declared. *)
  let schema =
    match
      List.find_opt
        (fun (definition : Tool_schemas_local_runtime.definition) ->
          String.equal definition.schema.name "masc_runtime_ollama_probe")
        Tool_schemas_local_runtime.definitions
    with
    | Some definition -> definition.schema.input_schema
    | None -> Alcotest.fail "masc_runtime_ollama_probe is not declared"
  in
  let bound field key expected =
    let actual =
      schema
      |> Yojson.Safe.Util.member "properties"
      |> Yojson.Safe.Util.member field
      |> Yojson.Safe.Util.member key
    in
    Alcotest.(check string)
      (Printf.sprintf "%s declares %s" field key)
      (Yojson.Safe.to_string (`Int expected))
      (Yojson.Safe.to_string actual)
  in
  bound "probe_runs" "minimum" 1;
  bound "probe_runs" "maximum" 4;
  bound "max_tokens" "minimum" 1;
  bound "max_tokens" "maximum" 128;
  bound "ps_timeout_sec" "minimum" 1;
  bound "ps_timeout_sec" "maximum" 30;
  bound "timeout_sec" "minimum" 1
;;

let () =
  Alcotest.run
    "keeper_tool_descriptor_registry_integrity"
    [ ( "surface_post schema parity"
      , [ test_case
            "both keeper_surface_post schemas agree with the executor"
            `Quick
            test_surface_post_schema_copies_agree
        ; test_case
            "slack-only parameters are not described as ignored"
            `Quick
            test_surface_post_descriptions_do_not_promise_ignoring
        ] )
    ; ( "uniqueness"
      , [ test_case "registry not empty" `Quick test_registry_not_empty
        ; test_case
            "a repeated schema name is rejected"
            `Quick
            test_duplicate_schema_name_is_rejected
        ; test_case
            "distinct schema names are accepted"
            `Quick
            test_distinct_schema_names_are_accepted
        ; test_case
            "a blank schema description is rejected"
            `Quick
            test_blank_schema_description_is_rejected
        ; test_case "public_name is unique" `Quick test_public_name_uniqueness
        ; test_case "internal_name is unique" `Quick test_internal_name_uniqueness
        ; test_case
            "Keeper model projection is single and unique"
            `Quick
            test_keeper_model_projection_is_single_and_unique
        ; test_case
            "transport aliases name one visible projection owner"
            `Quick
            test_transport_aliases_name_exact_visible_projection
        ; test_case
            "semantic capability has at most one Keeper model projection"
            `Quick
            test_semantic_capability_has_at_most_one_keeper_model_projection
        ; test_case
            "model-visible descriptors own capability identity"
            `Quick
            test_model_visible_descriptors_own_capability_identity
        ; test_case
            "model-visible descriptors have canonical input schemas"
            `Quick
            test_model_visible_descriptors_have_canonical_input_schemas
        ; Alcotest.test_case
            "the loader refuses a malformed declaration"
            `Quick
            test_the_loader_refuses_a_malformed_declaration
        ; Alcotest.test_case
            "the loader accepts the same declaration repaired"
            `Quick
            test_the_loader_accepts_the_same_declaration_repaired
        ; test_case
            "resolved descriptor schemas are structurally valid"
            `Quick
            test_all_resolved_descriptor_schemas_are_structurally_valid
        ; test_case
            "sandbox control descriptors use exact canonical schemas"
            `Quick
            test_sandbox_control_descriptors_use_exact_canonical_schemas
        ; test_case
            "structurally invalid schema is excluded"
            `Quick
            test_structurally_invalid_schema_is_excluded
        ; test_case
            "cluster descriptions come from the registry"
            `Quick
            test_cluster_descriptions_come_from_the_registry
        ; test_case
            "registered cluster model projections are explicit"
            `Quick
            test_registered_cluster_model_projections_are_explicit
        ; test_case
            "local runtime effect metadata is explicit"
            `Quick
            test_local_runtime_effect_metadata_is_explicit
        ; test_case
            "Keeper management projection is explicit"
            `Quick
            test_keeper_management_projection_is_explicit
        ; test_case
            "all Keeper shard schemas are descriptor-backed"
            `Quick
            test_all_keeper_shard_schemas_are_descriptor_backed
        ; test_case
            "all Keeper surface schemas are descriptor-backed"
            `Quick
            test_keeper_surface_schemas_are_descriptor_backed
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
            "keeper_memory_retract ends a successful turn"
            `Quick
            test_memory_retract_descriptor_is_terminal
        ; test_case
            "keeper_memory_retract descriptor schema is closed"
            `Quick
            test_memory_retract_descriptor_schema_is_closed
        ; test_case
            "keeper_memory_write ends a successful turn"
            `Quick
            test_memory_write_descriptor_is_terminal
        ; test_case
            "keeper_memory_write descriptor schema is closed"
            `Quick
            test_memory_write_descriptor_schema_is_closed
        ; test_case
            "keeper_memory_write rejects retired lifetime arguments"
            `Quick
            test_memory_write_rejects_retired_lifetime_argument
        ; test_case
            "Read public descriptor schema is closed"
            `Quick
            test_read_public_descriptor_schema_is_closed
        ; test_case
            "Read rejects unsupported line fields before translation"
            `Quick
            test_read_public_validation_rejects_line_fields
        ; test_case
            "Edit rejects an undeclared content key before translation"
            `Quick
            test_edit_public_validation_rejects_content
        ; test_case
            "translation validation policy is typed for all descriptors"
            `Quick
            test_translation_validation_policy_is_typed_for_all_descriptors
        ; test_case
            "shape-changing translations validate their output"
            `Quick
            test_shape_changing_post_validation_is_executed
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
            "keeper clusters project to descriptors"
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
    ; ( "surface-projection"
      , [ test_case
            "public_mcp_surface_tools has an exact dispatch owner"
            `Quick
            test_public_mcp_surface_has_exact_dispatch_owner
        ; test_case
            "public MCP membership matches the canonical surface"
            `Quick
            test_public_mcp_membership_matches_surface_ssot
        ] )
    ; ( "policy-projection"
      , [ test_case
            "concurrent execution opt-ins are exact"
            `Quick
            test_concurrent_execution_opt_ins_are_exact
        ; test_case
            "concurrent execution opt-ins are statically read-only"
            `Quick
            test_concurrent_opt_ins_are_statically_read_only
        ; test_case
            "descriptor owns the read-only metadata projection"
            `Quick
            test_readonly_policy_projection_is_descriptor_owned
        ; test_case
            "descriptor read-only policy evaluates tool input"
            `Quick
            test_readonly_policy_is_descriptor_input_aware
        ; test_case
            "public names project through descriptor resolution"
            `Quick
            test_public_name_projection_uses_descriptor_resolution
        ; test_case
            "keeper_run_tools_setup avoids public MCP catalog classifier"
            `Quick
            test_run_tools_setup_has_no_direct_public_mcp_catalog_read
        ; test_case
            "ollama probe schema declares the bounds it enforces"
            `Quick
            test_probe_schema_declares_the_bounds_it_enforces
        ] )
    ]
