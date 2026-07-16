(* RFC-0266 §7 Phase D — fusion run registry persistence.

   Verify that register/complete append JSONL events and that replay restores
   the registry with completed-run pruning. Tests are isolated: each case gets
   its own temp file path; the process-wide {!Fusion_run_registry.global} is
   never touched. *)

open Alcotest
module Registry = Fusion_run_registry
module R = struct
  include Registry

  let operation ~run_id ~keeper ~preset : Fusion_types.fusion_operation =
    { request =
        { run_id
        ; keeper
        ; prompt = "durable registry test"
        ; preset
        ; web_tools = true
        ; depth = Fusion_types.Fusion_depth.Top
        ; trigger = Fusion_types.Harness_eval
        }
    ; topology = Fusion_types.Judge_of_judges
    }
  ;;

  let mark_completed_result t ~run_id ?failure ?failure_code ~ok () =
    Registry.mark_completed t ~operation_id:run_id ?failure ?failure_code ~ok ()
  ;;

  let get t ~run_id = Registry.get t ~operation_id:run_id

  let register_running t ~run_id ~keeper ~preset ~started_at =
    match
      Registry.register_running t ~operation:(operation ~run_id ~keeper ~preset) ~started_at
    with
    | Ok () -> ()
    | Error error -> fail (Registry.persistence_error_to_string error)
  ;;

  let mark_completed t ~run_id ?failure ?failure_code ~ok () =
    match mark_completed_result t ~run_id ?failure ?failure_code ~ok () with
    | Ok () -> ()
    | Error error -> fail (Registry.completion_error_to_string error)
  ;;
end

let parse s = Yojson.Safe.from_string s

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let contains_substring value needle =
  let value_len = String.length value in
  let needle_len = String.length needle in
  let rec loop index =
    if needle_len = 0
    then true
    else if index + needle_len > value_len
    then false
    else if String.sub value index needle_len = needle
    then true
    else loop (index + 1)
  in
  loop 0
;;

let fresh_path suffix =
  let path = Filename.temp_file "fusion-runs-" suffix in
  remove_if_exists path;
  path
;;

let register_event ~run_id ~keeper ~preset ~started_at =
  Fusion_run_registry_event.Register
    { operation = R.operation ~run_id ~keeper ~preset; started_at }
  |> Fusion_run_registry_event.to_yojson
  |> Yojson.Safe.to_string
;;

let complete_event ~run_id ~ok =
  Fusion_run_registry_event.Complete
    { operation_id = run_id
    ; ok
    ; failure = None
    ; failure_code = None
    }
  |> Fusion_run_registry_event.to_yojson
  |> Yojson.Safe.to_string
;;

let field j k =
  match j with
  | `Assoc l -> List.assoc_opt k l
  | _ -> None
;;

let str j k =
  match field j k with
  | Some (`String s) -> s
  | _ -> failwith (Printf.sprintf "missing string field %s" k)
;;

let bool_ j k =
  match field j k with
  | Some (`Bool b) -> b
  | _ -> failwith (Printf.sprintf "missing bool field %s" k)
;;

let float_ j k =
  match field j k with
  | Some (`Float f) -> f
  | _ -> failwith (Printf.sprintf "missing float field %s" k)
;;

(* (1) Register + complete writes two JSONL lines plus a trailing newline. *)
let test_persist_register_complete () =
  let path = fresh_path ".jsonl" in
  let t = R.create ~path () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"p" ~started_at:1.0;
  R.mark_completed t ~run_id:"r1" ~ok:true ();
  let content = Fs_compat.load_file path in
  let lines = String.split_on_char '\n' content in
  check int "two events + trailing newline" 3 (List.length lines);
  let event1 = parse (List.nth lines 0) in
  check string "event1 kind" "register" (str event1 "event");
  let persisted_operation =
    match field event1 "operation" with
    | Some json ->
      (match Fusion_types.fusion_operation_of_yojson json with
       | Ok operation -> operation
       | Error error -> fail error)
    | None -> fail "register event must contain its canonical operation"
  in
  check bool "event1 canonical operation" true
    (Fusion_types.equal_fusion_operation
       (R.operation ~run_id:"r1" ~keeper:"k" ~preset:"p")
       persisted_operation);
  check (float 0.001) "event1 started_at" 1.0 (float_ event1 "started_at");
  let event2 = parse (List.nth lines 1) in
  check string "event2 kind" "complete" (str event2 "event");
  check string "event2 operation_id" "r1" (str event2 "operation_id");
  check bool "event2 ok" true (bool_ event2 "ok")
;;

let test_persist_failure_detail () =
  let path = fresh_path "-failure.jsonl" in
  let t = R.create ~path () in
  R.register_running t ~run_id:"r-fail" ~keeper:"k" ~preset:"p" ~started_at:1.0;
  R.mark_completed t ~run_id:"r-fail" ~failure:"judge failed: bad json"
    ~failure_code:"parse_error" ~ok:false ();
  let content = Fs_compat.load_file path in
  let lines = String.split_on_char '\n' content in
  let event2 = parse (List.nth lines 1) in
  check string "event2 failure" "judge failed: bad json" (str event2 "failure");
  check string "event2 failure_code" "parse_error" (str event2 "failure_code");
  let replayed = R.replay path in
  match R.get replayed ~run_id:"r-fail" with
  | Some { R.status = R.Completed { ok = false; failure; failure_code; _ }; _ } ->
    check (option string) "replayed failure" (Some "judge failed: bad json")
      failure;
    check (option string) "replayed failure_code" (Some "parse_error")
      failure_code
  | Some _ -> fail "expected replayed failed completion"
  | None -> fail "expected replayed run"
;;

let test_completion_append_failure_is_explicit () =
  let path = fresh_path "-completion-failure.jsonl" in
  let t = R.create ~path () in
  R.register_running t ~run_id:"r-volatile-complete" ~keeper:"k" ~preset:"p"
    ~started_at:1.0;
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Unix.rmdir path)
    (fun () ->
       (match R.mark_completed_result t ~run_id:"r-volatile-complete" ~ok:true () with
        | Error
            (R.Completion_persistence_failed
               (R.Append_failed { path = failed_path; _ })) ->
          check string "failed completion path" path failed_path
        | Error error -> fail (R.completion_error_to_string error)
        | Ok () -> fail "completion append failure must be explicit");
       match R.get t ~run_id:"r-volatile-complete" with
       | Some
           ({ R.status =
                R.Completed
                  { ok = true; receipt = R.Persistence_failed _; _ }
            ; _
            } as run) ->
         let json = R.run_to_yojson run in
         check string "receipt status" "persistence_failed" (str json "receipt_status")
       | Some _ -> fail "actual completion must retain failed receipt state"
       | None -> fail "completed run must remain observable")
;;

(* (2) Replay prunes completed runs to the newest [max_completed_retained]
   while preserving register-only rows as explicit recovery work. *)
let test_replay_prunes_completed () =
  let path = fresh_path "-prune.jsonl" in
  let t = R.create ~path () in
  for i = 1 to 70 do
    R.register_running
      t
      ~run_id:("r" ^ string_of_int i)
      ~keeper:"k"
      ~preset:"p"
      ~started_at:(float_of_int i);
    R.mark_completed t ~run_id:("r" ^ string_of_int i) ~ok:true ()
  done;
  (* Leave one run in [Running] state. The old worker is dead, so replay must
     expose it as recovery-required rather than live or silently dropping it. *)
  R.register_running t ~run_id:"r-running" ~keeper:"k" ~preset:"p" ~started_at:71.0;
  let t2 = R.replay path in
  let runs = R.list_runs t2 in
  check int "completed retention plus recovery row"
    (R.max_completed_retained + 1) (List.length runs);
  (match R.get t2 ~run_id:"r-running" with
   | Some
       { R.operation
       ; status = R.Recovery_required { reason = R.Worker_process_restarted }
       ; _
       } ->
     check bool "recovery row preserves canonical operation" true
       (Fusion_types.equal_fusion_operation
          (R.operation ~run_id:"r-running" ~keeper:"k" ~preset:"p")
          operation)
   | Some _ -> fail "unfinished run must be recovery-required after replay"
   | None -> fail "unfinished run must remain observable after replay");
  check bool "compacted log preserves unfinished run" true
    (contains_substring (Fs_compat.load_file path) "r-running");
  (* Newest completed run (r70) must be present; oldest (r1) pruned. *)
  check bool "newest completed kept" true (Option.is_some (R.get t2 ~run_id:"r70"));
  check bool "oldest completed pruned" true (Option.is_none (R.get t2 ~run_id:"r1"))
;;

(* (3) A fresh registry without a backing path does not write files. *)
let test_no_path_is_in_memory_only () =
  let path = fresh_path "-no-path.jsonl" in
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"p" ~started_at:1.0;
  R.mark_completed t ~run_id:"r1" ~ok:true ();
  check bool "no file created" false (Sys.file_exists path)
;;

(* (4) Replay skips malformed and removed-schema lines without dropping valid
   neighboring canonical events. The old metadata-only schema is not migrated. *)
let test_replay_skips_malformed_lines () =
  let path = fresh_path "-malformed.jsonl" in
  Fs_compat.save_file
    path
    (String.concat
       "\n"
	       [ register_event ~run_id:"r1" ~keeper:"k" ~preset:"p" ~started_at:1.0
	       ; {|not-json|}
	       ; {|{"event":"register","run_id":"r-legacy","keeper":"k","preset":"p","started_at":2.0}|}
	       ; {|{"event":"complete","run_id":"r1","ok":false}|}
	       ; complete_event ~run_id:"r1" ~ok:false
	       ; ""
	       ]);
  let t = R.replay path in
  check bool "legacy metadata-only register is rejected" true
    (Option.is_none (R.get t ~run_id:"r-legacy"));
  match R.get t ~run_id:"r1" with
  | Some { R.status = R.Completed { ok = false; _ }; _ } -> ()
  | Some _ -> fail "expected replayed run to be completed as failed"
  | None -> fail "expected valid replay events around malformed line to load"
;;

(* (5) Replay streams raw JSONL lines and compacts the retained state. *)
let test_replay_streams_and_compacts () =
  let path = fresh_path "-stream.jsonl" in
  let before =
    register_event ~run_id:"r-stream" ~keeper:"k" ~preset:"p" ~started_at:1.0
  in
  let after = complete_event ~run_id:"r-stream" ~ok:true in
  let malformed_padding = String.make 70000 'x' in
  let content = String.concat "\n" [ before; malformed_padding; after; "" ] in
  Fs_compat.save_file
    path
    content;
  let t = R.replay path in
  (match R.get t ~run_id:"r-stream" with
   | Some { R.status = R.Completed { ok = true; _ }; _ } -> ()
   | Some _ -> fail "expected streamed run to be completed"
   | None -> fail "expected streamed run to replay");
  match Fs_compat.file_size path with
  | Some size -> check bool "log compacted" true (size < String.length content)
  | None -> fail "expected compacted replay log to exist"
;;

(* (6) Replay does not compact away an unterminated tail line. *)
let test_replay_preserves_unterminated_tail () =
  let path = fresh_path "-partial-tail.jsonl" in
  let complete =
    register_event ~run_id:"r-partial" ~keeper:"k" ~preset:"p" ~started_at:1.0
  in
  let partial = complete_event ~run_id:"r-partial" ~ok:true in
  let content = String.concat "\n" [ complete; partial ] in
  Fs_compat.save_file
    path
    content;
  let t = R.replay path in
  (match R.get t ~run_id:"r-partial" with
   | None -> ()
   | Some _ -> fail "unterminated completion line must not publish stale running work");
  check string "partial tail preserved" content (Fs_compat.load_file path)
;;

let () =
  run
    "fusion_run_registry_persist"
    [ ( "rfc-0266-phase-d"
      , [ test_case "register+complete append JSONL" `Quick test_persist_register_complete
        ; test_case "failure detail survives replay" `Quick test_persist_failure_detail
        ; test_case "completion append failure is explicit" `Quick
            test_completion_append_failure_is_explicit
        ; test_case
            "replay prunes completed and preserves recovery work"
            `Quick
            test_replay_prunes_completed
        ; test_case "no-path registry is in-memory only" `Quick test_no_path_is_in_memory_only
        ; test_case "replay skips malformed lines" `Quick test_replay_skips_malformed_lines
        ; test_case "replay streams and compacts log" `Quick test_replay_streams_and_compacts
        ; test_case
            "replay preserves unterminated tail"
            `Quick
            test_replay_preserves_unterminated_tail
        ] )
    ]
;;
