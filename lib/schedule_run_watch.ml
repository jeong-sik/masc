let ( let* ) = Result.bind

(* --- Repository --- *)

type repo =
  { owner : string
  ; name : string
  }

let is_name_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
  | _ -> false
;;

let is_repo_part part =
  (not (String.equal part ""))
  && (not (String.equal part "."))
  && (not (String.equal part ".."))
  && String.for_all is_name_char part
;;

let repo_of_string raw =
  match String.split_on_char '/' raw with
  | [ owner; name ] when is_repo_part owner && is_repo_part name -> Ok { owner; name }
  | _ ->
    Error
      (Printf.sprintf
         "%S is not a GitHub repository: expected owner/name using letters, digits, '-', '_' and '.'"
         raw)
;;

let repo_to_string { owner; name } = owner ^ "/" ^ name

(* --- Target --- *)

type target =
  { repo : repo
  ; run_id : int
  ; run_attempt : int option
  }

let positive_int_of_digits raw =
  if String.equal raw "" || not (String.for_all (function '0' .. '9' -> true | _ -> false) raw)
  then None
  else (
    match int_of_string_opt raw with
    | Some n when n > 0 -> Some n
    | Some _ | None -> None)
;;

let url_prefix = "https://github.com/"
let url_shape = "https://github.com/<owner>/<repo>/actions/runs/<run_id>[/attempts/<n>]"

let drop_from ~sep text =
  match String.index_opt text sep with
  | Some index -> String.sub text 0 index
  | None -> text
;;

let target_of_run_url raw =
  let raw = String.trim raw in
  let refuse why = Error (Printf.sprintf "%s: expected %s" why url_shape) in
  if not (String.starts_with ~prefix:url_prefix raw)
  then refuse (Printf.sprintf "%S is not a github.com URL" raw)
  else (
    let rest =
      String.sub raw (String.length url_prefix) (String.length raw - String.length url_prefix)
    in
    let path = rest |> drop_from ~sep:'#' |> drop_from ~sep:'?' in
    let segments =
      match List.rev (String.split_on_char '/' path) with
      | "" :: reversed -> List.rev reversed
      | reversed -> List.rev reversed
    in
    let build owner name run attempt =
      let* repo = repo_of_string (owner ^ "/" ^ name) in
      match positive_int_of_digits run with
      | None -> refuse (Printf.sprintf "run id %S is not a positive integer" run)
      | Some run_id ->
        (match attempt with
         | None -> Ok { repo; run_id; run_attempt = None }
         | Some attempt_digits ->
           (match positive_int_of_digits attempt_digits with
            | None -> refuse (Printf.sprintf "attempt %S is not a positive integer" attempt_digits)
            | Some attempt -> Ok { repo; run_id; run_attempt = Some attempt }))
    in
    match segments with
    | [ owner; name; "actions"; "runs"; run ] -> build owner name run None
    | [ owner; name; "actions"; "runs"; run; "attempts"; attempt ] ->
      build owner name run (Some attempt)
    | _ -> refuse (Printf.sprintf "%S does not name a run" raw))
;;

let target_url { repo; run_id; run_attempt } =
  let attempt =
    match run_attempt with
    | None -> ""
    | Some attempt -> Printf.sprintf "/attempts/%d" attempt
  in
  Printf.sprintf "https://github.com/%s/actions/runs/%d%s" (repo_to_string repo) run_id attempt
;;

let describe_target { repo; run_id; run_attempt } =
  match run_attempt with
  | None -> Printf.sprintf "%s run %d" (repo_to_string repo) run_id
  | Some attempt -> Printf.sprintf "%s run %d attempt %d" (repo_to_string repo) run_id attempt
;;

let watch_field = "until_github_run"

let target_to_yojson { repo; run_id; run_attempt } =
  let attempt =
    match run_attempt with
    | None -> []
    | Some attempt -> [ "run_attempt", `Int attempt ]
  in
  `Assoc ([ "repo", `String (repo_to_string repo); "run_id", `Int run_id ] @ attempt)
;;

let target_of_yojson = function
  | `Assoc fields ->
    let* () =
      Json_util.reject_unknown_fields
        ~surface:watch_field
        ~allowed:[ "repo"; "run_id"; "run_attempt" ]
        fields
    in
    let positive field = function
      | `Int n when n > 0 -> Ok n
      | _ -> Error (Printf.sprintf "%s.%s must be a positive integer" watch_field field)
    in
    let* repo =
      match List.assoc_opt "repo" fields with
      | Some (`String raw) -> repo_of_string raw
      | Some _ | None -> Error (watch_field ^ ".repo must be an owner/name string")
    in
    let* run_id =
      match List.assoc_opt "run_id" fields with
      | Some value -> positive "run_id" value
      | None -> Error (watch_field ^ ".run_id is required")
    in
    let* run_attempt =
      match List.assoc_opt "run_attempt" fields with
      | None -> Ok None
      | Some value -> Result.map Option.some (positive "run_attempt" value)
    in
    Ok { repo; run_id; run_attempt }
  | _ -> Error (watch_field ^ " must be an object")
;;

(* --- What GitHub answers --- *)

type conclusion =
  | Success
  | Failure
  | Cancelled
  | Skipped
  | Timed_out
  | Neutral
  | Action_required
  | Stale
  | Startup_failure
  | Unrecognized of string

let conclusion_of_string = function
  | "success" -> Success
  | "failure" -> Failure
  | "cancelled" -> Cancelled
  | "skipped" -> Skipped
  | "timed_out" -> Timed_out
  | "neutral" -> Neutral
  | "action_required" -> Action_required
  | "stale" -> Stale
  | "startup_failure" -> Startup_failure
  | other -> Unrecognized other
;;

let conclusion_to_string = function
  | Success -> "success"
  | Failure -> "failure"
  | Cancelled -> "cancelled"
  | Skipped -> "skipped"
  | Timed_out -> "timed_out"
  | Neutral -> "neutral"
  | Action_required -> "action_required"
  | Stale -> "stale"
  | Startup_failure -> "startup_failure"
  | Unrecognized other -> other
;;

type observation =
  | Not_completed
  | Completed of conclusion option

(* An error body also carries a [status] string ("404"), so the answer must
   name the run that was asked for before its [status] is read. *)
let observation_of_run_json target = function
  | `Assoc fields ->
    let* () =
      match List.assoc_opt "id" fields with
      | Some (`Int id) when id = target.run_id -> Ok ()
      | Some (`Int id) ->
        Error (Printf.sprintf "the answer is for run %d, not run %d" id target.run_id)
      | Some _ | None -> Error "the answer has no integer id"
    in
    let* () =
      match target.run_attempt, List.assoc_opt "run_attempt" fields with
      | None, _ -> Ok ()
      | Some wanted, Some (`Int given) when given = wanted -> Ok ()
      | Some wanted, Some (`Int given) ->
        Error (Printf.sprintf "the answer is for attempt %d, not attempt %d" given wanted)
      | Some _, (Some _ | None) -> Error "the answer has no integer run_attempt"
    in
    (match List.assoc_opt "status" fields with
     | Some (`String "completed") ->
       (match List.assoc_opt "conclusion" fields with
        | None | Some `Null -> Ok (Completed None)
        | Some (`String raw) -> Ok (Completed (Some (conclusion_of_string raw)))
        | Some _ -> Error "run conclusion is neither a string nor null")
     | Some (`String _) -> Ok Not_completed
     | Some `Null | None -> Error "run status is absent or null"
     | Some _ -> Error "run status is not a string")
  | _ -> Error "run answer is not a JSON object"
;;

type read_failure =
  | Not_visible
  | Token_rejected
  | Forbidden
  | Rate_limited of { reset_at : float option }
  | Http_status of int
  | Transport_failed of string
  | Response_unreadable of string
  | Reader_unavailable of string
  | Reader_not_ready of string

let read_failure_to_string = function
  | Not_visible -> "the repository or run is not visible to the reader account"
  | Token_rejected -> "the reader account's token was rejected"
  | Forbidden -> "the reader account may not read this run"
  | Rate_limited { reset_at = Some at } ->
    Printf.sprintf "rate limited until %s" (Masc_domain.iso8601_of_unix_seconds at)
  | Rate_limited { reset_at = None } -> "rate limited"
  | Http_status status -> Printf.sprintf "GitHub answered HTTP %d" status
  | Transport_failed detail -> "the request failed: " ^ detail
  | Response_unreadable detail -> "the answer could not be read: " ^ detail
  | Reader_unavailable detail -> "no reader account: " ^ detail
  | Reader_not_ready detail -> "the reader account could not be used this time: " ^ detail
;;

(* HTTP: a 5xx status is the server's own trouble and can pass, and so can a
   408 or a 425, which ask the client to try again. Any other status that is
   not a success is the request's or the account's, and asking again gives the
   same answer. *)
let first_server_error_status = 500
let try_again_statuses = [ 408; 425 ]

let read_failure_is_permanent = function
  | Not_visible | Token_rejected | Forbidden | Response_unreadable _ | Reader_unavailable _ ->
    true
  | Http_status status ->
    status < first_server_error_status
    && not (List.exists (Int.equal status) try_again_statuses)
  | Rate_limited _ | Transport_failed _ | Reader_not_ready _ -> false
;;

(* --- The wake --- *)

type settled =
  | Run_completed of conclusion option
  | Run_unreadable of read_failure

let wake_message target settled ~original =
  let headline =
    match settled with
    | Run_completed (Some conclusion) ->
      Printf.sprintf "%s completed: %s" (describe_target target) (conclusion_to_string conclusion)
    | Run_completed None ->
      Printf.sprintf "%s completed with no conclusion" (describe_target target)
    | Run_unreadable failure ->
      Printf.sprintf
        "could not read %s (%s). This wake came early; check the run yourself."
        (describe_target target)
        (read_failure_to_string failure)
  in
  Printf.sprintf "[github_run_watch] %s\n%s\n\n%s" headline (target_url target) original
;;

(* The fields of a Keeper wake payload and its body. Any other payload has no
   watch. *)
let keeper_wake_parts = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields, List.assoc_opt "body" fields with
     | Some (`String kind), Some (`Assoc body)
       when String.equal kind Schedule_supported_kinds.keeper_wake -> Some (fields, body)
     | _ -> None)
  | _ -> None
;;

let watch_of_body body =
  match List.assoc_opt watch_field body with
  | None -> Ok None
  | Some value -> Result.map Option.some (target_of_yojson value)
;;

let watch_of_payload payload =
  match keeper_wake_parts payload with
  | None -> Ok None
  | Some (_, body) -> watch_of_body body
;;

let keeper_wake_body payload = Option.map snd (keeper_wake_parts payload)

let settle_body_payload payload ~field ~message =
  match keeper_wake_parts payload with
  | None -> Error "the payload is not a Keeper wake"
  | Some (fields, body) ->
    (match List.assoc_opt "message" body with
     | Some (`String original) ->
       let body =
         List.filter_map
           (fun (key, value) ->
             if String.equal key field
             then None
             else if String.equal key "message"
             then Some (key, `String (message original))
             else Some (key, value))
           body
       in
       Ok
         (`Assoc
           (List.map
              (fun (key, value) ->
                if String.equal key "body" then key, `Assoc body else key, value)
              fields))
     | Some _ | None -> Error "the Keeper wake payload has no message string")
;;

let settle_payload payload target settled =
  settle_body_payload payload ~field:watch_field ~message:(fun original ->
    wake_message target settled ~original)
;;

(* --- One pass --- *)

type verdict =
  | Woken of settled
  | Waiting_for_run
  | Waiting_to_read of read_failure
  | Not_woken of string

type outcome =
  { schedule_id : string
  ; target : target option
  ; verdict : verdict
  }

let one_shot_scheduled (request : Schedule_domain.schedule_request) =
  match request.status, request.recurrence with
  | Schedule_domain.Scheduled, Schedule_domain.One_shot -> true
  | ( Schedule_domain.Scheduled
    , (Schedule_domain.Interval _ | Schedule_domain.Daily _ | Schedule_domain.Cron _) ) ->
    false
  | ( ( Schedule_domain.Due
      | Schedule_domain.Running
      | Schedule_domain.Succeeded
      | Schedule_domain.Failed
      | Schedule_domain.Cancelled
      | Schedule_domain.Expired )
    , _ ) -> false
;;

let watched_row (request : Schedule_domain.schedule_request) =
  if not (one_shot_scheduled request)
  then None
  else (
    match watch_of_payload (Schedule_domain.payload_to_yojson request.payload) with
    | Ok None -> None
    | Ok (Some target) -> Some (request, Ok target)
    | Error detail -> Some (request, Error detail))
;;

(* The write is built from the row that was scanned and names that row's
   instance. The store compares it under its own lock
   ({!Schedule_store.Stale_instance}), so a Keeper who edited the schedule while
   its run was being read keeps the edit. The store also refuses the write once
   the row is running or finished ({!Schedule_domain.modify_allowed}). The new
   due time is the current second, or the stored one when that is earlier: a
   row whose time has passed and that the runner has not taken yet is not
   pushed later. *)
let make_due config ~now ~runner_tick_sec (scanned : Schedule_domain.schedule_request) ~payload =
  match
    Schedule_service.update
      config
      ~authority:Schedule_store.Operator_authority
      ~now
      ~runner_tick_sec
      ~timing_update:Schedule_store.Replace_timing
      ~expected_instance_id:scanned.schedule_instance_id
      ~schedule_id:scanned.schedule_id
      ~requested_at:scanned.requested_at
      ?expires_at:scanned.expires_at
      ~requested_by:scanned.requested_by
      ~scheduled_by:scanned.scheduled_by
      ~due_at:(Float.min scanned.due_at (Float.floor now))
      ~payload
      ~source:scanned.source
      ~recurrence:scanned.recurrence
      ()
  with
  | Ok _ -> Ok ()
  | Error failure -> Error (Schedule_service.service_error_to_string failure)
;;

let wake config ~now ~runner_tick_sec (scanned : Schedule_domain.schedule_request) target settled =
  match settle_payload (Schedule_domain.payload_to_yojson scanned.payload) target settled with
  | Error detail -> Not_woken detail
  | Ok payload ->
    (match make_due config ~now ~runner_tick_sec scanned ~payload with
     | Ok () -> Woken settled
     | Error detail -> Not_woken detail)
;;

let reads_once ~key ~read =
  let answers = Hashtbl.create 8 in
  let limited = ref None in
  fun target ->
    let key = key target in
    match Hashtbl.find_opt answers key with
    | Some answer -> answer
    | None ->
      let answer =
        match !limited with
        | Some failure -> Error failure
        | None ->
          let answer = read target in
          (match answer with
           | Error (Rate_limited _ as failure) -> limited := Some failure
           | Error
               ( Not_visible
               | Token_rejected
               | Forbidden
               | Http_status _
               | Transport_failed _
               | Response_unreadable _
               | Reader_unavailable _
               | Reader_not_ready _ )
           | Ok _ -> ());
          answer
      in
      Hashtbl.add answers key answer;
      answer
;;

let tick config ~now ~runner_tick_sec ~read =
  match Schedule_store.read_state_result config with
  | Error failure -> Error (Schedule_store.read_error_to_string failure)
  | Ok state ->
    let read_once = reads_once ~key:target_url ~read in
    let judge ((request : Schedule_domain.schedule_request), watch) =
      match watch with
      | Error detail ->
        { schedule_id = request.schedule_id
        ; target = None
        ; verdict = Not_woken ("the stored watch cannot be read: " ^ detail)
        }
      | Ok target ->
        let wake_with settled = wake config ~now ~runner_tick_sec request target settled in
        let verdict =
          match read_once target with
          | Ok Not_completed -> Waiting_for_run
          | Ok (Completed conclusion) -> wake_with (Run_completed conclusion)
          | Error failure ->
            if read_failure_is_permanent failure
            then wake_with (Run_unreadable failure)
            else Waiting_to_read failure
        in
        { schedule_id = request.schedule_id; target = Some target; verdict }
    in
    Ok (List.filter_map watched_row state.Schedule_store.schedules |> List.map judge)
;;
