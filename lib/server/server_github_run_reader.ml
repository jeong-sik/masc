module Pulls = Server_repository_pulls
module Facts = Repository_pulls
module Watch = Schedule_run_watch
module Checks = Schedule_checks_watch

let path_of_target (target : Watch.target) =
  let attempt =
    match target.run_attempt with
    | None -> ""
    | Some attempt -> Printf.sprintf "/attempts/%d" attempt
  in
  Printf.sprintf
    "/repos/%s/actions/runs/%d%s"
    (Watch.repo_to_string target.repo)
    target.run_id
    attempt
;;

(* One page of 100 runs. A commit with more runs than that is read as an
   unreadable answer by {!Schedule_checks_watch.observation_of_runs_json}. *)
let checks_runs_per_page = 100

let checks_path_of_target (target : Checks.target) =
  Printf.sprintf
    "/repos/%s/actions/runs?head_sha=%s&per_page=%d"
    (Watch.repo_to_string target.repo)
    (Checks.sha_to_string target.sha)
    checks_runs_per_page
;;

let http_not_found = 404

(* GitHub's REST limits reset within an hour. A longer wait in a header is not
   one the limit can ask for, and a time that far ahead would stop every watch
   from being read until then and would not format as a date in the log. *)
let longest_rate_limit_wait_sec = 3600.0

(* The status rules are the pull request reader's: the same GitHub rate-limit
   headers and the same reading of a 403. A REST answer adds one case, the 404
   that [failure_of_status] reports as a plain HTTP status. *)
let read_failure_of_status ~now_s response : Watch.read_failure option =
  match Pulls.failure_of_status ~now_s response with
  | None -> None
  | Some Facts.Token_rejected -> Some Watch.Token_rejected
  | Some (Facts.Rate_limited { reset_at }) ->
    let latest = now_s +. longest_rate_limit_wait_sec in
    Some (Watch.Rate_limited { reset_at = Option.map (Float.min latest) reset_at })
  | Some (Facts.Forbidden _) -> Some Watch.Forbidden
  | Some (Facts.Http_status { status }) when status = http_not_found -> Some Watch.Not_visible
  | Some (Facts.Http_status { status }) -> Some (Watch.Http_status status)
  | Some (Facts.Transport_failed message) -> Some (Watch.Transport_failed message)
  | Some (Facts.Response_unreadable message) -> Some (Watch.Response_unreadable message)
  | Some (Facts.Repository_not_visible | Facts.Graphql_errors _) ->
    (* [failure_of_status] reads the status line and the rate-limit headers
       only; these two come from a GraphQL body. *)
    Some (Watch.Response_unreadable "an HTTP status was read as a GraphQL failure")
;;

let interpret_with ~parse ~now_s (response : Pulls.response) =
  match read_failure_of_status ~now_s response with
  | Some failure -> Error failure
  | None ->
    (match Yojson.Safe.from_string response.body with
     | exception Yojson.Json_error message -> Error (Watch.Response_unreadable message)
     | json -> parse json |> Result.map_error (fun message -> Watch.Response_unreadable message))
;;

let interpret ~now_s target response =
  interpret_with ~parse:(Watch.observation_of_run_json target) ~now_s response
;;

let interpret_checks ~now_s target response =
  interpret_with ~parse:(Checks.observation_of_runs_json target) ~now_s response
;;

(* Why the reader cannot be used. A declaration that is absent stays absent
   until someone declares it, and its text reaches the Keeper's wake message,
   so it names no Keeper or file. A declaration or a token that could not be
   read can come from a file being written or a descriptor limit; asking again
   can pass, and the detail goes to the server log only. *)
let failure_of_reader (reader : Facts.reader) : Watch.read_failure =
  match reader with
  | Facts.Reader_not_declared ->
    Watch.Reader_unavailable "no [repositories] pr_reader is declared"
  | Facts.Reader_keeper_missing _ ->
    Watch.Reader_unavailable "the declared pr_reader is not a configured Keeper"
  | Facts.Reader_declaration_invalid reason ->
    Watch.Reader_not_ready ("the declaration is invalid or unreadable: " ^ reason)
  | Facts.Reader_token_unavailable { keeper; reason } ->
    Watch.Reader_not_ready (Printf.sprintf "no token for %s: %s" keeper reason)
  | Facts.Reader_ready { keeper } ->
    Watch.Reader_not_ready (Printf.sprintf "%s is ready but its read was refused" keeper)
;;

let read_path ~now ~http_get ~config ~path ~interpret =
  match Pulls.rest_get ~http_get ~config ~path with
  | Error (Pulls.Reader_not_ready reader) -> Error (failure_of_reader reader)
  | Error (Pulls.Reader_host_not_github host) ->
    Error
      (Watch.Reader_unavailable
         (Printf.sprintf "the pr_reader reads %s, and run reads go to github.com only" host))
  | Error (Pulls.Rest_transport_failed message) -> Error (Watch.Transport_failed message)
  | Ok response -> interpret ~now_s:(now ()) response
;;

let read ~now ~http_get ~config target =
  read_path
    ~now
    ~http_get
    ~config
    ~path:(path_of_target target)
    ~interpret:(fun ~now_s response -> interpret ~now_s target response)
;;

let read_checks ~now ~http_get ~config target =
  read_path
    ~now
    ~http_get
    ~config
    ~path:(checks_path_of_target target)
    ~interpret:(fun ~now_s response -> interpret_checks ~now_s target response)
;;
