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

let object_ j k =
  match field j k with
  | Some (`Assoc _ as value) -> value
  | _ -> failwith (Printf.sprintf "missing object field %s" k)
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
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:1.0;
  R.mark_completed t ~run_id:"r1" ~outcome:R.Succeeded;
  let content = Fs_compat.load_file path in
  let lines = String.split_on_char '\n' content in
  check int "two events + trailing newline" 3 (List.length lines);
  let event1 = parse (List.nth lines 0) in
  check string "event1 kind" "register" (str event1 "event");
  check string "event1 id" "r1" (str event1 "id");
  let registration = object_ event1 "registration" in
  check string "event1 keeper" "k" (str registration "keeper");
  check string "event1 preset" "p" (str registration "preset");
  check (float 0.001) "event1 started_at" 1.0 (float_ event1 "started_at");
  let event2 = parse (List.nth lines 1) in
  check string "event2 kind" "complete" (str event2 "event");
  check string "event2 id" "r1" (str event2 "id");
  check string "event2 outcome" "succeeded" (str (object_ event2 "completion") "outcome")
;;

let test_persist_failure_detail () =
  let path = fresh_path "-failure.jsonl" in
  let t = R.create ~path () in
  R.register_running t ~run_id:"r-fail" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:1.0;
  R.mark_completed t ~run_id:"r-fail"
    ~outcome:(R.Failed { reason = "judge failed: bad json"; code = "parse_error" });
  let content = Fs_compat.load_file path in
  let lines = String.split_on_char '\n' content in
  let event2 = parse (List.nth lines 1) in
  let completion = object_ event2 "completion" in
  check string "event2 failure" "judge failed: bad json" (str completion "reason");
  check string "event2 failure_code" "parse_error" (str completion "code");
  let replayed = R.replay path in
  match R.get replayed ~run_id:"r-fail" with
  | Some { R.status = R.Completed (R.Failed { reason; code }); _ } ->
    check string "replayed failure" "judge failed: bad json" reason;
    check string "replayed failure_code" "parse_error" code
  | Some _ -> fail "expected replayed failed completion"
  | None -> fail "expected replayed run"
;;

let test_persist_success_summary () =
  let path = fresh_path "-summary.jsonl" in
  let t = R.create ~path () in
  R.register_running t ~run_id:"r-summary" ~keeper:"k" ~preset:"p"
    ~topology:Fusion_types.Simple ~started_at:1.0;
  R.mark_completed t ~run_id:"r-summary"
    ~outcome:
      (R.Succeeded_with_summary
         { decision = R.decision_preview_of_string "recommend — ship"
         ; summary = "The panel reached consensus."
         });
  let content = Fs_compat.load_file path in
  let event2 = parse (List.nth (String.split_on_char '\n' content) 1) in
  let completion = object_ event2 "completion" in
  check string "persisted decision" "recommend — ship" (str completion "decision");
  check string "persisted summary" "The panel reached consensus."
    (str completion "summary");
  let replayed = R.replay path in
  match R.get replayed ~run_id:"r-summary" with
  | Some
      { R.status =
          R.Completed (R.Succeeded_with_summary { decision; summary })
      ; _
      } ->
    check string "replayed decision" "recommend — ship"
      (R.decision_preview_to_string decision);
    check string "replayed summary" "The panel reached consensus." summary
  | Some _ -> fail "expected replayed success summary"
  | None -> fail "expected replayed run"
;;

(* (2) Replay prunes completed runs to the newest [max_completed_retained]
   without resurrecting register-only rows as live work after restart. *)
let test_replay_prunes_completed () =
  let path = fresh_path "-prune.jsonl" in
  let t = R.create ~path () in
  for i = 1 to 70 do
    R.register_running
      t
      ~run_id:("r" ^ string_of_int i)
      ~keeper:"k"
      ~preset:"p" ~topology:Fusion_types.Simple
      ~started_at:(float_of_int i);
    R.mark_completed t ~run_id:("r" ^ string_of_int i) ~outcome:R.Succeeded
  done;
  (* Leave one run in [Running] state; replay must drop it because the worker
     fiber died with the old process. *)
  R.register_running t ~run_id:"r-running" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:71.0;
  let t2 = R.replay path in
  let runs = R.list_runs t2 in
  check int "pruned completed only" R.max_completed_retained (List.length runs);
  check bool "replayed running run dropped" true
    (Option.is_none (R.get t2 ~run_id:"r-running"));
  check bool "compacted log omits stale running run" false
    (String_util.contains_substring (Fs_compat.load_file path) "r-running");
  (* Newest completed run (r70) must be present; oldest (r1) pruned. *)
  check bool "newest completed kept" true (Option.is_some (R.get t2 ~run_id:"r70"));
  check bool "oldest completed pruned" true (Option.is_none (R.get t2 ~run_id:"r1"))
;;

(* (3) A fresh registry without a backing path does not write files. *)
let test_no_path_is_in_memory_only () =
  let path = fresh_path "-no-path.jsonl" in
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:1.0;
  R.mark_completed t ~run_id:"r1" ~outcome:R.Succeeded;
  check bool "no file created" false (Sys.file_exists path)
;;

(* (4) Replay skips malformed lines without dropping valid neighboring events. *)
let test_replay_skips_malformed_lines () =
  let path = fresh_path "-malformed.jsonl" in
  Fs_compat.save_file
    path
    (String.concat
       "\n"
       [ {|{"event":"register","id":"r1","started_at":1.0,"registration":{"keeper":"k","preset":"p","topology":"simple"}}|}
       ; {|not-json|}
       ; {|{"event":"register","id":42,"started_at":2.0,"registration":{"keeper":"k","preset":"p","topology":"simple"}}|}
       ; {|{"event":"complete","id":"r1","completion":{"outcome":"failed"}}|}
       ; {|{"event":"complete","id":"r1","completion":{"outcome":"failed","reason":"bad result","code":"bad_result"}}|}
       ; ""
       ]);
  let t = R.replay path in
  (match R.get t ~run_id:"r1" with
   | Some { R.status = R.Completed (R.Failed _); _ } -> ()
   | Some _ -> fail "expected replayed run to be completed as failed"
   | None -> fail "expected valid replay events around malformed line to load");
  check bool "malformed evidence is preserved" true
    (String_util.contains_substring (Fs_compat.load_file path) "not-json")
;;

(* (5) Replay streams raw JSONL lines and compacts the retained state. *)
let test_replay_streams_and_compacts () =
  let path = fresh_path "-stream.jsonl" in
  let before =
    {|{"event":"register","id":"r-stream","started_at":1.0,"registration":{"keeper":"k","preset":"p","topology":"simple"}}|}
  in
  let after =
    {|{"event":"complete","id":"r-stream","completion":{"outcome":"succeeded"}}|}
  in
  let blank_padding = String.make 70000 '\n' in
  let content = String.concat "\n" [ before; blank_padding; after; "" ] in
  Fs_compat.save_file
    path
    content;
  let t = R.replay path in
  (match R.get t ~run_id:"r-stream" with
   | Some { R.status = R.Completed R.Succeeded; _ } -> ()
   | Some _ -> fail "expected streamed run to be completed"
   | None -> fail "expected streamed run to replay");
  match Fs_compat.file_size path with
  | Some size -> check bool "log compacted" true (size < String.length content)
  | None -> fail "expected compacted replay log to exist"
;;

(* (6) Atomic replay compaction replaces the path inode. The shared JSONL
   writer caches descriptors, so replay must invalidate the descriptor opened
   by the pre-compaction registry before the replayed owner appends again. *)
let test_append_after_replay_compaction_targets_live_path () =
  let path = fresh_path "-append-after-replay.jsonl" in
  let original = R.create ~path () in
  R.register_running original ~run_id:"before" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:1.0;
  R.mark_completed original ~run_id:"before" ~outcome:R.Succeeded;
  let replayed = R.replay path in
  R.register_running replayed ~run_id:"after" ~keeper:"k" ~preset:"p" ~topology:Fusion_types.Simple ~started_at:2.0;
  R.mark_completed replayed ~run_id:"after" ~outcome:R.Succeeded;
  let replayed_again = R.replay path in
  check
    bool
    "pre-compaction run remains"
    true
    (Option.is_some (R.get replayed_again ~run_id:"before"));
  check
    bool
    "post-compaction append reaches live path"
    true
    (Option.is_some (R.get replayed_again ~run_id:"after"))
;;

(* (7) Replay does not compact away an unterminated tail line. *)
let test_replay_preserves_unterminated_tail () =
  let path = fresh_path "-partial-tail.jsonl" in
  let complete =
    {|{"event":"register","id":"r-partial","started_at":1.0,"registration":{"keeper":"k","preset":"p","topology":"simple"}}|}
  in
  let partial =
    {|{"event":"complete","id":"r-partial","completion":{"outcome":"succeeded"}}|}
  in
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
        ; test_case "success summary survives replay" `Quick
            test_persist_success_summary
        ; test_case
            "replay prunes completed and drops stale running runs"
            `Quick
            test_replay_prunes_completed
        ; test_case "no-path registry is in-memory only" `Quick test_no_path_is_in_memory_only
        ; test_case "replay skips malformed lines" `Quick test_replay_skips_malformed_lines
        ; test_case "replay streams and compacts log" `Quick test_replay_streams_and_compacts
        ; test_case
            "append after replay compaction targets the live path"
            `Quick
            test_append_after_replay_compaction_targets_live_path
        ; test_case
            "replay preserves unterminated tail"
            `Quick
            test_replay_preserves_unterminated_tail
        ] )
    ]
;;
