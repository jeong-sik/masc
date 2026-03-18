(** Governance_v2 - Petition/case/ruling/execution-order governance model.

    This module owns persistence and read-model assembly for the governance V2
    surface. Side-effectful execution remains outside this module so the root
    application can decide how to map execution orders into tasks or managed
    operations.
*)

open Yojson.Safe.Util

include Governance_v2_types

let stale_test_ttl_sec = 24.0 *. 3600.0

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

let read_file_safe path =
  try
    let ic = open_in path in
    let content =
      Fun.protect ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic))
    in
    Ok content
  with e -> Error (Printexc.to_string e)

let parse_json_safe ~context content =
  try Ok (Yojson.Safe.from_string content)
  with e -> Error (Printf.sprintf "%s: %s" context (Printexc.to_string e))

let list_dir_safe dir =
  try Ok (Array.to_list (Sys.readdir dir))
  with e -> Error (Printexc.to_string e)

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

let governance_root base_path =
  Filename.concat (Filename.concat base_path ".masc") "governance_v2"

let petitions_dir base_path =
  Filename.concat (governance_root base_path) "petitions"

let cases_dir base_path =
  Filename.concat (governance_root base_path) "cases"

let rulings_dir base_path =
  Filename.concat (governance_root base_path) "rulings"

let execution_orders_dir base_path =
  Filename.concat (governance_root base_path) "execution_orders"

let petition_path base_path petition_id =
  Filename.concat (petitions_dir base_path) (petition_id ^ ".json")

let case_path base_path case_id =
  Filename.concat (cases_dir base_path) (case_id ^ ".json")

let ruling_path base_path case_id =
  Filename.concat (rulings_dir base_path) (case_id ^ ".json")

let execution_order_path base_path case_id =
  Filename.concat (execution_orders_dir base_path) (case_id ^ ".json")

let ensure_dirs base_path =
  ensure_dir (petitions_dir base_path);
  ensure_dir (cases_dir base_path);
  ensure_dir (rulings_dir base_path);
  ensure_dir (execution_orders_dir base_path)

let write_json path json =
  let content = Yojson.Safe.pretty_to_string json in
  let dir = Filename.dirname path in
  let base = Filename.basename path in
  let tmp_path =
    Filename.concat dir (Printf.sprintf ".%s.tmp.%d" base (Unix.getpid ()))
  in
  let oc = open_out tmp_path in
  let closed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !closed then (try close_out oc with Sys_error _ -> ());
      if Sys.file_exists tmp_path then
        try Sys.remove tmp_path with Sys_error _ -> ())
    (fun () ->
      output_string oc content;
      flush oc;
      close_out oc;
      closed := true;
      Sys.rename tmp_path path)

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
  let rand = Random.int 1_000_000 in
  Printf.sprintf "%s-%d-%06d" prefix ts rand

let normalize_text raw =
  raw
  |> String.trim
  |> String.lowercase_ascii
  |> String.split_on_char '\n'
  |> String.concat " "

let normalize_key title action =
  let normalized_title =
    normalize_text title
    |> String.to_seq
    |> Seq.map (fun ch ->
           match ch with
           | 'a' .. 'z' | '0' .. '9' -> ch
           | _ -> '-')
    |> String.of_seq
    (* BUG-008: Collapse consecutive dashes and trim leading/trailing dashes *)
    |> (fun s ->
      let buf = Buffer.create (String.length s) in
      let prev_dash = ref false in
      String.iter (fun c ->
        if c = '-' then (if not !prev_dash then Buffer.add_char buf c; prev_dash := true)
        else (Buffer.add_char buf c; prev_dash := false)
      ) s;
      let result = Buffer.contents buf in
      (* Trim leading/trailing dashes *)
      let len = String.length result in
      let start = ref 0 in
      let stop = ref (len - 1) in
      while !start < len && result.[!start] = '-' do incr start done;
      while !stop > !start && result.[!stop] = '-' do decr stop done;
      if !start > !stop then "" else String.sub result !start (!stop - !start + 1))
  in
  let action_key =
    match action with
    | None -> "no-action"
    | Some request ->
        let parts =
          [
            request.action_type;
            Option.value ~default:"none" request.target_type;
            Option.value ~default:"none" request.target_id;
          ]
        in
        String.concat ":" parts |> normalize_text
  in
  normalized_title ^ "::" ^ action_key

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let string_opt_json = function
  | Some value -> `String value
  | None -> `Null

let float_opt_json = function
  | Some value -> `Float value
  | None -> `Null

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

let load_entities dir of_yojson =
  if not (Sys.file_exists dir) then []
  else
    match list_dir_safe dir with
    | Error _ -> []
    | Ok entries ->
        entries
        |> List.filter is_json_file
        |> List.filter_map (fun file ->
               match read_json (Filename.concat dir file) with
               | None -> None
               | Some json -> (
                   match of_yojson json with
                   | Ok value -> Some value
                   | Error _ -> None))

let load_petitions base_path : petition list =
  load_entities (petitions_dir base_path) petition_of_yojson

let load_cases_raw base_path : case_record list =
  load_entities (cases_dir base_path) case_of_yojson

let load_ruling base_path case_id =
  match read_json (ruling_path base_path case_id) with
  | None -> None
  | Some json -> Result.to_option (ruling_of_yojson json)

let load_execution_order base_path case_id =
  match read_json (execution_order_path base_path case_id) with
  | None -> None
  | Some json -> Result.to_option (execution_order_of_yojson json)

let write_petition base_path (petition : petition) =
  ensure_dirs base_path;
  write_json (petition_path base_path petition.id) (petition_to_yojson petition)

let write_case base_path (case_ : case_record) =
  ensure_dirs base_path;
  write_json (case_path base_path case_.id) (case_to_yojson case_)

let write_ruling base_path (ruling : ruling) =
  ensure_dirs base_path;
  write_json (ruling_path base_path ruling.case_id) (ruling_to_yojson ruling)

let write_execution_order base_path (order : execution_order) =
  ensure_dirs base_path;
  write_json
    (execution_order_path base_path order.case_id)
    (execution_order_to_yojson order)

let is_test_origin origin =
  match String.lowercase_ascii (String.trim origin) with
  | "test" | "harness" -> true
  | _ -> false

let delete_case_bundle base_path (case_ : case_record) =
  List.iter
    (fun petition_id ->
      let path = petition_path base_path petition_id in
      if Sys.file_exists path then Sys.remove path)
    case_.petition_ids;
  let case_file = case_path base_path case_.id in
  if Sys.file_exists case_file then Sys.remove case_file;
  let ruling_file = ruling_path base_path case_.id in
  if Sys.file_exists ruling_file then Sys.remove ruling_file;
  let order_file = execution_order_path base_path case_.id in
  if Sys.file_exists order_file then Sys.remove order_file

let purge_stale_test_cases base_path =
  let now = now_unix () in
  let stale_cases =
    load_cases_raw base_path
    |> List.filter (fun case_ ->
           is_test_origin case_.origin
           && now -. case_.updated_at >= stale_test_ttl_sec)
  in
  List.iter (delete_case_bundle base_path) stale_cases

let list_cases ?(include_test=false) ?(status_filter : case_status option) base_path :
    case_record list =
  purge_stale_test_cases base_path;
  load_cases_raw base_path
  |> List.filter (fun (case_ : case_record) ->
         (include_test || not (is_test_origin case_.origin))
         &&
         match status_filter with
         | None -> true
         | Some value -> case_.status = value)
  |> List.sort (fun (left : case_record) (right : case_record) ->
         Float.compare right.updated_at left.updated_at)

let list_execution_orders ?(status_filter : order_status option) base_path :
    execution_order list =
  purge_stale_test_cases base_path;
  load_entities (execution_orders_dir base_path) execution_order_of_yojson
  |> List.filter (fun (order : execution_order) ->
         match status_filter with
         | None -> true
         | Some value -> order.status = value)
  |> List.sort (fun (left : execution_order) (right : execution_order) ->
         Float.compare right.updated_at left.updated_at)

let get_case base_path case_id =
  match read_json (case_path base_path case_id) with
  | None -> Error (Printf.sprintf "Case not found: %s" case_id)
  | Some json -> case_of_yojson json

let get_case_bundle ?(include_test=true) base_path case_id =
  purge_stale_test_cases base_path;
  let* case_ = get_case base_path case_id in
  if (not include_test) && is_test_origin case_.origin then
    Error (Printf.sprintf "Case hidden by default filter: %s" case_id)
  else
    let petitions : petition list =
      case_.petition_ids
      |> List.filter_map (fun petition_id ->
             match read_json (petition_path base_path petition_id) with
             | None -> None
             | Some json -> Result.to_option (petition_of_yojson json))
      |> List.sort (fun (left : petition) (right : petition) ->
             Float.compare left.created_at right.created_at)
    in
    Ok
      ({
         case_;
         petitions;
         ruling = load_ruling base_path case_id;
         execution_order = load_execution_order base_path case_id;
       }
        : case_bundle)

let is_terminal_case_status = function
  | Executed | Blocked | Closed -> true
  | Pending_ruling | Ready_auto_execute | Needs_human_gate -> false

let submit_petition base_path ~title ~origin ~subject_type ~risk_class
    ~requested_action ~source_refs ~created_by =
  ensure_dirs base_path;
  (* File lock to prevent race condition between list_cases and write *)
  let lock_path = Filename.concat (cases_dir base_path) "_submit.lock" in
  let fd = Unix.openfile lock_path [Unix.O_CREAT; Unix.O_WRONLY] 0o644 in
  Fun.protect ~finally:(fun () ->
    (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
    Unix.close fd
  ) (fun () ->
    Unix.lockf fd Unix.F_LOCK 0;
    (* Include task_id from source_refs in dedup key for stronger matching *)
    let task_id_suffix =
      List.find_opt (fun s ->
        String.length s > 5 && String.sub s 0 5 = "task-"
      ) source_refs
      |> Option.value ~default:""
    in
    let base_key = normalize_key title requested_action in
    let normalized_key =
      if task_id_suffix = "" then base_key
      else base_key ^ "::" ^ task_id_suffix
    in
    let all_cases = list_cases ~include_test:true base_path in
    let all_active_cases =
      List.filter (fun (case_ : case_record) -> not (is_terminal_case_status case_.status))
        all_cases
    in
    (* BUG-1627/1608 FIX: Also check terminal (resolved/merged) cases.
       If a case for this task already reached a terminal state, skip
       creating a new petition to prevent unbounded petition accumulation. *)
    let resolved_case =
      if source_refs <> [] then
        List.find_opt (fun (case_ : case_record) ->
          is_terminal_case_status case_.status
          && String.equal case_.subject_type subject_type
          && List.exists (fun ref_ ->
               List.mem ref_ case_.source_refs) source_refs)
          all_cases
      else
        None
    in
    let now = now_unix () in
    (* If a terminal case already exists for this subject, do not create
       a new petition — the matter has been resolved. *)
    match resolved_case with
    | Some resolved ->
        Ok { petition = {
               id = ""; case_id = resolved.id; title; normalized_key;
               origin; subject_type; risk_class; requested_action;
               source_refs; created_by; created_at = now;
             };
             case_ = resolved; merged = true }
    | None ->
    (* Primary dedup: exact normalized_key match *)
    let existing_case =
      List.find_opt (fun case_ ->
             String.equal case_.normalized_key normalized_key)
        all_active_cases
    in
    (* Secondary dedup: match by shared source_refs for same subject_type.
       This catches duplicates when title changes (e.g. assignee or status
       changes) but the underlying subject (task/keeper) is the same. *)
    let existing_case =
      match existing_case with
      | Some _ -> existing_case
      | None when source_refs <> [] ->
          List.find_opt (fun (case_ : case_record) ->
            String.equal case_.subject_type subject_type
            && List.exists (fun ref_ ->
                 List.mem ref_ case_.source_refs) source_refs)
            all_active_cases
      | None -> None
    in
    let case_, merged =
      match existing_case with
      | Some case_ -> (case_, true)
      | None ->
          ( {
              id = generate_id "case";
              petition_ids = [];
              title;
              normalized_key;
              origin;
              subject_type;
              risk_class;
              status = Pending_ruling;
              created_at = now;
              updated_at = now;
              requested_action;
              source_refs;
              briefs = [];
            },
            false )
    in
    (* Skip duplicate petition: if case already has a petition with same key,
       just return the existing case without adding another petition.
       This prevents sentinel sweeps from accumulating 41+ petitions per task. *)
    if merged && List.length case_.petition_ids > 0 then
      Ok { petition = {
             id = ""; case_id = case_.id; title; normalized_key;
             origin; subject_type; risk_class; requested_action;
             source_refs; created_by; created_at = now;
           };
           case_; merged = true }
    else
    let petition =
      {
        id = generate_id "petition";
        case_id = case_.id;
        title;
        normalized_key;
        origin;
        subject_type;
        risk_class;
        requested_action;
        source_refs;
        created_by;
        created_at = now;
      }
    in
    let updated_case =
      {
        case_ with
        petition_ids = case_.petition_ids @ [ petition.id ];
        title = if String.trim case_.title = "" then title else case_.title;
        requested_action =
          (match case_.requested_action with Some _ -> case_.requested_action | None -> requested_action);
        source_refs =
          List.sort_uniq String.compare (case_.source_refs @ source_refs);
        updated_at = now;
        origin = if merged then case_.origin else origin;
      }
    in
    write_petition base_path petition;
    write_case base_path updated_case;
    Ok { petition; case_ = updated_case; merged }
  )

let submit_brief base_path ~case_id ~author ~stance ~summary ~evidence_refs =
  let* case_ = get_case base_path case_id in
  let brief =
    {
      id = generate_id "brief";
      author;
      stance;
      summary;
      evidence_refs;
      created_at = now_unix ();
    }
  in
  let updated_case =
    {
      case_ with
      briefs = case_.briefs @ [ brief ];
      updated_at = now_unix ();
    }
  in
  write_case base_path updated_case;
  Ok updated_case

let save_ruling base_path (ruling : ruling) =
  let* case_ = get_case base_path ruling.case_id in
  let next_status =
    match String.lowercase_ascii ruling.auto_execution_state with
    | "needs_human_gate" -> Needs_human_gate
    | "auto_executed" | "done" -> Executed
    | "blocked" -> Blocked
    | "ready_auto_execute" | "queued_auto" -> Ready_auto_execute
    | _ -> Pending_ruling
  in
  let updated_case = { case_ with status = next_status; updated_at = now_unix () } in
  write_case base_path updated_case;
  write_ruling base_path ruling;
  (* Auto-create execution order when ruling triggers Ready_auto_execute
     and no order exists yet. This closes the gap where sentinel-submitted
     rulings set the case status but never create the order needed for
     downstream execution. *)
  (if next_status = Ready_auto_execute then
     match load_execution_order base_path ruling.case_id with
     | Some _ -> ()  (* Order already exists *)
     | None ->
         let now = now_unix () in
         let order : execution_order = {
           id = generate_id "order";
           case_id = ruling.case_id;
           status = Queued_auto;
           risk_class = ruling.risk_class;
           action_request = ruling.recommended_action;
           created_at = now;
           updated_at = now;
           execution_ref = None;
           result_summary = None;
           actor = Some ruling.keeper_name;
         } in
         write_execution_order base_path order);
  Ok updated_case

let save_execution_order base_path (order : execution_order) =
  let* case_ = get_case base_path order.case_id in
  let next_status =
    match order.status with
    | Queued_auto -> Ready_auto_execute
    | Needs_human_gate_order -> Needs_human_gate
    | Auto_executed | Done -> Executed
    | Denied | Blocked_order -> Blocked
  in
  let updated_case = { case_ with status = next_status; updated_at = now_unix () } in
  write_case base_path updated_case;
  write_execution_order base_path order;
  Ok updated_case

let update_execution_order base_path (order : execution_order) =
  save_execution_order base_path order

let set_case_status base_path ~case_id ~status =
  let* case_ = get_case base_path case_id in
  let updated_case = { case_ with status; updated_at = now_unix () } in
  write_case base_path updated_case;
  Ok updated_case

let latest_generated_at base_path =
  list_cases ~include_test:true base_path
  |> List.fold_left
       (fun acc (case_ : case_record) ->
         match load_ruling base_path case_.id with
         | Some (ruling : ruling) -> max acc ruling.generated_at
         | None -> acc)
       0.0

let reset_legacy_storage base_path =
  let masc_root = Filename.concat base_path ".masc" in
  [ Filename.concat masc_root "debates";
    Filename.concat masc_root "consensus";
    Filename.concat masc_root "governance" ]
  |> List.iter (fun path ->
         if Sys.file_exists path then rm_rf path)
