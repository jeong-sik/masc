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
  match R.mark_completed t ~run_id ~outcome ~elapsed_s ~selected_slot:None ~output with
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
  (match R.get replayed ~run_id:"run-1" |> Option.get with
   | { status = R.Completed { selected_slot = Some selected_slot; _ }; _ } ->
     check string "selected slot" "librarian-primary" selected_slot
   | _ -> fail "selected slot did not survive durable replay");
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
  in
  check bool "blank selected slot is a typed writer error" true
    (match result with
     | Error R.Invalid_selected_slot -> true
     | Error R.Unknown_run | Error (R.Persistence_failed _) | Ok () -> false);
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
             ; elapsed_s
             ; output
             ; selected_slot
             }
       ; _
       } ->
     check string "typed restart code" "server_restarted" code;
     check string
       "operator detail"
       "exact-output fibers do not survive server restart"
       detail;
     check bool "elapsed time is retained" true (elapsed_s >= 2.0);
     check (option string) "no slot receipt is invented" None selected_slot;
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
   | R.Completed { output; _ } ->
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
  check string "current store file" "exact-lane-runs-v6.jsonl" R.storage_filename
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
    "exact-lane-runs-v6.jsonl" R.storage_filename;
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

(* The lanes this registry records, written out apart from the registry: every
   lane but the Verifier, whose reviews have registries of their own. *)
let recorded_lanes = [ R.Librarian; R.Hitl_auto_judge; R.Board_attention; R.Workspace_curator ]

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
    (recorded_lanes |> List.map Standalone_lane.to_id |> List.sort String.compare)
    (R.list_runs replayed
     |> List.map (fun (run : R.run) -> Standalone_lane.to_id run.lane)
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
  let kept = R.get replayed ~run_id:"kept" |> Option.get in
  check bool "a retained run keeps its payload files" true
    (kept.input_availability = R.Available && kept.output_availability = Some R.Available);
  remove_if_exists path
;;

(* Rows, the projection and the TUI all read a lane id back through
   [Standalone_lane.of_id]. The match here is the independent oracle: a lane
   added to the type does not compile here until it has a place, and a lane
   left out of [all] fails the first check. *)
let test_every_lane_is_listed_once_and_its_id_reads_back () =
  let place : Standalone_lane.t -> int = function
    | Standalone_lane.Librarian -> 0
    | Standalone_lane.Hitl_auto_judge -> 1
    | Standalone_lane.Board_attention -> 2
    | Standalone_lane.Workspace_curator -> 3
    | Standalone_lane.Verifier -> 4
  in
  check (list int) "all lists the five lanes once, in declaration order"
    [ 0; 1; 2; 3; 4 ]
    (List.map place Standalone_lane.all);
  List.iter
    (fun lane ->
      let id = Standalone_lane.to_id lane in
      check (option int) (id ^ " reads back as its own lane") (Some (place lane))
        (Option.map place (Standalone_lane.of_id id)))
    Standalone_lane.all;
  check (option int) "an id no lane has reads as no lane" None
    (Option.map place (Standalone_lane.of_id "verifer_exact"))
;;

(* A registration row of this store version, naming [lane]. *)
let registration_row lane =
  Printf.sprintf
    {|{"event":"register","id":"exact-lane-pin","started_at":30.0,"registration":{"lane":%S,"actor":"keeper-a","input":{"kind":"file","bytes":20,"sha256":"4f8c3b7d2a1e9f6c5b0a8d7e6f5c4b3a2918273645546372819a0b1c2d3e4f50"}}}|}
    (Standalone_lane.to_id lane)
;;

(* A Verifier review is recorded by the verification run registries, so this
   registry refuses the lane on the way in and on replay. The Board row beside
   it has the same shape, so the lane is the only reason for the refusal. *)
let test_the_registry_refuses_the_verifier_lane () =
  let registry = R.create () in
  let refused =
    match
      R.register_running registry ~run_id:"verifier-run" ~lane:R.Verifier
        ~actor:"keeper-a" ~started_at:1.0 ~input:(R.Exact_input `Null)
    with
    | () -> false
    | exception Invalid_argument _ -> true
  in
  check bool "a Verifier registration is refused" true refused;
  check int "and nothing is recorded" 0 (List.length (R.list_runs registry));
  (* The same call on a lane the registry records goes through, so the lane is
     what was refused, not the run id or the input. *)
  R.register_running registry ~run_id:"verifier-run" ~lane:R.Librarian
    ~actor:"keeper-a" ~started_at:1.0 ~input:(R.Exact_input `Null);
  check int "the same call on a recorded lane is kept" 1
    (List.length (R.list_runs registry));
  let read_and_refused lane =
    let path = fresh_log_path "exact-lane-verifier-row-" in
    Fs_compat.save_file path (registration_row lane ^ "\n");
    let report = R.cut_replay_log ~execute:false path in
    remove_if_exists path;
    report.Run_registry_core.lines_read, report.Run_registry_core.malformed_lines
  in
  check (pair int int) "a Board row is read and kept" (1, 0)
    (read_and_refused R.Board_attention);
  check (pair int int) "a Verifier row is read and refused" (1, 1)
    (read_and_refused R.Verifier)
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
  in
  (match completion with
   | Error (R.Persistence_failed failure) ->
     check bool "failure retains durable detail" true
       (String.trim failure.detail <> "")
   | Error R.Unknown_run -> fail "registered run became unknown"
   | Error R.Invalid_selected_slot -> fail "explicit None slot became invalid"
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

let () =
  run
    "exact_lane_run_registry"
    [ ( "registry"
      , [ test_case "durable exact evidence" `Quick test_round_trip_preserves_exact_evidence
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
        ; test_case "store version pins the registration shape" `Quick
            test_store_version_pins_the_registration_shape
        ; test_case "exact history is not cross-lane pruned" `Quick
            test_exact_history_is_not_pruned_across_lanes
        ; Alcotest.test_case
            "a busy lane cannot evict a quiet lane's history"
            `Quick
            test_a_busy_lane_cannot_evict_a_quiet_lanes_history
        ; test_case "every lane is listed once and its id reads back" `Quick
            test_every_lane_is_listed_once_and_its_id_reads_back
        ; test_case "the registry refuses the Verifier lane" `Quick
            test_the_registry_refuses_the_verifier_lane
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
