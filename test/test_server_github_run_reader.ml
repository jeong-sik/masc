open Alcotest
open Masc
module Pulls = Server_repository_pulls
module Reader = Server_github_run_reader
module Loop = Server_schedule_run_watch
module Watch = Schedule_run_watch
module Checks = Schedule_checks_watch

(* The server half of [until_github_run]: what a GitHub answer says about a
   run, which account reads it, and what one pass of the loop does to a
   schedule. Every case answers from a stub transport; none reaches GitHub. *)

let now_s = 1_790_000_000.0

let response ?(remaining = Some 4990) ?(reset = None) ?(retry_after = None) status body
  : Pulls.response
  =
  { Pulls.status
  ; body
  ; rate_limit_remaining = remaining
  ; rate_limit_reset = reset
  ; retry_after_s = retry_after
  }
;;

let repo_exn raw =
  match Watch.repo_of_string raw with
  | Ok repo -> repo
  | Error detail -> fail detail
;;

let target ?attempt run_id =
  { Watch.repo = repo_exn "jeong-sik/masc"; run_id; run_attempt = attempt }
;;

(* GET /repos/jeong-sik/masc/actions/runs/{id} answers read on 2026-11-05, cut
   to the fields a reader could use. *)
let completed_run =
  {|{"conclusion":"success","event":"pull_request","id":41895911884,"name":"PR type-check (dune build @check)","run_attempt":1,"status":"completed"}|}
;;

let in_progress_run =
  {|{"conclusion":null,"event":"pull_request","id":42042570610,"name":"PR type-check (dune build @check)","run_attempt":1,"status":"in_progress"}|}
;;

let not_found_body =
  {|{"message":"Not Found","documentation_url":"https://docs.github.com/rest/actions/workflow-runs#get-a-workflow-run","status":"404"}|}
;;

let result_to_string = function
  | Ok Watch.Not_completed -> "not completed"
  | Ok (Watch.Completed None) -> "completed, no conclusion"
  | Ok (Watch.Completed (Some conclusion)) ->
    "completed " ^ Watch.conclusion_to_string conclusion
  | Error failure -> "failed: " ^ Watch.read_failure_to_string failure
;;

(* Two failures agree when they are the same case with the same facts. The
   sentences that explain a case are for a person and are not compared. *)
let same_failure (a : Watch.read_failure) (b : Watch.read_failure) =
  match a, b with
  | Watch.Response_unreadable _, Watch.Response_unreadable _
  | Watch.Reader_unavailable _, Watch.Reader_unavailable _
  | Watch.Reader_not_ready _, Watch.Reader_not_ready _ -> true
  | _ -> a = b
;;

let read_answer =
  testable
    (fun ppf result -> Format.pp_print_string ppf (result_to_string result))
    (fun a b ->
      match a, b with
      | Error x, Error y -> same_failure x y
      | _ -> a = b)
;;

let check_read label expected result = check read_answer label expected result

(* --- What an answer says --- *)

let test_path () =
  check
    string
    "latest attempt"
    "/repos/jeong-sik/masc/actions/runs/41895911884"
    (Reader.path_of_target (target 41895911884));
  check
    string
    "named attempt"
    "/repos/jeong-sik/masc/actions/runs/41895911884/attempts/2"
    (Reader.path_of_target (target ~attempt:2 41895911884))
;;

let test_interpret_runs () =
  let read run_id body = Reader.interpret ~now_s (target run_id) (response 200 body) in
  check_read
    "completed"
    (Ok (Watch.Completed (Some Watch.Success)))
    (read 41895911884 completed_run);
  check_read "in progress" (Ok Watch.Not_completed) (read 42042570610 in_progress_run);
  check_read
    "an answer about another run"
    (Error (Watch.Response_unreadable ""))
    (read 7 completed_run);
  (match read 41895911884 "<html>" with
   | Error (Watch.Response_unreadable _) -> ()
   | Ok _ | Error _ -> fail "a body that is not JSON must read as unreadable");
  check bool "a 200 with an error-shaped body is not a run" true
    (Result.is_error (read 41895911884 not_found_body))
;;

let test_interpret_statuses () =
  let read r = Reader.interpret ~now_s (target 41895911884) r in
  let limit_used_up reset = response 403 ~remaining:(Some 0) ~reset:(Some reset) "{}" in
  List.iter
    (fun (label, expected, answer) -> check_read label expected (read answer))
    [ "404 is the repository or the run", Error Watch.Not_visible, response 404 not_found_body
    ; ( "401"
      , Error Watch.Token_rejected
      , response 401 {|{"message":"Bad credentials"}|} )
    ; "plain 403", Error Watch.Forbidden, response 403 "{}"
    ; ( "403 with the limit used up"
      , Error (Watch.Rate_limited { reset_at = Some (now_s +. 600.0) })
      , limit_used_up (now_s +. 600.0) )
    ; ( "403 with retry-after"
      , Error (Watch.Rate_limited { reset_at = Some (now_s +. 20.0) })
      , response 403 ~retry_after:(Some 20) ~reset:(Some (now_s +. 600.0)) "{}" )
    ; "429 without a time", Error (Watch.Rate_limited { reset_at = None }), response 429 "{}"
    ; "500", Error (Watch.Http_status 500), response 500 "{}"
    ; "408", Error (Watch.Http_status 408), response 408 "{}"
    ; "301", Error (Watch.Http_status 301), response 301 "{}"
    ]
;;

(* A header that names a time more than an hour ahead is read as an hour
   ahead: the pause it sets must not outlast any limit GitHub has, and the log
   line that prints the time must not meet a date it cannot format. *)
let test_a_rate_limit_wait_is_bounded () =
  let read r = Reader.interpret ~now_s (target 41895911884) r in
  List.iter
    (fun (label, expected, answer) -> check_read label expected (read answer))
    [ ( "retry-after of many years"
      , Error (Watch.Rate_limited { reset_at = Some (now_s +. 3600.0) })
      , response 429 ~retry_after:(Some 4_000_000_000) "{}" )
    ; ( "a reset time in the next century"
      , Error (Watch.Rate_limited { reset_at = Some (now_s +. 3600.0) })
      , response 403 ~remaining:(Some 0) ~reset:(Some 1.0e17) "{}" )
    ; ( "a wait inside the hour stays"
      , Error (Watch.Rate_limited { reset_at = Some (now_s +. 60.0) })
      , response 429 ~retry_after:(Some 60) "{}" )
    ]
;;

(* --- Which account reads --- *)

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

let write_file path text =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc text)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path)
    else Sys.remove path
;;

let reader_keeper = "pr-reader"

(* runtime.toml names the reader, the Keeper is declared and its GitHub CLI
   holds [token] for [host]. *)
let declare_reader ?(host = "github.com") ?(declaration = "") config token =
  let base_path = config.Workspace.base_path in
  write_file
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
    (Printf.sprintf "[repositories]\npr_reader = %S\n%s" reader_keeper declaration);
  write_file
    (Config_dir_resolver.keeper_toml_path_for_base_path ~base_path reader_keeper)
    "[keeper]\n";
  match Keeper_github_identity.secret_files_of_base_path ~base_path ~keeper_name:reader_keeper with
  | [ hosts ] ->
    write_file hosts (Printf.sprintf "%s:\n  user: reader\n  oauth_token: %s\n" host token);
    Unix.chmod hosts 0o600
  | _ -> fail "expected one hosts.yml path for the reader"
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_dir "server_github_run_reader_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf path);
  let config = Workspace.default_config path in
  ignore (Workspace.init config ~agent_name:(Some "run-reader-test"));
  f config
;;

(* Answers every GET with [answer] and records the URL and token of each. *)
let stub_get answer =
  let calls = ref [] in
  let http_get ~url ~token =
    calls := (url, token) :: !calls;
    answer
  in
  http_get, fun () -> List.rev !calls
;;

let test_read_uses_the_declared_reader () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let http_get, calls = stub_get (Ok (response 200 completed_run)) in
  check_read
    "the run"
    (Ok (Watch.Completed (Some Watch.Success)))
    (Reader.read ~now:(fun () -> now_s) ~http_get ~config (target 41895911884));
  check
    (list (pair string string))
    "the REST URL and the reader's token"
    [ "https://api.github.com/repos/jeong-sik/masc/actions/runs/41895911884", "gho_reader" ]
    (calls ())
;;

let test_read_without_a_reader_does_not_reach_github () =
  with_workspace
  @@ fun config ->
  let http_get, calls = stub_get (Ok (response 200 completed_run)) in
  (match Reader.read ~now:(fun () -> now_s) ~http_get ~config (target 41895911884) with
   | Error (Watch.Reader_unavailable _) -> ()
   | Ok _ | Error _ -> fail "no declared reader must read as unavailable");
  check int "no request" 0 (List.length (calls ()))
;;

let test_read_on_another_host_does_not_reach_github () =
  with_workspace
  @@ fun config ->
  declare_reader
    config
    ~host:"ghe.example"
    ~declaration:"github_host = \"ghe.example\"\ngraphql_url = \"https://ghe.example/api/graphql\"\n"
    "gho_enterprise";
  let http_get, calls = stub_get (Ok (response 200 completed_run)) in
  (match Reader.read ~now:(fun () -> now_s) ~http_get ~config (target 41895911884) with
   | Error (Watch.Reader_unavailable reason) ->
     check bool "the reason names the host" true
       (String_util.contains_substring reason "ghe.example")
   | Ok _ | Error _ -> fail "an Enterprise reader must read as unavailable");
  check int "no request" 0 (List.length (calls ()))
;;

let write_runtime_toml config text =
  write_file
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:config.Workspace.base_path)
    text
;;

let read_once config =
  let http_get, calls = stub_get (Ok (response 200 completed_run)) in
  Reader.read ~now:(fun () -> now_s) ~http_get ~config (target 41895911884), calls
;;

(* A declaration that cannot be used and a declared reader whose token cannot
   be found are states the next pass may find changed: a file being written, a
   login that finishes. Reading them as permanent would wake every watched
   schedule early and drop its watch for good. *)
let test_a_reader_that_is_not_ready_can_pass () =
  with_workspace
  @@ fun config ->
  write_runtime_toml config "[repositories]\npr_reader = 42\n";
  let invalid, calls = read_once config in
  (match invalid with
   | Error (Watch.Reader_not_ready _ as failure) ->
     check bool "an invalid declaration can pass" false (Watch.read_failure_is_permanent failure)
   | Ok _ | Error _ -> fail "an invalid declaration must read as not ready");
  check int "no request" 0 (List.length (calls ()));
  write_runtime_toml config (Printf.sprintf "[repositories]\npr_reader = %S\n" reader_keeper);
  write_file
    (Config_dir_resolver.keeper_toml_path_for_base_path
       ~base_path:config.Workspace.base_path
       reader_keeper)
    "[keeper]\n";
  match fst (read_once config) with
  | Error (Watch.Reader_not_ready _ as failure) ->
    check bool "a missing token can pass" false (Watch.read_failure_is_permanent failure)
  | Ok _ | Error _ -> fail "a reader without a token must read as not ready"
;;

(* The text of a permanent reader failure goes into the Keeper's wake message,
   so it carries no name from runtime.toml and no file text. *)
let test_a_pr_reader_that_is_not_a_keeper_is_permanent_and_names_nothing () =
  with_workspace
  @@ fun config ->
  write_runtime_toml config (Printf.sprintf "[repositories]\npr_reader = %S\n" reader_keeper);
  match fst (read_once config) with
  | Error (Watch.Reader_unavailable text as failure) ->
    check bool "permanent" true (Watch.read_failure_is_permanent failure);
    check bool "the text names no Keeper" false (String_util.contains_substring text reader_keeper)
  | Ok _ | Error _ -> fail "a pr_reader that is not a Keeper must read as unavailable"
;;

let test_read_reports_a_request_that_did_not_complete () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let http_get, _ = stub_get (Error "curl exit code 28: Operation timed out") in
  check_read
    "transport"
    (Error (Watch.Transport_failed "curl exit code 28: Operation timed out"))
    (Reader.read ~now:(fun () -> now_s) ~http_get ~config (target 41895911884))
;;

(* --- The runs of a commit --- *)

let commit_sha = "8b666a19e3455100528bb90b861374c56e563f82"

let commit_target =
  match Checks.sha_of_string commit_sha with
  | Ok sha -> { Checks.repo = repo_exn "jeong-sik/masc"; sha }
  | Error detail -> fail detail
;;

(* GET /repos/jeong-sik/masc/actions/runs?head_sha=8b666a19...&per_page=100
   answered on 2026-11-11 for the head of #51286, cut to the fields a reader
   could use. *)
let runs_of_51286 =
  let run id name event status conclusion =
    Printf.sprintf
      {|{"id":%d,"name":%S,"event":%S,"head_sha":%S,"status":%S,"conclusion":%s}|}
      id
      name
      event
      commit_sha
      status
      conclusion
  in
  let approval id event = run id "Approval merge request" event "completed" {|"success"|} in
  Printf.sprintf
    {|{"total_count":8,"workflow_runs":[%s]}|}
    (String.concat
       ","
       [ approval 1 "pull_request_target"
       ; approval 2 "pull_request_target"
       ; approval 3 "pull_request_review"
       ; run 4 "PR type-check (dune build @check)" "pull_request" "completed" {|"cancelled"|}
       ; run 5 "Changelog fragments" "pull_request" "completed" {|"success"|}
       ; run 6 "Changelog fragments" "pull_request" "completed" {|"success"|}
       ; run 7 "PR type-check (dune build @check)" "pull_request" "completed" {|"failure"|}
       ; approval 8 "pull_request_review"
       ])
;;

let checks_result_to_string = function
  | Ok Checks.Not_settled -> "not settled"
  | Ok (Checks.Settled runs) -> Printf.sprintf "settled %d" (List.length runs)
  | Error failure -> "failed: " ^ Watch.read_failure_to_string failure
;;

let checks_answer =
  testable
    (fun ppf result -> Format.pp_print_string ppf (checks_result_to_string result))
    (fun a b ->
      match a, b with
      | Error x, Error y -> same_failure x y
      | Ok (Checks.Settled x), Ok (Checks.Settled y) -> List.length x = List.length y
      | _ -> a = b)
;;

let test_checks_path () =
  check
    string
    "the runs of the head sha, one page of 100"
    ("/repos/jeong-sik/masc/actions/runs?head_sha=" ^ commit_sha ^ "&per_page=100")
    (Reader.checks_path_of_target commit_target)
;;

let test_interpret_checks () =
  let read r = Reader.interpret_checks ~now_s commit_target r in
  let settled_by_four =
    Ok (Checks.Settled (List.init 4 (fun _ ->
      { Checks.workflow = ""; event = Checks.Pull_request; conclusion = None })))
  in
  List.iter
    (fun (label, expected, answer) -> check checks_answer label expected (read answer))
    [ "the head of 51286", settled_by_four, response 200 runs_of_51286
    ; ( "a commit no workflow ran on is not a missing repository"
      , Ok Checks.Not_settled
      , response 200 {|{"total_count":0,"workflow_runs":[]}|} )
    ; "404 is the repository", Error Watch.Not_visible, response 404 not_found_body
    ; ( "a limit used up"
      , Error (Watch.Rate_limited { reset_at = Some (now_s +. 600.0) })
      , response 403 ~remaining:(Some 0) ~reset:(Some (now_s +. 600.0)) "{}" )
    ; "a body that is not JSON", Error (Watch.Response_unreadable ""), response 200 "<html>"
    ; ( "more runs than one page"
      , Ok Checks.Not_settled
      , response 200 {|{"total_count":250,"workflow_runs":[]}|} )
    ; ( "an error-shaped body"
      , Error (Watch.Response_unreadable "")
      , response 200 not_found_body )
    ]
;;

let test_read_checks_uses_the_declared_reader () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let http_get, calls = stub_get (Ok (response 200 runs_of_51286)) in
  let url =
    "https://api.github.com/repos/jeong-sik/masc/actions/runs?head_sha=" ^ commit_sha ^ "&per_page=100"
  in
  check
    checks_answer
    "four check runs"
    (Ok (Checks.Settled (List.init 4 (fun _ ->
      { Checks.workflow = ""; event = Checks.Pull_request; conclusion = None }))))
    (Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target);
  check
    (list (pair string string))
    "the REST URL and the reader's token, revalidated once"
    [ url, "gho_reader"; url, "gho_reader" ]
    (calls ())
;;

let completed_check_run_json ~id ?(event = "pull_request") ?(status = "completed") ?(conclusion = "success") () =
  Printf.sprintf
    {|{"id":%d,"name":"run-%03d","event":%S,"head_sha":%S,"status":%S,"conclusion":%S}|}
    id
    id
    event
    commit_sha
    status
    conclusion
;;

let runs_page ~total_count runs =
  Printf.sprintf
    {|{"total_count":%d,"workflow_runs":[%s]}|}
    total_count
    (String.concat "," runs)
;;

let checks_url page =
  let base =
    "https://api.github.com/repos/jeong-sik/masc/actions/runs?head_sha=" ^ commit_sha ^ "&per_page=100"
  in
  if page = 1 then base else base ^ "&page=" ^ string_of_int page
;;

let read_with_answers answers =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let calls = ref [] in
  let http_get ~url ~token =
    calls := (url, token) :: !calls;
    match List.assoc_opt url answers with
    | Some answer -> answer
    | None -> Error ("unexpected URL: " ^ url)
  in
  let result = Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target in
  result, List.rev !calls
;;

let expected_run_names count = List.init count (fun index -> Printf.sprintf "run-%03d" (index + 1))

let check_settled_names label expected result =
  match result with
  | Ok (Checks.Settled runs) ->
    check (list string) label expected (List.map (fun run -> run.Checks.workflow) runs)
  | Ok Checks.Not_settled -> fail (label ^ ": not settled")
  | Error failure -> fail (label ^ ": " ^ Watch.read_failure_to_string failure)
;;

let test_read_checks_reads_every_page () =
  let result, calls =
    read_with_answers
      [ checks_url 1, Ok (response 200 (runs_page ~total_count:101 (List.init 100 (fun index -> completed_check_run_json ~id:(index + 1) ()))))
      ; checks_url 2, Ok (response 200 (runs_page ~total_count:101 [ completed_check_run_json ~id:101 () ]))
      ]
  in
  check_settled_names "all 101 check runs" (expected_run_names 101) result;
  check
    (list (pair string string))
    "both pages read and revalidated"
    [ checks_url 1, "gho_reader"; checks_url 2, "gho_reader"; checks_url 1, "gho_reader"; checks_url 2, "gho_reader" ]
    calls
;;

let test_read_checks_allows_empty_check_page () =
  let result, calls =
    read_with_answers
      [ checks_url 1, Ok (response 200 (runs_page ~total_count:101 (List.init 100 (fun index -> completed_check_run_json ~id:(index + 1) ()))))
      ; checks_url 2, Ok (response 200 (runs_page ~total_count:101 [ completed_check_run_json ~id:101 ~event:"pull_request_target" () ]))
      ]
  in
  check_settled_names "all 100 check runs" (expected_run_names 100) result;
  check
    (list (pair string string))
    "both pages read and revalidated"
    [ checks_url 1, "gho_reader"; checks_url 2, "gho_reader"; checks_url 1, "gho_reader"; checks_url 2, "gho_reader" ]
    calls
;;

let test_read_checks_preserves_watch_when_total_count_changes () =
  let result, calls =
    read_with_answers
      [ checks_url 1, Ok (response 200 (runs_page ~total_count:101 (List.init 100 (fun index -> completed_check_run_json ~id:(index + 1) ()))))
      ; checks_url 2, Ok (response 200 (runs_page ~total_count:102 [ completed_check_run_json ~id:101 () ]))
      ]
  in
  check checks_answer "changed total_count" (Ok Checks.Not_settled) result;
  check
    (list (pair string string))
    "both pages"
    [ checks_url 1, "gho_reader"; checks_url 2, "gho_reader" ]
    calls
;;

let test_read_checks_preserves_watch_when_run_ids_repeat () =
  let result, calls =
    read_with_answers
      [ checks_url 1, Ok (response 200 (runs_page ~total_count:101 (List.init 100 (fun index -> completed_check_run_json ~id:(index + 1) ()))))
      ; checks_url 2, Ok (response 200 (runs_page ~total_count:101 [ completed_check_run_json ~id:100 () ]))
      ]
  in
  check checks_answer "duplicate run id" (Ok Checks.Not_settled) result;
  check
    (list (pair string string))
    "both pages"
    [ checks_url 1, "gho_reader"; checks_url 2, "gho_reader" ]
    calls
;;

let test_read_checks_rechecks_later_page_membership () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let second_url = checks_url 2 in
  let second_calls = ref 0 in
  let calls = ref [] in
  let original_first = runs_page ~total_count:101 (List.init 100 (fun index -> completed_check_run_json ~id:(index + 1) ())) in
  let original_second = runs_page ~total_count:101 [ completed_check_run_json ~id:101 () ] in
  let replacement_second = runs_page ~total_count:101 [ completed_check_run_json ~id:999 () ] in
  let http_get ~url ~token =
    calls := (url, token) :: !calls;
    if url = second_url then (
      second_calls := !second_calls + 1;
      if !second_calls = 1 then Ok (response 200 original_second) else Ok (response 200 replacement_second))
    else if url = checks_url 1 then Ok (response 200 original_first)
    else Error ("unexpected URL: " ^ url)
  in
  let result = Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target in
  check checks_answer "changed later-page membership" (Ok Checks.Not_settled) result;
  check
    (list (pair string string))
    "both pages read and revalidated"
    [ checks_url 1, "gho_reader"; second_url, "gho_reader"; checks_url 1, "gho_reader"; second_url, "gho_reader" ]
    (List.rev !calls)
;;

let test_read_checks_rejects_duplicate_ids_on_same_page () =
  let result, calls =
    read_with_answers
      [ checks_url 1,
        Ok (response 200 (runs_page ~total_count:1 [ completed_check_run_json ~id:1 (); completed_check_run_json ~id:1 () ])) ]
  in
  check checks_answer "duplicate ids on one page" (Ok Checks.Not_settled) result;
  check (list (pair string string)) "one page" [ checks_url 1, "gho_reader" ] calls
;;

let test_read_checks_all_empty_pages_are_not_settled () =
  let result, calls =
    read_with_answers
      [ checks_url 1,
        Ok (response 200
          (runs_page ~total_count:101
            (List.init 100 (fun index -> completed_check_run_json ~id:(index + 1) ~event:"pull_request_target" ()))))
      ; checks_url 2,
        Ok (response 200 (runs_page ~total_count:101 [ completed_check_run_json ~id:101 ~event:"pull_request_target" () ])) ]
  in
  check checks_answer "all pages empty of checks" (Ok Checks.Not_settled) result;
  check
    (list (pair string string))
    "both pages"
    [ checks_url 1, "gho_reader"; checks_url 2, "gho_reader" ]
    calls
;;

let test_read_checks_rejects_total_change_on_revalidation () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let first_url = checks_url 1 in
  let first_calls = ref 0 in
  let calls = ref [] in
  let original = runs_page ~total_count:1 [ completed_check_run_json ~id:1 () ] in
  let changed = runs_page ~total_count:2 [ completed_check_run_json ~id:1 () ] in
  let http_get ~url ~token =
    calls := (url, token) :: !calls;
    if url = first_url then (
      first_calls := !first_calls + 1;
      if !first_calls = 1 then Ok (response 200 original) else Ok (response 200 changed))
    else
      Error ("unexpected URL: " ^ url)
  in
  let result = Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target in
  check checks_answer "total changed on revalidation" (Ok Checks.Not_settled) result;
  check (list (pair string string)) "first page read twice" [ first_url, "gho_reader"; first_url, "gho_reader" ] (List.rev !calls)
;;

let test_read_checks_rejects_queued_on_revalidation () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let first_url = checks_url 1 in
  let first_calls = ref 0 in
  let calls = ref [] in
  let original = runs_page ~total_count:1 [ completed_check_run_json ~id:1 () ] in
  let queued = runs_page ~total_count:1 [ completed_check_run_json ~id:1 ~status:"in_progress" ~conclusion:"null" () ] in
  let http_get ~url ~token =
    calls := (url, token) :: !calls;
    if url = first_url then (
      first_calls := !first_calls + 1;
      if !first_calls = 1 then Ok (response 200 original) else Ok (response 200 queued))
    else
      Error ("unexpected URL: " ^ url)
  in
  let result = Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target in
  check checks_answer "completed became queued on revalidation" (Ok Checks.Not_settled) result;
  check (list (pair string string)) "first page read twice" [ first_url, "gho_reader"; first_url, "gho_reader" ] (List.rev !calls)
;;

let test_read_checks_rejects_duplicate_id_on_revalidation () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let first_url = checks_url 1 in
  let first_calls = ref 0 in
  let calls = ref [] in
  let original = runs_page ~total_count:1 [ completed_check_run_json ~id:1 () ] in
  let duplicate = runs_page ~total_count:1 [ completed_check_run_json ~id:1 (); completed_check_run_json ~id:1 () ] in
  let http_get ~url ~token =
    calls := (url, token) :: !calls;
    if url = first_url then (
      first_calls := !first_calls + 1;
      if !first_calls = 1 then Ok (response 200 original) else Ok (response 200 duplicate))
    else
      Error ("unexpected URL: " ^ url)
  in
  let result = Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target in
  check checks_answer "duplicate id on revalidation" (Ok Checks.Not_settled) result;
  check (list (pair string string)) "first page read twice" [ first_url, "gho_reader"; first_url, "gho_reader" ] (List.rev !calls)
;;

let test_read_checks_rechecks_first_page_membership () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let first_url = checks_url 1 in
  let first_calls = ref 0 in
  let calls = ref [] in
  let original = runs_page ~total_count:101 (List.init 100 (fun index -> completed_check_run_json ~id:(index + 1) ())) in
  let replacement =
    runs_page ~total_count:101
      (completed_check_run_json ~id:999 ()
      :: List.init 99 (fun index -> completed_check_run_json ~id:(index + 2) ()))
  in
  let http_get ~url ~token =
    calls := (url, token) :: !calls;
    if url = first_url then (
      first_calls := !first_calls + 1;
      if !first_calls = 1 then Ok (response 200 original) else Ok (response 200 replacement))
    else if url = checks_url 2 then
      Ok (response 200 (runs_page ~total_count:101 [ completed_check_run_json ~id:101 () ]))
    else
      Error ("unexpected URL: " ^ url)
  in
  let result = Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target in
  check checks_answer "changed first-page membership" (Ok Checks.Not_settled) result;
  check
    (list (pair string string))
    "first page read twice and second page once"
    [ first_url, "gho_reader"; checks_url 2, "gho_reader"; first_url, "gho_reader" ]
    (List.rev !calls)
;;

let test_read_checks_rejects_more_unique_runs_than_total () =
  let result, calls =
    read_with_answers
      [ checks_url 1,
        Ok (response 200 (runs_page ~total_count:1 [ completed_check_run_json ~id:1 (); completed_check_run_json ~id:2 () ])) ]
  in
  check checks_answer "more unique runs than total" (Ok Checks.Not_settled) result;
  check (list (pair string string)) "one page" [ checks_url 1, "gho_reader" ] calls
;;

let test_read_checks_rejects_missing_id () =
  let missing_id =
    Printf.sprintf
      {|{"name":"run-1","event":"pull_request","head_sha":%S,"status":"completed","conclusion":"success"}|}
      commit_sha
  in
  let result, calls =
    read_with_answers [ checks_url 1, Ok (response 200 (runs_page ~total_count:1 [ missing_id ])) ]
  in
  check checks_answer "missing run id" (Error (Watch.Response_unreadable "")) result;
  check (list (pair string string)) "one page" [ checks_url 1, "gho_reader" ] calls
;;

let test_read_checks_without_a_reader_does_not_reach_github () =
  with_workspace
  @@ fun config ->
  let http_get, calls = stub_get (Ok (response 200 runs_of_51286)) in
  check
    checks_answer
    "no reader"
    (Error (Watch.Reader_unavailable ""))
    (Reader.read_checks ~now:(fun () -> now_s) ~http_get ~config commit_target);
  check int "no request" 0 (List.length (calls ()))
;;

let () =
  run
    "server_github_run_reader"
    [ ( "answer"
      , [ test_case "path" `Quick test_path
        ; test_case "runs" `Quick test_interpret_runs
        ; test_case "statuses" `Quick test_interpret_statuses
        ; test_case "a rate limit wait is bounded" `Quick test_a_rate_limit_wait_is_bounded
        ] )
    ; ( "reader"
      , [ test_case "uses the declared reader" `Quick test_read_uses_the_declared_reader
        ; test_case
            "without a reader it does not reach GitHub"
            `Quick
            test_read_without_a_reader_does_not_reach_github
        ; test_case
            "on another host it does not reach GitHub"
            `Quick
            test_read_on_another_host_does_not_reach_github
        ; test_case
            "a reader that is not ready can pass"
            `Quick
            test_a_reader_that_is_not_ready_can_pass
        ; test_case
            "a pr_reader that is not a Keeper is permanent and names nothing"
            `Quick
            test_a_pr_reader_that_is_not_a_keeper_is_permanent_and_names_nothing
        ; test_case
            "reports a request that did not complete"
            `Quick
            test_read_reports_a_request_that_did_not_complete
        ] )
    ; ( "commit"
      , [ test_case "path" `Quick test_checks_path
        ; test_case "answers" `Quick test_interpret_checks
        ; test_case "uses the declared reader" `Quick test_read_checks_uses_the_declared_reader
        ; test_case "reads every page" `Quick test_read_checks_reads_every_page
        ; test_case "allows empty check page" `Quick test_read_checks_allows_empty_check_page
        ; test_case "changed total_count" `Quick test_read_checks_preserves_watch_when_total_count_changes
        ; test_case "duplicate run ids" `Quick test_read_checks_preserves_watch_when_run_ids_repeat
        ; test_case "rechecks later-page membership" `Quick test_read_checks_rechecks_later_page_membership
        ; test_case "duplicate ids on one page" `Quick test_read_checks_rejects_duplicate_ids_on_same_page
        ; test_case "all pages empty of checks" `Quick test_read_checks_all_empty_pages_are_not_settled
        ; test_case "total changed on revalidation" `Quick test_read_checks_rejects_total_change_on_revalidation
        ; test_case "completed became queued on revalidation" `Quick test_read_checks_rejects_queued_on_revalidation
        ; test_case "duplicate id on revalidation" `Quick test_read_checks_rejects_duplicate_id_on_revalidation
        ; test_case "rechecks first-page membership" `Quick test_read_checks_rechecks_first_page_membership
        ; test_case "more unique runs than total" `Quick test_read_checks_rejects_more_unique_runs_than_total
        ; test_case "missing run id" `Quick test_read_checks_rejects_missing_id
        ; test_case
            "without a reader it does not reach GitHub"
            `Quick
            test_read_checks_without_a_reader_does_not_reach_github
        ] )
    ]
;;
