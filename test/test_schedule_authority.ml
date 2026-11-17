open Alcotest
open Schedule_domain

module Store = Schedule_store
module Service = Schedule_service
module Runner = Schedule_runner

let retention_days = Store.terminal_schedule_retention_days
let store_ok = function Ok value -> value | Error error -> fail (Store.store_error_to_string error)
let service_ok = function Ok value -> value | Error error -> fail (Service.service_error_to_string error)
let primary config = Filename.concat (Workspace_utils.masc_dir config) Store.schedules_filename
let mirror config = primary config ^ Common.recovery_mirror_suffix
let read path = In_channel.with_open_bin path In_channel.input_all
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let human id = { id; kind = Human_operator; display_name = None }

(* This test owns only a schedule store. Use the actual filesystem backend,
   without importing unrelated Workspace initialization or accepting its
   in-memory fallback. Backend and Schedule_store create their own directories. *)
let with_backend base_path f =
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      match previous_fs with
      | None -> Fs_compat.clear_fs ()
      | Some fs -> Fs_compat.set_fs fs)
    (fun () ->
      Eio_main.run @@ fun env ->
      let fs = Eio.Stdenv.fs env in
      Fs_compat.set_fs fs;
      let backend_config = Workspace_utils.backend_config_for base_path in
      let backend = Backend.FileSystem.create ~fs ~clock:(Eio.Stdenv.clock env) backend_config in
      let config : Workspace_utils.config =
        { base_path; workspace_path = base_path; lock_expiry_minutes = 2;
          backend_config; backend = Workspace_utils.FileSystem backend }
      in
      f config)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path

let with_workspace f =
  let dir = Filename.temp_dir "schedule_authority_" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> with_backend dir f)

let create config id =
  Service.create config ~now:100.0 ~runner_tick_sec:1.0 ~schedule_id:id
    ~requested_by:(human "requester") ~scheduled_by:(human "scheduler")
    ~due_at:200.0 ~payload:(`Assoc ["kind", `String "consumer.note"; "body", `Assoc []])
    ~source:Operator_request () |> service_ok

let cancel ?(withdraw = fun _ _ -> Ok ()) config id =
  Service.cancel config ~authority:Store.Operator_authority ~schedule_id:id
    ~cancelled_by:(human "operator") ~reason:"cancel fixture" ~withdraw_queued_wakes:withdraw
    |> service_ok

let refresh config =
  Store.refresh_due config ~now:201.0 ~retention_days |> store_ok

let start config =
  let state, _ = refresh config in
  match Store.due_wake_candidates state with
  | [candidate] -> candidate, (Store.start_due_candidate config ~now:201.0 ~candidate |> store_ok)
  | _ -> fail "fixture did not produce exactly one due candidate"

let break_primary config = function
  | Store.Primary_missing -> Unix.unlink (primary config)
  | Store.Primary_unusable -> write (primary config) "{invalid primary"

let check_primary_unchanged config = function
  | Store.Primary_missing -> check bool "primary remains absent" false (Sys.file_exists (primary config))
  | Store.Primary_unusable -> check string "invalid primary preserved" "{invalid primary" (read (primary config))

let refused cause label = function
  | Error (Store.Primary_ledger_unavailable observed) ->
    check bool (label ^ " preserves cause") true (observed = cause)
  | Error error -> failf "%s: %s" label (Store.store_error_to_string error)
  | Ok _ -> fail (label ^ " accepted recovery-only authority")

let check_mirror_read config cause =
  match Store.read_state_observed config with
  | Ok (state, Store.Recovery_mirror observed) ->
    check bool "read provenance" true (observed = cause);
    check int "mirror row remains readable" 1 (List.length state.schedules)
  | Ok (_, (Store.Primary_ledger | Store.Uninitialized)) -> fail "read promoted mirror"
  | Error error -> fail (Store.read_error_to_string error)

let test_fresh () =
  with_workspace @@ fun config ->
  (match Store.read_state_observed config with
   | Ok (state, Store.Uninitialized) -> check int "fresh is empty" 0 (List.length state.schedules)
   | _ -> fail "absent ledger was not Fresh");
  check bool "read created no primary" false (Sys.file_exists (primary config));
  check bool "read created no mirror" false (Sys.file_exists (mirror config));
  ignore (create config "fresh");
  (match Store.read_state_observed config with
   | Ok (_, Store.Primary_ledger) -> ()
   | _ -> fail "fresh creation did not establish primary authority")

let test_mutations cause =
  with_workspace @@ fun config ->
  let request = create config "settled" in
  let candidate, started = start config in
  let stale = read (mirror config) in
  ignore (Store.accept_running config ~now:202.0 ~attempt:started.attempt () |> store_ok);
  let authoritative = read (primary config) in
  write (mirror config) stale;
  break_primary config cause;
  let withdrawals = ref 0 in
  let cancellation = make_cancellation ~cancelled_by:(human "operator") ~reason:"test" |> Result.get_ok in
  let operations =
    [ "insert", (fun () -> Store.insert_request config ~runner_tick_sec:1.0 request |> Result.map ignore)
    ; "update", (fun () -> Store.update_request config ~authority:Store.Operator_authority ~now:150.0 ~runner_tick_sec:1.0 request |> Result.map ignore)
    ; "cancel", (fun () -> Store.cancel_request config ~authority:Store.Operator_authority
        ~schedule_id:request.schedule_id ~cancellation
        ~withdraw_queued_wakes:(fun _ _ -> incr withdrawals; Ok ()) |> Result.map ignore)
    ; "due refresh", (fun () -> Store.refresh_due config ~now:203.0 ~retention_days |> Result.map ignore)
    ; "recurrence advance", (fun () -> Store.reschedule_due_recurring config ~now:203.0 ~schedule_ids:[request.schedule_id] |> Result.map ignore)
    ; "startup recovery", (fun () -> Store.recover_running_on_startup config ~now:203.0 |> Result.map ignore)
    ; "retire consumer", (fun () -> Store.cancel_matching config ~should_cancel:(fun _ -> true))
    ; "prune", (fun () -> Store.prune_completed config |> Result.map ignore)
    ; "append note", (fun () -> Store.append_note config ~schedule_id:request.schedule_id
        ~author_id:"operator" ~author_kind:Human_operator ~body:"refuse" ~now:203.0 |> Result.map ignore)
    ]
  in
  let attempt_operations =
    [ "start", (fun () -> Store.start_due_candidate config ~now:203.0 ~candidate |> Result.map ignore)
    ; "accept", (fun () -> Store.accept_running config ~now:202.0 ~attempt:started.attempt () |> Result.map ignore)
    ; "fail", (fun () -> Store.fail_running config ~now:202.0 ~attempt:started.attempt ~failure_scope:Store.Schedule_failure ~error:"refuse" |> Result.map ignore)
    ; "retry", (fun () -> Store.retry_running config ~now:202.0 ~attempt:started.attempt ~reason:Store.Interrupted_by_process_restart |> Result.map ignore)
    ; "reject due", (fun () -> Store.fail_due_candidate config ~now:203.0 ~candidate ~error:"refuse" |> Result.map ignore)
    ]
  in
  List.iter (fun (label, mutate) ->
    refused cause label (mutate ());
    check_primary_unchanged config cause;
    check string (label ^ " preserves mirror") stale (read (mirror config))) operations;
  List.iter (fun (label, mutate) ->
    (match mutate () with
     | Error (Store.Running_attempt_unavailable {schedule_id; _}) ->
       check string (label ^ " keeps attempt identity") request.schedule_id schedule_id
     | Error error -> failf "%s: %s" label (Store.store_error_to_string error)
     | Ok () -> fail (label ^ " accepted recovery-only attempt authority"));
    check_primary_unchanged config cause;
    check string (label ^ " preserves mirror") stale (read (mirror config))) attempt_operations;
  check int "no cancellation callback" 0 !withdrawals;
  check_mirror_read config cause;
  check_primary_unchanged config cause;
  check string "read preserves mirror" stale (read (mirror config));
  write (primary config) authoritative;
  ignore (create config "restored");
  match Store.get_schedule config ~schedule_id:request.schedule_id with
  | Some row -> check string "settlement survives restoration" "succeeded" (schedule_status_to_string row.status)
  | None -> fail "settled row disappeared"

let test_service cause =
  with_workspace @@ fun config ->
  let request = create config "cancelled" in
  let stale = read (mirror config) in
  ignore (cancel config request.schedule_id);
  write (mirror config) stale;
  break_primary config cause;
  let withdrawals = ref 0 in
  (match Service.cancel config ~authority:Store.Operator_authority ~schedule_id:request.schedule_id
    ~cancelled_by:(human "operator") ~reason:"repeat"
    ~withdraw_queued_wakes:(fun _ _ -> incr withdrawals; Ok ()) with
   | Error (Service.Store_error (Store.Primary_ledger_unavailable observed)) ->
     check bool "service preserves cause" true (observed = cause)
   | Error error -> fail (Service.service_error_to_string error)
   | Ok _ -> fail "service cancellation accepted mirror");
  check int "service never withdraws consumer work" 0 !withdrawals;
  check_primary_unchanged config cause;
  check string "service preserves mirror" stale (read (mirror config))

let consumer calls : Runner.consumer =
  { accepts = (fun _ -> incr calls; Ok ())
  ; defer_wake = (fun _ ~occurrence_id:_ _ -> incr calls; None)
  ; dispatch = (fun _ ~now:_ _ _ ~commit_acceptance ->
      incr calls;
      let detail = `Assoc ["accepted", `Bool true] in
      Result.map (fun acceptance_commit -> Runner.Work_accepted {detail; acceptance_commit})
        (commit_acceptance detail))
  }

let tick config calls =
  Runner.tick config ~consumer:(consumer calls) ~pending_settlements:[]
    ~now:203.0 ~retention_days

let signals config = Dated_jsonl.read_recent (Runner.signal_store config) 100

let check_runner_refusal config cause =
  let before = signals config in
  let calls = ref 0 in
  (match tick config calls with
   | Error {Runner.error = Runner.Service_error (Service.Store_error
       (Store.Primary_ledger_unavailable observed)); _} ->
     check bool "runner preserves cause" true (observed = cause)
   | Error error -> fail (Runner.tick_failure_to_string error)
   | Ok _ -> fail "runner accepted mirror");
  check int "no consumer hooks" 0 !calls;
  check (list string) "signal rows unchanged"
    (List.map Yojson.Safe.to_string before) (List.map Yojson.Safe.to_string (signals config))

let reopen_child base_path cause =
  with_backend base_path @@ fun config ->
  let stale = read (mirror config) in
  check_mirror_read config cause;
  refused cause "restarted startup recovery" (Store.recover_running_on_startup config ~now:204.0);
  check_runner_refusal config cause;
  check_primary_unchanged config cause;
  check string "restarted process preserves mirror" stale (read (mirror config))

let child_reopen config cause =
  let executable = Unix.realpath Sys.executable_name in
  let cause_arg = match cause with Store.Primary_missing -> "missing" | Store.Primary_unusable -> "unusable" in
  let argv = [|executable; "--reopen"; config.Workspace_utils.base_path; cause_arg|] in
  let pid = Unix.create_process executable argv Unix.stdin Unix.stdout Unix.stderr in
  let rec wait () =
    match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
  in
  match wait () with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> failf "fresh child exited %d" code
  | Unix.WSIGNALED signal -> failf "fresh child signalled %d" signal
  | Unix.WSTOPPED signal -> failf "fresh child stopped %d" signal

let test_running_restart cause =
  with_workspace @@ fun config ->
  ignore (create config "settled-before-restart");
  let _, started = start config in
  let stale = read (mirror config) in
  ignore (Store.accept_running config ~now:202.0 ~attempt:started.attempt () |> store_ok);
  write (mirror config) stale;
  break_primary config cause;
  child_reopen config cause;
  check_primary_unchanged config cause;
  check string "running mirror survives fresh child" stale (read (mirror config))

let test_runner ~completed ~restart cause =
  with_workspace @@ fun config ->
  let request = create config "terminal" in
  let stale = read (mirror config) in
  if completed then (
    let calls = ref 0 in
    match tick config calls with
    | Ok _ -> check bool "fixture really dispatched" true (!calls > 0)
    | Error error -> fail (Runner.tick_failure_to_string error))
  else ignore (cancel config request.schedule_id);
  let authoritative = read (primary config) in
  let before = signals config in
  write (mirror config) stale;
  break_primary config cause;
  check_runner_refusal config cause;
  if restart then child_reopen config cause;
  check_primary_unchanged config cause;
  check string "runner preserves mirror" stale (read (mirror config));
  check int "no additional signal" (List.length before) (List.length (signals config));
  write (primary config) authoritative;
  let calls = ref 0 in
  (match tick config calls with
   | Ok _ -> ()
   | Error error -> fail (Runner.tick_failure_to_string error));
  check int "restored terminal authority prevents another dispatch" 0 !calls

let () =
  match Array.to_list Sys.argv with
  | [_; "--reopen"; base; "missing"] -> reopen_child base Store.Primary_missing
  | [_; "--reopen"; base; "unusable"] -> reopen_child base Store.Primary_unusable
  | _ ->
    let cases =
      List.concat_map (fun (label, cause) ->
        [ test_case ("all mutations/" ^ label) `Quick (fun () -> test_mutations cause)
        ; test_case ("running mirror and fresh child/" ^ label) `Quick (fun () -> test_running_restart cause)
        ; test_case ("service callback/" ^ label) `Quick (fun () -> test_service cause)
        ; test_case ("cancelled runner and fresh child/" ^ label) `Quick (fun () -> test_runner ~completed:false ~restart:true cause)
        ; test_case ("settled runner and fresh child/" ^ label) `Quick (fun () -> test_runner ~completed:true ~restart:true cause)
        ]) ["missing", Store.Primary_missing; "unusable", Store.Primary_unusable]
    in
    run "Schedule authority" ["authority", test_case "Fresh remains writable" `Quick test_fresh :: cases]
