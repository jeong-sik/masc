open Alcotest

module Payload = struct
  type registration = Yojson.Safe.t
  type completion = Yojson.Safe.t
  let name = "strict-current-fixture"
  let registration_to_yojson value = value
  let registration_of_yojson value = Ok value
  let retired_registration_of_yojson _ = Ok None
  let completion_to_yojson value = value
  let completion_of_yojson value = Ok value
  let shed_registration _ = `Null
  let shed_completion _ = `Null
  let running_noun = "request"
  let restart_reason = "fixture restart"
  let replayed_running_completion = Some (fun ~started_at:_ _ -> `String "restart projection")
  let completed_retention = `All
  let retention_group = None
end
module R = Run_registry_core.Make (Payload)
let json = testable Yojson.Safe.pp Yojson.Safe.equal
let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let load = Fs_compat.load_file
let with_path work =
  let directory = Filename.temp_dir "registry-current-disk-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory)
    (fun () -> work directory (Filename.concat directory "runs.jsonl"))
let selected registry = match R.read_current_from_log registry ~id:"original" with
  | Ok (Some entry) -> entry
  | Ok None -> fail "original registration is absent"
  | Error _ -> fail "original history is unreadable"
let register registry input = R.register registry ~id:"original" ~started_at:123. ~registration:input
let complete registry output = match R.complete registry ~id:"original" ~completion:output with
  | `Completed -> ()
  | `Unknown | `Persistence_failed _ -> fail "fixture completion was not persisted"
let assert_running entry = match entry.R.status with
  | R.Running -> () | Completed _ -> fail "disk Running was converted to a terminal"
let assert_completed output entry = match entry.R.status with
  | R.Completed actual -> check json "full completion from the current log" output actual
  | Running -> fail "durable completion was lost"
let error_name = function
  | R.Volatile_store -> "volatile"
  | Not_initialized -> "not initialized"
  | Incomplete_startup _ -> "incomplete startup"
  | Non_regular_history _ -> "nonregular"
  | Invalid_history _ -> "invalid history"
  | Incomplete_history -> "incomplete history"
  | Snapshot_changed -> "snapshot changed"
  | Read_failed _ -> "read failed"
  | Read_cleanup_failed _ -> "read cleanup failed"
let check_error label expected = function
  | Error error -> check string label expected (error_name error)
  | Ok (Some _ | None) -> fail (label ^ ": unexpectedly readable")
let register_row id input = Yojson.Safe.to_string (`Assoc ["event",`String "register";
  "id",`String id;"started_at",`Float 123.;"registration",input]) ^ "\n"
let complete_row id output = Yojson.Safe.to_string (`Assoc ["event",`String "complete";
  "id",`String id;"completion",output]) ^ "\n"

let test_full_lifecycle () = with_path (fun _ path ->
  let registry = R.replay path in
  let input = `Assoc ["prompt",`String (String.make 70000 'x')] in
  register registry input;
  let entry = selected registry in
  check json "requested registration is never a shed placeholder" input entry.registration;
  assert_running entry;
  complete registry (`Assoc ["answer",`String "original"]);
  assert_completed (`Assoc ["answer",`String "original"]) (selected registry);
  register registry `Null;
  let replacement = selected registry in
  check json "available JSON null is preserved" `Null replacement.registration;
  assert_running replacement;
  complete registry `Null;
  assert_completed `Null (selected registry))

let test_readiness () = with_path (fun _ path ->
  check_error "volatile state is unavailable" "volatile"
    (R.read_current_from_log (R.create ()) ~id:"original");
  let unopened = R.create ~path () in
  register unopened (`String "real bytes"); complete unopened (`String "real result");
  check_error "create cannot borrow disk authority from its live projection" "not initialized"
    (R.read_current_from_log unopened ~id:"original");
  check bool "legacy completion lookup preserves its create contract" true
    (match R.completed_from_log unopened ~id:"original" with
     | Ok (Some entry) -> (match entry.status with R.Completed _ -> true | Running -> false)
     | Ok None | Error _ -> false))

let test_missing_is_read_only () = with_path (fun directory path ->
  let registry = R.replay path in
  let before = Array.to_list (Sys.readdir directory) in
  check bool "initial ENOENT is distinct absence" true
    (R.read_current_from_log registry ~id:"original" = Ok None);
  check (list string) "read creates no log or sibling lock file" before (Array.to_list (Sys.readdir directory));
  write path "";
  Unix.chmod path 0o640;
  check bool "present empty log has no original registration" true
    (R.read_current_from_log registry ~id:"original" = Ok None);
  check int "read does not chmod existing history" 0o640 ((Unix.stat path).st_perm land 0o777))

let test_current_damage_refuses_all () = with_path (fun _ path ->
  let registry = R.replay path in
  register registry (`String "original input"); complete registry (`String "original output");
  let valid = load path in
  List.iter (fun suffix ->
    write path (valid ^ suffix);
    check_error "unrelated malformed/orphan history refuses the requested terminal" "invalid history"
      (R.read_current_from_log registry ~id:"original"))
    ["{bad JSON}\n";complete_row "unregistered-other" (`String "orphan")];
  write path (valid ^ "{unfinished");
  let bytes = load path in
  check_error "unterminated tail refuses even a readable original terminal" "incomplete history"
    (R.read_current_from_log registry ~id:"original");
  check string "failed read does not truncate or repair" bytes (load path))

let test_incomplete_startup_is_not_erased () = with_path (fun _ path ->
  write path (register_row "original" (`String "input") ^ "{broken}\n");
  let registry = R.replay path in
  write path (register_row "original" (`String "input"));
  check_error "later readable bytes do not erase incomplete startup" "incomplete startup"
    (R.read_current_from_log registry ~id:"original"))

let test_disk_running_is_not_replay_projection () = with_path (fun _ path ->
  let registry = R.replay path in
  register registry (`String "retained input");
  let bytes = load path in
  let restarted = R.replay_with_retained_history path in
  (match R.get_metadata restarted ~id:"original" with
   | Some {status=R.Completed _;_} -> ()
   | Some {status=R.Running;_} | None -> fail "fixture did not create a restart projection");
  assert_running (selected restarted);
  check string "strict observation never serializes a synthetic restart" bytes (load path))

let test_prefix_rewrite_is_fresh () = with_path (fun _ path ->
  let registry = R.replay path in
  register registry (`String "first"); complete registry (`String "answer");
  ignore (R.completed_from_log registry ~id:"original");
  ignore (selected registry);
  let inode = (Unix.stat path).st_ino in
  write path (register_row "original" (`String "other") ^ complete_row "original" (`String "answer")
    ^ register_row "another" `Null);
  check int "fixture rewrites and extends the same inode" inode (Unix.stat path).st_ino;
  check json "fresh read does not reuse an append-prefix cache" (`String "other") (selected registry).registration)

let test_io_is_not_absence () = with_path (fun directory path ->
  write path "regular parent";
  let impossible = Filename.concat path "child.jsonl" in
  let registry = R.replay impossible in
  check_error "ENOTDIR is not ENOENT" "read failed"
    (R.read_current_from_log registry ~id:"original");
  let registry = R.replay (Filename.concat directory "not-yet-present") in
  Unix.mkdir (Filename.concat directory "not-yet-present") 0o700;
  check_error "a directory cannot be an empty history" "nonregular"
    (R.read_current_from_log registry ~id:"original"))

let folded path f = Fs_compat.fold_private_jsonl_locked_result path ~init:[]
  ~f:(fun rows row -> f row;row::rows)
let test_stream_framing_and_alias () = with_path (fun directory path ->
  let long = String.make 70000 'a' in
  write path ("\n" ^ long ^ "\nlast\npartial");
  let alias = Filename.concat directory "alias" in
  Unix.symlink path alias;
  match folded alias (fun _ -> ()) with
  | Fs_compat.Private_file_succeeded (Fs_compat.Private_jsonl_fold.Present {value;rows_end;end_offset}) ->
    check (list string) "stream handles blank rows and a row spanning buffers" ["last";long;""] value;
    check int "complete rows boundary" (String.length long + 7) rows_end;
    check int "tail remains explicitly outside the fold" (rows_end + 7) end_offset
  | Private_file_succeeded Missing | Private_file_failed _
  | Private_file_succeeded_with_cleanup_failure _ | Private_file_failed_with_cleanup_failure _ ->
    fail "regular target alias did not stream")

let test_changed_binding_is_refused () = with_path (fun directory path ->
  write path "original\n";
  let replacement = Filename.concat directory "replacement" in
  write replacement "different\n";
  let result = folded path (fun _ -> Unix.rename replacement path) in
  check bool "read from an unlinked descriptor is never current history" true
    (match result with
     | Fs_compat.Private_file_failed Fs_compat.Private_jsonl_fold.Snapshot_changed -> true
     | Private_file_succeeded _ | Private_file_failed (Read_error _)
     | Private_file_succeeded_with_cleanup_failure _ | Private_file_failed_with_cleanup_failure _ -> false);
  check string "reader does not restore or overwrite the replacement" "different\n" (load path))

let test_concurrent_reads_and_writes () = with_path (fun _ path ->
  let registry = R.replay path in
  register registry (`String "retained");
  Eio_main.run (fun _ -> Eio.Fiber.both
    (fun () -> complete registry (`String "terminal"))
    (fun () -> ignore (selected registry)));
  assert_completed (`String "terminal") (selected registry))

let test_startup_orphan_cannot_be_compacted_away () = with_path (fun _ path ->
  write path (complete_row "orphan" `Null);
  let original=load path in
  let module B = Run_registry_core.Make (struct include Payload let completed_retention=`Latest 1 end) in
  let registry=B.replay path in
  check string "orphan prevents otherwise clean compaction" original (load path);
  check bool "strict reconciliation cannot borrow false clean startup authority" true
    (match B.reconcile_current registry ~id:"original" ~decide:(fun _ -> Ok (B.Confirm_current,())) with
     | Error (B.Current_source_unavailable (B.Incomplete_startup report)) -> report.malformed_lines=1
     | Ok () | Error (Current_source_unavailable (Volatile_store | Not_initialized | Non_regular_history _
         | Invalid_history _ | Incomplete_history | Snapshot_changed | Read_failed _ | Read_cleanup_failed _)
         | Decision_refused _ | Invalid_change _ | Publication_failed _) -> false))
let test_retained_history_late_terminal_has_original_registration () = with_path (fun _ path ->
  let module B = Run_registry_core.Make (struct include Payload let completed_retention=`Latest 1 end) in
  write path (register_row "old" `Null ^ complete_row "old" `Null
    ^ register_row "new" `Null ^ complete_row "new" `Null ^ complete_row "old" (`String "late"));
  let registry=B.replay_with_retained_history path in
  check bool "retention eviction is not an orphaned lifecycle" true
    (match B.replay_status registry with
     | Run_registry_core.Replayed report -> report.malformed_lines=0 && report.reached_end
     | Not_replayed | Log_absent -> false))

module Retired_payload = struct
  include Payload
  let completed_retention = `Latest 2
  let retired_registration_of_yojson = function
    | `Assoc fields ->
      (match List.assoc_opt "kind" fields with
       | Some (`String "retired") ->
         (match List.assoc_opt "lane" fields with
          | Some (`String lane) -> Ok (Some lane)
          | Some _ | None -> Error "retired registration missing lane")
       | Some (`String "active") -> Ok None
       | Some _ | None -> Error "unknown registration kind")
    | _ -> Error "registration must be an object"
  let registration_of_yojson = function
    | `Assoc fields as value ->
      (match List.assoc_opt "kind" fields with
       | Some (`String "active") -> Ok value
       | Some _ | None -> Error "non-active registration")
    | _ -> Error "registration must be an object"
end
module RT = Run_registry_core.Make (Retired_payload)

let register_row_at id started_at input =
  Yojson.Safe.to_string
    (`Assoc [ "event", `String "register"; "id", `String id; "started_at", `Float started_at; "registration", input ])
  ^ "\n"
let active_reg label = `Assoc ["kind", `String "active"; "label", `String label]
let retired_reg lane = `Assoc ["kind", `String "retired"; "lane", `String lane]

let contains_substring ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  nlen = 0 || loop 0

let capture_stderr f =
  let pipe_read, pipe_write = Unix.pipe () in
  let saved_stderr = Unix.dup Unix.stderr in
  Unix.dup2 pipe_write Unix.stderr;
  Unix.close pipe_write;
  let result =
    Fun.protect
      ~finally:(fun () ->
        flush stderr;
        Unix.dup2 saved_stderr Unix.stderr;
        Unix.close saved_stderr)
      f
  in
  Unix.set_nonblock pipe_read;
  let buf = Buffer.create 256 in
  let tmp = Bytes.create 256 in
  let rec read_all () =
    match Unix.read pipe_read tmp 0 256 with
    | 0 -> ()
    | n ->
      Buffer.add_subbytes buf tmp 0 n;
      read_all ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
  in
  read_all ();
  Unix.close pipe_read;
  result, Buffer.contents buf

let test_retired_pair_is_counted_and_compacted_while_preserving_active () = with_path (fun _ path ->
  let evicted_rows =
    register_row_at "active-evicted" 1. (active_reg "evicted")
    ^ complete_row "active-evicted" (`String "evicted-out")
  in
  let active_1_rows =
    register_row_at "active-1" 2. (active_reg "a1")
    ^ complete_row "active-1" (`String "out-1")
  in
  let retired_rows =
    register_row_at "retired-1" 3. (retired_reg "librarian_memory")
    ^ complete_row "retired-1" (`String "retired-out")
  in
  let active_2_rows =
    register_row_at "active-2" 4. (active_reg "a2")
    ^ complete_row "active-2" (`String "out-2")
  in
  let expected_preserved = active_1_rows ^ retired_rows ^ active_2_rows in
  let expected_digest = Digest.to_hex (Digest.string expected_preserved) in
  write path (evicted_rows ^ expected_preserved);
  let first, first_logs = capture_stderr (fun () -> RT.replay path) in
  (match RT.replay_status first with
   | Run_registry_core.Replayed
       { lines_read = 8
       ; malformed_lines = 0
       ; retired_registrations = 1
       ; retired_completions = 1
       ; dropped_running = 0
       ; reached_end = true
       } -> ()
   | _ -> fail "first replay should count retired pair separately from malformed lines");
  check (list string) "retired_ids exposes preserved retired registration id" [ "retired-1" ] (RT.retired_ids first);
  let after_first = load path in
  check string "compaction evicts old active rows while preserving retired pair bytes and event order verbatim"
    expected_preserved after_first;
  check string "preserved retired and active rows retain exact digest"
    expected_digest (Digest.to_hex (Digest.string after_first));
  check bool "first boot emits aggregate retired summary" true
    (contains_substring ~needle:"skipped 1 retired registration(s) and 1 paired completion(s) during replay" first_logs);
  check bool "first boot emits no per-id unknown completion warning" false
    (contains_substring ~needle:"replay skipped completion for unknown id" first_logs);
  check bool "retired id is absent from projection" true (Option.is_none (RT.get_metadata first ~id:"retired-1"));
  check bool "retired id is absent from strict read" true (RT.read_current_from_log first ~id:"retired-1" = Ok None);
  (match RT.read_current_from_log first ~id:"active-1" with
   | Ok (Some { registration; status = RT.Completed (`String "out-1"); _ }) ->
     check json "active-1 registration preserved" (active_reg "a1") registration
   | _ -> fail "active-1 was not preserved");
  (match RT.read_current_from_log first ~id:"active-2" with
   | Ok (Some { registration; status = RT.Completed (`String "out-2"); _ }) ->
     check json "active-2 registration preserved" (active_reg "a2") registration
   | _ -> fail "active-2 was not preserved");
  let second, second_logs = capture_stderr (fun () -> RT.replay path) in
  (match RT.replay_status second with
   | Run_registry_core.Replayed
       { lines_read = 6
       ; malformed_lines = 0
       ; retired_registrations = 1
       ; retired_completions = 1
       ; dropped_running = 0
       ; reached_end = true
       } -> ()
   | _ -> fail "reboot replay should continue observing preserved retired rows with zero malformed lines");
  check string "reboot compaction keeps identical bytes and digest"
    expected_digest (Digest.to_hex (Digest.string (load path)));
  check bool "reboot emits aggregate retired summary" true
    (contains_substring ~needle:"skipped 1 retired registration(s) and 1 paired completion(s) during replay" second_logs);
  check bool "reboot emits no per-id unknown completion warning" false
    (contains_substring ~needle:"replay skipped completion for unknown id" second_logs))

let test_retired_pair_with_retained_history_allows_strict_reads () = with_path (fun _ path ->
  write path
    (register_row "retired-1" (retired_reg "workspace_memory_curator")
     ^ register_row "active-1" (active_reg "a1")
     ^ complete_row "active-1" (`String "out-1"));
  let registry = RT.replay_with_retained_history path in
  (match RT.completed_from_log registry ~id:"active-1" with
   | Ok (Some { status = RT.Completed (`String "out-1"); _ }) -> ()
   | _ -> fail "active-1 completion should be readable before retired completion arrives");
  (* Append retired completion later to exercise incremental observer_index.retired *)
  let channel = open_out_gen [Open_append; Open_binary] 0o600 path in
  output_string channel (complete_row "retired-1" (`String "late-retired-out"));
  close_out channel;
  check bool "retired completion returns Ok None in completed_from_log" true
    (RT.completed_from_log registry ~id:"retired-1" = Ok None);
  (match RT.completed_from_log registry ~id:"active-1" with
   | Ok (Some { status = RT.Completed (`String "out-1"); _ }) -> ()
   | _ -> fail "active-1 completion remains readable after retired completion");
  check bool "retired id returns Ok None in read_current_from_log" true
    (RT.read_current_from_log registry ~id:"retired-1" = Ok None);
  check bool "reconcile_current confirms active-1 despite retained retired rows" true
    (RT.reconcile_current registry ~id:"active-1"
       ~decide:(fun current ->
         match current with
         | Some { status = RT.Completed (`String "out-1"); _ } -> Ok (RT.Confirm_current, ())
         | _ -> Error "missing active-1")
     = Ok ()))

let test_true_orphan_and_corrupted_retired_row_remain_malformed () = with_path (fun _ path ->
  let orphan_log =
    register_row "retired-1" (retired_reg "verifier_exact")
    ^ complete_row "retired-1" (`String "retired-out")
    ^ complete_row "unknown-orphan" (`String "orphan-out")
  in
  write path orphan_log;
  let reg_orphan = RT.replay path in
  check string "true orphan blocks compaction even with retired pairs" orphan_log (load path);
  (match RT.replay_status reg_orphan with
   | Run_registry_core.Replayed
       { lines_read = 3
       ; malformed_lines = 1
       ; retired_registrations = 1
       ; retired_completions = 1
       ; dropped_running = 0
       ; reached_end = true
       } -> ()
   | _ -> fail "true orphan must still be counted as malformed");
  check bool "incomplete startup refuses strict read when orphan is present" true
    (match RT.read_current_from_log reg_orphan ~id:"retired-1" with
     | Error (RT.Incomplete_startup report) -> report.malformed_lines = 1
     | _ -> false);
  let broken_retired =
    register_row "broken-retired" (`Assoc ["kind", `String "retired"])
    ^ complete_row "broken-retired" (`String "out")
  in
  write path broken_retired;
  let reg_broken = RT.replay path in
  check string "corrupted retired registration blocks compaction" broken_retired (load path);
  match RT.replay_status reg_broken with
  | Run_registry_core.Replayed
      { lines_read = 2
      ; malformed_lines = 2
      ; retired_registrations = 0
      ; retired_completions = 0
      ; dropped_running = 0
      ; reached_end = true
      } -> ()
  | _ -> fail "corrupted retired registration and its completion must be malformed")

let () = run "strict current registry disk observation" ["current history",[
  test_case "startup orphan cannot disappear before strict publication" `Quick test_startup_orphan_cannot_be_compacted_away;
  test_case "retention eviction does not orphan a valid late terminal" `Quick test_retained_history_late_terminal_has_original_registration;
  test_case "retired registration and completion pairs are counted and compacted cleanly" `Quick test_retired_pair_is_counted_and_compacted_while_preserving_active;
  test_case "retained retired rows allow strict reads and incremental observer lookup" `Quick test_retired_pair_with_retained_history_allows_strict_reads;
  test_case "true orphans and corrupted retired rows remain malformed" `Quick test_true_orphan_and_corrupted_retired_row_remain_malformed;
  test_case "full registration, terminal, reset and available null" `Quick test_full_lifecycle;
  test_case "volatile/uninitialized and legacy lookup contracts" `Quick test_readiness;
  test_case "absent and empty reads never create or chmod" `Quick test_missing_is_read_only;
  test_case "unrelated damage and partial tails refuse without repair" `Quick test_current_damage_refuses_all;
  test_case "incomplete startup remains explicit" `Quick test_incomplete_startup_is_not_erased;
  test_case "actual disk Running differs from replay completion" `Quick test_disk_running_is_not_replay_projection;
  test_case "same-inode prefix replacement is read fresh" `Quick test_prefix_rewrite_is_fresh;
  test_case "I/O and nonregular history are not absence" `Quick test_io_is_not_absence;
  test_case "stream framing and regular symlink contract" `Quick test_stream_framing_and_alias;
  test_case "changed path binding rejects stale descriptor" `Quick test_changed_binding_is_refused;
  test_case "current read serializes with completion" `Quick test_concurrent_reads_and_writes]]
