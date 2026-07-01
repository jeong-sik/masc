(* RFC-0266 §7 Phase D — fusion run registry persistence.

   Verify that register/complete append JSONL events and that replay restores
   the registry with completed-run pruning. Tests are isolated: each case gets
   its own temp file path; the process-wide {!Fusion_run_registry.global} is
   never touched. *)

open Alcotest
module R = Fusion_run_registry

let parse s = Yojson.Safe.from_string s

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let fresh_path suffix =
  let path = Filename.temp_file "fusion-runs-" suffix in
  remove_if_exists path;
  path
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
  check string "event1 run_id" "r1" (str event1 "run_id");
  check string "event1 keeper" "k" (str event1 "keeper");
  check string "event1 preset" "p" (str event1 "preset");
  check (float 0.001) "event1 started_at" 1.0 (float_ event1 "started_at");
  let event2 = parse (List.nth lines 1) in
  check string "event2 kind" "complete" (str event2 "event");
  check string "event2 run_id" "r1" (str event2 "run_id");
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
  | Some { R.status = R.Completed { ok = false; failure; failure_code }; _ } ->
    check (option string) "replayed failure" (Some "judge failed: bad json")
      failure;
    check (option string) "replayed failure_code" (Some "parse_error")
      failure_code
  | Some _ -> fail "expected replayed failed completion"
  | None -> fail "expected replayed run"
;;

(* (2) Replay prunes completed runs to the newest [max_completed_retained]
   while preserving all running runs. *)
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
  (* Leave one run in [Running] state so we can verify running runs are kept. *)
  R.register_running t ~run_id:"r-running" ~keeper:"k" ~preset:"p" ~started_at:71.0;
  let t2 = R.replay path in
  let runs = R.list_runs t2 in
  check int "pruned completed + kept running" (R.max_completed_retained + 1) (List.length runs);
  (* The running run must still be present. *)
  check bool "running run preserved" true
    (Option.is_some (R.get t2 ~run_id:"r-running"));
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

(* (4) Replay skips malformed lines without dropping valid neighboring events. *)
let test_replay_skips_malformed_lines () =
  let path = fresh_path "-malformed.jsonl" in
  Fs_compat.save_file
    path
    (String.concat
       "\n"
	       [ {|{"event":"register","run_id":"r1","keeper":"k","preset":"p","started_at":1.0}|}
	       ; {|not-json|}
	       ; {|{"event":"register","run_id":42,"keeper":"k","preset":"p","started_at":2.0}|}
	       ; {|{"event":"complete","run_id":"r1","ok":"false"}|}
	       ; {|{"event":"complete","run_id":"r1","ok":false}|}
	       ; ""
	       ]);
  let t = R.replay path in
  match R.get t ~run_id:"r1" with
  | Some { R.status = R.Completed { ok = false; _ }; _ } -> ()
  | Some _ -> fail "expected replayed run to be completed as failed"
  | None -> fail "expected valid replay events around malformed line to load"
;;

(* (5) Replay streams raw JSONL lines and compacts the retained state. *)
let test_replay_streams_and_compacts () =
  let path = fresh_path "-stream.jsonl" in
  let before =
    {|{"event":"register","run_id":"r-stream","keeper":"k","preset":"p","started_at":1.0}|}
  in
  let after = {|{"event":"complete","run_id":"r-stream","ok":true}|} in
  let malformed_padding = String.make 70000 'x' in
  let content = String.concat "\n" [ before; malformed_padding; after; "" ] in
  Fs_compat.save_file
    path
    content;
  let t = R.replay path in
  (match R.get t ~run_id:"r-stream" with
   | Some { R.status = Completed { ok = true }; _ } -> ()
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
    {|{"event":"register","run_id":"r-partial","keeper":"k","preset":"p","started_at":1.0}|}
  in
  let partial = {|{"event":"complete","run_id":"r-partial","ok":true}|} in
  let content = String.concat "\n" [ complete; partial ] in
  Fs_compat.save_file
    path
    content;
  let t = R.replay path in
  (match R.get t ~run_id:"r-partial" with
   | Some { R.status = Running; _ } -> ()
   | Some _ -> fail "unterminated completion line must not replay"
   | None -> fail "completed line before partial tail should replay");
  check string "partial tail preserved" content (Fs_compat.load_file path)
;;

let () =
  run
    "fusion_run_registry_persist"
    [ ( "rfc-0266-phase-d"
      , [ test_case "register+complete append JSONL" `Quick test_persist_register_complete
        ; test_case "failure detail survives replay" `Quick test_persist_failure_detail
        ; test_case "replay prunes completed runs" `Quick test_replay_prunes_completed
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
