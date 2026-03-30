(** Governance_v2_serde - JSON serialization and file I/O helpers for
    governance V2 types.

    Covers to_yojson / of_yojson for action_request, petition, case_record,
    case_brief, ruling, and execution_order. Also includes path helpers,
    file I/O, and normalization utilities. *)

open Yojson.Safe.Util
open Result_syntax

include Governance_v2_types

(* ================================================================ *)
(* File I/O helpers                                                  *)
(* ================================================================ *)

let read_file_safe path =
  try Ok (Fs_compat.load_file path)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let parse_json_safe ~context content =
  try Ok (Yojson.Safe.from_string content)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printf.sprintf "%s: %s" context (Printexc.to_string e))

let list_dir_safe dir =
  try Ok (Array.to_list (Sys.readdir dir))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let rec ensure_dir path =
  if not (Sys.file_exists path) then (
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then ensure_dir parent;
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let is_json_file path =
  Filename.check_suffix path ".json"

let write_json path json =
  let content = Yojson.Safe.pretty_to_string json in
  let dir = Filename.dirname path in
  let base = Filename.basename path in
  let tmp_path =
    Filename.concat dir (Printf.sprintf ".%s.tmp.%d" base (Unix.getpid ()))
  in
  match
    Fs_compat.save_file tmp_path content;
    Sys.rename tmp_path path
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as e) ->
      (try Sys.remove tmp_path with Sys_error _ -> ());
      raise e
  | exception exn ->
      (try Sys.remove tmp_path with Sys_error _ -> ());
      raise exn

let read_json path =
  match read_file_safe path with
  | Error _ -> None
  | Ok content -> (
      match parse_json_safe ~context:path content with
      | Ok json -> Some json
      | Error _ -> None)

let now_unix () = Time_compat.now ()

let generate_id prefix =
  let ts = int_of_float (now_unix () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF in
  Printf.sprintf "%s-%d-%06x" prefix ts hash

(* ================================================================ *)
(* JSON serialization                                                *)
(* ================================================================ *)

let risk_class_to_string = function
  | Low -> "low"
  | High -> "high"

let risk_class_of_string = function
  | "low" -> Ok Low
  | "high" -> Ok High
  | value -> Error (Printf.sprintf "Unknown risk_class: %s" value)

let brief_stance_to_string = function
  | Support -> "support"
  | Oppose -> "oppose"
  | Neutral -> "neutral"

let brief_stance_of_string = function
  | "support" -> Ok Support
  | "oppose" -> Ok Oppose
  | "neutral" -> Ok Neutral
  | value -> Error (Printf.sprintf "Unknown brief stance: %s" value)

let case_status_to_string = function
  | Pending_ruling -> "pending_ruling"
  | Ready_auto_execute -> "ready_auto_execute"
  | Needs_human_gate -> "needs_human_gate"
  | Executed -> "executed"
  | Blocked -> "blocked"
  | Closed -> "closed"

let case_status_of_string = function
  | "pending_ruling" -> Ok Pending_ruling
  | "ready_auto_execute" -> Ok Ready_auto_execute
  | "needs_human_gate" -> Ok Needs_human_gate
  | "executed" -> Ok Executed
  | "blocked" -> Ok Blocked
  | "closed" -> Ok Closed
  | value -> Error (Printf.sprintf "Unknown case status: %s" value)

let order_status_to_string = function
  | Queued_auto -> "queued_auto"
  | Needs_human_gate_order -> "needs_human_gate"
  | Auto_executed -> "auto_executed"
  | Done -> "done"
  | Denied -> "denied"
  | Blocked_order -> "blocked"

let order_status_of_string = function
  | "queued_auto" -> Ok Queued_auto
  | "needs_human_gate" -> Ok Needs_human_gate_order
  | "auto_executed" -> Ok Auto_executed
  | "done" -> Ok Done
  | "denied" -> Ok Denied
  | "blocked" -> Ok Blocked_order
  | value -> Error (Printf.sprintf "Unknown execution order status: %s" value)

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let string_opt_json = Json_util.string_opt_to_json
let float_opt_json = Json_util.float_opt_to_json

let action_request_to_yojson (request : action_request) =
  let fields =
    [
      ("action_type", `String request.action_type);
      ("target_type", string_opt_json request.target_type);
      ("target_id", string_opt_json request.target_id);
      ( "payload",
        match request.payload with
        | Some payload -> payload
        | None -> `Null );
    ]
  in
  `Assoc fields

let action_request_of_yojson json =
  try
    let action_type = json |> member "action_type" |> to_string |> String.trim in
    if action_type = "" then Error "action_type is required"
    else
      let payload =
        match json |> member "payload" with
        | `Null -> None
        | (`Assoc _ | `List _ | `String _ | `Bool _ | `Int _ | `Intlit _ | `Float _) as value ->
            Some value
      in
      Ok
        {
          action_type;
          target_type = json |> member "target_type" |> to_string_option;
          target_id = json |> member "target_id" |> to_string_option;
          payload;
        }
  with Type_error (msg, _) -> Error msg

let petition_to_yojson (petition : petition) =
  `Assoc
    [
      ("id", `String petition.id);
      ("case_id", `String petition.case_id);
      ("title", `String petition.title);
      ("normalized_key", `String petition.normalized_key);
      ("origin", `String petition.origin);
      ("subject_type", `String petition.subject_type);
      ("risk_class", `String (risk_class_to_string petition.risk_class));
      ( "requested_action",
        match petition.requested_action with
        | Some value -> action_request_to_yojson value
        | None -> `Null );
      ("source_refs", string_list_json petition.source_refs);
      ("created_by", `String petition.created_by);
      ("created_at", `Float petition.created_at);
    ]

let petition_of_yojson json =
  let* risk_class =
    json |> member "risk_class" |> to_string |> String.lowercase_ascii
    |> risk_class_of_string
  in
  let requested_action =
    match json |> member "requested_action" with
    | `Null -> Ok None
    | (`Assoc _ as value) ->
        let* request = action_request_of_yojson value in
        Ok (Some request)
    | _ -> Error "requested_action must be an object"
  in
  let* requested_action = requested_action in
  Ok
    {
      id = json |> member "id" |> to_string;
      case_id = json |> member "case_id" |> to_string;
      title = json |> member "title" |> to_string;
      normalized_key = json |> member "normalized_key" |> to_string;
      origin = json |> member "origin" |> to_string;
      subject_type = json |> member "subject_type" |> to_string;
      risk_class;
      requested_action;
      source_refs = json |> member "source_refs" |> to_list |> List.map to_string;
      created_by = json |> member "created_by" |> to_string;
      created_at = json |> member "created_at" |> to_float;
    }

let case_brief_to_yojson (brief : case_brief) =
  `Assoc
    [
      ("id", `String brief.id);
      ("author", `String brief.author);
      ("stance", `String (brief_stance_to_string brief.stance));
      ("summary", `String brief.summary);
      ("evidence_refs", string_list_json brief.evidence_refs);
      ("created_at", `Float brief.created_at);
    ]

let case_brief_of_yojson json =
  let* stance =
    json |> member "stance" |> to_string |> String.lowercase_ascii
    |> brief_stance_of_string
  in
  Ok
    {
      id = json |> member "id" |> to_string;
      author = json |> member "author" |> to_string;
      stance;
      summary = json |> member "summary" |> to_string;
      evidence_refs = json |> member "evidence_refs" |> to_list |> List.map to_string;
      created_at = json |> member "created_at" |> to_float;
    }

let case_to_yojson (case_ : case_record) =
  `Assoc
    [
      ("id", `String case_.id);
      ("petition_ids", string_list_json case_.petition_ids);
      ("title", `String case_.title);
      ("normalized_key", `String case_.normalized_key);
      ("origin", `String case_.origin);
      ("subject_type", `String case_.subject_type);
      ("risk_class", `String (risk_class_to_string case_.risk_class));
      ("status", `String (case_status_to_string case_.status));
      ("created_at", `Float case_.created_at);
      ("updated_at", `Float case_.updated_at);
      ( "requested_action",
        match case_.requested_action with
        | Some value -> action_request_to_yojson value
        | None -> `Null );
      ("source_refs", string_list_json case_.source_refs);
      ("briefs", `List (List.map case_brief_to_yojson case_.briefs));
    ]


let case_of_yojson json =
  let* risk_class =
    json |> member "risk_class" |> to_string |> String.lowercase_ascii
    |> risk_class_of_string
  in
  let* status =
    json |> member "status" |> to_string |> String.lowercase_ascii
    |> case_status_of_string
  in
  let requested_action =
    match json |> member "requested_action" with
    | `Null -> Ok None
    | (`Assoc _ as value) ->
        let* request = action_request_of_yojson value in
        Ok (Some request)
    | _ -> Error "requested_action must be an object"
  in
  let* requested_action = requested_action in
  let briefs_json = json |> member "briefs" |> to_list in
  let rec collect_briefs acc = function
    | [] -> Ok (List.rev acc)
    | hd :: tl -> (
        match case_brief_of_yojson hd with
        | Ok brief -> collect_briefs (brief :: acc) tl
        | Error _ as error -> error)
  in
  let* briefs = collect_briefs [] briefs_json in
  Ok
    {
      id = json |> member "id" |> to_string;
      petition_ids = json |> member "petition_ids" |> to_list |> List.map to_string;
      title = json |> member "title" |> to_string;
      normalized_key = json |> member "normalized_key" |> to_string;
      origin = json |> member "origin" |> to_string;
      subject_type = json |> member "subject_type" |> to_string;
      risk_class;
      status;
      created_at = json |> member "created_at" |> to_float;
      updated_at = json |> member "updated_at" |> to_float;
      requested_action;
      source_refs = json |> member "source_refs" |> to_list |> List.map to_string;
      briefs;
    }

let ruling_to_yojson (ruling : ruling) =
  `Assoc
    [
      ("id", `String ruling.id);
      ("case_id", `String ruling.case_id);
      ("status", `String ruling.status);
      ("summary", `String ruling.summary);
      ("confidence", `Float ruling.confidence);
      ("provenance", `String ruling.provenance);
      ("generated_at", `Float ruling.generated_at);
      ("expires_at", float_opt_json ruling.expires_at);
      ("keeper_name", `String ruling.keeper_name);
      ("model_used", string_opt_json ruling.model_used);
      ("risk_class", `String (risk_class_to_string ruling.risk_class));
      ("evidence_refs", string_list_json ruling.evidence_refs);
      ( "recommended_action",
        match ruling.recommended_action with
        | Some value -> action_request_to_yojson value
        | None -> `Null );
      ("auto_execution_state", `String ruling.auto_execution_state);
    ]

let ruling_of_yojson json =
  let* risk_class =
    json |> member "risk_class" |> to_string |> String.lowercase_ascii
    |> risk_class_of_string
  in
  let recommended_action =
    match json |> member "recommended_action" with
    | `Null -> Ok None
    | (`Assoc _ as value) ->
        let* request = action_request_of_yojson value in
        Ok (Some request)
    | _ -> Error "recommended_action must be an object"
  in
  let* recommended_action = recommended_action in
  Ok
    {
      id = json |> member "id" |> to_string;
      case_id = json |> member "case_id" |> to_string;
      status = json |> member "status" |> to_string;
      summary = json |> member "summary" |> to_string;
      confidence = json |> member "confidence" |> to_float;
      provenance = json |> member "provenance" |> to_string;
      generated_at = json |> member "generated_at" |> to_float;
      expires_at =
        (match json |> member "expires_at" with
        | `Float value -> Some value
        | `Int value -> Some (float_of_int value)
        | _ -> None);
      keeper_name = json |> member "keeper_name" |> to_string;
      model_used = json |> member "model_used" |> to_string_option;
      risk_class;
      evidence_refs = json |> member "evidence_refs" |> to_list |> List.map to_string;
      recommended_action;
      auto_execution_state = json |> member "auto_execution_state" |> to_string;
    }

let execution_order_to_yojson (order : execution_order) =
  `Assoc
    [
      ("id", `String order.id);
      ("case_id", `String order.case_id);
      ("status", `String (order_status_to_string order.status));
      ("risk_class", `String (risk_class_to_string order.risk_class));
      ( "action_request",
        match order.action_request with
        | Some value -> action_request_to_yojson value
        | None -> `Null );
      ("created_at", `Float order.created_at);
      ("updated_at", `Float order.updated_at);
      ("execution_ref", string_opt_json order.execution_ref);
      ("result_summary", string_opt_json order.result_summary);
      ("actor", string_opt_json order.actor);
    ]

let execution_order_of_yojson json =
  let* risk_class =
    json |> member "risk_class" |> to_string |> String.lowercase_ascii
    |> risk_class_of_string
  in
  let* status =
    json |> member "status" |> to_string |> String.lowercase_ascii
    |> order_status_of_string
  in
  let action_request =
    match json |> member "action_request" with
    | `Null -> Ok None
    | (`Assoc _ as value) ->
        let* request = action_request_of_yojson value in
        Ok (Some request)
    | _ -> Error "action_request must be an object"
  in
  let* action_request = action_request in
  Ok
    {
      id = json |> member "id" |> to_string;
      case_id = json |> member "case_id" |> to_string;
      status;
      risk_class;
      action_request;
      created_at = json |> member "created_at" |> to_float;
      updated_at = json |> member "updated_at" |> to_float;
      execution_ref = json |> member "execution_ref" |> to_string_option;
      result_summary = json |> member "result_summary" |> to_string_option;
      actor = json |> member "actor" |> to_string_option;
    }
