(** Governance_v2 - Petition/case/ruling/execution-order governance model.

    This module owns persistence and read-model assembly for the governance V2
    surface. Side-effectful execution remains outside this module so the root
    application can decide how to map execution orders into tasks or managed
    operations.
*)

include Governance_v2_serde
open Result_syntax

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

let contains_substring = String_util.contains_substring

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
    |> (fun s ->
      let buf = Buffer.create (String.length s) in
      let prev_dash = ref false in
      String.iter (fun c ->
        if c = '-' then (if not !prev_dash then Buffer.add_char buf c; prev_dash := true)
        else (Buffer.add_char buf c; prev_dash := false)
      ) s;
      let result = Buffer.contents buf in
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

let semantic_stopwords =
  [
    "a";
    "an";
    "and";
    "for";
    "in";
    "of";
    "on";
    "or";
    "please";
    "the";
    "this";
    "that";
    "to";
    "via";
    "with";
  ]

(** Canonical action verb and noun synonyms for case dedup.
    Groups equivalent terms to a single canonical form so
    "Clear X to default" and "Reset X" produce the same key. *)
let canonical_semantic_token token =
  match token with
  | "" -> None
  (* Infrastructure nouns *)
  | "db" | "database" | "postgres" | "postgresql" -> Some "database"
  | "connection" | "connections" | "connect" -> Some "connection"
  | "timeout" | "timeouts" | "deadline" | "wait" -> Some "timeout"
  | "service" | "services" | "server" -> Some "service"
  | "param" | "parameter" | "setting" | "config" | "configuration" -> Some "parameter"
  | "second" | "seconds" | "sec" | "secs" -> Some "seconds"
  | "minute" | "minutes" | "min" | "mins" -> Some "minutes"
  | "value" | "values" | "val" -> Some "value"
  | "default" | "defaults" | "original" | "initial" -> Some "default"
  | "limit" | "limits" | "cap" | "ceiling" | "maximum" | "max" -> Some "limit"
  | "threshold" | "thresholds" -> Some "threshold"
  (* Action verbs — mutative *)
  | "set" | "update" | "change" | "modify" | "alter" | "adjust" -> Some "set"
  | "clear" | "reset" | "restore" | "revert" | "rollback" | "undo" -> Some "reset"
  | "create" | "add" | "new" | "insert" -> Some "create"
  | "delete" | "remove" | "drop" | "destroy" | "purge" -> Some "delete"
  | "restart" | "reboot" | "reload" -> Some "restart"
  | "enable" | "activate" | "turn_on" -> Some "enable"
  | "disable" | "deactivate" | "turn_off" -> Some "disable"
  | "increase" | "raise" | "extend" | "bump" | "scale_up" -> Some "increase"
  | "decrease" | "reduce" | "lower" | "scale_down" | "shrink" -> Some "decrease"
  (* Action verbs — read/review *)
  | "review" | "audit" | "inspect" | "check" | "verify" -> Some "review"
  | "approve" | "accept" | "allow" | "permit" -> Some "approve"
  | "deny" | "reject" | "block" | "refuse" -> Some "deny"
  | other when List.mem other semantic_stopwords -> None
  | other -> Some other

let semantic_title_key title =
  Text_similarity.normalize_for_similarity title
  |> List.filter_map canonical_semantic_token
  |> List.sort_uniq String.compare
  |> String.concat " "

let rec normalize_json_semantics (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.map (fun (key, value) ->
               (normalize_text key, normalize_json_semantics value))
        |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List items -> `List (List.map normalize_json_semantics items)
  | `String value -> `String (normalize_text value)
  | (`Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) as value -> value

(** Canonicalize a compound action string like "set_param" or "clear-param".
    Splits on underscores/hyphens/spaces, maps each token, and rejoins. *)
let canonicalize_action_str s =
  s
  |> normalize_text
  |> String.to_seq
  |> Seq.map (fun ch ->
       match ch with 'a'..'z' | '0'..'9' -> ch | _ -> ' ')
  |> String.of_seq
  |> String.split_on_char ' '
  |> List.filter_map canonical_semantic_token
  |> String.concat "_"

let semantic_action_key = function
  | None -> None
  | Some (request : action_request) ->
      let payload_key =
        match request.payload with
        | None -> "null"
        | Some payload ->
            payload
            |> normalize_json_semantics
            |> Yojson.Safe.sort
            |> Yojson.Safe.to_string
      in
      Some
        (String.concat "::"
           [
             canonicalize_action_str request.action_type;
             canonicalize_action_str (Option.value ~default:"none" request.target_type);
             normalize_text (Option.value ~default:"none" request.target_id);
             payload_key;
           ])

let semantically_matches_case ~title ~subject_type ~requested_action
    (case_ : case_record) =
  String.equal case_.subject_type subject_type
  &&
  match (semantic_action_key requested_action, semantic_action_key case_.requested_action) with
  | Some left, Some right -> String.equal left right
  | None, None ->
      let incoming_title = semantic_title_key title in
      incoming_title <> ""
      && String.equal incoming_title (semantic_title_key case_.title)
  | _ -> false

let stale_test_ttl_sec = 24.0 *. 3600.0
let stale_artifact_ttl_sec = 12.0 *. 3600.0

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

(** Wrap write_json so filesystem errors become Result instead of raising.
    Eio cancellation is re-raised (not a write failure). *)
let try_write path json =
  try
    write_json path json;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Error (Printf.sprintf "write failed: %s: %s" path (Printexc.to_string exn))

let write_petition base_path (petition : petition) =
  ensure_dirs base_path;
  try_write (petition_path base_path petition.id) (petition_to_yojson petition)

let write_case base_path (case_ : case_record) =
  ensure_dirs base_path;
  try_write (case_path base_path case_.id) (case_to_yojson case_)

let write_ruling base_path (ruling : ruling) =
  ensure_dirs base_path;
  try_write (ruling_path base_path ruling.case_id) (ruling_to_yojson ruling)

let write_execution_order base_path (order : execution_order) =
  ensure_dirs base_path;
  try_write
    (execution_order_path base_path order.case_id)
    (execution_order_to_yojson order)

let is_test_origin origin =
  match String.lowercase_ascii (String.trim origin) with
  | "test" | "harness" -> true
  | _ -> false

let title_has_artifact_signature title =
  let title = String.lowercase_ascii (String.trim title) in
  String.starts_with ~prefix:"autonomy post volume high" title
  || contains_substring title "qa-"
  || contains_substring title "sm-test"
  || contains_substring title "stress-"
  || contains_substring title "team session fallback"
  || contains_substring title "ghost-agent-not-joined"

let source_ref_has_artifact_signature refs =
  List.exists
    (fun ref_ ->
      let ref_ = String.lowercase_ascii (String.trim ref_) in
      String.starts_with ~prefix:"anomaly-autonomy-post-volume" ref_
      || String.starts_with ~prefix:"anomaly:autonomy-post-volume" ref_
      || String.starts_with ~prefix:"task-qa-" ref_
      || String.starts_with ~prefix:"task-sm-test" ref_
      || String.starts_with ~prefix:"task-stress-" ref_)
    refs

let is_stale_artifact_case now (case_ : case_record) =
  now -. case_.updated_at >= stale_artifact_ttl_sec
  &&
  (title_has_artifact_signature case_.title
   || source_ref_has_artifact_signature case_.source_refs)

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
  List.iter (delete_case_bundle base_path) stale_cases;
  List.length stale_cases

let purge_stale_artifact_cases base_path =
  let now = now_unix () in
  let stale_cases =
    load_cases_raw base_path
    |> List.filter (fun case_ ->
           not (is_test_origin case_.origin) && is_stale_artifact_case now case_)
  in
  List.iter (delete_case_bundle base_path) stale_cases;
  List.length stale_cases

let list_cases ?(include_test=false) ?(status_filter : case_status option) base_path :
    case_record list =
  ignore (purge_stale_test_cases base_path);
  ignore (purge_stale_artifact_cases base_path);
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
  ignore (purge_stale_test_cases base_path);
  ignore (purge_stale_artifact_cases base_path);
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
  ignore (purge_stale_test_cases base_path);
  ignore (purge_stale_artifact_cases base_path);
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

let run_blocking_lock_op f = Eio_guard.run_in_systhread f

let submit_petition base_path ~title ~origin ~subject_type ~risk_class
    ~requested_action ~source_refs ~created_by =
  ensure_dirs base_path;
  (* File lock to prevent race condition between list_cases and write.
     Uses F_TLOCK (non-blocking) in systhread to avoid blocking Eio scheduler. *)
  let lock_path = Filename.concat (cases_dir base_path) "_submit.lock" in
  let fd = run_blocking_lock_op (fun () ->
    File_lock_eio.acquire_flock_retry ~lock_path
      ~mode:[Unix.O_CREAT; Unix.O_WRONLY] ~perm:0o644
      ~caller:"governance_v2" ()
  ) in
  Fun.protect ~finally:(fun () ->
      run_blocking_lock_op (fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
        Unix.close fd))
  (fun () ->
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
    let resolved_case =
      List.find_opt
        (fun (case_ : case_record) ->
          is_terminal_case_status case_.status
          &&
          ((source_refs <> []
            && String.equal case_.subject_type subject_type
            && List.exists (fun ref_ -> List.mem ref_ case_.source_refs) source_refs)
           || semantically_matches_case ~title ~subject_type ~requested_action case_))
        all_cases
    in
    let now = now_unix () in
    match resolved_case with
    | Some resolved ->
        Ok { petition = {
               id = ""; case_id = resolved.id; title; normalized_key;
               origin; subject_type; risk_class; requested_action;
               source_refs; created_by; created_at = now;
             };
             case_ = resolved; merged = true }
    | None ->
    let existing_case =
      List.find_opt (fun case_ ->
             String.equal case_.normalized_key normalized_key)
        all_active_cases
    in
    let existing_case =
      match existing_case with
      | Some _ -> existing_case
      | None when source_refs <> [] ->
          List.find_opt (fun (case_ : case_record) ->
            String.equal case_.subject_type subject_type
            && List.exists (fun ref_ ->
                 List.mem ref_ case_.source_refs) source_refs)
            all_active_cases
      | None ->
          List.find_opt
            (semantically_matches_case ~title ~subject_type ~requested_action)
            all_active_cases
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
    let* () = write_petition base_path petition in
    let* () = write_case base_path updated_case in
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
  let* () = write_case base_path updated_case in
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
  let* () = write_case base_path updated_case in
  let* () = write_ruling base_path ruling in
  let* () =
    if next_status = Ready_auto_execute then
      match load_execution_order base_path ruling.case_id with
      | Some _ -> Ok ()
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
          write_execution_order base_path order
    else Ok ()
  in
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
  let* () = write_case base_path updated_case in
  let* () = write_execution_order base_path order in
  Ok updated_case

let update_execution_order base_path (order : execution_order) =
  save_execution_order base_path order

let set_case_status base_path ~case_id ~status =
  let* case_ = get_case base_path case_id in
  let updated_case = { case_ with status; updated_at = now_unix () } in
  let* () = write_case base_path updated_case in
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
