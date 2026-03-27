(* CDAL proof bundle decoder -- MASC-side consumer of OAS proof manifests.

   Boundary rule: no OAS type imports. JSON is the interface.
   See cdal_proof_decoder.mli for invariants I1/I2/I3. *)

(* {1 Types -- independent of OAS, coupled at JSON schema level} *)

type result_status =
  | Completed
  | Errored
  | Timed_out
  | Cancelled

type execution_mode =
  | Diagnose
  | Draft
  | Execute

type risk_class =
  | Low
  | Medium
  | High
  | Critical

type provider_snapshot = {
  provider_name : string;
  model_id : string;
  api_version : string option;
}

type capability_snapshot = {
  tools : string list;
  mcp_servers : string list;
  max_turns : int;
  max_tokens : int option;
  thinking_enabled : bool option;
}

type artifact_ref = string

type proof_manifest = {
  schema_version : int;
  run_id : string;
  contract_id : string;
  requested_execution_mode : execution_mode;
  effective_execution_mode : execution_mode;
  mode_decision_source : string;
  risk_class : risk_class;
  provider_snapshot : provider_snapshot;
  capability_snapshot : capability_snapshot;
  tool_trace_refs : artifact_ref list;
  raw_evidence_refs : artifact_ref list;
  checkpoint_ref : artifact_ref option;
  result_status : result_status;
  started_at : float;
  ended_at : float;
}

type decode_error =
  | Schema_version_unsupported of int
  | Missing_field of string
  | Invalid_field of { field : string; reason : string }
  | Json_parse_error of string

let pp_decode_error fmt = function
  | Schema_version_unsupported v ->
    Format.fprintf fmt "Schema_version_unsupported(%d)" v
  | Missing_field f ->
    Format.fprintf fmt "Missing_field(%s)" f
  | Invalid_field { field; reason } ->
    Format.fprintf fmt "Invalid_field(%s: %s)" field reason
  | Json_parse_error msg ->
    Format.fprintf fmt "Json_parse_error(%s)" msg

let decode_error_to_string err =
  Format.asprintf "%a" pp_decode_error err

type evidence_gap = {
  run_id : string option;
  missing_fields : string list;
  invalid_fields : (string * string) list;
  raw_json_excerpt : string;
}

let schema_version_supported = 1

(* {1 JSON helpers} *)

let member key json =
  match json with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

let require_string field json =
  match member field json with
  | Some (`String s) -> Ok s
  | Some `Null -> Error (Missing_field field)
  | Some other ->
    Error (Invalid_field { field; reason =
      Printf.sprintf "expected string, got %s"
        (Yojson.Safe.to_string other) })
  | None -> Error (Missing_field field)

let require_int field json =
  match member field json with
  | Some (`Int i) -> Ok i
  | Some (`Float f) when Float.is_integer f -> Ok (Float.to_int f)
  | Some `Null -> Error (Missing_field field)
  | Some other ->
    Error (Invalid_field { field; reason =
      Printf.sprintf "expected int, got %s"
        (Yojson.Safe.to_string other) })
  | None -> Error (Missing_field field)

let require_float field json =
  match member field json with
  | Some (`Float f) -> Ok f
  | Some (`Int i) -> Ok (Float.of_int i)
  | Some `Null -> Error (Missing_field field)
  | Some other ->
    Error (Invalid_field { field; reason =
      Printf.sprintf "expected float, got %s"
        (Yojson.Safe.to_string other) })
  | None -> Error (Missing_field field)

let optional_string field json =
  match member field json with
  | Some (`String s) -> Ok (Some s)
  | Some `Null | None -> Ok None
  | Some other ->
    Error (Invalid_field { field; reason =
      Printf.sprintf "expected string or null, got %s"
        (Yojson.Safe.to_string other) })

let optional_int field json =
  match member field json with
  | Some (`Int i) -> Ok (Some i)
  | Some (`Float f) when Float.is_integer f -> Ok (Some (Float.to_int f))
  | Some `Null | None -> Ok None
  | Some other ->
    Error (Invalid_field { field; reason =
      Printf.sprintf "expected int or null, got %s"
        (Yojson.Safe.to_string other) })

let optional_bool field json =
  match member field json with
  | Some (`Bool b) -> Ok (Some b)
  | Some `Null | None -> Ok None
  | Some other ->
    Error (Invalid_field { field; reason =
      Printf.sprintf "expected bool or null, got %s"
        (Yojson.Safe.to_string other) })

let require_string_list field json =
  match member field json with
  | Some (`List items) ->
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: rest -> go (s :: acc) rest
      | other :: _ ->
        Error (Invalid_field { field; reason =
          Printf.sprintf "list item is not a string: %s"
            (Yojson.Safe.to_string other) })
    in
    go [] items
  | Some `Null -> Error (Missing_field field)
  | Some other ->
    Error (Invalid_field { field; reason =
      Printf.sprintf "expected list, got %s"
        (Yojson.Safe.to_string other) })
  | None -> Error (Missing_field field)

(* {1 Enum decoders} *)

let result_status_of_string = function
  | "completed" -> Ok Completed
  | "errored" -> Ok Errored
  | "timed_out" -> Ok Timed_out
  | "cancelled" -> Ok Cancelled
  | s -> Error (Invalid_field { field = "result_status";
                                reason = Printf.sprintf "unknown value: %s" s })

let execution_mode_of_string field = function
  | "diagnose" -> Ok Diagnose
  | "draft" -> Ok Draft
  | "execute" -> Ok Execute
  | s -> Error (Invalid_field { field;
                                reason = Printf.sprintf "unknown mode: %s" s })

let risk_class_of_string = function
  | "low" -> Ok Low
  | "medium" -> Ok Medium
  | "high" -> Ok High
  | "critical" -> Ok Critical
  | s -> Error (Invalid_field { field = "risk_class";
                                reason = Printf.sprintf "unknown class: %s" s })

(* {1 Sub-record decoders} *)

let decode_provider_snapshot json =
  match member "provider_snapshot" json with
  | None -> Error (Missing_field "provider_snapshot")
  | Some ps ->
    let ( let* ) = Result.bind in
    let* provider_name = require_string "provider_name" ps in
    let* model_id = require_string "model_id" ps in
    let* api_version = optional_string "api_version" ps in
    Ok { provider_name; model_id; api_version }

let decode_capability_snapshot json =
  match member "capability_snapshot" json with
  | None -> Error (Missing_field "capability_snapshot")
  | Some cs ->
    let ( let* ) = Result.bind in
    let* tools = require_string_list "tools" cs in
    let* mcp_servers = require_string_list "mcp_servers" cs in
    let* max_turns = require_int "max_turns" cs in
    let* max_tokens = optional_int "max_tokens" cs in
    let* thinking_enabled = optional_bool "thinking_enabled" cs in
    Ok { tools; mcp_servers; max_turns; max_tokens; thinking_enabled }

(* {1 Main decoder -- Invariant I1: total, no exceptions} *)

let of_json json =
  let ( let* ) = Result.bind in
  (* I3: schema version guard first *)
  let* sv = require_int "schema_version" json in
  if sv <> schema_version_supported then
    Error (Schema_version_unsupported sv)
  else
    let* run_id = require_string "run_id" json in
    let* contract_id = require_string "contract_id" json in
    let* req_mode_str = require_string "requested_execution_mode" json in
    let* requested_execution_mode =
      execution_mode_of_string "requested_execution_mode" req_mode_str in
    let* eff_mode_str = require_string "effective_execution_mode" json in
    let* effective_execution_mode =
      execution_mode_of_string "effective_execution_mode" eff_mode_str in
    let* mode_decision_source = require_string "mode_decision_source" json in
    let* risk_class_str = require_string "risk_class" json in
    let* risk_class = risk_class_of_string risk_class_str in
    let* provider_snapshot = decode_provider_snapshot json in
    let* capability_snapshot = decode_capability_snapshot json in
    let* tool_trace_refs = require_string_list "tool_trace_refs" json in
    let* raw_evidence_refs = require_string_list "raw_evidence_refs" json in
    let* checkpoint_ref = optional_string "checkpoint_ref" json in
    let* result_status_str = require_string "result_status" json in
    let* result_status = result_status_of_string result_status_str in
    let* started_at = require_float "started_at" json in
    let* ended_at = require_float "ended_at" json in
    Ok {
      schema_version = sv;
      run_id;
      contract_id;
      requested_execution_mode;
      effective_execution_mode;
      mode_decision_source;
      risk_class;
      provider_snapshot;
      capability_snapshot;
      tool_trace_refs;
      raw_evidence_refs;
      checkpoint_ref;
      result_status;
      started_at;
      ended_at;
    }

(* {1 Encoder -- for Invariant I2 roundtrip} *)

let result_status_to_string = function
  | Completed -> "completed"
  | Errored -> "errored"
  | Timed_out -> "timed_out"
  | Cancelled -> "cancelled"

let execution_mode_to_string = function
  | Diagnose -> "diagnose"
  | Draft -> "draft"
  | Execute -> "execute"

let risk_class_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"

let option_to_json f = function
  | None -> `Null
  | Some v -> f v

let to_json m =
  `Assoc [
    "schema_version", `Int m.schema_version;
    "run_id", `String m.run_id;
    "contract_id", `String m.contract_id;
    "requested_execution_mode",
      `String (execution_mode_to_string m.requested_execution_mode);
    "effective_execution_mode",
      `String (execution_mode_to_string m.effective_execution_mode);
    "mode_decision_source", `String m.mode_decision_source;
    "risk_class", `String (risk_class_to_string m.risk_class);
    "provider_snapshot", `Assoc [
      "provider_name", `String m.provider_snapshot.provider_name;
      "model_id", `String m.provider_snapshot.model_id;
      "api_version",
        option_to_json (fun s -> `String s) m.provider_snapshot.api_version;
    ];
    "capability_snapshot", `Assoc [
      "tools", `List (List.map (fun s -> `String s) m.capability_snapshot.tools);
      "mcp_servers",
        `List (List.map (fun s -> `String s) m.capability_snapshot.mcp_servers);
      "max_turns", `Int m.capability_snapshot.max_turns;
      "max_tokens",
        option_to_json (fun i -> `Int i) m.capability_snapshot.max_tokens;
      "thinking_enabled",
        option_to_json (fun b -> `Bool b) m.capability_snapshot.thinking_enabled;
    ];
    "tool_trace_refs",
      `List (List.map (fun s -> `String s) m.tool_trace_refs);
    "raw_evidence_refs",
      `List (List.map (fun s -> `String s) m.raw_evidence_refs);
    "checkpoint_ref",
      option_to_json (fun s -> `String s) m.checkpoint_ref;
    "result_status", `String (result_status_to_string m.result_status);
    "started_at", `Float m.started_at;
    "ended_at", `Float m.ended_at;
  ]

(* {1 Evidence gap extraction -- antifragile learning} *)

let json_excerpt json =
  let s = Yojson.Safe.to_string json in
  if String.length s > 200 then String.sub s 0 200 ^ "..." else s

let evidence_gap_of_error ~json err =
  let run_id =
    match member "run_id" json with
    | Some (`String s) -> Some s
    | _ -> None
  in
  match err with
  | Schema_version_unsupported v ->
    { run_id;
      missing_fields = [];
      invalid_fields = ["schema_version",
        Printf.sprintf "unsupported version %d (supported: %d)"
          v schema_version_supported];
      raw_json_excerpt = json_excerpt json }
  | Missing_field f ->
    { run_id; missing_fields = [f]; invalid_fields = [];
      raw_json_excerpt = json_excerpt json }
  | Invalid_field { field; reason } ->
    { run_id; missing_fields = []; invalid_fields = [field, reason];
      raw_json_excerpt = json_excerpt json }
  | Json_parse_error msg ->
    { run_id; missing_fields = []; invalid_fields = ["_json", msg];
      raw_json_excerpt = json_excerpt json }

(* {1 Helpers} *)

let execution_mode_to_int = function
  | Diagnose -> 0
  | Draft -> 1
  | Execute -> 2

let was_downgraded m =
  execution_mode_to_int m.effective_execution_mode
  < execution_mode_to_int m.requested_execution_mode

let duration_s m = m.ended_at -. m.started_at
