open Alcotest
module R = Masc.Exact_lane_run_registry

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

(* Payload files live next to the log, so each test gets its own directory:
   runs of one id in a shared temp directory would overwrite each other's
   payload files. *)
let fresh_log_path prefix = Filename.concat (Filename.temp_dir prefix "") R.storage_filename

let payload_run_dir path ~run_id =
  Filename.concat (Filename.concat (Filename.dirname path) R.payload_dirname) run_id
;;

(* The one [kind] file ("input" or "output") the run's directory holds. Its
   name carries the value's digest. *)
let payload_file path ~run_id kind =
  let dir = payload_run_dir path ~run_id in
  match
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> String.starts_with ~prefix:(kind ^ "-") name)
  with
  | [ name ] -> Filename.concat dir name
  | names -> failf "expected one %s payload in %s, found %d" kind dir (List.length names)
;;

let mark_completed_exn t ~run_id ~outcome ~elapsed_s ~output =
  match R.mark_completed t ~run_id ~outcome ~elapsed_s ~selected_slot:None ~output () with
  | Ok () -> ()
  | Error error ->
    failf
      "exact-lane completion failed: %s"
      (R.completion_error_to_string error)
;;

let mark_completed_with_selected_slot_exn
      t
      ~run_id
      ~outcome
      ~elapsed_s
      ~selected_slot
      ~output
  =
  match
    R.mark_completed
      t
      ~run_id
      ~outcome
      ~elapsed_s
      ~selected_slot
      ~output
      ()
  with
  | Ok () -> ()
  | Error error ->
    failf
      "exact-lane completion with slot failed: %s"
      (R.completion_error_to_string error)
;;

let test_round_trip_preserves_exact_evidence () =
  let path = fresh_log_path "exact-lane-runs-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-1"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input (`Assoc [ "message_count", `Int 4 ]));
  mark_completed_with_selected_slot_exn
    registry
    ~run_id:"run-1"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~selected_slot:(Some "librarian-primary")
    ~output:(`Assoc [ "fact_count", `Int 3 ]);
  let original = R.get registry ~run_id:"run-1" |> Option.get |> R.run_to_yojson in
  let replayed = R.replay path in
  let restored = R.get replayed ~run_id:"run-1" |> Option.get |> R.run_to_yojson in
  check string "round trip" (Yojson.Safe.to_string original) (Yojson.Safe.to_string restored);
  let replayed_again = R.replay path in
  check string "second restart keeps the same original evidence"
    (Yojson.Safe.to_string original)
    (R.get replayed_again ~run_id:"run-1" |> Option.get |> R.run_to_yojson
     |> Yojson.Safe.to_string);
  List.iter (fun retained ->
    match R.get retained ~run_id:"run-1" |> Option.get with
    | { status = R.Completed
          { origin = R.Producer; elapsed_s = Some elapsed_s
          ; selected_slot = Some selected_slot; _ }; _ } ->
      check string "selected slot" "librarian-primary" selected_slot;
      check (float 0.) "measured producer duration survives restart" 0.5 elapsed_s
    | _ -> fail "producer origin and measured duration did not survive durable replay")
    [registry; replayed; replayed_again];
  remove_if_exists path
;;

let test_replay_selects_latest_payloads_across_blank_rows () =
  let path = fresh_log_path "exact-lane-latest-" in
  let registry = R.create ~path () in
  let register text =
    R.register_running registry ~run_id:"same-id" ~lane:R.Librarian
      ~actor:"keeper-a" ~started_at:10.0
      ~input:(R.Exact_input (`Assoc [ "prompt", `String text ]))
  in
  register "old input";
  mark_completed_exn registry ~run_id:"same-id" ~outcome:R.Succeeded
    ~elapsed_s:0.5 ~output:(`String "old completion");
  register "새 입력";
  mark_completed_exn registry ~run_id:"same-id"
    ~outcome:(R.Failed { code = "cancelled"; detail = "operator cancelled" })
    ~elapsed_s:0.8 ~output:(`Assoc [ "result", `String "취소된 실행의 원문" ]);
  let expected = R.get registry ~run_id:"same-id" |> Option.get |> R.run_to_yojson in
  let rows = Fs_compat.load_file path |> String.split_on_char '\n' in
  Fs_compat.save_file path ("\n \n" ^ String.concat "\n\n \n" rows);
  for _ = 1 to 2 do
    let replayed = R.replay path in
    check string "latest registration and completion remain paired"
      (Yojson.Safe.to_string expected)
      (R.get replayed ~run_id:"same-id" |> Option.get |> R.run_to_yojson
       |> Yojson.Safe.to_string)
  done;
  let retained =
    Fs_compat.load_file path |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  check int "only the retained register and complete survive" 2 (List.length retained);
  remove_if_exists path
;;

let test_completion_without_slot_receipt_writes_explicit_null () =
  let path = fresh_log_path "exact-lane-null-slot-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-no-receipt"
    ~lane:R.Board_attention
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input `Null);
  mark_completed_exn
    registry
    ~run_id:"run-no-receipt"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:`Null;
  let lines = Fs_compat.load_file path |> String.split_on_char '\n' in
  let completion_event = Yojson.Safe.from_string (List.nth lines 1) in
  (match completion_event with
   | `Assoc fields ->
     (match List.assoc_opt "completion" fields with
      | Some (`Assoc completion_fields) ->
        check bool "None is explicit durable evidence" true
          (List.assoc_opt "selected_slot" completion_fields = Some `Null)
      | _ -> fail "completion event must carry an object payload")
   | _ -> fail "completion event must be an object");
  remove_if_exists path
;;

let sample_usage =
  { R.input_tokens = 1200
  ; output_tokens = 340
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 900
  ; cost_usd = Some 0.0042
  }

let test_usage_is_recorded_and_survives_replay () =
  let path = fresh_log_path "exact-lane-usage-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-usage"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input `Null);
  (match
     R.mark_completed
       registry
       ~run_id:"run-usage"
       ~outcome:R.Succeeded
       ~elapsed_s:0.5
       ~selected_slot:(Some "librarian-primary")
       ~usage:sample_usage
       ~output:`Null
       ()
   with
   | Ok () -> ()
   | Error error ->
     failf "usage completion failed: %s" (R.completion_error_to_string error));
  (match R.get registry ~run_id:"run-usage" with
   | Some { status = R.Completed { usage = Some usage; _ }; _ } ->
     check int "input tokens" 1200 usage.R.input_tokens;
     check int "cache read tokens" 900 usage.cache_read_input_tokens;
     check bool "provider charge" true (usage.cost_usd = Some 0.0042)
   | _ -> fail "usage did not reach the completed status");
  let summary =
    R.get registry ~run_id:"run-usage" |> Option.get |> R.run_summary_to_yojson
  in
  check bool "summary carries usage for cost measurement" true
    Yojson.Safe.Util.(member "usage" summary <> `Null);
  let replayed = R.replay path in
  (match R.get replayed ~run_id:"run-usage" with
   | Some
       { status =
           R.Completed { usage = Some usage; selected_slot = Some slot; _ }
       ; _
       } ->
     check string "selected slot survives" "librarian-primary" slot;
     check int "usage survives durable replay" 340 usage.output_tokens
   | _ -> fail "usage did not survive durable replay");
  remove_if_exists path
;;

(* A producer that has no usage still writes the required field as null. *)
let test_completion_without_usage_replays_as_none () =
  let path = fresh_log_path "exact-lane-no-usage-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-none"
    ~lane:R.Board_attention
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input `Null);
  mark_completed_exn
    registry
    ~run_id:"run-none"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:`Null;
  let lines = Fs_compat.load_file path |> String.split_on_char '\n' in
  (match Yojson.Safe.Util.member "completion" (Yojson.Safe.from_string (List.nth lines 1)) with
   | `Assoc fields -> check bool "absent provider usage is written as explicit null" true
       (List.assoc_opt "usage" fields = Some `Null)
   | _ -> fail "completion event must carry an object payload");
  let replayed = R.replay path in
  (match R.get replayed ~run_id:"run-none" with
   | Some { status = R.Completed { outcome = R.Succeeded; usage = None; _ }; _ } -> ()
   | _ -> fail "usage-less completion must replay as a successful None");
  remove_if_exists path
;;

(* A usage report is provider evidence, not a free-form bag: a negative token
   count is refused, and the refusal takes the run down rather than being
   silently read as zero. *)
let test_malformed_usage_is_rejected_not_read () =
  let path = fresh_log_path "exact-lane-bad-usage-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-bad-usage"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input `Null);
  mark_completed_exn
    registry
    ~run_id:"run-bad-usage"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:`Null;
  let lines = Fs_compat.load_file path |> String.split_on_char '\n' in
  let completion_event =
    match Yojson.Safe.from_string (List.nth lines 1) with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "completion"
              then (
                match value with
                | `Assoc completion_fields ->
                  name
                  , `Assoc
                      (("usage"
                        , `Assoc
                            [ "input_tokens", `Int (-1)
                            ; "output_tokens", `Int 1
                            ; "cache_creation_input_tokens", `Int 0
                            ; "cache_read_input_tokens", `Int 0
                            ])
                       :: completion_fields)
                | _ -> fail "completion event must carry an object payload")
              else name, value)
           fields)
    | _ -> fail "completion event must be an object"
  in
  Fs_compat.save_file
    path
    (String.concat
       "\n"
       [ List.nth lines 0; Yojson.Safe.to_string completion_event; "" ]);
  let replayed = R.replay path in
  check
    (option string)
    "negative token count is refused and the run restart-fails"
    (Some "failed")
    (R.get replayed ~run_id:"run-bad-usage"
     |> Option.map (fun run -> R.status_label run.R.status));
  remove_if_exists path
;;

let test_missing_selected_slot_completion_is_not_replayed_as_success () =
  let path = fresh_log_path "exact-lane-legacy-slot-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"legacy-run"
    ~lane:R.Board_attention
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input `Null);
  mark_completed_exn
    registry
    ~run_id:"legacy-run"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:`Null;
  let lines = Fs_compat.load_file path |> String.split_on_char '\n' in
  let completion_event =
    match Yojson.Safe.from_string (List.nth lines 1) with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "completion"
              then (
                match value with
                | `Assoc completion_fields ->
                  name, `Assoc (List.remove_assoc "selected_slot" completion_fields)
                | _ -> fail "completion event must carry an object payload")
              else name, value)
           fields)
    | _ -> fail "completion event must be an object"
  in
  Fs_compat.save_file
    path
    (String.concat
       "\n"
       [ List.nth lines 0; Yojson.Safe.to_string completion_event; "" ]);
  let replayed = R.replay path in
  check
    (option string)
    "pre-v4 completion is rejected and its registration is restart-failed"
    (Some "failed")
    (R.get replayed ~run_id:"legacy-run" |> Option.map (fun run -> R.status_label run.R.status));
  remove_if_exists path
;;

(* #29277. A hard cut leaves rows carrying a field no current decoder reads.
   Such a row only leaves the log through compaction, and [replay] declines to
   compact while one is present — so the store keeps it, and the retention
   bound stops applying to that store. Live evidence on 2026-08-23: 2 000 rows
   in [exact-lane-runs-v4.jsonl] surviving every boot, 36 MB serving zero
   readable runs. This pins that the deployment cut is the way out. *)
let test_hard_cut_artifact_does_not_poison_compaction_forever () =
  let path = fresh_log_path "exact-lane-hard-cut-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"live-run"
    ~lane:R.Board_attention
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input (`Assoc [ "candidate_id", `String "retained-candidate" ]));
  mark_completed_exn
    registry
    ~run_id:"live-run"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:(`Assoc [ "decision", `String "retained judgment" ]);
  let expected = R.get registry ~run_id:"live-run" |> Option.get |> R.run_to_yojson in
  let live_lines =
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> not (String.equal line ""))
  in
  (* A registration written before the field was cut, same shape the live
     store held. *)
  let artifact =
    match Yojson.Safe.from_string (List.nth live_lines 0) with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "id"
              then name, `String "hard-cut-run"
              else if String.equal name "registration"
              then (
                match value with
                | `Assoc registration ->
                  name, `Assoc (("subject_id", `String "s-1") :: registration)
                | _ -> fail "registration event must carry an object payload")
              else name, value)
           fields)
    | _ -> fail "registration event must be an object"
  in
  Fs_compat.save_file
    path
    (String.concat "\n" (live_lines @ [ Yojson.Safe.to_string artifact; "" ]));
  let replayed = R.replay path in
  check
    (option string)
    "the readable run still replays"
    (Some "succeeded")
    (R.get replayed ~run_id:"live-run"
     |> Option.map (fun run -> R.status_label run.R.status));
  let after_replay : Run_registry_core.cut_report =
    R.cut_replay_log ~execute:false path
  in
  check int "replay left the unreadable row on disk" 1 after_replay.malformed_lines;
  let cut : Run_registry_core.cut_report = R.cut_replay_log ~execute:true path in
  check bool "the cut rewrote the store" true cut.rewritten;
  check int "the cut dropped the unreadable row" 1 cut.malformed_lines;
  let after_cut : Run_registry_core.cut_report =
    R.cut_replay_log ~execute:false path
  in
  check int "nothing unreadable is left" 0 after_cut.malformed_lines;
  check int "the readable run survived the cut" 1 after_cut.retained_entries;
  check string "cut preserves the original payload beside an unreadable row"
    (Yojson.Safe.to_string expected)
    (R.replay path |> R.get ~run_id:"live-run" |> Option.get |> R.run_to_yojson
     |> Yojson.Safe.to_string);
  check
    (option string)
    "and still replays"
    (Some "succeeded")
    (R.replay path
     |> R.get ~run_id:"live-run"
     |> Option.map (fun run -> R.status_label run.R.status));
  remove_if_exists path
;;

(* The unterminated-tail guard is the one the cut keeps: a partial read must
   not become a truncating rewrite. *)
let test_cut_refuses_a_store_with_an_unterminated_tail () =
  let path = fresh_log_path "exact-lane-torn-tail-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"live-run"
    ~lane:R.Board_attention
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input `Null);
  mark_completed_exn
    registry
    ~run_id:"live-run"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:`Null;
  let content = Fs_compat.load_file path in
  Fs_compat.save_file path (content ^ "{\"event\":\"reg");
  let cut : Run_registry_core.cut_report = R.cut_replay_log ~execute:true path in
  check bool "the cut left the store alone" false cut.rewritten;
  (* A caller that only reads [rewritten] cannot tell "nothing needed cutting"
     from "the cut declined". [reached_end] is what separates them, and the
     dry run reports it too — otherwise a deploy step would call this a
     success. *)
  check bool "and says why" false cut.reached_end;
  check
    bool
    "the dry run predicts the refusal"
    false
    (R.cut_replay_log ~execute:false path).reached_end;
  check
    string
    "the bytes are untouched"
    (content ^ "{\"event\":\"reg")
    (Fs_compat.load_file path);
  remove_if_exists path
;;

let test_blank_selected_slot_is_rejected_before_write () =
  let registry = R.create () in
  R.register_running
    registry
    ~run_id:"blank-slot"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input `Null);
  let result =
    R.mark_completed
      registry
      ~run_id:"blank-slot"
      ~outcome:R.Succeeded
      ~elapsed_s:0.5
      ~selected_slot:(Some " \t")
      ~output:`Null
      ()
  in
  check bool "blank selected slot is a typed writer error" true
    (match result with
     | Error R.Invalid_selected_slot -> true
     | Error R.Unknown_run | Error R.Invalid_elapsed_duration
     | Error (R.Persistence_failed _) | Ok () -> false);
  check string "invalid completion leaves the registered run running" "running"
    (R.get registry ~run_id:"blank-slot" |> Option.get |> fun run -> R.status_label run.R.status)
;;

let test_running_shape_has_no_invented_completion () =
  let registry = R.create () in
  R.register_running
    registry
    ~run_id:"run-live"
    ~lane:R.Board_attention
    ~actor:"keeper-a"
    ~started_at:20.0
    ~input:(R.Exact_input `Null);
  let run = R.get registry ~run_id:"run-live" |> Option.get in
  check string "status" "running" (R.status_label run.status);
  match R.run_to_yojson run with
  | `Assoc fields ->
    check bool "no elapsed" false (List.mem_assoc "elapsed_s" fields);
    check bool "no output" false (List.mem_assoc "output" fields)
  | _ -> fail "run serializer must emit an object"
;;

let test_replay_settles_running_as_server_restart_failure () =
  let path = fresh_log_path "exact-lane-restart-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running registry ~run_id:"interrupted-run" ~lane:R.Librarian
    ~actor:"keeper-a" ~started_at:1.0 ~input:(R.Exact_input (`String "older run"));
  mark_completed_exn registry ~run_id:"interrupted-run" ~outcome:R.Succeeded
    ~elapsed_s:0.5 ~output:(`String "completion preceding the latest registration");
  R.register_running
    registry
    ~run_id:"interrupted-run"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:(Time_compat.now () -. 2.0)
    ~input:(R.Exact_input (`Assoc [ "message_count", `Int 4 ]));
  let replayed = R.replay path in
  (match R.get replayed ~run_id:"interrupted-run" with
   | Some
       { status =
           R.Completed
             { outcome = R.Failed { code; detail }
             ; origin
             ; elapsed_s
             ; output
             ; selected_slot
             ; usage
             }
       ; _
       } ->
     check string "typed restart code" "server_restarted" code;
     check bool "restart is an observation, not a producer completion" true
       (origin = R.Restart_replay);
     check string
       "operator detail"
       "exact-output fibers do not survive server restart"
       detail;
     check (option (float 0.)) "replay does not invent a duration" None elapsed_s;
     check (option string) "no slot receipt is invented" None selected_slot;
     check bool "no usage is invented" true (usage = None);
     check
       string
       "durable output names the interruption"
       "server_restarted"
       (Yojson.Safe.Util.member "reason" output |> Yojson.Safe.Util.to_string)
   | Some run ->
     failf "replayed run stayed non-terminal: %s" (R.status_label run.status)
   | None -> fail "replayed running exact lane disappeared");
  let replayed_again = R.replay path in
  let second = R.get replayed_again ~run_id:"interrupted-run" |> Option.get in
  check bool "latest registration input survives both restarts" true
    (second.input = R.Exact_input (`Assoc [ "message_count", `Int 4 ]));
  (match second.status with
   | R.Completed { origin = R.Restart_replay; elapsed_s = None; output; _ } ->
     check string "restart completion body survives the second compaction"
       "server_restarted"
       (Yojson.Safe.Util.member "reason" output |> Yojson.Safe.Util.to_string)
   | _ -> fail "restart must remain terminal");
  check
    (option string)
    "the synthesized terminal event survives another replay"
    (Some "failed")
    (R.get replayed_again ~run_id:"interrupted-run"
     |> Option.map (fun run -> R.status_label run.R.status));
  remove_if_exists path
;;

let test_current_storage_generation () =
  check string "current store file" "exact-lane-runs-v7.jsonl" R.storage_filename
;;

let test_replay_sweep_preserves_the_other_storage_generation () =
  let path = fresh_log_path "exact-lane-generation-ownership-" in
  let previous_root = Filename.concat (Filename.dirname path) "exact-lane-run-payloads" in
  let previous_run = Filename.concat previous_root "old-original" in
  Fs_compat.mkdir_p previous_run;
  let sentinel = Filename.concat previous_run "output-original.json" in
  let original_bytes = "{\"original\":\"previous generation evidence\"}" in
  Fs_compat.save_file sentinel original_bytes;
  let registry = R.create ~path () in
  R.register_running registry ~run_id:"current-original" ~lane:R.Librarian
    ~actor:"keeper-a" ~started_at:10.0 ~input:(R.Exact_input `Null);
  mark_completed_exn registry ~run_id:"current-original" ~outcome:R.Succeeded
    ~elapsed_s:0.5 ~output:(`String "current evidence");
  let orphan = payload_run_dir path ~run_id:"current-unreferenced" in
  Unix.mkdir orphan 0o700;
  Fs_compat.save_file (Filename.concat orphan "input-0.json") "{}";
  for _ = 1 to 2 do
    let replayed = R.replay path in
    check bool "current sweep actually removes its own unreferenced payload" false
      (Sys.file_exists orphan);
    check string "current replay cannot delete another generation's actual bytes"
      original_bytes (Fs_compat.load_file sentinel);
    match R.get replayed ~run_id:"current-original" with
    | Some {output_availability=Some R.Available;_} -> ()
    | _ -> fail "current generation evidence must remain readable after sweeping"
  done;
  remove_if_exists path
;;

let test_current_completion_requires_origin_and_nullable_duration () =
  let path = fresh_log_path "exact-lane-completion-shape-" in
  let registry = R.create ~path () in
  R.register_running registry ~run_id:"completion-shape" ~lane:R.Librarian
    ~actor:"keeper-a" ~started_at:10.0 ~input:(R.Exact_input `Null);
  mark_completed_exn registry ~run_id:"completion-shape" ~outcome:R.Succeeded
    ~elapsed_s:0.5 ~output:(`String "original output");
  let rows = In_channel.with_open_text path In_channel.input_lines in
  let registration = List.nth rows 0 in
  let completion = Yojson.Safe.from_string (List.nth rows 1) in
  let rewrite change = match completion with
    | `Assoc fields -> `Assoc (List.map (function
        | "completion", `Assoc payload -> "completion", `Assoc (change payload)
        | field -> field) fields)
    | _ -> fail "completion row is not an object" in
  let set key value fields = (key, value) :: List.remove_assoc key fields in
  let check_rejected_bytes label row =
    Fs_compat.save_file path (registration ^ "\n" ^ row ^ "\n");
    let report = R.cut_replay_log ~execute:false path in
    check int (label ^ ": both rows inspected") 2 report.Run_registry_core.lines_read;
    check int (label ^ ": completion is malformed, not a terminal receipt")
      1 report.Run_registry_core.malformed_lines in
  let check_rejected (label, change) =
    check_rejected_bytes label (Yojson.Safe.to_string (rewrite change)) in
  List.iter check_rejected
    [ "missing origin", List.remove_assoc "origin"
    ; "unknown origin", set "origin" (`String "future_origin")
    ; "null origin", set "origin" `Null
    ; "missing duration", List.remove_assoc "elapsed_s"
    ; "negative duration", set "elapsed_s" (`Float (-0.5))
    ; "negative integer duration", set "elapsed_s" (`Int (-1))
    ; "string duration", set "elapsed_s" (`String "0.5")
    ; "boolean duration", set "elapsed_s" (`Bool false)
    ; "missing usage", List.remove_assoc "usage"
    ; "measured replay duration", set "origin" (`String "restart_replay")
    ; "forged replay success", (fun fields ->
        fields |> set "origin" (`String "restart_replay") |> set "elapsed_s" `Null)
    ];
  (* Safe writers correctly refuse nonstandard numbers. Raw literals are
     deliberate invalid input bytes, so the finite decoder is actually reached. *)
  let raw = Yojson.Raw.from_string (Yojson.Safe.to_string completion) in
  List.iter (fun literal ->
    let row = match raw with
      | `Assoc fields -> `Assoc (List.map (function
          | "completion", `Assoc payload ->
            "completion", `Assoc (("elapsed_s", `Floatlit literal) :: List.remove_assoc "elapsed_s" payload)
          | field -> field) fields)
      | _ -> fail "expected original completion object" in
    let bytes = Yojson.Raw.to_string row in
    let parsed = Yojson.Safe.from_string bytes in
    check bool (literal ^ ": malformed duration reaches the numeric codec") true
      (match Yojson.Safe.Util.(member "elapsed_s" (member "completion" parsed)) with
       | `Float value -> not (Float.is_finite value)
       | _ -> false);
    check_rejected_bytes (literal ^ " duration") bytes)
    ["NaN"; "Infinity"; "-Infinity"];
  (* Null is an explicit absence of measurement, not zero or a replay origin. *)
  Fs_compat.save_file path (registration ^ "\n" ^
    Yojson.Safe.to_string (rewrite (set "elapsed_s" `Null)) ^ "\n");
  for _ = 1 to 2 do
    let replayed = R.replay path in
    match R.get replayed ~run_id:"completion-shape" with
    | Some {status=R.Completed
        {outcome=R.Succeeded;origin=R.Producer;elapsed_s=None;_};_} -> ()
    | _ -> fail "explicit unknown producer duration changed origin or invented elapsed"
  done;
  remove_if_exists path
;;

let test_invalid_measured_duration_cannot_mutate_a_run () =
  let path = fresh_log_path "exact-lane-invalid-duration-" in
  let registry = R.create ~path () in
  R.register_running registry ~run_id:"duration" ~lane:R.Librarian
    ~actor:"keeper-a" ~started_at:10.0 ~input:(R.Exact_input `Null);
  let verify_invalid () =
    let before = Fs_compat.load_file path in
    let original = R.get registry ~run_id:"duration" |> Option.get |> R.run_to_yojson in
    let payloads = Sys.readdir (payload_run_dir path ~run_id:"duration")
      |> Array.to_list |> List.sort String.compare in
    List.iter (fun elapsed_s ->
      (match R.mark_completed registry ~run_id:"duration" ~outcome:R.Succeeded
         ~elapsed_s ~selected_slot:None ~output:(`String "must not be published") () with
       | Error R.Invalid_elapsed_duration -> ()
       | Error (R.Unknown_run | R.Invalid_selected_slot | R.Persistence_failed _) | Ok () ->
         fail "invalid measured duration was not refused before publication");
      check string "invalid measurement cannot append a completion" before (Fs_compat.load_file path);
      check bool "invalid measurement cannot change the original run" true
        (Yojson.Safe.equal original (R.get registry ~run_id:"duration" |> Option.get |> R.run_to_yojson));
      check (list string) "invalid measurement cannot publish an output payload" payloads
        (Sys.readdir (payload_run_dir path ~run_id:"duration")
         |> Array.to_list |> List.sort String.compare))
      [Float.nan; Float.infinity; Float.neg_infinity; -0.5] in
  verify_invalid ();
  mark_completed_exn registry ~run_id:"duration" ~outcome:R.Succeeded
    ~elapsed_s:0.5 ~output:(`String "original completion");
  verify_invalid ();
  remove_if_exists path
;;

(* The registration decoder is exact-field, so a row shape it stops accepting
   is unreadable forever, and a store holding such rows never compacts. A shape
   change therefore rides on the store version. This test holds the two
   together: the first fixture is a full registration row of this version, the
   second is the shape the previous version wrote (the input value inside the
   row), and changing the decoder means changing both fixtures and
   [storage_filename] in one commit. *)
let current_registration_row =
  {|{"event":"register","id":"exact-board-attention-pin","started_at":30.0,"registration":{"lane":"board_attention_exact","actor":"keeper-a","input":{"kind":"file","bytes":20,"sha256":"4f8c3b7d2a1e9f6c5b0a8d7e6f5c4b3a2918273645546372819a0b1c2d3e4f50"}}}|}

let inline_input_registration_row =
  {|{"event":"register","id":"exact-board-attention-pin","started_at":30.0,"registration":{"lane":"board_attention_exact","actor":"keeper-a","input":{"kind":"exact","payload":{"candidate_id":"c"}}}}|}

let test_store_version_pins_the_registration_shape () =
  (* Reads the decoder's verdict on the row, not only whether an ID survives
     replay. A registration that decodes is restart-failed into a terminal row,
     while a refused row is absent. [cut_replay_log] reports what the same
     decoder read and counts what it refused. *)
  let malformed_lines row =
    let path = fresh_log_path "exact-lane-shape-" in
    Fs_compat.save_file path (row ^ "\n");
    let report = R.cut_replay_log ~execute:false path in
    remove_if_exists path;
    report.Run_registry_core.lines_read, report.Run_registry_core.malformed_lines
  in
  check string "the row shape below belongs to this store version"
    "exact-lane-runs-v7.jsonl" R.storage_filename;
  check (pair int int) "a registration row of this version is read and accepted"
    (1, 0) (malformed_lines current_registration_row);
  check (pair int int) "an input value inside the row is rejected, not read"
    (1, 1) (malformed_lines inline_input_registration_row)
;;

(* The retained-run bound exists to serve the internal-agents monitor, which
   pages backwards through this store with a cursor. A bound below that route's
   maximum page size would let the operator's "older" request walk off the end
   of the store, so the relation is pinned here rather than left to the comment
   that derives it: raising exact_lane_run_page_max without revisiting the
   retention fails this. *)
let monitor_pages_retained = 10

let test_retention_is_derived_from_the_monitor_page_size () =
  let page_max = Server_routes_http_routes_dashboard.exact_lane_run_page_max in
  check bool "retention holds whole pages, not a fraction of one" true
    (R.max_completed_retained >= page_max);
  check int "retention is the page maximum times the pages the monitor keeps"
    (page_max * monitor_pages_retained)
    R.max_completed_retained
;;

(* The bound is applied, not merely declared. In-memory registry so writing
   past it stays cheap. *)
let test_completed_runs_are_bounded () =
  let registry = R.create () in
  let total = R.max_completed_retained + 8 in
  for index = 1 to total do
    let run_id = Printf.sprintf "run-%05d" index in
    R.register_running
      registry
      ~run_id
      ~lane:R.Librarian
      ~actor:"keeper-a"
      ~started_at:(float_of_int index)
      ~input:(R.Exact_input (`Assoc [ "index", `Int index ]));
    mark_completed_exn
      registry
      ~run_id
      ~outcome:R.Succeeded
      ~elapsed_s:0.1
      ~output:(`Assoc [ "index", `Int index ])
  done;
  check int "completed runs are bounded"
    R.max_completed_retained
    (List.length (R.list_runs registry));
  let has run_id =
    List.exists (fun (run : R.run) -> String.equal run.R.run_id run_id)
      (R.list_runs registry)
  in
  check bool "the newest completed run is retained" true
    (has (Printf.sprintf "run-%05d" total));
  check bool "the oldest completed run is evicted" false (has "run-00001")
;;

(* Lane audit W8: the retention bound is per lane. Under the old global
   bound the busiest lane (librarian, every few turns per keeper) evicted
   the quietest lane's entire history. The three Board-attention runs here
   are OLDER than every librarian run and must survive a librarian overflow. *)
let test_a_busy_lane_cannot_evict_a_quiet_lanes_history () =
  let registry = R.create () in
  let record ~run_id ~lane ~started_at =
    R.register_running
      registry
      ~run_id
      ~lane
      ~actor:"keeper-a"
      ~started_at
      ~input:(R.Exact_input (`Assoc []));
    mark_completed_exn
      registry
      ~run_id
      ~outcome:R.Succeeded
      ~elapsed_s:0.1
      ~output:(`Assoc [])
  in
  for index = 1 to 3 do
    record
      ~run_id:(Printf.sprintf "board-%02d" index)
      ~lane:R.Board_attention
      ~started_at:(float_of_int index)
  done;
  for index = 1 to R.max_completed_retained + 8 do
    record
      ~run_id:(Printf.sprintf "librarian-%05d" index)
      ~lane:R.Librarian
      ~started_at:(float_of_int (100 + index))
  done;
  let runs = R.list_runs registry in
  let count lane =
    List.length (List.filter (fun (run : R.run) -> run.R.lane = lane) runs)
  in
  check int "the quiet lane's whole history survives" 3 (count R.Board_attention);
  check int "the busy lane is bounded to its own quota"
    R.max_completed_retained
    (count R.Librarian)
;;

(* The lanes this registry records, written out apart from the registry.
   Verifier reviews have their own stores; Stagehand retains no runs here. *)
let recorded_lanes = [ R.Librarian; R.Hitl_auto_judge; R.Board_attention; R.Workspace_curator; R.Candle_appraiser ]

let test_exact_history_is_not_pruned_across_lanes () =
  let path = fresh_log_path "exact-lane-runs-all-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  let lanes = Array.of_list recorded_lanes in
  List.init 80 Fun.id
  |> List.iter (fun index ->
    let run_id = Printf.sprintf "run-%02d" index in
    let lane =
      lanes.(index mod Array.length lanes)
    in
    R.register_running
      registry
      ~run_id
      ~lane
      ~actor:"keeper-a"
      ~started_at:(float_of_int index)
      ~input:(R.Exact_input (`Assoc [ "index", `Int index ]));
    mark_completed_exn
      registry
      ~run_id
      ~outcome:R.Succeeded
      ~elapsed_s:0.1
      ~output:(`Assoc [ "index", `Int index ]));
  let replayed = R.replay path in
  check int "all exact runs survive replay" 80 (List.length (R.list_runs replayed));
  check
    (list string)
    "every registered lane survives replay"
    (recorded_lanes
     |> List.map (fun lane -> R.lane_id lane)
     |> List.sort String.compare)
    (R.list_runs replayed
     |> List.map (fun (run : R.run) -> R.lane_id run.lane)
     |> List.sort_uniq String.compare);
  let permissions = (Unix.stat path).Unix.st_perm land 0o777 in
  check int "durable registry is private" 0o600 permissions;
  let payload_permissions =
    (Unix.stat (payload_file path ~run_id:"run-00" "input")).Unix.st_perm land 0o777
  in
  check int "payload files are as private as the log" 0o600 payload_permissions;
  remove_if_exists path
;;

(* A payload file is written before the row that names it, so a failed append
   leaves one behind. Replay removes every payload directory no retained row
   names and leaves the retained runs' files readable. *)
let test_replay_removes_payload_files_no_row_names () =
  let path = fresh_log_path "exact-lane-orphans-" in
  let registry = R.create ~path () in
  R.register_running registry ~run_id:"kept" ~lane:R.Librarian ~actor:"fixture"
    ~started_at:1.0 ~input:(R.Exact_input (`String "kept input"));
  mark_completed_exn registry ~run_id:"kept" ~outcome:R.Succeeded ~elapsed_s:0.1
    ~output:(`String "kept output");
  let orphan = Filename.concat (payload_run_dir path ~run_id:"orphan") "input-0.json" in
  Unix.mkdir (Filename.dirname orphan) 0o700;
  Fs_compat.save_file orphan "{}";
  let replayed = R.replay path in
  check bool "a payload directory no row names is removed" false
    (Sys.file_exists (Filename.dirname orphan));
  (match (R.startup_observation replayed).payload_sweep with
   | R.Swept counts ->
     check int "retained and orphan root entries examined" 2 counts.examined_root_entries;
     check int "one successful unlink" 1 counts.unlinked_entries;
     check int "one successful rmdir" 1 counts.removed_run_directories;
     check int "no failed root entries" 0 counts.failed_root_entries
   | R.Not_attempted | R.Replay_not_trusted | R.Root_absent | R.Root_unavailable
   | R.Sweep_scope_failed _ ->
     fail "clean replay did not record its sweep");
  let kept = R.get replayed ~run_id:"kept" |> Option.get in
  check bool "a retained run keeps its payload files" true
    (kept.input_availability = R.Available && kept.output_availability = Some R.Available);
  remove_if_exists path
;;

(* A registration row of this store version, naming [lane]. *)
let registration_row lane =
  Printf.sprintf
    {|{"event":"register","id":"exact-lane-pin","started_at":30.0,"registration":{"lane":%S,"actor":"keeper-a","input":{"kind":"file","bytes":20,"sha256":"4f8c3b7d2a1e9f6c5b0a8d7e6f5c4b3a2918273645546372819a0b1c2d3e4f50"}}}|}
    (Standalone_lane.to_id lane)
;;

(* Verifier reviews have their own registries and Stagehand requests have no
   retained run registry yet. Rows naming either lane are refused on replay. *)
let test_the_registry_refuses_unrecorded_lanes () =
  check bool "the Verifier lane has no registry lane" true
    (Option.is_none (R.lane_of_standalone Standalone_lane.Verifier));
  check bool "the Browser Stagehand lane has no registry lane" true
    (Option.is_none (R.lane_of_standalone Standalone_lane.Browser_stagehand));
  List.iter
    (fun lane ->
       check bool (Standalone_lane.to_id lane ^ " converts back to itself") true
         (match R.lane_of_standalone lane with
          | Some recorded -> Lane_run_identity.equal (R.run_lane recorded) (Standalone_lane.run_identity lane)
          | None -> lane = Standalone_lane.Verifier || lane = Standalone_lane.Browser_stagehand))
    Standalone_lane.all;
  let read_and_refused lane =
    let path = fresh_log_path "exact-lane-verifier-row-" in
    Fs_compat.save_file path (registration_row lane ^ "\n");
    let report = R.cut_replay_log ~execute:false path in
    remove_if_exists path;
    report.Run_registry_core.lines_read, report.Run_registry_core.malformed_lines
  in
  check (pair int int) "a Board row is read and kept" (1, 0)
    (read_and_refused Standalone_lane.Board_attention);
  check (pair int int) "a Verifier row is read and refused" (1, 1)
    (read_and_refused Standalone_lane.Verifier);
  check (pair int int) "a Stagehand row is read and refused" (1, 1)
    (read_and_refused Standalone_lane.Browser_stagehand)
;;

let test_failed_durable_registration_is_not_published_in_memory () =
  let directory = fresh_log_path "exact-lane-runs-dir-" in
  Unix.mkdir directory 0o700;
  let registry = R.create ~path:directory () in
  let failed =
    try
      R.register_running
        registry
        ~run_id:"not-published"
        ~lane:R.Librarian
        ~actor:"keeper-a"
        ~started_at:1.0
        ~input:(R.Exact_input `Null);
      false
    with
    | Sys_error _ | Unix.Unix_error _ -> true
  in
  check bool "directory cannot be used as durable JSONL" true failed;
  check int "failed registration absent" 0 (List.length (R.list_runs registry));
  Unix.rmdir directory
;;

let test_failed_durable_completion_is_explicitly_visible () =
  let path = fresh_log_path "exact-lane-completion-failure-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"completion-not-published"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:1.0
    ~input:(R.Exact_input `Null);
  Sys.remove path;
  Unix.mkdir path 0o700;
  let completion =
    R.mark_completed
      registry
      ~run_id:"completion-not-published"
      ~outcome:(R.Failed { code = "model_error"; detail = "typed failure detail" })
      ~elapsed_s:0.1
      ~selected_slot:None
      ~output:(`String "must-not-publish")
      ()
  in
  (match completion with
   | Error (R.Persistence_failed failure) ->
     check bool "failure retains durable detail" true
       (String.trim failure.detail <> "")
   | Error R.Unknown_run -> fail "registered run became unknown"
   | Error R.Invalid_selected_slot -> fail "explicit None slot became invalid"
   | Error R.Invalid_elapsed_duration -> fail "finite measured duration became invalid"
   | Ok () -> fail "directory unexpectedly received durable completion");
  let run = R.get registry ~run_id:"completion-not-published" |> Option.get in
  check bool "failed append keeps its actual output available" true
    (run.output_availability = Some R.Available);
  check bool "the input is still read from its payload file" true
    (run.input_availability = R.Available);
  check bool "failed completion is not reported as running" true
    (not (String.equal "running" (R.status_label run.status)));
  (match run.status with
   | R.Completion_persistence_failed
       { intended_outcome = R.Failed { code; detail }
       ; output = `String output
       ; failure
       ; _
       } ->
     check string "intended output remains observable" "must-not-publish" output;
     check string "intended failure code remains observable" "model_error" code;
     check string "intended failure detail remains observable" "typed failure detail" detail;
     check bool "persistence failure remains explicit" true
       (String.trim failure.detail <> "")
   | _ -> fail "expected explicit completion persistence failure");
  (match R.run_to_yojson run with
   | `Assoc fields ->
     check bool "serialized persistence error" true
       (List.mem_assoc "persistence_error" fields);
     check bool "serialized persistence state" true
       (List.mem_assoc "persistence_state" fields);
     check (option string) "serialized intended failure code" (Some "model_error")
       (Option.bind
          (List.assoc_opt "intended_code" fields)
          (function `String value -> Some value | _ -> None));
     check (option string) "serialized intended failure detail" (Some "typed failure detail")
       (Option.bind
          (List.assoc_opt "intended_detail" fields)
          (function `String value -> Some value | _ -> None))
   | _ -> fail "run serializer must emit an object");
  Unix.rmdir path
;;

let test_observation_reads_do_not_wait_for_durable_writer () =
  let path = fresh_log_path "exact-lane-read-projection-" in
  (* The child locks the log file itself, so the file exists before the fork. *)
  Unix.close (Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ] 0o600);
  let registry = R.create ~path () in
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  match Unix.fork () with
  | 0 ->
    Unix.close ready_read;
    (try
       let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
       Unix.lockf fd Unix.F_LOCK 0;
       ignore (Unix.write_substring ready_write "x" 0 1 : int);
       Unix.sleepf 0.5;
       Unix.close fd;
       Unix._exit 0
     with
     | e ->
       (* The parent reads only the exit code, so the child says what went
          wrong before it goes. Without this the failure is
          "durable-lock child failed: exit 2" and names no cause: the ENOENT
          #36638 fixed took a temporary print in here to find. *)
       prerr_endline ("durable-lock child: " ^ Printexc.to_string e);
       Unix._exit 2)
  | child ->
    Unix.close ready_write;
    let ready = Bytes.create 1 in
    ignore (Unix.read ready_read ready 0 1 : int);
    Unix.close ready_read;
    Fun.protect
      ~finally:(fun () ->
        let rec wait_child () =
          try Unix.waitpid [] child with
          | Unix.Unix_error (Unix.EINTR, _, _) -> wait_child ()
        in
        (match wait_child () with
         | _, Unix.WEXITED 0 -> ()
         | _, status ->
           failf
             "durable-lock child failed: %s"
             (match status with
              | Unix.WEXITED code -> Printf.sprintf "exit %d" code
              | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
              | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal));
        remove_if_exists path;
        remove_if_exists (Fs_compat.private_jsonl_lock_path path))
      (fun () ->
         Eio_main.run @@ fun env ->
         let clock = Eio.Stdenv.clock env in
         Eio.Switch.run @@ fun sw ->
         let started, set_started = Eio.Promise.create () in
         Eio.Fiber.fork ~sw (fun () ->
           Eio.Promise.resolve set_started ();
           R.register_running
             registry
             ~run_id:"writer-blocked-on-durable-lock"
             ~lane:R.Board_attention
             ~actor:"keeper-a"
             ~started_at:1.0
             ~input:(R.Exact_input `Null));
         Eio.Promise.await started;
         Eio.Time.sleep clock 0.05;
         let read_started_at = Eio.Time.now clock in
         let visible = R.list_runs registry in
         let read_elapsed_s = Eio.Time.now clock -. read_started_at in
         check int "pre-commit projection remains unchanged" 0 (List.length visible);
         check bool "Atomic projection read does not wait for durable writer" true
           (read_elapsed_s < 0.2))
;;

(* Paging exists because listing everything serialized 5,908 runs to 246 MB on
   every load. The properties that make a page trustworthy are that it is a
   total order (so a boundary cannot lose a run) and that a summary carries no
   payload (so the size that forced paging cannot creep back). *)
let test_pages_are_a_total_order_over_equal_timestamps () =
  let registry = R.create () in
  List.iter
    (fun run_id ->
       R.register_running
         registry
         ~run_id
         ~lane:R.Librarian
         ~actor:"keeper-a"
         ~started_at:10.0
         ~input:(R.Exact_input (`Assoc [ "n", `Int 1 ])))
    [ "run-a"; "run-b"; "run-c"; "run-d" ];
  let first = R.recent_runs registry ~limit:2 ~before:None in
  check int "page size honoured" 2 (List.length first.runs);
  check int "total counts every retained run, not the page" 4 first.total;
  check bool "more remains" true first.has_more;
  let last = List.nth first.runs 1 in
  let second =
    R.recent_runs registry ~limit:2 ~before:(Some (last.R.started_at, last.R.run_id))
  in
  check int "second page size" 2 (List.length second.runs);
  check bool "no more after the last page" false second.has_more;
  let ids page = List.map (fun (run : R.run) -> run.R.run_id) page in
  let seen = ids first.runs @ ids second.runs in
  check int "every run appears exactly once across pages" 4 (List.length (List.sort_uniq String.compare seen));
  check
    (list string)
    "identical started_at is ordered by run_id, newest first"
    [ "run-d"; "run-c"; "run-b"; "run-a" ]
    seen
;;

let test_summary_carries_no_payload () =
  let registry = R.create () in
  R.register_running
    registry
    ~run_id:"run-1"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input (`Assoc [ "conversation_history", `String "…megabytes…" ]));
  mark_completed_exn
    registry
    ~run_id:"run-1"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:(`Assoc [ "fact_count", `Int 3 ]);
  let run = R.get registry ~run_id:"run-1" |> Option.get in
  let field name json =
    match json with
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  let summary = R.run_summary_to_yojson run in
  let detail = R.run_to_yojson run in
  check bool "summary omits input" true (Option.is_none (field "input" summary));
  check bool "summary omits output" true (Option.is_none (field "output" summary));
  check bool "summary does not invent a subject" true (field "subject_id" summary = Some `Null);
  check bool "detail keeps input" true (Option.is_some (field "input" detail));
  check bool "detail keeps output" true (Option.is_some (field "output" detail));
  check bool "summary still identifies the run" true (Option.is_some (field "run_id" summary))
;;

(* The projection dropping the payload was never the question -- it already
   did. What held 498 MB of live heap on this fleet was the store underneath
   it keeping every retained row whole, to serve a detail view that reads one
   at a time (measured 2026-09-05).

   This weighs the store rather than reading a field, because a field can be
   `Null while the bytes are still reachable from somewhere else. *)
let test_the_store_does_not_hold_the_payloads_it_retains () =
  let path = fresh_log_path "exact-lane-weight-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  let payload_bytes = 200_000 in
  let runs = 40 in
  for i = 1 to runs do
    let run_id = Printf.sprintf "run-%d" i in
    R.register_running
      registry
      ~run_id
      ~lane:R.Librarian
      ~actor:"keeper-a"
      ~started_at:(float_of_int i)
      ~input:(R.Exact_input (`Assoc [ "prompt", `String (String.make payload_bytes 'A') ]));
    mark_completed_exn
      registry
      ~run_id
      ~outcome:R.Succeeded
      ~elapsed_s:1.0
      ~output:(`Assoc [ "reply", `String (String.make payload_bytes 'B') ])
  done;
  Gc.full_major ();
  let held = Obj.reachable_words (Obj.repr registry) * (Sys.word_size / 8) in
  let written = runs * payload_bytes * 2 in
  check bool
    (Printf.sprintf
       "the store holds %d bytes for %d bytes of payload"
       held
       written)
    true
    (held < written / 10);
  (* And the payloads are still there to be read, one at a time. *)
  check bool "a detail read still gets the whole input" true
    (match (R.get registry ~run_id:"run-7" |> Option.get).R.input with
     | R.Exact_input (`Assoc [ "prompt", `String s ]) -> String.length s = payload_bytes
     | _ -> false);
  for _ = 1 to 2 do
    let replayed = R.replay path in
    Gc.full_major ();
    let held = Obj.reachable_words (Obj.repr replayed) * (Sys.word_size / 8) in
    check bool "replay retains metadata without retaining the full payloads" true
      (held < written / 10);
    let detail = R.get replayed ~run_id:"run-7" |> Option.get in
    check bool "full input remains readable after compaction" true
      (detail.input = R.Exact_input (`Assoc [ "prompt", `String (String.make payload_bytes 'A') ]));
    check bool "full output remains readable after compaction" true
      (match detail.status with
       | R.Completed { output; _ } ->
         output = `Assoc [ "reply", `String (String.make payload_bytes 'B') ]
       | _ -> false)
  done;
  remove_if_exists path
;;

let test_projected_runs_omit_payload_in_memory () =
  let path = fresh_log_path "exact-lane-proj-" in
  remove_if_exists path;
  let registry = R.create ~path () in
  R.register_running
    registry
    ~run_id:"run-large"
    ~lane:R.Librarian
    ~actor:"keeper-a"
    ~started_at:10.0
    ~input:(R.Exact_input (`Assoc [ "prompt", `String (String.make 1000 'A') ]));
  (* Verify an active Running run has stripped input in projection *)
  let running_listed = List.hd (R.list_runs registry) in
  check bool "running listed run input is stripped" true
    (match running_listed.R.input with R.Exact_input `Null -> true | _ -> false);
  check bool "running get preserves full input" true
    (match (R.get registry ~run_id:"run-large" |> Option.get).R.input with
     | R.Exact_input (`Assoc [ "prompt", `String s ]) -> String.length s = 1000
     | _ -> false);
  mark_completed_exn
    registry
    ~run_id:"run-large"
    ~outcome:R.Succeeded
    ~elapsed_s:0.5
    ~output:(`Assoc [ "completion", `String (String.make 1000 'B') ]);
  let listed_run = List.hd (R.list_runs registry) in
  check bool "listed run input is stripped" true
    (match listed_run.R.input with R.Exact_input `Null -> true | _ -> false);
  check bool "listed run output is stripped" true
    (match listed_run.R.status with R.Completed { output = `Null; _ } -> true | _ -> false);
  let paged_run = List.hd (R.recent_runs registry ~limit:1 ~before:None).runs in
  check bool "paged run input is stripped" true
    (match paged_run.R.input with R.Exact_input `Null -> true | _ -> false);
  check bool "paged run output is stripped" true
    (match paged_run.R.status with R.Completed { output = `Null; _ } -> true | _ -> false);
  (* Non-existent run fast-rejects to None *)
  check bool "non-existent run returns None" true
    (Option.is_none (R.get registry ~run_id:"run-nonexistent"));
  let detail_run = R.get registry ~run_id:"run-large" |> Option.get in
  check bool "get run detail preserves full input from disk" true
    (match detail_run.R.input with
     | R.Exact_input (`Assoc [ "prompt", `String s ]) -> String.length s = 1000
     | _ -> false);
  check bool "get run detail preserves full output from disk" true
    (match detail_run.R.status with
     | R.Completed { output = `Assoc [ "completion", `String s ]; _ } -> String.length s = 1000
     | _ -> false);
  remove_if_exists path
;;

let test_memory_only_and_disk_null_are_available_values () =
  let run_id = "run-\"한글" in
  let verify registry =
    R.register_running registry ~run_id ~lane:R.Librarian ~actor:"fixture"
      ~started_at:1.0 ~input:(R.Exact_input `Null);
    let running = R.get registry ~run_id |> Option.get in
    check bool "JSON null input is an available value" true
      (running.input_availability = R.Available);
    check bool "running has not produced output" true
      (running.output_availability = None);
    mark_completed_exn registry ~run_id ~outcome:R.Succeeded ~elapsed_s:0.5 ~output:`Null;
    let completed = R.get registry ~run_id |> Option.get in
    check bool "completed JSON null output is available" true
      (completed.output_availability = Some R.Available);
    check string "completion lifecycle retained" "succeeded" (R.status_label completed.status);
    (match R.run_to_yojson completed with
     | `Assoc fields ->
       check bool "null output remains explicitly present" true
         (List.assoc_opt "output" fields = Some `Null)
     | _ -> fail "expected a run object");
    let projected = List.hd (R.list_runs registry) in
    check bool "listing has not loaded payloads" true
      (projected.input_availability = R.Not_loaded
       && projected.output_availability = Some R.Not_loaded);
    R.register_running registry ~run_id:"rich-run" ~lane:R.Librarian ~actor:"fixture"
      ~started_at:2.0 ~input:(R.Exact_input (`String "full input"));
    mark_completed_exn registry ~run_id:"rich-run" ~outcome:R.Succeeded
      ~elapsed_s:0.5 ~output:(`String "full output");
    let rich = R.get registry ~run_id:"rich-run" |> Option.get in
    check bool "available values retain their actual bytes" true
      (rich.input = R.Exact_input (`String "full input")
       && match rich.status with
          | R.Completed { output = `String "full output"; _ } -> true
          | _ -> false)
  in
  verify (R.create ());
  let path = fresh_log_path "exact-null-evidence-" in
  Fun.protect ~finally:(fun () -> remove_if_exists path)
    (fun () -> verify (R.create ~path ()))
;;

(* A replay that stopped at a torn tail publishes fewer runs than the log
   holds. Sweeping against that set would delete payloads the log still names,
   so such a replay removes nothing. *)
let test_a_partial_replay_leaves_payload_files_alone () =
  let path = fresh_log_path "exact-lane-partial-replay-" in
  let registry = R.create ~path () in
  R.register_running registry ~run_id:"kept" ~lane:R.Librarian ~actor:"fixture"
    ~started_at:1.0 ~input:(R.Exact_input (`String "kept input"));
  mark_completed_exn registry ~run_id:"kept" ~outcome:R.Succeeded ~elapsed_s:0.1
    ~output:(`String "kept output");
  let unnamed = payload_run_dir path ~run_id:"not-in-this-read" in
  Unix.mkdir unnamed 0o700;
  Fs_compat.save_file (Filename.concat unnamed "input-0.json") "{}";
  Fs_compat.save_file path (Fs_compat.load_file path ^ "{\"event\":\"reg");
  Fs_compat.invalidate_cached_writer path;
  let replayed = R.replay path in
  check bool "untrusted replay records its refusal" true
    ((R.startup_observation replayed).payload_sweep = R.Replay_not_trusted);
  check bool "a replay that stopped at a torn tail sweeps nothing" true
    (Sys.file_exists unnamed);
  let kept = R.get replayed ~run_id:"kept" |> Option.get in
  check bool "the runs it did read stay readable" true
    (kept.input_availability = R.Available && kept.output_availability = Some R.Available);
  remove_if_exists path
;;

(* A replay can read to the end and still skip a row it could not decode. That
   row may have named payload files, so this replay removes nothing either. *)
let test_a_replay_that_skipped_an_unreadable_row_leaves_payload_files_alone () =
  let path = fresh_log_path "exact-lane-unreadable-row-" in
  let registry = R.create ~path () in
  R.register_running registry ~run_id:"kept" ~lane:R.Librarian ~actor:"fixture"
    ~started_at:1.0 ~input:(R.Exact_input (`String "kept input"));
  mark_completed_exn registry ~run_id:"kept" ~outcome:R.Succeeded ~elapsed_s:0.1
    ~output:(`String "kept output");
  let unnamed = payload_run_dir path ~run_id:"named-by-the-unreadable-row" in
  Unix.mkdir unnamed 0o700;
  Fs_compat.save_file (Filename.concat unnamed "input-0.json") "{}";
  Fs_compat.save_file path (Fs_compat.load_file path ^ "{\"event\":\"register\"}\n");
  Fs_compat.invalidate_cached_writer path;
  let read : Run_registry_core.cut_report = R.cut_replay_log ~execute:false path in
  check bool "the replay reads to the end" true read.reached_end;
  check int "and skips the one row it cannot decode" 1 read.malformed_lines;
  let replayed = R.replay path in
  check bool "untrusted replay records its refusal" true
    ((R.startup_observation replayed).payload_sweep = R.Replay_not_trusted);
  check bool "a replay that skipped a row sweeps nothing" true (Sys.file_exists unnamed);
  let kept = R.get replayed ~run_id:"kept" |> Option.get in
  check bool "the runs it did read stay readable" true
    (kept.input_availability = R.Available && kept.output_availability = Some R.Available);
  remove_if_exists path
;;

(* A second registration of one id writes its input under a new name before
   the append. If that append fails, the row and the entry still name the first
   input, and its file is untouched. *)
let test_a_failed_second_registration_keeps_the_first_payload () =
  let path = fresh_log_path "exact-lane-second-registration-" in
  let registry = R.create ~path () in
  let register input =
    R.register_running registry ~run_id:"same-id" ~lane:R.Librarian ~actor:"fixture"
      ~started_at:1.0 ~input:(R.Exact_input (`String input))
  in
  register "first input";
  Sys.remove path;
  Unix.mkdir path 0o700;
  (match register "second input" with
   | () -> fail "a registration whose append cannot land was accepted"
   | exception (Sys_error _ | Unix.Unix_error _) -> ());
  let run = R.get registry ~run_id:"same-id" |> Option.get in
  check bool "the first registration's input is still served" true
    (run.input_availability = R.Available
     && run.input = R.Exact_input (`String "first input"));
  Unix.rmdir path
;;

let with_completed_payload_source f =
  let path = fresh_log_path "exact-payload-source-" in
  Fun.protect ~finally:(fun () -> remove_if_exists path) (fun () ->
    let registry = R.create ~path () in
    R.register_running registry ~run_id:"payload-run" ~lane:R.Librarian
      ~actor:"fixture" ~started_at:1.0 ~input:(R.Exact_input (`String "actual input"));
    mark_completed_exn registry ~run_id:"payload-run"
      ~outcome:(R.Failed { code = "provider_failed"; detail = "actual failure" })
      ~elapsed_s:0.5 ~output:(`String "actual output");
    f registry path)
;;

let test_missing_payload_files_do_not_erase_terminal_identity () =
  with_completed_payload_source (fun registry path ->
    let input = payload_file path ~run_id:"payload-run" "input" in
    let output = payload_file path ~run_id:"payload-run" "output" in
    Sys.remove input;
    Sys.remove output;
    let run = R.get registry ~run_id:"payload-run" |> Option.get in
    check string "original run remains failed" "failed" (R.status_label run.status);
    check string "original identity remains" "payload-run" run.run_id;
    check bool "input and output report their missing files" true
      (run.input_availability = R.Unavailable R.Missing_registration
       && run.output_availability = Some (R.Unavailable R.Missing_completion));
    (* A path that exists but cannot be read as a file is a source failure,
       not a missing payload. *)
    Unix.mkdir output 0o700;
    let run = R.get registry ~run_id:"payload-run" |> Option.get in
    check bool "an unreadable output names the source failure" true
      (match run.output_availability with
       | Some (R.Unavailable (R.Source_unavailable detail)) -> String.trim detail <> ""
       | _ -> false);
    check bool "unknown run remains absent" true
      (Option.is_none (R.get registry ~run_id:"unknown")))
;;

let test_each_payload_file_reports_its_own_availability () =
  with_completed_payload_source (fun registry path ->
    let input = payload_file path ~run_id:"payload-run" "input" in
    let output = payload_file path ~run_id:"payload-run" "output" in
    let output_bytes = Fs_compat.load_file output in
    Sys.remove output;
    let run = R.get registry ~run_id:"payload-run" |> Option.get in
    check bool "input survives a missing output file" true
      (run.input_availability = R.Available
       && run.output_availability = Some (R.Unavailable R.Missing_completion));
    check string "missing output is not a running run" "failed" (R.status_label run.status);
    Fs_compat.save_file output output_bytes;
    Sys.remove input;
    let run = R.get registry ~run_id:"payload-run" |> Option.get in
    check bool "output survives a missing input file" true
      (run.input_availability = R.Unavailable R.Missing_registration
       && run.output_availability = Some R.Available))
;;

let test_a_changed_payload_file_is_refused_not_served () =
  with_completed_payload_source (fun registry path ->
    let output = payload_file path ~run_id:"payload-run" "output" in
    let original = Fs_compat.load_file output in
    let refused label bytes =
      Fs_compat.save_file output bytes;
      let run = R.get registry ~run_id:"payload-run" |> Option.get in
      check bool (label ^ ": input stays readable") true (run.input_availability = R.Available);
      check bool (label ^ ": the output is refused") true
        (match run.output_availability with
         | Some (R.Unavailable (R.Invalid_payload detail)) -> String.trim detail <> ""
         | _ -> false);
      check bool (label ^ ": no value is served") true
        (match run.status with R.Completed { output = `Null; _ } -> true | _ -> false);
      check string (label ^ ": terminal status is kept") "failed" (R.status_label run.status)
    in
    refused "a different size" (original ^ " ");
    refused "the same size, other bytes"
      (String.map (fun c -> if Char.equal c 'a' then 'b' else c) original);
    (* Another run's payload file is not this run's evidence. *)
    Fs_compat.save_file output original;
    R.register_running registry ~run_id:"another-run" ~lane:R.Librarian
      ~actor:"fixture" ~started_at:2.0 ~input:(R.Exact_input (`String "other input"));
    Fs_compat.save_file (payload_file path ~run_id:"another-run" "input") "not json";
    let run = R.get registry ~run_id:"payload-run" |> Option.get in
    check bool "a damaged file of another run does not touch this one" true
      (run.input_availability = R.Available && run.output_availability = Some R.Available))
;;

let test_startup_observation_is_immutable_and_distinguishes_absence () =
  let path = fresh_log_path "exact-startup-observation-" in
  let created = R.create ~path () in
  let before = R.startup_observation created in
  check bool "create has no replay or sweep" true
    (before.replay = Run_registry_core.Not_replayed && before.payload_sweep = R.Not_attempted);
  let absent = R.replay path |> R.startup_observation in
  check bool "absent log does not authorize a sweep" true
    (absent.replay = Run_registry_core.Log_absent && absent.payload_sweep = R.Replay_not_trusted);
  Fs_compat.save_file path "";
  let replayed = R.replay path in
  let startup = R.startup_observation replayed in
  check bool "clean empty log observes missing payload root" true
    (startup.payload_sweep = R.Root_absent);
  R.register_running replayed ~run_id:"later" ~lane:R.Librarian ~actor:"fixture"
    ~started_at:1.0 ~input:(R.Exact_input `Null);
  check bool "live registration does not rewrite startup observation" true
    (R.startup_observation replayed == startup);
  check bool "create observation also remains the same object" true
    (R.startup_observation created == before);
  remove_if_exists path
;;

let test_startup_sweep_reports_partial_removal_without_conflating_units () =
  let path = fresh_log_path "exact-startup-partial-removal-" in
  Fs_compat.save_file path "";
  let root = Filename.concat (Filename.dirname path) R.payload_dirname in
  Unix.mkdir root 0o700;
  let orphan = Filename.concat root "orphan" in
  Unix.mkdir orphan 0o700;
  let removable = Filename.concat orphan "remove-me.json" in
  Fs_compat.save_file removable "{}";
  (* A nested directory makes Sys.remove fail independently of permissions.
     readdir order is unspecified: compare acknowledgements with actual effects. *)
  let blocker = Filename.concat orphan "nested-directory" in
  Unix.mkdir blocker 0o700;
  let unexpected = Filename.concat root "root-file" in
  Fs_compat.save_file unexpected "{}";
  let replayed = R.replay path in
  (match (R.startup_observation replayed).payload_sweep with
   | R.Swept counts ->
     check int "two root entries examined" 2 counts.examined_root_entries;
     check int "one partially failed root entry" 1 counts.failed_root_entries;
     check int "no rmdir succeeded" 0 counts.removed_run_directories;
     let actual_unlinks = if Sys.file_exists removable then 1 else 2 in
     check int "successful unlinks survive the later error" actual_unlinks counts.unlinked_entries
   | R.Not_attempted | R.Replay_not_trusted | R.Root_absent | R.Root_unavailable
   | R.Sweep_scope_failed _ ->
     fail "expected an observed sweep with partial failure");
  check bool "independent root file was removed" false (Sys.file_exists unexpected);
  check bool "failed directory remains" true (Sys.file_exists blocker);
  remove_if_exists removable;
  Unix.rmdir blocker;
  Unix.rmdir orphan;
  Unix.rmdir root;
  remove_if_exists path
;;

let test_startup_sweep_reports_unavailable_root () =
  let path = fresh_log_path "exact-startup-unavailable-root-" in
  Fs_compat.save_file path "";
  let root = Filename.concat (Filename.dirname path) R.payload_dirname in
  Fs_compat.save_file root "not a directory";
  let observation = R.replay path |> R.startup_observation in
  check bool "a non-directory root is unavailable, not absent or swept" true
    (observation.payload_sweep = R.Root_unavailable);
  remove_if_exists root;
  remove_if_exists path
;;

let with_payload_link_fixture f =
  let path = fresh_log_path "exact-payload-nofollow-" in
  let base = Filename.dirname path in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base) (fun () ->
    let outside = Filename.concat base "owned-marker-directory" in
    Unix.mkdir outside 0o700;
    let marker = Filename.concat outside "owned-marker.txt" in
    let bytes = "owned marker outside the payload root must stay unchanged" in
    Fs_compat.save_file marker bytes;
    f path outside (fun () ->
      check string "actual marker bytes outside payload root preserved" bytes
        (Fs_compat.load_file marker)))
;;

let check_one_link_unlink replayed =
  match (R.startup_observation replayed).payload_sweep with
  | R.Swept counts ->
    check int "one root entry examined" 1 counts.examined_root_entries;
    check int "only the link name was unlinked" 1 counts.unlinked_entries;
    check int "no directory removal claimed" 0 counts.removed_run_directories;
    check int "no failure hidden" 0 counts.failed_root_entries
  | R.Not_attempted | R.Replay_not_trusted | R.Root_absent | R.Root_unavailable
   | R.Sweep_scope_failed _ ->
    fail "expected a completed descriptor-bound sweep"
;;

let test_payload_root_link_is_refused_without_following_it () =
  with_payload_link_fixture (fun path outside check_marker ->
    Fs_compat.save_file path "";
    let root = Filename.concat (Filename.dirname path) R.payload_dirname in
    Unix.symlink outside root;
    let replayed = R.replay path in
    check bool "linked root is unavailable, not an empty successful sweep" true
      ((R.startup_observation replayed).payload_sweep = R.Root_unavailable);
    check_marker ();
    check bool "root link itself is retained" true
      ((Unix.lstat root).Unix.st_kind = Unix.S_LNK))
;;

let test_orphan_directory_link_only_unlinks_the_link_name () =
  with_payload_link_fixture (fun path outside check_marker ->
    Fs_compat.save_file path "";
    let root = Filename.concat (Filename.dirname path) R.payload_dirname in
    Unix.mkdir root 0o700;
    let link = Filename.concat root "orphan-link" in
    Unix.symlink outside link;
    let replayed = R.replay path in
    check_marker ();
    check bool "unreferenced root link removed" false (Sys.file_exists link);
    check_one_link_unlink replayed)
;;

let test_retained_directory_link_never_grants_target_cleanup () =
  with_payload_link_fixture (fun path outside check_marker ->
    let registry = R.create ~path () in
    R.register_running registry ~run_id:"retained" ~lane:R.Librarian ~actor:"fixture"
      ~started_at:1.0 ~input:(R.Exact_input (`String "original retained input"));
    let dir = payload_run_dir path ~run_id:"retained" in
    Unix.rename dir (Filename.concat (Filename.dirname path) "saved-original-directory");
    Unix.symlink outside dir;
    let replayed = R.replay path in
    check_marker ();
    check bool "the registry still names the retained run" true
      (List.exists (fun (run : R.run) -> run.run_id = "retained") (R.list_runs replayed));
    check bool "cleanup removed only the directory-link name" false (Sys.file_exists dir);
    check_one_link_unlink replayed)
;;

let test_unreferenced_leaf_link_never_unlinks_its_target () =
  with_payload_link_fixture (fun path outside check_marker ->
    let registry = R.create ~path () in
    R.register_running registry ~run_id:"retained" ~lane:R.Librarian ~actor:"fixture"
      ~started_at:1.0 ~input:(R.Exact_input (`String "original retained input"));
    let link = Filename.concat (payload_run_dir path ~run_id:"retained") "unexpected-link" in
    Unix.symlink (Filename.concat outside "owned-marker.txt") link;
    let replayed = R.replay path in
    check_marker ();
    check bool "unreferenced leaf link removed" false (Sys.file_exists link);
    check_one_link_unlink replayed;
    let retained = R.get replayed ~run_id:"retained" |> Option.get in
    check bool "actual referenced input remains readable" true
      (retained.input_availability = R.Available))
;;

let () =
  run
    "exact_lane_run_registry"
    [ ( "registry"
      , [ test_case "payload root link is refused without following it" `Quick
            test_payload_root_link_is_refused_without_following_it
        ; test_case "orphan directory link unlinks only its own name" `Quick
            test_orphan_directory_link_only_unlinks_the_link_name
        ; test_case "retained directory link cannot authorize target cleanup" `Quick
            test_retained_directory_link_never_grants_target_cleanup
        ; test_case "unreferenced leaf link cannot unlink its target" `Quick
            test_unreferenced_leaf_link_never_unlinks_its_target
        ; test_case "startup observation is immutable and distinguishes absence" `Quick
            test_startup_observation_is_immutable_and_distinguishes_absence
        ; test_case "startup sweep reports partial effects in separate units" `Quick
            test_startup_sweep_reports_partial_removal_without_conflating_units
        ; test_case "startup sweep reports unavailable root" `Quick
            test_startup_sweep_reports_unavailable_root
        ; test_case "durable exact evidence" `Quick test_round_trip_preserves_exact_evidence
        ; test_case "memory and disk preserve available JSON null" `Quick
            test_memory_only_and_disk_null_are_available_values
        ; test_case "missing payload files preserve terminal identity" `Quick
            test_missing_payload_files_do_not_erase_terminal_identity
        ; test_case "each payload file reports its own availability" `Quick
            test_each_payload_file_reports_its_own_availability
        ; test_case "a changed payload file is refused, not served" `Quick
            test_a_changed_payload_file_is_refused_not_served
        ; test_case "replay removes payload files no row names" `Quick
            test_replay_removes_payload_files_no_row_names
        ; test_case "a partial replay leaves payload files alone" `Quick
            test_a_partial_replay_leaves_payload_files_alone
        ; test_case "a replay that skipped an unreadable row leaves payload files alone" `Quick
            test_a_replay_that_skipped_an_unreadable_row_leaves_payload_files_alone
        ; test_case "a failed second registration keeps the first payload" `Quick
            test_a_failed_second_registration_keeps_the_first_payload
        ; test_case "latest payloads survive blank rows and repeated replay" `Quick
            test_replay_selects_latest_payloads_across_blank_rows
        ; test_case "missing receipt is explicit null" `Quick
            test_completion_without_slot_receipt_writes_explicit_null
        ; test_case "usage is recorded and survives replay" `Quick
            test_usage_is_recorded_and_survives_replay
        ; test_case "completion without usage replays as None" `Quick
            test_completion_without_usage_replays_as_none
        ; test_case "malformed usage is rejected, not read" `Quick
            test_malformed_usage_is_rejected_not_read
        ; test_case "pre-v4 completion is not replayed as success" `Quick
            test_missing_selected_slot_completion_is_not_replayed_as_success
        ; test_case "blank selected slot is rejected before write" `Quick
            test_blank_selected_slot_is_rejected_before_write
        ; test_case "hard-cut artifact does not poison compaction forever" `Quick
            test_hard_cut_artifact_does_not_poison_compaction_forever
        ; test_case "cut refuses a store with an unterminated tail" `Quick
            test_cut_refuses_a_store_with_an_unterminated_tail
        ; test_case "running shape" `Quick test_running_shape_has_no_invented_completion
        ; test_case "restart settles running lane" `Quick
            test_replay_settles_running_as_server_restart_failure
        ; test_case "current storage generation" `Quick test_current_storage_generation
        ; test_case "replay sweep preserves another storage generation" `Quick
            test_replay_sweep_preserves_the_other_storage_generation
        ; test_case "current completion requires origin and nullable duration" `Quick
            test_current_completion_requires_origin_and_nullable_duration
        ; test_case "invalid measured duration cannot mutate a run" `Quick
            test_invalid_measured_duration_cannot_mutate_a_run
        ; test_case "store version pins the registration shape" `Quick
            test_store_version_pins_the_registration_shape
        ; test_case "exact history is not cross-lane pruned" `Quick
            test_exact_history_is_not_pruned_across_lanes
        ; Alcotest.test_case
            "a busy lane cannot evict a quiet lane's history"
            `Quick
            test_a_busy_lane_cannot_evict_a_quiet_lanes_history
        ; test_case "the registry refuses lanes without retained runs" `Quick
            test_the_registry_refuses_unrecorded_lanes
        ; test_case "retention is derived from the monitor page size" `Quick
            test_retention_is_derived_from_the_monitor_page_size
        ; test_case "completed runs are bounded" `Quick
            test_completed_runs_are_bounded
        ; test_case "failed durable registration is not published" `Quick
            test_failed_durable_registration_is_not_published_in_memory
        ; test_case "failed durable completion is explicitly visible" `Quick
            test_failed_durable_completion_is_explicitly_visible
        ; test_case "observation reads do not wait for durable writer" `Quick
            test_observation_reads_do_not_wait_for_durable_writer
        ; test_case "pages are a total order over equal timestamps" `Quick
            test_pages_are_a_total_order_over_equal_timestamps
        ; test_case "summary carries no payload" `Quick test_summary_carries_no_payload
        ; test_case "projected runs omit payload in memory" `Quick
            test_projected_runs_omit_payload_in_memory
        ; test_case "the store does not hold the payloads it retains" `Quick
            test_the_store_does_not_hold_the_payloads_it_retains
        ] )
    ]
