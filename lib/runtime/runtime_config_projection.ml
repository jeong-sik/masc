open Runtime_config_error
open Result.Syntax

type config_source_revision = Config_source_revision of string
type config_commit_order = Config_commit_order of int64

type config_observation =
  { path : string
  ; source_text : string
  ; source_revision : config_source_revision
  }

type config_edit_error =
  | Config_source_conflict of config_observation
  | Config_edit_failed of string

type config_durability =
  | Durable
  | Durability_unconfirmed of { detail : string }

type config_commit_error =
  | Config_commit_refused of string
  | Config_commit_write_failed of Fs_compat.atomic_replace_failure

(* Where the exact-output registry reads its targets. The server builds them
   from runtime.toml's HTTP bindings, unless [AGENT_CORE_MODEL_CATALOG] names a
   full replacement catalog, whose [[targets]] rows are then the whole set and
   carry their own [body_timeout_s] ([Runtime.exact_output_resolver_catalog] reads
   this same answer for boot and every config commit). An empty or blank
   value names no file, as it always has for this variable. *)
type exact_output_target_source =
  | Runtime_binding_targets
  | Replacement_catalog_targets of { path : string }

type exact_output_registry_application =
  | Exact_output_registry_replaced of { origin : exact_output_target_source }
  | Exact_output_registry_unpublished
  | Exact_output_registry_kept of
      { reason : Runtime_exact_output_registry.publication_error }

(* The registry a config commit kept because neither the committed text nor
   the file it replaced rebuilds one. It keeps serving, but the file on disk
   now publishes no registry at the next boot, so health reports it until a
   later commit replaces the registry. *)
type exact_output_registry_stale =
  { stale_reason : Runtime_exact_output_registry.publication_error
  ; stale_since_commit : config_commit_order
  }

type config_commit_receipt =
  { observation : config_observation
  ; durability : config_durability
  ; order : config_commit_order
  ; lock_warnings : config_lock_warning list
  ; exact_output_registry : exact_output_registry_application
  }

and config_lock_warning =
  | Config_lock_release_unconfirmed of string

type keeper_assignment_state =
  | Assignment_missing
  | Assignment_present of string

type keeper_assignment_revision =
  | Runtime_config_missing
  | Runtime_config_present of
      { source_revision : config_source_revision
      ; assignment : keeper_assignment_state
      }

type keeper_assignment_cas_error =
  | Assignment_revision_conflict of keeper_assignment_revision
  | Assignment_io_error of string

type lane_set_error =
  | Lane_set_revision_conflict of { expected : string; observed : string }
  | Lane_set_invalid of string

type keeper_assignment_write =
  | Assignment_unchanged of keeper_assignment_revision
  | Assignment_committed of
      { receipt : config_commit_receipt
      ; revision : keeper_assignment_revision
      }

type keeper_assignment_transaction =
  | Missing_runtime_config of { keeper_name : string }
  | Present_runtime_config of
      { path : string
      ; source_text : string
      ; keeper_name : string
      ; revision : keeper_assignment_revision
      }

type 'a config_lock_receipt =
  { value : 'a
  ; warnings : config_lock_warning list
  }

let config_source_revision_to_string (Config_source_revision revision) = revision
let lane_set_error_to_string = function
  | Lane_set_revision_conflict { expected; observed } ->
    Printf.sprintf
      "runtime.toml changed since the lane candidates were read (expected %s, observed %s); reload before editing"
      expected observed
  | Lane_set_invalid detail -> detail
;;
let config_commit_order_to_string (Config_commit_order order) = Int64.to_string order
let compare_config_commit_order (Config_commit_order left) (Config_commit_order right) =
  Int64.compare left right
;;

let config_lock_warning_to_yojson = function
  | Config_lock_release_unconfirmed detail ->
    `Assoc
      [ "code", `String "runtime_config_lock_release_unconfirmed"
      ; "detail", `String detail
      ]
;;

let keeper_assignment_state_to_yojson = function
  | Assignment_missing -> `Assoc [ "state", `String "missing" ]
  | Assignment_present runtime_id ->
    `Assoc [ "state", `String "assigned"; "runtime_id", `String runtime_id ]
;;

let keeper_assignment_revision_to_yojson revision =
  match revision with
  | Runtime_config_missing -> `Assoc [ "state", `String "runtime_config_missing" ]
  | Runtime_config_present { source_revision; assignment } ->
    `Assoc
      [ "state", `String "runtime_config_present"
      ; "source_revision", `String (config_source_revision_to_string source_revision)
      ; "assignment", keeper_assignment_state_to_yojson assignment
      ]
;;

let keeper_assignment_revision_of_yojson = function
  | `Assoc [ ("state", `String "runtime_config_missing") ] ->
    Ok Runtime_config_missing
  | `Assoc fields ->
    let source_revision =
      match List.assoc_opt "source_revision" fields with
      | Some (`String value) when String_util.is_lowercase_sha256_hex value ->
        Ok (Config_source_revision value)
      | Some _ -> Error "runtime assignment source_revision must be lowercase SHA-256 hex"
      | None -> Error "runtime assignment source_revision is required"
    in
    let assignment =
      match List.assoc_opt "assignment" fields with
      | Some (`Assoc assignment_fields) ->
        (match List.assoc_opt "state" assignment_fields with
         | Some (`String "missing") when List.length assignment_fields = 1 ->
           Ok Assignment_missing
         | Some (`String "assigned") ->
           (match assignment_fields with
            | [ ("state", `String "assigned"); ("runtime_id", `String runtime_id) ]
            | [ ("runtime_id", `String runtime_id); ("state", `String "assigned") ]
              when String.trim runtime_id <> "" ->
              Ok (Assignment_present runtime_id)
            | _ -> Error "assigned runtime revision requires only runtime_id")
         | Some (`String state) ->
           Error (Printf.sprintf "unsupported runtime assignment state: %S" state)
         | Some _ -> Error "runtime assignment state must be a string"
         | None -> Error "runtime assignment state is required")
      | Some _ -> Error "runtime assignment revision must be an object"
      | None -> Error "runtime assignment revision is required"
    in
    let* source_revision = source_revision in
    let* assignment = assignment in
    if List.assoc_opt "state" fields <> Some (`String "runtime_config_present")
    then Error "runtime assignment revision state must be runtime_config_present"
    else if List.length fields <> 3
    then Error "runtime assignment revision has unexpected fields"
    else Ok (Runtime_config_present { source_revision; assignment })
  | _ -> Error "runtime assignment revision must be an object"
;;

let config_source_revision_of_text source_text =
  let digest =
    Digestif.SHA256.(to_hex (digest_string ("runtime_config_source\x00" ^ source_text)))
  in
  Config_source_revision digest

let config_observation ~path source_text =
  { path; source_text; source_revision = config_source_revision_of_text source_text }
;;

(* Explain why a validation target [id] is absent from the materialized
   [runtimes]. An [id] present in [dropped_bindings] was defined but failed to
   materialize — surface that reason (the actionable cause). An [id] absent from
   both is a genuine operator typo and keeps the original "not found among N
   runtimes" wording. The result is the suffix that follows the quoted id in
   each caller's message, so the existing prefix ("[runtime.assignments].<k> =
   <id>") is preserved and the typo case stays byte-for-byte unchanged. *)

(** TOML 에서 Runtime 목록과 default Runtime 을 로드한다.

    fail-fast: [\[runtime\] default] 가 없거나 그 id 가 목록에 없으면 [Error].
    silent fallback 일절 없음 (runtime→Runtime 비전: TOML 에 default 없으면
    프로그램 실행 불가). *)
type missing_catalog_model =
  { runtime_id : string
  ; provider_id : string
  ; provider_label : string
  ; model_id : string
  }

type missing_catalog_report =
  { config_path : string
  ; missing_models : missing_catalog_model list
  }

type unavailable_runtime_assignment =
  { keeper_name : string
  ; runtime_id : string
  }

type dropped_runtime_route =
  { route_name : string
  ; runtime_id : string
  }

type dropped_runtime_lane =
  { lane_id : string
  ; runtime_ids : string list
  }

type startup_degradation =
  { report : missing_catalog_report
  ; configured_default_runtime_id : string
  ; disabled_runtime_ids : string list
  ; unavailable_assignments : unavailable_runtime_assignment list
  }

type init_default_outcome =
  | Initialized
  | Initialized_degraded of startup_degradation

type strict_init_error =
  | Runtime_config_error of string
  | Missing_catalog_models of missing_catalog_report

let missing_catalog_model_to_string (missing : missing_catalog_model) =
  Printf.sprintf
    "%s (provider_label=%s, model=%s)"
    missing.runtime_id
    missing.provider_label
    missing.model_id
;;

let missing_catalog_report_to_string (report : missing_catalog_report) =
  Printf.sprintf
    "%s: %d runtime model(s) absent from the AGENT_CORE capability catalog; they \
     would use provider_default and silently drop thinking/sampling control. \
     Add a row for each to the AGENT_CORE embedded catalog: %s"
    report.config_path
    (List.length report.missing_models)
    (String.concat ", " (List.map missing_catalog_model_to_string report.missing_models))
;;

let strict_init_error_to_string = function
  | Runtime_config_error msg -> msg
  | Missing_catalog_models report -> missing_catalog_report_to_string report
;;

let startup_degradation_to_string (degradation : startup_degradation) =
  Printf.sprintf
    "runtime catalog degraded boot: disabled %d uncatalogued runtime(s); \
     default %S; unavailable configured routes: %s"
    (List.length degradation.disabled_runtime_ids)
    degradation.configured_default_runtime_id
    (String.concat ", "
       (List.map missing_catalog_model_to_string degradation.report.missing_models))
;;

let unavailable_assignment_to_yojson (entry : unavailable_runtime_assignment) =
  `Assoc
    [ "keeper_name", `String entry.keeper_name
    ; "runtime_id", `String entry.runtime_id
    ]
;;

let missing_catalog_model_to_yojson (entry : missing_catalog_model) =
  `Assoc
    [ "runtime_id", `String entry.runtime_id
    ; "provider_id", `String entry.provider_id
    ; "provider_label", `String entry.provider_label
    ; "model_id", `String entry.model_id
    ]
;;

(* Rule 2 (catalog-missing bindings) and rule 3 (exact slots without a body
   deadline) both leave the server running with less than the file declared,
   so both are said here, the one report health, the runtime inventory and
   the dashboard already read. The key set is the same in every case so a
   reader never has to guess which shape it got. [status_reasons] and
   [operator_action_reasons] name every cause present, so the health rollup
   says both when both happen; [terminal_reason] keeps naming the catalog
   when it is one of them. *)
let catalog_degradation_reason = "missing_agent_core_catalog_models"
let exact_slot_degradation_reason = "exact_slot_body_deadline_absent"
let exact_registry_stale_reason = "exact_output_registry_stale"

let exact_output_registry_stale_message (stale : exact_output_registry_stale) =
  Printf.sprintf
    "the exact-output registry kept since config commit %s no longer matches \
     runtime.toml, and the file on disk publishes no registry at the next boot: %s"
    (config_commit_order_to_string stale.stale_since_commit)
    (Runtime_exact_output_registry.publication_error_to_string stale.stale_reason)
;;

let exact_output_registry_stale_to_yojson = function
  | None -> `Null
  | Some (stale : exact_output_registry_stale) ->
    `Assoc
      [ ( "reason"
        , `String (Runtime_exact_output_registry.publication_error_to_string stale.stale_reason) )
      ; ( "kept_since_commit"
        , `String (config_commit_order_to_string stale.stale_since_commit) )
      ; "message", `String (exact_output_registry_stale_message stale)
      ]
;;

let startup_degradation_to_yojson
    ~(exact_slots : exact_slot_degradation)
    ~(exact_registry_stale : exact_output_registry_stale option)
    (degradation : startup_degradation option)
  =
  let gaps_json =
    [ ( "exact_slot_body_deadline_gaps"
      , `List (List.map exact_slot_body_deadline_gap_to_yojson exact_slots.gaps) )
    ; ( "exact_lanes_emptied_by_body_deadline_gaps"
      , `List (List.map (fun id -> `String id) exact_slots.emptied_lane_ids) )
    ]
  in
  let gaps_message =
    let slots = List.map exact_slot_body_deadline_gap_to_string exact_slots.gaps in
    let lanes =
      List.map
        (Printf.sprintf
           "exact-output lane %S is unavailable: every slot is left out and it \
            declares no cli_slots")
        exact_slots.emptied_lane_ids
    in
    String.concat "; " (slots @ lanes)
  in
  let gaps_next_action =
    Printf.sprintf
      "Add %s to each named provider. Until then those exact-output slots are \
       left out of their lanes; a lane with nothing left walks its cli_slots, \
       and a lane with no cli_slots is unavailable."
      Runtime_schema.exact_body_timeout_s_key
  in
  let reasons_json reasons =
    let json = `List (List.map (fun reason -> `String reason) reasons) in
    [ "status_reasons", json; "operator_action_reasons", json ]
  in
  let exact_json =
    gaps_json
    @ [ "exact_output_registry_stale", exact_output_registry_stale_to_yojson exact_registry_stale ]
  in
  (* Each exact-output cause present, in the order its reason is listed:
     (reason, message, next action). *)
  let exact_parts =
    (match exact_slots.gaps with
     | [] -> []
     | _ :: _ -> [ exact_slot_degradation_reason, gaps_message, gaps_next_action ])
    @
    match exact_registry_stale with
    | None -> []
    | Some stale ->
      [ ( exact_registry_stale_reason
        , exact_output_registry_stale_message stale
        , "Fix runtime.toml so it rebuilds the exact-output registry and save it; \
           a restart before that leaves exact output unavailable." )
      ]
  in
  let reasons parts = List.map (fun (reason, _, _) -> reason) parts in
  let messages parts = List.map (fun (_, message, _) -> message) parts in
  let next_actions parts = List.map (fun (_, _, next_action) -> next_action) parts in
  match degradation, exact_parts with
  | None, [] ->
    `Assoc
      ([ "schema", `String "masc.runtime_startup_degradation.v1"
       ; "status", `String "ok"
       ; "degraded", `Bool false
       ; "operator_action_required", `Bool false
       ; "terminal_reason", `String "none"
       ; "missing_catalog_model_count", `Int 0
       ; "disabled_runtime_ids", `List []
       ]
       @ reasons_json []
       @ exact_json)
  | None, ((terminal_reason, _, _) :: _ as parts) ->
    `Assoc
      ([ "schema", `String "masc.runtime_startup_degradation.v1"
       ; "status", `String "degraded"
       ; "degraded", `Bool true
       ; "operator_action_required", `Bool true
       ; "terminal_reason", `String terminal_reason
       ; "message", `String (String.concat "; " (messages parts))
       ; "missing_catalog_model_count", `Int 0
       ; "disabled_runtime_ids", `List []
       ]
       @ reasons_json (reasons parts)
       @ exact_json
       @ [ "next_action", `String (String.concat " " (next_actions parts)) ])
  | Some degradation, parts ->
    let catalog_message = startup_degradation_to_string degradation in
    let catalog_next_action =
      "Inspect the unavailable configured runtime IDs and their capability catalog entries. \
       Explicit Keeper assignments remain unchanged and unavailable assignments cannot dispatch."
    in
    `Assoc
      ([ "schema", `String "masc.runtime_startup_degradation.v1"
       ; "status", `String "degraded"
       ; "degraded", `Bool true
       ; "operator_action_required", `Bool true
       ; "terminal_reason", `String catalog_degradation_reason
       ; "message", `String (String.concat "; " (catalog_message :: messages parts))
       ; "config_path", `String degradation.report.config_path
       ; "configured_default_runtime_id"
         , `String degradation.configured_default_runtime_id
       ; "missing_catalog_model_count", `Int (List.length degradation.report.missing_models)
       ; ( "missing_catalog_models"
         , `List (List.map missing_catalog_model_to_yojson degradation.report.missing_models)
         )
       ; ( "disabled_runtime_ids"
         , `List (List.map (fun id -> `String id) degradation.disabled_runtime_ids)
         )
       ; ( "unavailable_assignments"
         , `List (List.map unavailable_assignment_to_yojson degradation.unavailable_assignments)
         )
       ]
       @ reasons_json (catalog_degradation_reason :: reasons parts)
       @ exact_json
       @ [ "next_action", `String (String.concat " " (catalog_next_action :: next_actions parts)) ])
;;
