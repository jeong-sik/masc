let ( let* ) = Result.bind

module Run_watch = Schedule_run_watch

(* --- Commit --- *)

type sha = string

let sha_length = 40
let short_sha_length = 12

let is_hex_digit = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false
;;

let sha_of_string raw =
  if String.length raw = sha_length && String.for_all is_hex_digit raw
  then Ok (String.lowercase_ascii raw)
  else
    Error
      (Printf.sprintf
         "%S is not a full commit sha: expected %d hexadecimal digits"
         raw
         sha_length)
;;

let sha_to_string sha = sha

(* --- Target --- *)

type target =
  { repo : Run_watch.repo
  ; sha : sha
  }

let watch_field = "until_github_checks"
let url_prefix = "https://github.com/"
let url_shape = "https://github.com/<owner>/<repo>/commit/<40 hexadecimal digits>"

let drop_from ~sep text =
  match String.index_opt text sep with
  | Some index -> String.sub text 0 index
  | None -> text
;;

let target_of_commit_url raw =
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
    match segments with
    | [ owner; name; "commit"; sha ] ->
      let* repo = Run_watch.repo_of_string (owner ^ "/" ^ name) in
      (match sha_of_string sha with
       | Ok sha -> Ok { repo; sha }
       | Error why -> refuse why)
    | _ -> refuse (Printf.sprintf "%S does not name a commit" raw))
;;

let target_url { repo; sha } =
  Printf.sprintf "https://github.com/%s/commit/%s" (Run_watch.repo_to_string repo) sha
;;

let describe_target { repo; sha } =
  Printf.sprintf
    "%s commit %s"
    (Run_watch.repo_to_string repo)
    (String.sub sha 0 short_sha_length)
;;

let target_to_yojson { repo; sha } =
  `Assoc [ "repo", `String (Run_watch.repo_to_string repo); "sha", `String sha ]
;;

let target_of_yojson = function
  | `Assoc fields ->
    let* () =
      Json_util.reject_unknown_fields
        ~surface:watch_field
        ~allowed:[ "repo"; "sha" ]
        fields
    in
    let* repo =
      match List.assoc_opt "repo" fields with
      | Some (`String raw) -> Run_watch.repo_of_string raw
      | Some _ | None -> Error (watch_field ^ ".repo must be an owner/name string")
    in
    let* sha =
      match List.assoc_opt "sha" fields with
      | Some (`String raw) ->
        sha_of_string raw |> Result.map_error (fun why -> watch_field ^ ".sha: " ^ why)
      | Some _ | None -> Error (watch_field ^ ".sha must be a string")
    in
    Ok { repo; sha }
  | _ -> Error (watch_field ^ " must be an object")
;;

(* --- What GitHub answers --- *)

type event =
  | Push
  | Pull_request
  | Workflow_run
  | Other_event of string

let event_of_string = function
  | "push" -> Push
  | "pull_request" -> Pull_request
  | "workflow_run" -> Workflow_run
  | other -> Other_event other
;;

let event_to_string = function
  | Push -> "push"
  | Pull_request -> "pull_request"
  | Workflow_run -> "workflow_run"
  | Other_event other -> other
;;

let is_check_event = function
  | Push | Pull_request | Workflow_run -> true
  | Other_event _ -> false
;;

type check_run =
  { workflow : string
  ; event : event
  ; conclusion : Run_watch.conclusion option
  }

type observation =
  | Not_settled
  | Settled of check_run list

let string_member fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Printf.sprintf "a run has no string %s" name)
;;

(* One run of the answer: whether it completed, and what it is. A run of
   another commit is an error, because the list is asked for by [head_sha] and
   an answer that ignored the filter must not read as this commit's. *)
let run_of_json target = function
  | `Assoc fields ->
    let* head = string_member fields "head_sha" in
    let* () =
      if String.equal (String.lowercase_ascii head) target.sha
      then Ok ()
      else Error (Printf.sprintf "the answer holds a run of commit %s, not %s" head target.sha)
    in
    let* workflow = string_member fields "name" in
    let* event = Result.map event_of_string (string_member fields "event") in
    let* completed =
      match List.assoc_opt "status" fields with
      | Some (`String status) -> Ok (String.equal status "completed")
      | Some `Null | None -> Error "run status is absent or null"
      | Some _ -> Error "run status is not a string"
    in
    let* conclusion =
      match List.assoc_opt "conclusion" fields with
      | None | Some `Null -> Ok None
      | Some (`String raw) -> Ok (Some (Run_watch.conclusion_of_string raw))
      | Some _ -> Error "run conclusion is neither a string nor null"
    in
    Ok (completed, { workflow; event; conclusion })
  | _ -> Error "a run in the answer is not a JSON object"
;;

let observation_of_runs_json ?(allow_incomplete = false) target = function
  | `Assoc fields ->
    let* total =
      match List.assoc_opt "total_count" fields with
      | Some (`Int total) -> Ok total
      | Some _ | None -> Error "the answer has no integer total_count"
    in
    let* items =
      match List.assoc_opt "workflow_runs" fields with
      | Some (`List items) -> Ok items
      | Some _ | None -> Error "the answer has no workflow_runs list"
    in
    let held = List.length items in
    let* runs =
      List.fold_left
        (fun acc item ->
          let* acc = acc in
          let* run = run_of_json target item in
          Ok (run :: acc))
        (Ok [])
        items
      |> Result.map List.rev
    in
    let checks = List.filter (fun (_, run) -> is_check_event run.event) runs in
    (match checks with
     | [] -> Ok Not_settled
     | _ :: _ when total > held && not allow_incomplete -> Ok Not_settled
     | _ :: _ ->
       if List.for_all fst checks
       then Ok (Settled (List.map snd checks))
       else Ok Not_settled)
  | _ -> Error "the runs answer is not a JSON object"
;;

(* --- The wake --- *)

type settled =
  | Checks_completed of check_run list
  | Checks_unreadable of Run_watch.read_failure

let run_line run =
  let conclusion =
    match run.conclusion with
    | Some conclusion -> Run_watch.conclusion_to_string conclusion
    | None -> "no conclusion"
  in
  Printf.sprintf "- %s (%s): %s" run.workflow (event_to_string run.event) conclusion
;;

let wake_message target settled ~original =
  let headline, lines =
    match settled with
    | Checks_completed runs ->
      ( Printf.sprintf
          "%s: %d check runs completed"
          (describe_target target)
          (List.length runs)
      , List.map run_line runs )
    | Checks_unreadable failure ->
      ( Printf.sprintf
          "could not read the runs of %s (%s). This wake came early; check the runs \
           yourself."
          (describe_target target)
          (Run_watch.read_failure_to_string failure)
      , [] )
  in
  String.concat
    "\n"
    ((("[github_checks_watch] " ^ headline) :: lines) @ [ target_url target; ""; original ])
;;

let watch_of_body body =
  match List.assoc_opt watch_field body with
  | None -> Ok None
  | Some value -> Result.map Option.some (target_of_yojson value)
;;

let watch_of_payload payload =
  match Run_watch.keeper_wake_body payload with
  | None -> Ok None
  | Some body -> watch_of_body body
;;

let settle_payload payload target settled =
  Run_watch.settle_body_payload payload ~field:watch_field ~message:(fun original ->
    wake_message target settled ~original)
;;

(* --- One pass --- *)

type verdict =
  | Woken of settled
  | Waiting_for_checks
  | Waiting_to_read of Run_watch.read_failure
  | Not_woken of string

type outcome =
  { schedule_id : string
  ; target : target option
  ; verdict : verdict
  }

let watched_row (request : Schedule_domain.schedule_request) =
  if not (Run_watch.one_shot_scheduled request)
  then None
  else (
    match watch_of_payload (Schedule_domain.payload_to_yojson request.payload) with
    | Ok None -> None
    | Ok (Some target) -> Some (request, Ok target)
    | Error detail -> Some (request, Error detail))
;;

let wake config ~now ~runner_tick_sec (scanned : Schedule_domain.schedule_request) target settled =
  match settle_payload (Schedule_domain.payload_to_yojson scanned.payload) target settled with
  | Error detail -> Not_woken detail
  | Ok payload ->
    (match Run_watch.make_due config ~now ~runner_tick_sec scanned ~payload with
     | Ok () -> Woken settled
     | Error detail -> Not_woken detail)
;;

let tick config ~now ~runner_tick_sec ~read =
  match Schedule_store.read_state_result config with
  | Error failure -> Error (Schedule_store.read_error_to_string failure)
  | Ok state ->
    let read_once = Run_watch.reads_once ~key:target_url ~read in
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
          | Ok Not_settled -> Waiting_for_checks
          | Ok (Settled runs) -> wake_with (Checks_completed runs)
          | Error failure ->
            if Run_watch.read_failure_is_permanent failure
            then wake_with (Checks_unreadable failure)
            else Waiting_to_read failure
        in
        { schedule_id = request.schedule_id; target = Some target; verdict }
    in
    Ok (List.filter_map watched_row state.Schedule_store.schedules |> List.map judge)
;;
