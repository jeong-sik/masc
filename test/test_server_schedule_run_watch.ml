open Alcotest
open Masc
module Pulls = Server_repository_pulls
module Reader = Server_github_run_reader
module Loop = Server_schedule_run_watch
module Watch = Schedule_run_watch
module Checks = Schedule_checks_watch

(* One pass of the [until_github_run] loop over a real schedule store, and the
   pause it asks for. Every case answers from a stub transport; none reaches
   GitHub. *)

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

(* --- One pass of the loop --- *)

let person id =
  { Schedule_domain.id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let watched_wake ~message run =
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc
          [ "keeper_name", `String "k-1"
          ; "message", `String message
          ; Watch.watch_field, Watch.target_to_yojson run
          ] )
    ]
;;

let create_row config ~schedule_id run =
  match
    Schedule_service.create
      config
      ~now:100.0
      ~runner_tick_sec:1.0
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(person "requester")
      ~scheduled_by:(person "scheduler")
      ~due_at:3600.0
      ~payload:(watched_wake ~message:"merge if green" run)
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok request -> request
  | Error err -> fail (Schedule_service.service_error_to_string err)
;;

let stored config schedule_id =
  match Schedule_store.get_schedule config ~schedule_id with
  | Some request -> request
  | None -> fail ("no schedule " ^ schedule_id)
;;

let message_of (request : Schedule_domain.schedule_request) =
  match Schedule_domain.payload_to_yojson request.Schedule_domain.payload with
  | `Assoc fields ->
    (match List.assoc_opt "body" fields with
     | Some (`Assoc body) ->
       (match List.assoc_opt "message" body with
        | Some (`String message) -> message
        | Some _ | None -> fail "no message")
     | Some _ | None -> fail "no body")
  | _ -> fail "payload is not an object"
;;

let pass config http_get = Loop.pass ~now:(fun () -> 200.5) ~http_get ~config

let test_pass_wakes_a_schedule_whose_run_completed () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_row config ~schedule_id:"s-1" (target 41895911884));
  let http_get, calls = stub_get (Ok (response 200 completed_run)) in
  check (float 0.0) "the next pass is one interval away" Loop.poll_interval_sec (pass config http_get);
  let woken = stored config "s-1" in
  check (float 0.0) "due at the current second" 200.0 woken.Schedule_domain.due_at;
  check
    string
    "the message tells the outcome"
    (Watch.wake_message
       (target 41895911884)
       (Watch.Run_completed (Some Watch.Success))
       ~original:"merge if green")
    (message_of woken);
  check int "one read" 1 (List.length (calls ()));
  check (float 0.0) "a second pass has nothing to read" Loop.poll_interval_sec (pass config http_get);
  check int "still one read" 1 (List.length (calls ()))
;;

let test_pass_leaves_a_schedule_whose_run_is_going () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let before = create_row config ~schedule_id:"s-1" (target 42042570610) in
  let http_get, calls = stub_get (Ok (response 200 in_progress_run)) in
  check (float 0.0) "the next pass" Loop.poll_interval_sec (pass config http_get);
  let after = stored config "s-1" in
  check string "same instance" before.Schedule_domain.schedule_instance_id after.Schedule_domain.schedule_instance_id;
  check (float 0.0) "same due time" 3600.0 after.Schedule_domain.due_at;
  check int "read again at the next pass" 1 (List.length (calls ()))
;;

let test_pass_waits_out_a_rate_limit () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_row config ~schedule_id:"s-1" (target 41895911884));
  let http_get, _ =
    stub_get (Ok (response 403 ~remaining:(Some 0) ~reset:(Some 2000.0) {|{"message":"rate limit"}|}))
  in
  check (float 0.0) "until the time GitHub gave" (2000.0 -. 200.5) (pass config http_get);
  check (float 0.0) "the schedule is untouched" 3600.0 (stored config "s-1").Schedule_domain.due_at;
  let far_http_get, _ =
    stub_get (Ok (response 429 ~retry_after:(Some 4_000_000_000) {|{"message":"slow down"}|}))
  in
  check (float 0.0) "never longer than an hour" 3600.0 (pass config far_http_get)
;;

let test_pass_wakes_early_when_the_reader_cannot_see_the_run () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_row config ~schedule_id:"s-1" (target 41895911884));
  let http_get, _ = stub_get (Ok (response 404 not_found_body)) in
  ignore (pass config http_get);
  let woken = stored config "s-1" in
  check (float 0.0) "due at the current second" 200.0 woken.Schedule_domain.due_at;
  check
    string
    "the message says the run could not be read"
    (Watch.wake_message
       (target 41895911884)
       (Watch.Run_unreadable Watch.Not_visible)
       ~original:"merge if green")
    (message_of woken)
;;

(* --- The commit watch in the same loop --- *)

let commit_sha = "8b666a19e3455100528bb90b861374c56e563f82"

let commit_target =
  match Checks.sha_of_string commit_sha with
  | Ok sha -> { Checks.repo = repo_exn "jeong-sik/masc"; sha }
  | Error detail -> fail detail
;;

let commit_runs_url =
  "https://api.github.com/repos/jeong-sik/masc/actions/runs?head_sha=" ^ commit_sha ^ "&per_page=100"
;;

let run_url = "https://api.github.com/repos/jeong-sik/masc/actions/runs/41895911884"

(* The answer for the commit: one approval run that ended, and one
   [pull_request] run in [status]. Each run carries its integer [id], as the
   GitHub answer does; the reader refuses a run without one. *)
let commit_runs status =
  let conclusion = if String.equal status "completed" then {|"success"|} else "null" in
  Printf.sprintf
    {|{"total_count":2,"workflow_runs":[{"id":41895911883,"name":"Approval merge request","event":"pull_request_review","head_sha":%S,"status":"completed","conclusion":"success"},{"id":41895911884,"name":"PR type-check (dune build @check)","event":"pull_request","head_sha":%S,"status":%S,"conclusion":%s}]}|}
    commit_sha
    commit_sha
    status
    conclusion
;;

let checks_wake ~message =
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc
          [ "keeper_name", `String "k-1"
          ; "message", `String message
          ; Checks.watch_field, Checks.target_to_yojson commit_target
          ] )
    ]
;;

let create_checks_row config ~schedule_id =
  match
    Schedule_service.create
      config
      ~now:100.0
      ~runner_tick_sec:1.0
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(person "requester")
      ~scheduled_by:(person "scheduler")
      ~due_at:3600.0
      ~payload:(checks_wake ~message:"merge if green")
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok request -> request
  | Error err -> fail (Schedule_service.service_error_to_string err)
;;

(* Answers each URL from the list; any other URL is an error that fails the
   test, so a read the case did not expect cannot pass unnoticed. *)
let routed_get routes =
  let calls = ref [] in
  let http_get ~url ~token:_ =
    calls := url :: !calls;
    match List.assoc_opt url routes with
    | Some answer -> Ok answer
    | None -> Error ("no route for " ^ url)
  in
  http_get, fun () -> List.rev !calls
;;

let test_pass_wakes_a_schedule_whose_commit_checks_completed () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_checks_row config ~schedule_id:"s-1");
  let http_get, calls = routed_get [ commit_runs_url, response 200 (commit_runs "completed") ] in
  check (float 0.0) "the next pass is one interval away" Loop.poll_interval_sec (pass config http_get);
  let woken = stored config "s-1" in
  check (float 0.0) "due at the current second" 200.0 woken.Schedule_domain.due_at;
  check
    string
    "the message lists the check run"
    (Checks.wake_message
       commit_target
       (Checks.Checks_completed
          [ { Checks.workflow = "PR type-check (dune build @check)"
            ; event = Checks.Pull_request
            ; conclusion = Some Watch.Success
            }
          ])
       ~original:"merge if green")
    (message_of woken);
  (* A settled answer wakes the schedule only after a second read of the same
     pages returns the same runs. *)
  check (list string) "the commit is read and read again" [ commit_runs_url; commit_runs_url ] (calls ());
  check (float 0.0) "a second pass has nothing to read" Loop.poll_interval_sec (pass config http_get);
  check int "the second pass read nothing" 2 (List.length (calls ()))
;;

let test_pass_leaves_a_schedule_whose_commit_checks_are_going () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  let before = create_checks_row config ~schedule_id:"s-1" in
  let http_get, calls = routed_get [ commit_runs_url, response 200 (commit_runs "in_progress") ] in
  check (float 0.0) "the next pass" Loop.poll_interval_sec (pass config http_get);
  let after = stored config "s-1" in
  check string "same instance" before.Schedule_domain.schedule_instance_id after.Schedule_domain.schedule_instance_id;
  check (float 0.0) "same due time" 3600.0 after.Schedule_domain.due_at;
  check int "read again at the next pass" 1 (List.length (calls ()))
;;

let test_pass_serves_a_run_watch_and_a_commit_watch_together () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_row config ~schedule_id:"run" (target 41895911884));
  ignore (create_checks_row config ~schedule_id:"commit");
  let http_get, calls =
    routed_get
      [ run_url, response 200 completed_run
      ; commit_runs_url, response 200 (commit_runs "completed")
      ]
  in
  ignore (pass config http_get);
  check (list string) "the run once, the settled commit twice"
    [ run_url; commit_runs_url; commit_runs_url ] (calls ());
  check (float 0.0) "the run watch woke" 200.0 (stored config "run").Schedule_domain.due_at;
  check (float 0.0) "the commit watch woke" 200.0 (stored config "commit").Schedule_domain.due_at
;;

(* Both watches read with one account, so after a limit the run watch met, the
   commit is not asked for. *)
let test_pass_skips_the_commit_read_after_a_rate_limit () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_row config ~schedule_id:"run" (target 41895911884));
  ignore (create_checks_row config ~schedule_id:"commit");
  let limited = response 403 ~remaining:(Some 0) ~reset:(Some 2000.0) {|{"message":"rate limit"}|} in
  let http_get, calls = routed_get [ run_url, limited; commit_runs_url, limited ] in
  check (float 0.0) "until the time GitHub gave" (2000.0 -. 200.5) (pass config http_get);
  check (list string) "the commit was not read" [ run_url ] (calls ());
  check (float 0.0) "the commit watch keeps its fallback" 3600.0 (stored config "commit").Schedule_domain.due_at
;;

let test_pass_waits_out_a_rate_limit_met_on_the_commit () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_checks_row config ~schedule_id:"commit");
  let limited = response 403 ~remaining:(Some 0) ~reset:(Some 2000.0) {|{"message":"rate limit"}|} in
  let http_get, _ = routed_get [ commit_runs_url, limited ] in
  check (float 0.0) "until the time GitHub gave" (2000.0 -. 200.5) (pass config http_get)
;;

let test_pass_wakes_a_commit_watch_early_when_the_reader_cannot_see_the_repository () =
  with_workspace
  @@ fun config ->
  declare_reader config "gho_reader";
  ignore (create_checks_row config ~schedule_id:"commit");
  let http_get, _ = routed_get [ commit_runs_url, response 404 not_found_body ] in
  ignore (pass config http_get);
  let woken = stored config "commit" in
  check (float 0.0) "due at the current second" 200.0 woken.Schedule_domain.due_at;
  check
    string
    "the message says the runs could not be read"
    (Checks.wake_message
       commit_target
       (Checks.Checks_unreadable Watch.Not_visible)
       ~original:"merge if green")
    (message_of woken)
;;

(* --- The pause --- *)

let outcome verdict : Watch.outcome =
  { Watch.schedule_id = "s"; target = Some (target 1); verdict }
;;

let test_pause_after () =
  let limited reset_at = outcome (Watch.Waiting_to_read (Watch.Rate_limited { reset_at })) in
  let failed failure = outcome (Watch.Waiting_to_read failure) in
  List.iter
    (fun (label, expected, outcomes) ->
      check (float 0.0) label expected (Loop.pause_after ~now:1000.0 outcomes))
    [ "nothing watched", Loop.poll_interval_sec, []
    ; "a run still going", Loop.poll_interval_sec, [ outcome Watch.Waiting_for_run ]
    ; "a limit that lifts later", 1500.0, [ limited (Some 2500.0) ]
    ; "the longest of two limits", 2000.0, [ limited (Some 2500.0); limited (Some 3000.0) ]
    ; "a limit that lifted already", Loop.poll_interval_sec, [ limited (Some 900.0) ]
    ; "a limit with no time", Loop.poll_interval_sec, [ limited None ]
    ; ( "another failure"
      , Loop.poll_interval_sec
      , [ failed (Watch.Transport_failed "curl exit code 28") ] )
    ; ( "a reader that is not ready"
      , Loop.poll_interval_sec
      , [ failed (Watch.Reader_not_ready "the declaration is being written") ] )
    ]
;;

let () =
  run
    "server_schedule_run_watch"
    [ ( "pass"
      , [ test_case
            "wakes a schedule whose run completed"
            `Quick
            test_pass_wakes_a_schedule_whose_run_completed
        ; test_case
            "leaves a schedule whose run is going"
            `Quick
            test_pass_leaves_a_schedule_whose_run_is_going
        ; test_case "waits out a rate limit" `Quick test_pass_waits_out_a_rate_limit
        ; test_case
            "wakes early when the reader cannot see the run"
            `Quick
            test_pass_wakes_early_when_the_reader_cannot_see_the_run
        ] )
    ; ( "commit watch"
      , [ test_case
            "wakes a schedule whose checks completed"
            `Quick
            test_pass_wakes_a_schedule_whose_commit_checks_completed
        ; test_case
            "leaves a schedule whose checks are going"
            `Quick
            test_pass_leaves_a_schedule_whose_commit_checks_are_going
        ; test_case
            "serves a run watch and a commit watch together"
            `Quick
            test_pass_serves_a_run_watch_and_a_commit_watch_together
        ; test_case
            "skips the commit read after a rate limit"
            `Quick
            test_pass_skips_the_commit_read_after_a_rate_limit
        ; test_case
            "waits out a rate limit met on the commit"
            `Quick
            test_pass_waits_out_a_rate_limit_met_on_the_commit
        ; test_case
            "wakes early when the reader cannot see the repository"
            `Quick
            test_pass_wakes_a_commit_watch_early_when_the_reader_cannot_see_the_repository
        ] )
    ; "pause", [ test_case "pause after" `Quick test_pause_after ]
    ]
;;
