(** Tools inventory, effective skill surfaces and retained workspace catalog.
    Pure wire models and decoders; callers own HTTP and presentation effects. *)
open Tui_decode_fields

let ( let* ) = Result.bind

type tool_entry = {
  tl_name : string;
  tl_description : string;
  tl_surfaces : string list;
  tl_direct_call : bool;
}

type inventory_freshness =
  | Warming
  | Settled

type effective_tool_origin =
  | Descriptor_origin
  | Instruction_skill_origin
  | Composition_skill_origin of { skill_source_id : string option }
  | Composition_control_origin
  | Unrecognised_origin of string

let effective_tool_origin_kind = function
  | Descriptor_origin -> "descriptor"
  | Instruction_skill_origin -> "instruction_skill"
  | Composition_skill_origin _ -> "composition_skill"
  | Composition_control_origin -> "composition_control"
  | Unrecognised_origin kind -> kind

type effective_tool = {
  et_name : string;
  et_origin : effective_tool_origin;
}

type effective_tool_delivery =
  | Effective_tools_delivered
  | Effective_tools_suppressed_runtime_unsupported

type skill_flow_dependency = {
  sfd_node_id : string;
  sfd_kind : string;
}

type skill_flow_node = {
  sfn_id : string;
  sfn_tool_name : string;
  sfn_dependencies : skill_flow_dependency list;
  sfn_batch_index : int;
  sfn_execution_mode : string;
}

type skill_flow_batch = {
  sfb_index : int;
  sfb_execution_mode : string;
  sfb_node_ids : string list;
}

type skill_flow = {
  sf_nodes : skill_flow_node list;
  sf_batches : skill_flow_batch list;
}

type effective_skill_load_reason =
  | Skill_catalog_default
  | Skill_keeper_profile
  | Skill_task of string

type effective_skill_profile = {
  esp_reference : Skill_reference.t;
  esp_name : string;
  esp_kind : string;
  esp_execution : string;
  esp_body_bytes : int;
  esp_discovery_bytes : int;
  esp_load_reasons : effective_skill_load_reason list;
  esp_node_count : int;
  esp_batch_count : int;
  esp_max_parallelism : int;
  esp_flow : skill_flow option;
}

(* A Skill name the Keeper profile selected that the turn's catalog does not
   hold. It is not a read failure -- the document may not exist at all -- so it
   is a different fact from [ets_skills_left_out] and the producer sends it as
   its own list. [csn_reason] is the producer's word for why
   (`not_in_turn_skill_catalog`); every entry carries one
   (Keeper_skill_catalog.configured_name_unavailable_to_yojson). *)
type configured_skill_name_unavailable = {
  csn_name : string;
  csn_reason : string;
}

type effective_tool_surface =
  | Effective_surface_available of {
      ets_keeper_name : string;
      ets_runtime_id : string;
      ets_official_client_kind : string;
      ets_tool_delivery : effective_tool_delivery;
      ets_native_posture : string option;
      ets_skill_snapshot_revision : string;
      ets_skill_resource_read_max_bytes : int option;
      ets_instruction_skills : Skill_reference.t list;
      (* Documents the catalog could not read. Beside the skills rather than
         missing from them: a skill left out is absent from what the Keeper
         can call, and absence with no reason reads as a skill nobody
         wrote. *)
      ets_skills_left_out : string list;
      (* Names the profile selected and the turn catalog does not carry. The
         dashboard draws these under "Unavailable Skills"; this reader exists
         so the other renderer of the same surface says it too. *)
      ets_unavailable_skill_names : configured_skill_name_unavailable list;
      ets_composition_skills : Skill_reference.t list;
      ets_skill_profiles : effective_skill_profile list;
      ets_tool_surface_bytes : int;
      ets_skill_tool_surface_bytes : int;
      ets_skill_discovery_bytes : int;
      ets_skill_eager_body_bytes : int;
      ets_skill_body_bytes : int;
      ets_tools : effective_tool list;
      ets_tool_surface_sha256 : string option;
    }
  | Effective_surface_unavailable of {
      ets_keeper_name : string;
      ets_reason : string;
      ets_detail : string;
    }
  | Effective_surface_warming of { ets_keeper_name : string }

type skill_activation_projection =
  | Skill_activations_available of
      { sap_keeper_name : string
      ; sap_ledger : Keeper_skill_activation_ledger.t
      }
  | Skill_activations_no_session of { sap_keeper_name : string }
  | Skill_activations_unavailable of
      { sap_keeper_name : string
      ; sap_reason : string
      ; sap_detail : string
      }

type tool_snapshot = {
  ts_tools : tool_entry list;
  ts_count : int;
  ts_freshness : inventory_freshness;
  ts_effective : effective_tool_surface option;
  ts_skill_activations : skill_activation_projection option;
}

let decode_tool_entry json =
  let* tl_name = required_string_field json "name" in
  let* tl_description = required_string_field json "description" in
  let* tl_surfaces = decode_string_name_list json "surfaces" in
  let* tl_direct_call =
    decode_bool_field_or json "direct_call_allowed" ~default:false
  in
  Ok { tl_name; tl_description; tl_surfaces; tl_direct_call }

let decode_effective_tool json =
  let* et_name = required_string_field json "name" in
  let* origin = required_object_field json "origin" in
  let* kind = required_string_field origin "kind" in
  (* Which configured skill source supplied this tool.
     Keeper_effective_tool_surface.origin_to_yojson sends
     origin.skill_provenance for a composition skill and for no other kind:
     an object when the provenance resolved, null when it did not, and the
     object always holds identity.source_id. So the key is required for that
     kind and not read for the others. Without the key the Tools screen would
     draw a bare "composition_skill" and never say which source it came
     from. *)
  let* et_origin =
    match kind with
    | "descriptor" -> Ok Descriptor_origin
    | "instruction_skill" -> Ok Instruction_skill_origin
    | "composition_control" -> Ok Composition_control_origin
    | "composition_skill" ->
      let* skill_source_id =
        match Json_util.assoc_member_opt "skill_provenance" origin with
        | None -> missing_field "skill_provenance"
        | Some `Null -> Ok None
        | Some (`Assoc _ as provenance) ->
          let* identity = required_object_field provenance "identity" in
          let* source_id = required_string_field identity "source_id" in
          Ok (Some source_id)
        | Some bad -> field_type_error "skill_provenance" "an object or null" bad
      in
      Ok (Composition_skill_origin { skill_source_id })
    (* A kind a newer server adds is kept as the word it sent: the Tools
       column still draws it, and the rest of the surface still loads. *)
    | unrecognised -> Ok (Unrecognised_origin unrecognised)
  in
  Ok { et_name; et_origin }

let decode_skill_reference_list json field =
  let* values = required_list_field json field in
  match Skill_reference.list_of_yojson (`List values) with
  | Ok references -> Ok references
  | Error _ -> Error (Printf.sprintf "%s is not a canonical Skill reference list" field)

let decode_effective_tool_delivery json =
  let* status = required_string_field json "status" in
  match status with
  | "delivered" -> Ok Effective_tools_delivered
  | "suppressed" ->
      let* reason = required_string_field json "reason" in
      (match reason with
       | "runtime_tools_unsupported" ->
         Ok Effective_tools_suppressed_runtime_unsupported
       | unknown ->
         Error (Printf.sprintf "tool_delivery.reason has unknown value %S" unknown))
  | unknown ->
      Error (Printf.sprintf "tool_delivery.status has unknown value %S" unknown)

let decode_skill_flow_dependency json =
  let* sfd_node_id = required_string_field json "node_id" in
  let* sfd_kind = required_string_field json "kind" in
  Ok { sfd_node_id; sfd_kind }

let decode_skill_flow_node json =
  let* sfn_id = required_string_field json "id" in
  let* sfn_tool_name = required_string_field json "tool_name" in
  let* dependencies = required_list_field json "dependencies" in
  let* sfn_dependencies =
    decode_list "skill flow dependencies" decode_skill_flow_dependency dependencies
  in
  let* sfn_batch_index = required_int_field json "batch_index" in
  let* sfn_execution_mode = required_string_field json "execution_mode" in
  Ok
    { sfn_id
    ; sfn_tool_name
    ; sfn_dependencies
    ; sfn_batch_index
    ; sfn_execution_mode
    }

let decode_skill_flow_batch json =
  let* sfb_index = required_int_field json "index" in
  let* sfb_execution_mode = required_string_field json "execution_mode" in
  let* node_ids = required_list_field json "node_ids" in
  let* sfb_node_ids =
    decode_list
      "skill flow batch node ids"
      (function
        | `String value -> Ok value
        | bad -> field_type_error "node_ids" "a string" bad)
      node_ids
  in
  Ok { sfb_index; sfb_execution_mode; sfb_node_ids }

let decode_skill_flow json =
  let* nodes = required_list_field json "nodes" in
  let* sf_nodes = decode_list "skill flow nodes" decode_skill_flow_node nodes in
  let* batches = required_list_field json "batches" in
  let* sf_batches = decode_list "skill flow batches" decode_skill_flow_batch batches in
  Ok { sf_nodes; sf_batches }

let decode_effective_skill_load_reason json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "catalog_default" -> Ok Skill_catalog_default
  | "keeper_profile" -> Ok Skill_keeper_profile
  | "task" ->
    let* task_id = required_string_field json "task_id" in
    Ok (Skill_task task_id)
  | value ->
    Error (Printf.sprintf "effective Skill load reason has unknown kind %S" value)
;;

let decode_effective_skill_profile json =
  let* reference = required_object_field json "reference" in
  let* esp_reference =
    Skill_reference.of_yojson reference
    |> Result.map_error (fun _ -> "effective Skill profile reference is invalid")
  in
  let* identity = required_object_field reference "identity" in
  let* esp_name = required_string_field identity "name" in
  let* esp_kind = required_string_field json "kind" in
  let* esp_execution = required_string_field json "execution" in
  let* context = required_object_field json "context" in
  let* esp_body_bytes = required_int_field context "body_bytes" in
  let* esp_discovery_bytes = required_int_field context "discovery_bytes" in
  let* load_reasons = required_list_field json "load_reasons" in
  let* esp_load_reasons =
    decode_list
      "effective Skill profile load reasons"
      decode_effective_skill_load_reason
      load_reasons
  in
  let* plan = required_object_field json "plan" in
  let* esp_node_count = required_int_field plan "node_count" in
  let* esp_batch_count = required_int_field plan "batch_count" in
  let* esp_max_parallelism = required_int_field plan "max_parallelism" in
  let* flow = optional_object_field json "flow" in
  let* esp_flow =
    match flow with
    | None -> Ok None
    | Some json -> decode_skill_flow json |> Result.map Option.some
  in
  Ok
    { esp_reference
    ; esp_name
    ; esp_kind
    ; esp_execution
    ; esp_body_bytes
    ; esp_discovery_bytes
    ; esp_load_reasons
    ; esp_node_count
    ; esp_batch_count
    ; esp_max_parallelism
    ; esp_flow
    }

let decode_effective_tool_surface json =
  let* status = required_string_field json "status" in
  let* ets_keeper_name = required_string_field json "keeper_name" in
  match status with
  | "warming" -> Ok (Effective_surface_warming { ets_keeper_name })
  | "unavailable" ->
      let* ets_reason = required_string_field json "reason" in
      let* ets_detail = required_string_field json "detail" in
      Ok
        (Effective_surface_unavailable
           { ets_keeper_name; ets_reason; ets_detail })
  | "available" ->
      let* ets_runtime_id = required_string_field json "runtime_id" in
      let* ets_official_client_kind =
        required_string_field json "official_client_kind"
      in
      let* tool_delivery = required_object_field json "tool_delivery" in
      let* ets_tool_delivery = decode_effective_tool_delivery tool_delivery in
      let* ets_native_posture = optional_string_field json "native_posture" in
      let* ets_skill_snapshot_revision =
        required_string_field json "skill_snapshot_revision"
      in
      let* ets_skill_resource_read_max_bytes =
        optional_int_field json "skill_resource_read_max_bytes"
      in
      let* ets_skills_left_out =
        decode_string_name_list json "skills_left_out"
      in
      let* unavailable_skill_names_json =
        required_list_field json "unavailable_skill_names"
      in
      let* ets_unavailable_skill_names =
        decode_list "effective_keeper_surface.unavailable_skill_names"
          (fun entry ->
            let* csn_name = required_string_field entry "name" in
            let* csn_reason = required_string_field entry "reason" in
            Ok { csn_name; csn_reason })
          unavailable_skill_names_json
      in
      let* ets_instruction_skills =
        decode_skill_reference_list json "instruction_skills"
      in
      let* ets_composition_skills =
        decode_skill_reference_list json "composition_skills"
      in
      let* skill_profiles_json = optional_list_field json "skill_profiles" in
      let* ets_skill_profiles =
        decode_list
          "effective_keeper_surface.skill_profiles"
          decode_effective_skill_profile
          skill_profiles_json
      in
      let* tool_surface_bytes = optional_int_field json "tool_surface_bytes" in
      let ets_tool_surface_bytes = Option.value ~default:0 tool_surface_bytes in
      let* ets_skill_tool_surface_bytes =
        optional_int_field json "skill_tool_surface_bytes"
      in
      let ets_skill_tool_surface_bytes =
        Option.value ~default:0 ets_skill_tool_surface_bytes
      in
      let* ets_skill_discovery_bytes =
        required_int_field json "skill_discovery_bytes"
      in
      let* ets_skill_eager_body_bytes =
        required_int_field json "skill_eager_body_bytes"
      in
      let* skill_body_bytes = optional_int_field json "skill_body_bytes" in
      let ets_skill_body_bytes = Option.value ~default:0 skill_body_bytes in
      let* tools_json = required_list_field json "tools" in
      let* ets_tools =
        decode_list "effective_keeper_surface.tools" decode_effective_tool
          tools_json
      in
      let* ets_tool_surface_sha256 =
        optional_string_field json "tool_surface_sha256"
      in
      Ok
        (Effective_surface_available
           { ets_keeper_name;
             ets_runtime_id;
             ets_official_client_kind;
             ets_tool_delivery;
             ets_native_posture;
             ets_skill_snapshot_revision;
             ets_skill_resource_read_max_bytes;
             ets_instruction_skills;
             ets_skills_left_out;
             ets_unavailable_skill_names;
             ets_composition_skills;
             ets_skill_profiles;
             ets_tool_surface_bytes;
             ets_skill_tool_surface_bytes;
             ets_skill_discovery_bytes;
             ets_skill_eager_body_bytes;
             ets_skill_body_bytes;
             ets_tools;
             ets_tool_surface_sha256;
           })
  | unknown ->
      Error
        (Printf.sprintf
           "effective_keeper_surface.status has unknown value %S" unknown)

let decode_skill_activation_ledger ~keeper_name json =
  Keeper_skill_activation_ledger.of_projection_yojson json
  |> Result.map (fun sap_ledger ->
    Skill_activations_available
      { sap_keeper_name = keeper_name; sap_ledger })
  |> Result.map_error (fun error ->
    "skill activation ledger is invalid: "
    ^ Keeper_skill_activation_ledger.decode_error_code error)

let decode_skill_activation_projection json =
  let* status = required_string_field json "status" in
  let* sap_keeper_name = required_string_field json "keeper_name" in
  match status with
  | "available" ->
      let* ledger = required_object_field json "ledger" in
      decode_skill_activation_ledger ~keeper_name:sap_keeper_name ledger
  | "no_session" -> Ok (Skill_activations_no_session { sap_keeper_name })
  | "unavailable" ->
      let* sap_reason = required_string_field json "reason" in
      let* sap_detail = required_string_field json "detail" in
      Ok
        (Skill_activations_unavailable
           { sap_keeper_name; sap_reason; sap_detail })
  | unknown ->
      Error (Printf.sprintf "skill_activations.status has unknown value %S" unknown)

(* ── Workspace skills catalog (/api/v1/skills) ─────────────────────
   The dashboard renders the full surface set; the TUI Tools screen reads
   per-skill usage rows (cross-keeper tracking) and reuses the skill_flow
   decoder the effective-surface profiles already share. Usage may be absent
   while the ledger side is warming. A valid instruction/composition surface
   always carries its profile; only an unavailable surface has none. *)

type skill_usage_row =
  { su_keeper : string
  ; su_invocations : int
  ; su_deliveries : int
  ; su_actions : int
  ; su_last_used_at : string option
  }

type skills_catalog_surface =
  { scs_name : string
  ; scs_kind : string
  ; scs_usage : skill_usage_row list
  ; scs_flow : skill_flow option
  }

module Skill_document = Agent_core.Skill_document

type skill_rejection_diagnostic =
  { srd_diagnostic : Skill_document.diagnostic
  ; srd_message : string
  }

type skill_rejection_reason =
  | Skill_document_rejected of skill_rejection_diagnostic list
  | Skill_document_unreadable
  | Skill_exact_identity_duplicate
  | Skill_invalid_package_id

type skill_catalog_rejection =
  { scr_source_index : int
  ; scr_source_id : string
  ; scr_package_id : string option
  ; scr_content_revision : string option
  ; scr_reason : skill_rejection_reason
  }

type skills_catalog_state =
  | Skills_ready
  | Skills_not_registered
  | Skills_uninitialized
  | Skills_invalid_workspace

type skill_source_observation =
  | Skill_source_ready of int
  | Skill_source_missing
  | Skill_source_not_directory of string
  | Skill_source_unavailable of string
  | Skill_source_unresolved

type skill_catalog_source =
  { scso_id : string
  ; scso_anchor : string
  ; scso_path : string option
  ; scso_access : string
  ; scso_observation : skill_source_observation
  }

type skill_catalog_config =
  | Skill_config_configured of
      { revision : string
      ; resource_read_max_bytes : int option
      }
  | Skill_config_rejected of
      { source_revision : string
      ; diagnostics : string list
      }
  | Skill_config_unreadable

type skill_usage_coverage = {
  suc_ledgers_loaded : int;
  suc_unavailable : string list;
}

type skill_catalog_shadow = {
  scsh_winner : Skill_reference.identity;
  scsh_shadowed : Skill_reference.identity;
}

type skills_catalog =
  { sc_state : skills_catalog_state
  ; sc_config : skill_catalog_config option
  ; sc_sources : skill_catalog_source list
  ; sc_surfaces : skills_catalog_surface list
  ; sc_rejections : skill_catalog_rejection list
  ; sc_shadows : skill_catalog_shadow list
  ; sc_usage_coverage : skill_usage_coverage option
  }

let skills_catalog_state_to_string = function
  | Skills_ready -> "ready"
  | Skills_not_registered -> "not_registered"
  | Skills_uninitialized -> "uninitialized"
  | Skills_invalid_workspace -> "invalid_workspace"

let skill_diagnostic_code_to_string = function
  | Skill_document.Missing_frontmatter -> "missing_frontmatter"
  | Skill_document.Byte_order_mark -> "byte_order_mark"
  | Skill_document.Unterminated_frontmatter -> "unterminated_frontmatter"
  | Skill_document.Malformed_yaml _ -> "malformed_yaml"
  | Skill_document.Frontmatter_not_mapping -> "frontmatter_not_mapping"
  | Skill_document.Duplicate_field _ -> "duplicate_field"
  | Skill_document.Duplicate_metadata_key _ -> "duplicate_metadata_key"
  | Skill_document.Unexpected_frontmatter_field _ ->
    "unexpected_frontmatter_field"
  | Skill_document.Missing_name -> "missing_name"
  | Skill_document.Missing_description -> "missing_description"
  | Skill_document.Invalid_field_type _ -> "invalid_field_type"
  | Skill_document.Invalid_name _ -> "invalid_name"
  | Skill_document.Name_mismatch _ -> "name_mismatch"
  | Skill_document.Description_too_long _ -> "description_too_long"
  | Skill_document.Compatibility_empty -> "compatibility_empty"
  | Skill_document.Compatibility_too_long _ -> "compatibility_too_long"
  | Skill_document.Invalid_metadata_value _ -> "invalid_metadata_value"

let validate_closed_object ~label ~allowed = function
  | `Assoc fields ->
    let rec find_duplicate seen = function
      | [] -> None
      | (key, _) :: rest ->
        if List.mem key seen then Some key else find_duplicate (key :: seen) rest
    in
    (match find_duplicate [] fields with
     | Some key ->
       Error (Printf.sprintf "%s duplicates field %S" label key)
     | None ->
       (match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
        | Some (key, _) ->
          Error (Printf.sprintf "%s has unexpected field %S" label key)
        | None -> Ok ()))
  | bad -> field_type_error label "an object" bad

let required_nullable_nonempty_string_field json key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | None -> missing_field key
     | Some `Null -> Ok None
     | Some (`String "") ->
       Error (Printf.sprintf "field '%s' must be non-empty or null" key)
     | Some (`String value) -> Ok (Some value)
     | Some bad -> field_type_error key "a non-empty string or null" bad)
  | bad -> field_type_error "skill snapshot rejection" "an object" bad

let decode_skill_document_field json =
  let* () = validate_closed_object ~label:"diagnostic.field" ~allowed:[ "kind"; "name" ] json in
  let* kind = required_string_field json "kind" in
  let* name = required_string_field json "name" in
  match kind, name with
  | "standard", "name" -> Ok (Skill_document.Standard Skill_document.Name)
  | "standard", "description" ->
    Ok (Skill_document.Standard Skill_document.Description)
  | "standard", "license" -> Ok (Skill_document.Standard Skill_document.License)
  | "standard", "compatibility" ->
    Ok (Skill_document.Standard Skill_document.Compatibility)
  | "standard", "metadata" -> Ok (Skill_document.Standard Skill_document.Metadata)
  | "standard", "allowed-tools" ->
    Ok (Skill_document.Standard Skill_document.Allowed_tools_syntax_only)
  | "standard", unknown ->
    Error (Printf.sprintf "diagnostic.field has unknown standard name %S" unknown)
  | "extension", name -> Ok (Skill_document.Extension name)
  | unknown, _ ->
    Error (Printf.sprintf "diagnostic.field has unknown kind %S" unknown)

let decode_skill_expected_shape json =
  match json with
  | `String "string" -> Ok Skill_document.String_value
  | `String "string_mapping" -> Ok Skill_document.String_mapping
  | `String unknown ->
    Error (Printf.sprintf "diagnostic.expected has unknown value %S" unknown)
  | bad -> field_type_error "diagnostic.expected" "a string" bad

let decode_skill_name_violation json =
  let* kind = required_string_field json "kind" in
  let closed fields =
    validate_closed_object
      ~label:"diagnostic.violations[]"
      ~allowed:("kind" :: fields)
      json
  in
  match kind with
  | "empty_name" ->
    let* () = closed [] in
    Ok Skill_document.Empty_name
  | "name_too_long" ->
    let* () = closed [ "length"; "maximum" ] in
    let* length = required_nonnegative_int_field json "length" in
    let* maximum = required_int_field json "maximum" in
    if maximum <= 0
    then Error "field 'maximum' must be positive"
    else Ok (Skill_document.Name_too_long { length; maximum })
  | "name_not_lowercase" ->
    let* () = closed [] in
    Ok Skill_document.Name_not_lowercase
  | "name_starts_with_hyphen" ->
    let* () = closed [] in
    Ok Skill_document.Name_starts_with_hyphen
  | "name_ends_with_hyphen" ->
    let* () = closed [] in
    Ok Skill_document.Name_ends_with_hyphen
  | "name_has_consecutive_hyphens" ->
    let* () = closed [] in
    Ok Skill_document.Name_has_consecutive_hyphens
  | "name_has_invalid_character" ->
    let* () = closed [] in
    Ok Skill_document.Name_has_invalid_character
  | unknown ->
    Error (Printf.sprintf "skill name violation has unknown kind %S" unknown)

let decode_skill_rejection_diagnostic json =
  let* code = required_string_field json "code" in
  let* srd_message = required_nonempty_string_field json "message" in
  let closed payload =
    validate_closed_object
      ~label:"skill rejection diagnostic"
      ~allowed:("code" :: "message" :: payload)
      json
  in
  let* srd_diagnostic =
    match code with
    | "missing_frontmatter" ->
      let* () = closed [] in
      Ok Skill_document.Missing_frontmatter
    | "byte_order_mark" ->
      let* () = closed [] in
      Ok Skill_document.Byte_order_mark
    | "unterminated_frontmatter" ->
      let* () = closed [] in
      Ok Skill_document.Unterminated_frontmatter
    | "malformed_yaml" ->
      let* () = closed [ "detail" ] in
      let* detail = required_nonempty_string_field json "detail" in
      Ok (Skill_document.Malformed_yaml detail)
    | "frontmatter_not_mapping" ->
      let* () = closed [] in
      Ok Skill_document.Frontmatter_not_mapping
    | "duplicate_field" ->
      let* () = closed [ "field" ] in
      let* field_json = required_object_field json "field" in
      let* field = decode_skill_document_field field_json in
      Ok (Skill_document.Duplicate_field field)
    | "duplicate_metadata_key" ->
      let* () = closed [ "key" ] in
      let* key = required_string_field json "key" in
      Ok (Skill_document.Duplicate_metadata_key key)
    | "unexpected_frontmatter_field" ->
      let* () = closed [ "field" ] in
      let* field = required_string_field json "field" in
      Ok (Skill_document.Unexpected_frontmatter_field field)
    | "missing_name" ->
      let* () = closed [] in
      Ok Skill_document.Missing_name
    | "missing_description" ->
      let* () = closed [] in
      Ok Skill_document.Missing_description
    | "invalid_field_type" ->
      let* () = closed [ "field"; "expected" ] in
      let* field_json = required_object_field json "field" in
      let* field = decode_skill_document_field field_json in
      let* expected_json = required_member json "expected" in
      let* expected = decode_skill_expected_shape expected_json in
      Ok (Skill_document.Invalid_field_type { field; expected })
    | "invalid_name" ->
      let* () = closed [ "name"; "violations" ] in
      let* name = required_string_field json "name" in
      let* violations_json = required_list_field json "violations" in
      let* violations =
        decode_list
          "skill rejection diagnostic.violations"
          decode_skill_name_violation
          violations_json
      in
      Ok (Skill_document.Invalid_name { name; violations })
    | "name_mismatch" ->
      let* () = closed [ "declared"; "directory" ] in
      let* declared = required_string_field json "declared" in
      let* directory = required_string_field json "directory" in
      Ok (Skill_document.Name_mismatch { declared; directory })
    | "description_too_long" ->
      let* () = closed [ "length" ] in
      let* length = required_nonnegative_int_field json "length" in
      Ok (Skill_document.Description_too_long { length })
    | "compatibility_empty" ->
      let* () = closed [] in
      Ok Skill_document.Compatibility_empty
    | "compatibility_too_long" ->
      let* () = closed [ "length" ] in
      let* length = required_nonnegative_int_field json "length" in
      Ok (Skill_document.Compatibility_too_long { length })
    | "invalid_metadata_value" ->
      let* () = closed [ "key" ] in
      let* key = required_string_field json "key" in
      Ok (Skill_document.Invalid_metadata_value { key })
    | unknown ->
      Error (Printf.sprintf "skill diagnostic code has unknown value %S" unknown)
  in
  Ok { srd_diagnostic; srd_message }

let decode_skill_usage_row json =
  let* su_keeper = required_string_field json "keeper" in
  let* su_invocations = required_int_field json "invocations" in
  let* su_deliveries = required_int_field json "deliveries" in
  let* su_actions = required_int_field json "actions" in
  let* su_last_used_at = optional_string_field json "last_used_at" in
  Ok { su_keeper; su_invocations; su_deliveries; su_actions; su_last_used_at }

let decode_skills_catalog_surface json =
  let* reference = required_object_field json "reference" in
  let* identity = required_object_field reference "identity" in
  let* scs_name = required_string_field identity "name" in
  let* scs_kind = required_string_field json "kind" in
  let* usage_json = optional_list_field json "usage" in
  let* scs_usage = decode_list "usage" decode_skill_usage_row usage_json in
  let* scs_flow =
    match scs_kind, member "profile" json with
    | ("instruction" | "composition"), (`Assoc _ as profile) ->
        let* flow_field = required_member profile "flow" in
        (match flow_field with
         | `Null -> Ok None
         | `Assoc _ as flow ->
             decode_skill_flow flow |> Result.map Option.some
         | bad -> field_type_error "profile.flow" "an object or null" bad)
    | ("instruction" | "composition"), bad ->
      field_type_error "profile" "an object" bad
    | "unavailable", `Null -> Ok None
    | "unavailable", bad -> field_type_error "profile" "absent" bad
    | unknown, _ ->
      Error (Printf.sprintf "skills surface kind has unknown value %S" unknown)
  in
  Ok { scs_name; scs_kind; scs_usage; scs_flow }

let decode_skill_catalog_rejection json =
  let* () =
    validate_closed_object
      ~label:"skill snapshot rejection"
      ~allowed:
        [ "source_index"
        ; "source_id"
        ; "package_id"
        ; "content_revision"
        ; "reason"
        ]
      json
  in
  let* scr_source_index = required_nonnegative_int_field json "source_index" in
  let* scr_source_id = required_nonempty_string_field json "source_id" in
  let* scr_package_id =
    required_nullable_nonempty_string_field json "package_id"
  in
  let* scr_content_revision =
    required_nullable_nonempty_string_field json "content_revision"
  in
  let* reason = required_object_field json "reason" in
  let* kind = required_string_field reason "kind" in
  let* scr_reason =
    match kind with
    | "document_rejected" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind"; "diagnostics" ]
          reason
      in
      let* diagnostics_json = required_list_field reason "diagnostics" in
      let* diagnostics =
        decode_list
          "snapshot.rejections.reason.diagnostics"
          decode_skill_rejection_diagnostic
          diagnostics_json
      in
      Ok (Skill_document_rejected diagnostics)
    | "document_unreadable" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind" ]
          reason
      in
      Ok Skill_document_unreadable
    | "exact_identity_duplicate" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind" ]
          reason
      in
      Ok Skill_exact_identity_duplicate
    | "invalid_package_id" ->
      let* () =
        validate_closed_object
          ~label:"skill snapshot rejection.reason"
          ~allowed:[ "kind" ]
          reason
      in
      Ok Skill_invalid_package_id
    | unknown ->
      Error (Printf.sprintf "skill rejection kind has unknown value %S" unknown)
  in
  Ok
    { scr_source_index
    ; scr_source_id
    ; scr_package_id
    ; scr_content_revision
    ; scr_reason
    }

let decode_skill_catalog_shadow json =
  let* () =
    validate_closed_object
      ~label:"skill snapshot shadow"
      ~allowed:[ "winner"; "shadowed" ]
      json
  in
  let identity field =
    let* value = required_object_field json field in
    Skill_reference.identity_of_yojson value
    |> Result.map_error (fun _ ->
      Printf.sprintf "skill snapshot shadow %s is not an exact identity" field)
  in
  let* scsh_winner = identity "winner" in
  let* scsh_shadowed = identity "shadowed" in
  (* The snapshot pairs two entries that declare one name
     (Skill_catalog_snapshot.effective_projection). A pair with two names, or
     one identity twice, is not a shadow. *)
  if not (String.equal scsh_winner.Skill_reference.name scsh_shadowed.Skill_reference.name)
  then
    Error
      (Printf.sprintf "skill snapshot shadow pairs two names, %S and %S"
         scsh_winner.Skill_reference.name scsh_shadowed.Skill_reference.name)
  else if Skill_reference.equal_identity scsh_winner scsh_shadowed
  then Error "skill snapshot shadow names one identity as both winner and shadowed"
  else Ok { scsh_winner; scsh_shadowed }

(* Shadows and rejections are the two ways a declared Skill stays out of what
   Keeper turns see, and both are read from the same closed snapshot object. *)
let decode_skill_snapshot_shadows_and_rejections json =
  let* () =
    validate_closed_object
      ~label:"skills snapshot"
      ~allowed:
        [ "snapshot_revision"
        ; "catalog_revision"
        ; "config"
        ; "sources"
        ; "skills"
        ; "effective_skills"
        ; "shadows"
        ; "rejections"
        ]
      json
  in
  let* _snapshot_revision =
    required_nonempty_string_field json "snapshot_revision"
  in
  let* _catalog_revision =
    required_nonempty_string_field json "catalog_revision"
  in
  let* _config = required_object_field json "config" in
  let* _sources = required_list_field json "sources" in
  let* _skills = required_list_field json "skills" in
  let* _effective_skills = required_list_field json "effective_skills" in
  let* shadows_json = required_list_field json "shadows" in
  let* rejections_json = required_list_field json "rejections" in
  let* shadows =
    decode_list "snapshot.shadows" decode_skill_catalog_shadow shadows_json
  in
  let* rejections =
    decode_list
      "snapshot.rejections"
      decode_skill_catalog_rejection
      rejections_json
  in
  Ok (shadows, rejections)

(* One discovery source, as [/api/v1/skills] publishes it. The endpoint that
   the Skill editor calls answers a different question -- it filters to the
   read-write sources that resolved, because it is picking somewhere to write
   -- so a source that is missing, read-only, or refused can only be read
   here. *)
let decode_skill_catalog_source json =
  let* () =
    validate_closed_object
      ~label:"skill snapshot source"
      ~allowed:[ "id"; "anchor"; "path"; "access"; "observation" ]
      json
  in
  let* scso_id = required_nonempty_string_field json "id" in
  let* scso_anchor = required_nonempty_string_field json "anchor" in
  let* scso_path = optional_string_field json "path" in
  let* scso_access = required_nonempty_string_field json "access" in
  let* observation = required_object_field json "observation" in
  let* kind = required_string_field observation "kind" in
  let* scso_observation =
    match kind with
    | "ready" ->
      let* candidates = required_nonnegative_int_field observation "candidates" in
      Ok (Skill_source_ready candidates)
    | "missing" -> Ok Skill_source_missing
    | "not_directory" ->
      let* file_kind = required_nonempty_string_field observation "file_kind" in
      Ok (Skill_source_not_directory file_kind)
    | "unavailable" ->
      let* operation = required_nonempty_string_field observation "operation" in
      Ok (Skill_source_unavailable operation)
    | "unresolved" -> Ok Skill_source_unresolved
    | unknown ->
      Error
        (Printf.sprintf "skill source observation has unknown kind %S" unknown)
  in
  Ok { scso_id; scso_anchor; scso_path; scso_access; scso_observation }

(* The Skill section of runtime.toml as the catalog read it. A rejected
   section still leaves a working catalog, which is why it has to be said:
   nothing else on the screen changes when the operator's configuration stops
   parsing. *)
let decode_skill_catalog_config json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "configured" ->
    let* () =
      validate_closed_object
        ~label:"skill snapshot config"
        ~allowed:[ "kind"; "revision"; "resource_read_max_bytes" ]
        json
    in
    let* revision = required_nonempty_string_field json "revision" in
    let* resource_read_max_bytes =
      optional_int_field json "resource_read_max_bytes"
    in
    Ok (Skill_config_configured { revision; resource_read_max_bytes })
  | "rejected" ->
    let* () =
      validate_closed_object
        ~label:"skill snapshot config"
        ~allowed:[ "kind"; "source_revision"; "diagnostics" ]
        json
    in
    let* source_revision = required_nonempty_string_field json "source_revision" in
    let* diagnostics_json = optional_list_field json "diagnostics" in
    let* diagnostics =
      decode_list
        "snapshot.config.diagnostics"
        (fun item ->
           match item with
           | `String text -> Ok text
           | bad -> field_type_error "snapshot.config.diagnostics" "a string" bad)
        diagnostics_json
    in
    Ok (Skill_config_rejected { source_revision; diagnostics })
  | "unreadable" ->
    let* () =
      validate_closed_object
        ~label:"skill snapshot config"
        ~allowed:[ "kind" ]
        json
    in
    Ok Skill_config_unreadable
  | unknown ->
    Error (Printf.sprintf "skill snapshot config has unknown kind %S" unknown)

let decode_skill_usage_coverage json =
  let* coverage = required_object_field json "usage_coverage" in
  let* suc_ledgers_loaded =
    required_nonnegative_int_field coverage "ledgers_loaded"
  in
  let* unavailable = required_list_field coverage "unavailable" in
  let* suc_unavailable =
    decode_list "usage_coverage.unavailable"
      (function
        | `String detail -> Ok detail
        | bad -> field_type_error "usage_coverage.unavailable" "a string" bad)
      unavailable
  in
  Ok { suc_ledgers_loaded; suc_unavailable }

let decode_skills_catalog json =
  let* schema = required_string_field json "schema" in
  if not (String.equal schema "masc.skill-snapshot/v1")
  then Error (Printf.sprintf "unknown schema %S" schema)
  else
    let* state = required_string_field json "state" in
    match state with
    | "ready" ->
      let* () =
        validate_closed_object
          ~label:"response"
          ~allowed:[ "schema"; "state"; "snapshot"; "surfaces"; "usage_coverage" ]
          json
      in
      let* coverage = decode_skill_usage_coverage json in
      let* snapshot = required_object_field json "snapshot" in
      let* sc_shadows, sc_rejections =
        decode_skill_snapshot_shadows_and_rejections snapshot
      in
      let* config_json = required_object_field snapshot "config" in
      let* config = decode_skill_catalog_config config_json in
      let* sources_json = optional_list_field snapshot "sources" in
      let* sc_sources =
        decode_list "snapshot.sources" decode_skill_catalog_source sources_json
      in
      let* surfaces_json = required_list_field json "surfaces" in
      let* sc_surfaces =
        decode_list "surfaces" decode_skills_catalog_surface surfaces_json
      in
      Ok
        { sc_state = Skills_ready
        ; sc_config = Some config
        ; sc_sources
        ; sc_surfaces
        ; sc_rejections
        ; sc_shadows
        ; sc_usage_coverage = Some coverage
        }
    | "not_registered" ->
      let* () =
        validate_closed_object
          ~label:"response"
          ~allowed:[ "schema"; "state" ]
          json
      in
      Ok
        { sc_state = Skills_not_registered
        ; sc_config = None
        ; sc_sources = []
        ; sc_surfaces = []
        ; sc_rejections = []
        ; sc_shadows = []
        ; sc_usage_coverage = None
        }
    | "uninitialized" ->
      let* () =
        validate_closed_object
          ~label:"response"
          ~allowed:[ "schema"; "state" ]
          json
      in
      Ok
        { sc_state = Skills_uninitialized
        ; sc_config = None
        ; sc_sources = []
        ; sc_surfaces = []
        ; sc_rejections = []
        ; sc_shadows = []
        ; sc_usage_coverage = None
        }
    | "invalid_workspace" ->
      let* () =
        validate_closed_object
          ~label:"response"
          ~allowed:[ "schema"; "state"; "reason" ]
          json
      in
      let* reason = required_object_field json "reason" in
      let* () =
        validate_closed_object
          ~label:"reason"
          ~allowed:[ "code" ]
          reason
      in
      let* code = required_string_field reason "code" in
      if not (String.equal code "invalid_workspace")
      then Error (Printf.sprintf "invalid workspace has unknown reason %S" code)
      else
        Ok
          { sc_state = Skills_invalid_workspace
          ; sc_config = None
          ; sc_sources = []
          ; sc_surfaces = []
          ; sc_rejections = []
          ; sc_shadows = []
          ; sc_usage_coverage = None
          }
    | unknown ->
      Error (Printf.sprintf "unknown state %S" unknown)

let decode_tool_snapshot json =
  (* The tools envelope carries config and runtime resolution beside the
     inventory; this reads the inventory and leaves the rest to the dashboard,
     which has room to show it. *)
  let* inventory = required_object_field json "tool_inventory" in
  let* tools_json = required_list_field inventory "tools" in
  let* ts_tools = decode_list "tools" decode_tool_entry tools_json in
  let* ts_count = required_int_field inventory "count" in
  (* Only the warming placeholder carries this flag, and it carries it as
     [true]; a payload built from a real inventory does not mention it. So an
     absent flag is a built inventory, and the pane can tell "the server has
     not looked yet" apart from "there are none" -- which it could not, and so
     reported a warming server as a workspace with no tools registered. *)
  let* warming = optional_bool_field json "is_warming" in
  let ts_freshness =
    match warming with Some true -> Warming | Some false | None -> Settled
  in
  let* effective_json = required_member json "effective_keeper_surface" in
  let* ts_effective =
    match effective_json with
    | `Null -> Ok None
    | `Assoc _ as value ->
        Result.map Option.some (decode_effective_tool_surface value)
    | bad -> field_type_error "effective_keeper_surface" "an object or null" bad
  in
  let* skill_activations_json = required_member json "skill_activations" in
  let* ts_skill_activations =
    match skill_activations_json with
    | `Null -> Ok None
    | `Assoc _ as value ->
        Result.map Option.some (decode_skill_activation_projection value)
    | bad -> field_type_error "skill_activations" "an object or null" bad
  in
  Ok
    { ts_tools
    ; ts_count
    ; ts_freshness
    ; ts_effective
    ; ts_skill_activations
    }
