open Alcotest
open Masc
module Trace = Server_dashboard_http_keeper_api_trace
module Checkpoints = Server_dashboard_http_keeper_api_checkpoints
module Runtime_lens_scan = Server_dashboard_http_keeper_runtime_manifest_scan
module Runtime_lens_swimlane = Server_dashboard_http_keeper_runtime_lens_swimlane
module T = Trajectory

(* What the operator's window currently says. The store takes the window as an
   argument -- it is reachable from a raw Domain, where reading a setting
   raises -- so every caller names it. These cases are not about the window and
   pass what production passes. *)
let history_retained () =
  Runtime_params.get Runtime_settings.keeper_checkpoint_history_retained

let mk_thinking_with_turn ~turn ~block_index ~reasoning_kind =
  T.Withheld_thinking
    { ts = Float.of_int turn
    ; ts_iso = "2026-06-29T00:00:00Z"
    ; turn
    ; block_index
    ; reasoning_kind
    ; char_count = 10
    }
;;

let mk_thinking ~block_index =
  mk_thinking_with_turn
    ~turn:1
    ~block_index
    ~reasoning_kind:T.Thinking_block
;;

let test_dedupe_preserves_first_order () =
  let t1 = mk_thinking ~block_index:1 in
  let t2 = mk_thinking ~block_index:2 in
  let t1_dup = mk_thinking ~block_index:1 in
  let input = [ t1; t2; t1_dup ] in
  let result = Trace.dedupe_thinking_lines input in
  check int "length" 2 (List.length result);
  match result with
  | [ T.Withheld_thinking a; T.Withheld_thinking b ] ->
    check int "first" 1 a.block_index;
    check int "second" 2 b.block_index
  | _ -> fail "expected two thinking lines"
;;

let test_dedupe_distinguishes_turn_identity () =
  let t1 =
    mk_thinking_with_turn
      ~turn:1
      ~block_index:1
      ~reasoning_kind:T.Thinking_block
  in
  let t2 =
    mk_thinking_with_turn
      ~turn:2
      ~block_index:1
      ~reasoning_kind:T.Thinking_block
  in
  let input = [ t1; t2 ] in
  let result = Trace.dedupe_thinking_lines input in
  check int "length" 2 (List.length result)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_file "trace-test" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let test_chat_trace_block_by_turn_ref_reads_allowed_trace_ids () =
  with_temp_dir (fun dir ->
    let config = Workspace.default_config dir in
    let masc_root = Workspace.masc_dir config in
    let keeper_name = "keeper-chat-trace" in
    T.append_withheld_thinking
      ~masc_root
      ~keeper_name
      ~trace_id:"trace-current"
      { ts = 1.0
      ; ts_iso = "2026-07-01T00:00:01Z"
      ; turn = 1
      ; block_index = 0
      ; reasoning_kind = T.Thinking_block
      ; char_count = 12
      };
    T.append_withheld_thinking
      ~masc_root
      ~keeper_name
      ~trace_id:"trace-old"
      { ts = 2.0
      ; ts_iso = "2026-07-01T00:00:02Z"
      ; turn = 42
      ; block_index = 0
      ; reasoning_kind = T.Thinking_block
      ; char_count = 8
      };
    let trace_block_by_turn_ref =
      Trace.chat_trace_block_by_turn_ref
        ~max_lines:10
        ~config
        ~keeper_name
        ~allowed_trace_ids:[ "trace-current"; "trace-old" ]
    in
    let old_ref = Ids.Turn_ref.make ~trace_id:"trace-old" ~absolute_turn:42 in
    (match trace_block_by_turn_ref old_ref with
     | Some
         (Keeper_chat_blocks.Trace
           { trace = [ Keeper_chat_blocks.Trace_think { text = ""; content_withheld = true; _ } ] })
       -> ()
     | Some _ -> fail "old trace_id returned unexpected trace block"
     | None -> fail "allowed older trace_id should enrich");
    let disallowed_ref =
      Ids.Turn_ref.make ~trace_id:"trace-unlisted" ~absolute_turn:42
    in
    check
      bool
      "unlisted trace_id is not used as a filesystem read key"
      true
      (Option.is_none (trace_block_by_turn_ref disallowed_ref)))
;;

let test_chat_trace_window_preserves_payload_and_snapshot () =
  with_temp_dir (fun dir ->
    let config = Workspace.default_config dir in
    let masc_root = Workspace.masc_dir config in
    let keeper_name = "keeper-chat-window" in
    let trace_id = "trace-window" in
    let rows = List.init 230 (fun index ->
      T.Tool_call
        { ts = float_of_int index; ts_iso = string_of_int index; turn = 1; round = 1
        ; tool_name = "tool-" ^ string_of_int index
        ; args_json = if index = 30 then "plain args" else "{\"index\":1}"
        ; gate_decision = T.Pass
        ; result = Some (if index = 31 then "plain result" else "{\"ok\":true}")
        ; duration_ms = index; error = None; execution_id = Some ("execution-" ^ string_of_int index)
        }) in
    let path = T.trajectory_path masc_root keeper_name trace_id in
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file path
      (rows |> List.map (fun row -> Yojson.Safe.to_string (T.trajectory_line_to_json row) ^ "\n")
       |> String.concat "");
    let resolve () = Trace.chat_trace_block_by_turn_ref ~max_lines:500 ~config
      ~keeper_name ~allowed_trace_ids:[trace_id] in
    let read = resolve () in
    let turn = Ids.Turn_ref.make ~trace_id ~absolute_turn:1 in
    (match read turn with
     | Some (Keeper_chat_blocks.Trace {trace; omitted}) ->
       check int "only the newest steps are displayed" 200 (List.length trace);
       check int "omission count describes the same window" 30 omitted;
       (match trace with
        | Keeper_chat_blocks.Trace_tool first :: Keeper_chat_blocks.Trace_tool second :: _ ->
          check string "first retained step" "tool-30" first.name;
          check bool "invalid argument JSON stays literal" true (first.args = Some (`String "plain args"));
          check bool "invalid result JSON stays literal" true (second.result = Some (`String "plain result"))
        | _ -> fail "expected retained tool steps")
     | _ -> fail "expected one trace block");
    let absent = Ids.Turn_ref.make ~trace_id ~absolute_turn:2 in
    check bool "absent turn" true (Option.is_none (read absent));
    T.append_withheld_thinking ~masc_root ~keeper_name ~trace_id
      {ts=300.; ts_iso="later"; turn=2; block_index=0; reasoning_kind=T.Thinking_block; char_count=1};
    check bool "one render keeps its original trace observation" true (Option.is_none (read absent));
    check bool "the next render observes the appended turn" true (Option.is_some (resolve () absent)))
;;

let string_member key = function
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`String value) -> value
    | Some _ -> fail (Printf.sprintf "%s is not a string" key)
    | None -> fail (Printf.sprintf "%s missing" key))
  | _ -> fail "expected object"
;;

let json_with_field row_json field replacement =
  match row_json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
            if String.equal key field then key, replacement else key, value)
         fields)
  | _ -> fail "fixture must encode as an object"
;;

let runtime_manifest_json_with_event row_json event =
  json_with_field row_json "event" (`String event)
;;

let runtime_manifest_json_without_field row_json field =
  match row_json with
  | `Assoc fields -> `Assoc (List.remove_assoc field fields)
  | _ -> fail "fixture must encode as an object"
;;

(* The scan record carries no mutable field, so folding a row must leave the
   argument at its previous value and report the advance through the return.
   This pins the property the fold buys: a caller can hold on to an earlier
   scan without it drifting under them. It does not compile against the
   in-place shape, where [update_runtime_manifest_scan] returned [unit]. *)
let test_runtime_manifest_scan_fold_leaves_input_untouched () =
  let scan =
    Runtime_lens_scan.make_runtime_manifest_scan
      ~path:"/tmp/immutable-runtime-manifest.jsonl"
      ~limit:4
      ~scan_line_limit:16
      ~scan_scope:"test"
  in
  let row =
    Keeper_runtime_manifest.make
      ~keeper_name:"immutable-scan-keeper"
      ~trace_id:"trace-immutable-scan"
      ~keeper_turn_id:7
      ~event:Keeper_runtime_manifest.Turn_finished
      ~status:"finished"
      ()
  in
  let advanced = Runtime_lens_scan.update_runtime_manifest_scan scan row in
  check int "argument keeps its row count" 0 scan.total_rows;
  check bool "argument keeps its terminal flag" false scan.has_terminal;
  check
    (list int)
    "argument keeps its terminal turn ids"
    []
    scan.terminal_keeper_turn_ids;
  check int "result counts the row" 1 advanced.total_rows;
  check bool "result observes the terminal event" true advanced.has_terminal;
  check
    (list int)
    "result records the terminal turn id"
    [ 7 ]
    advanced.terminal_keeper_turn_ids
;;

let test_runtime_manifest_scan_surfaces_diagnostics_without_repeat_warnings () =
  with_temp_dir @@ fun dir ->
  let config = Workspace.default_config dir in
  let keeper_name = "manifest-diagnostic-keeper" in
  let trace_id = "trace-manifest-diagnostics" in
  let active_row =
    Keeper_runtime_manifest.make
      ~keeper_name
      ~trace_id
      ~keeper_turn_id:1
      ~event:Keeper_runtime_manifest.Turn_started
      ~status:"started"
      ()
    |> Keeper_runtime_manifest.to_json
  in
  let rows =
    [ runtime_manifest_json_with_event active_row "unsupported_manifest_event_1"
    ; runtime_manifest_json_with_event active_row "unsupported_manifest_event_2"
    ; runtime_manifest_json_with_event active_row "unsupported_manifest_event_3"
    ; runtime_manifest_json_with_event active_row "unsupported_manifest_event_4"
    ; runtime_manifest_json_with_event active_row "unsupported_manifest_event_5"
    ; json_with_field
        (runtime_manifest_json_with_event active_row "unsupported_manifest_event_1")
        "schema_version"
        (`Int 2)
    ; runtime_manifest_json_without_field active_row "status"
    ; active_row
    ]
  in
  let path =
    Keeper_runtime_manifest.path_for_trace config ~keeper_name ~trace_id
  in
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out path in
  List.iter
    (fun row -> Printf.fprintf channel "%s\n" (Yojson.Safe.to_string row))
    rows;
  Printf.fprintf channel "{not-json\n";
  close_out channel;
  let warnings = ref [] in
  Console_sink.For_testing.reset ();
  Console_sink.For_testing.set_writer (Some (fun line -> warnings := line :: !warnings));
  let scan =
    Fun.protect
      ~finally:Console_sink.For_testing.reset
      (fun () ->
         Runtime_lens_scan.read_runtime_manifest_scan
           ~config
           ~keeper_name
           ~trace_id
           ~limit:2
           ())
  in
  check int "one active row decoded" 1 scan.total_rows;
  check int "all rows scanned" 9 scan.scanned_lines;
  check int "reader emits no per-row warnings" 0 (List.length !warnings);
  let diagnostics = Runtime_lens_scan.runtime_manifest_scan_diagnostics_json scan in
  let open Yojson.Safe.Util in
  check string
    "diagnostic schema"
    "keeper.runtime_manifest_scan_diagnostics.v1"
    (diagnostics |> member "schema" |> to_string);
  check int
    "unsupported rows counted"
    5
    (diagnostics |> member "unsupported_event_count" |> to_int);
  check int
    "unsupported rows outside the identity request bound are explicit"
    3
    (diagnostics
     |> member "unsupported_event_unattributed_count"
     |> to_int);
  check int
    "invalid manifest rows counted"
    2
    (diagnostics |> member "invalid_manifest_row_count" |> to_int);
  check int
    "invalid json rows counted"
    1
    (diagnostics |> member "invalid_json_row_count" |> to_int);
  let unsupported_counts =
    diagnostics |> member "unsupported_event_counts" |> to_list
  in
  check int
    "unsupported identity aggregation obeys request bound"
    2
    (List.length unsupported_counts);
  check int
    "diagnostic samples obey request bound"
    2
    (diagnostics |> member "samples" |> to_list |> List.length)
;;

let test_tool_runtime_zero_event_lane_is_not_observed () =
  let scan =
    Runtime_lens_scan.make_runtime_manifest_scan
      ~path:"/tmp/empty-runtime-manifest.jsonl"
      ~limit:10
      ~scan_line_limit:10
      ~scan_scope:"test"
  in
  let json =
    Runtime_lens_swimlane.runtime_lens_swimlane_json
      scan
      []
      ~lane:"tool_runtime"
      ~label:"Tool Runtime"
      ~events:[]
      ~terminal_status:"not_observed"
      ~synthetic_events:[]
  in
  check string "terminal status" "not_observed"
    (string_member "terminal_status" json);
  check string "empty tool-runtime lane is not complete" "not_observed"
    (string_member "completeness" json)
;;

(* #32971 Root A: the retired "provider" lane demanded
   provider_attempt_started / provider_attempt_finished, which no code has
   written since #19536 removed the Cascade driver. Every turn therefore
   reported turn_terminal_incomplete and no Keeper could reach a lane set
   without a gap. Two things must hold now: no policy may name an event the
   tree cannot produce, and the dispatch-closure assertion the provider lane
   carried must still be asked on the lane that has the rows. *)
let manifest_row ~event =
  { Keeper_runtime_manifest.schema_version = 1
  ; ts = "2026-09-04T00:00:00Z"
  ; keeper_name = "swimlane-fixture"
  ; trace_id = "trace/swimlane-fixture"
  ; keeper_turn_id = Some 1
  ; agent_core_turn_count = Some 1
  ; logical_seq = None
  ; event
  ; runtime_id = None
  ; status = "ok"
  ; decision = `Assoc []
  ; links =
      { receipt_path = None; checkpoint_path = None; tool_call_log_path = None }
  }
;;

let scan_of_events events =
  List.fold_left
    (fun scan event ->
       Runtime_lens_scan.update_runtime_manifest_scan scan (manifest_row ~event))
    (Runtime_lens_scan.make_runtime_manifest_scan
       ~path:"/tmp/swimlane-fixture.jsonl"
       ~limit:64
       ~scan_line_limit:64
       ~scan_scope:"test")
    events
;;

let test_manifest_event_vocabulary_is_pinned () =
  (* The retired pair must not come back by way of a new variant: nothing in
     the tree appends them, so a policy naming one is unsatisfiable. *)
  check
    (list string)
    "manifest event kinds"
    [ "turn_started"
    ; "phase_gate_decided"
    ; "runtime_routed"
    ; "runtime_execution_built"
    ; "runtime_completed"
    ; "runtime_failed"
    ; "pre_dispatch_blocked"
    ; "provider_lane_resolved"
    ; "context_injected"
    ; "history_projection_observed"
    ; "skill_preparation_observed"
    ; "preparation_observed"
    ; "event_bus_correlated"
    ; "checkpoint_loaded"
    ; "checkpoint_saved"
    ; "receipt_appended"
    ; "turn_finished"
    ]
    (List.map
       Keeper_runtime_manifest.event_kind_to_string
       Keeper_runtime_manifest.all_event_kinds)
;;

let test_history_projection_preserves_context_diagnostics () =
  let scan = Runtime_lens_scan.make_runtime_manifest_scan
    ~path:"/tmp/projection-context-fixture.jsonl" ~limit:64
    ~scan_line_limit:64 ~scan_scope:"test" in
  let context = { (manifest_row ~event:Keeper_runtime_manifest.Context_injected)
    with decision = `Assoc ["context_digest", `String "injected-context"] } in
  let projection = { (manifest_row ~event:Keeper_runtime_manifest.History_projection_observed)
    with decision = `Assoc ["scope", `String "first_request_projection_in_provider_attempt_not_delivery"] } in
  let scan = Runtime_lens_scan.update_runtime_manifest_scan scan context in
  let scan = Runtime_lens_scan.update_runtime_manifest_scan scan projection in
  check int "projection is not a context injection" 1 scan.context_injected_count;
  (match scan.latest_context_injected_row with
   | Some row -> check bool "latest actual injection remains selected" true (row = context)
   | None -> fail "actual context injection disappeared");
  check int "projection event remains observable" 1
    (Hashtbl.find scan.event_counts "history_projection_observed");
  let projection_only = scan_of_events [Keeper_runtime_manifest.History_projection_observed] in
  let lane = Runtime_lens_swimlane.runtime_lens_agent_core_swimlane_json projection_only [] in
  check int "actual lane includes projection observation" 1
    Yojson.Safe.Util.(lane |> member "event_count" |> to_int);
  check string "projection alone is not an empty lane" "projection_observed"
    (string_member "terminal_status" lane);
  check string "projection alone does not prove checkpoint completion" "incomplete"
    (string_member "completeness" lane)
;;

let test_runtime_lane_asserts_dispatch_closure () =
  let open Keeper_runtime_manifest in
  let routed_only = scan_of_events [ Runtime_routed ] in
  check
    string
    "a dispatch that never terminated is not complete"
    "mandatory_present"
    (Runtime_lens_swimlane.runtime_lens_swimlane_completeness
       routed_only
       "masc_policy_runtime");
  let closed = scan_of_events [ Runtime_routed; Runtime_completed ] in
  check
    string
    "a dispatch closed by runtime_completed is complete"
    "complete"
    (Runtime_lens_swimlane.runtime_lens_swimlane_completeness
       closed
       "masc_policy_runtime");
  let failed = scan_of_events [ Runtime_routed; Runtime_failed ] in
  check
    string
    "a dispatch closed by runtime_failed is complete"
    "complete"
    (Runtime_lens_swimlane.runtime_lens_swimlane_completeness
       failed
       "masc_policy_runtime")
;;

let test_no_lane_policy_names_a_retired_provider_lane () =
  check
    (list string)
    "lane policies"
    [ "keeper"; "masc_policy_runtime"; "agent_core_agent"; "memory_context" ]
    (List.map
       (fun policy -> policy.Runtime_lens_swimlane.lane)
       Runtime_lens_swimlane.lane_policies)
;;

let make_checkpoint_inventory_meta ~name ~trace_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String trace_id
        ])
  with
  | Ok meta -> meta
  | Error detail -> fail ("checkpoint inventory meta fixture failed: " ^ detail)
;;

let make_inventory_checkpoint ~session_id ~turn_count ~created_at =
  Agent_core.Checkpoint.
    { version = checkpoint_version
    ; session_id
    ; agent_name = "checkpoint-inventory-test"
    ; model = "opaque-runtime"
    ; system_prompt = None
    ; messages = []
    ; usage = Agent_core.Types.empty_usage
    ; turn_count
    ; created_at
    ; tools = []
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; temperature = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; reasoning_effort = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; response_format = Agent_core.Types.Off
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; pending_input = None; mcp_sessions = []
    ; working_context = None
    }
;;

(* Exercise the actual handlers and HTTP/JSON projection without a listener. *)
let checkpoint_http_response ~meth ~keeper_name ~body handler =
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create handler in
  let wire = Printf.sprintf
      "%s /api/v1/keepers/%s/checkpoints HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n%s"
      meth keeper_name (String.length body) body in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0
            ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output
          (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  let lines = String.split_on_char '\n' (Buffer.contents output) in
  let status = match lines with
    | first :: _ ->
      (match String.split_on_char ' ' first with
       | _ :: code :: _ -> int_of_string code
       | _ -> fail "invalid HTTP status line")
    | [] -> fail "missing HTTP response" in
  let rec response_body = function
    | "\r" :: rest -> String.concat "\n" rest
    | _ :: rest -> response_body rest
    | [] -> fail "missing HTTP header boundary" in
  status, Yojson.Safe.from_string (response_body lines)
;;

let post_checkpoint_history state ~keeper_name snapshot_ids =
  let body = Yojson.Safe.to_string
      (`Assoc [ "action", `String "delete_history"
              ; "snapshot_ids", `List (List.map (fun id -> `String id) snapshot_ids) ]) in
  checkpoint_http_response ~meth:"POST" ~keeper_name ~body (fun reqd ->
    Server_dashboard_http_keeper_api_post.handle_keeper_checkpoints_post
      state (Httpun.Reqd.request reqd) reqd body)
;;

let get_checkpoint_inventory state ~keeper_name =
  checkpoint_http_response ~meth:"GET" ~keeper_name ~body:"" (fun reqd ->
    let request = Httpun.Reqd.request reqd in
    Server_dashboard_http_keeper_api.handle_keeper_get_subroutes state request request reqd)
;;

let test_history_delete_preserves_session_files () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  with_temp_dir @@ fun dir ->
  let module Store = Keeper_checkpoint_store in
  let state = Mcp_server.For_testing.create_state ~base_path:dir in
  let config = Mcp_server.workspace_config state in
  let keeper_name = "checkpoint-delete" in
  let trace_id = Keeper_identity.generate_trace_id ~now:1.0 () in
  Keeper_meta_store.replace_snapshot config
    (make_checkpoint_inventory_meta ~name:keeper_name ~trace_id)
  |> Result.map_error (fun detail -> fail detail) |> Result.get_ok;
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  let checkpoint turn_count =
    { (make_inventory_checkpoint ~session_id:trace_id ~turn_count
         ~created_at:(float_of_int turn_count)) with
      Agent_core.Checkpoint.messages =
        [ Agent_core.Types.user_msg (Printf.sprintf "saved turn %d" turn_count) ] } in
  let previous = checkpoint 1 and current = checkpoint 2 in
  List.iter (fun checkpoint ->
    match Store.save_agent_core_classified ~session_dir ~history_retained:2 checkpoint with
    | Ok (Store.Saved _) -> ()
    | Ok (Store.Stale_noop _) -> fail "fixture checkpoint was stale"
    | Error detail -> fail detail) [ previous; current ];
  let previous_id = Store.agent_core_history_snapshot_id_of_checkpoint previous in
  let selected_id = Store.agent_core_history_snapshot_id_of_checkpoint current in
  let absent_id = Store.agent_core_history_snapshot_id_of_checkpoint (checkpoint 3) in
  let failed_id = Store.agent_core_history_snapshot_id_of_checkpoint (checkpoint 4) in
  let path id = Filename.concat session_dir id in
  let canonical = Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  check int "selected archive is a hardlink of current canonical"
    (Unix.stat canonical).Unix.st_ino (Unix.stat (path selected_id)).Unix.st_ino;
  let other_files = [ "history.jsonl"; "history.internal.jsonl"; "notes.json"
                    ; "agent-core-snapshot-.json" ] in
  List.iter (fun id -> Fs_compat.save_file (path id) ("retained " ^ id)) other_files;
  let rejected = Filename.basename canonical :: other_files in
  Fs_compat.mkdir_p (path failed_id);
  let preserved = List.map (fun id -> id, Fs_compat.load_file (path id))
      (previous_id :: rejected) in
  let check_preserved () =
    List.iter (fun (id, bytes) ->
      check string (id ^ " retains its bytes") bytes (Fs_compat.load_file (path id)))
      preserved;
    check (list string)
      "only the requested archive was removed"
      [ failed_id; previous_id ]
      (Store.list_agent_core_history_files ~session_dir) in
  let status, json = post_checkpoint_history state ~keeper_name
      (selected_id :: rejected @ [ absent_id; failed_id ]) in
  let open Yojson.Safe.Util in
  let ids field json = json |> member field |> to_list |> List.map to_string in
  check int "mixed deletion HTTP status" 200 status;
  check (list string) "HTTP reports only the archive as deleted" [ selected_id ]
    (ids "deleted_snapshot_ids" json);
  check (list string) "only the absent archive is missing"
    [ absent_id ] (ids "missing_snapshot_ids" json);
  check (list string) "non-archive names are refused"
    rejected (ids "refused_snapshot_ids" json);
  check (list string) "a valid archive that cannot be unlinked reports failure"
    [ failed_id ] (ids "failed_snapshot_ids" json);
  check bool "the failed removal remains present" true (Sys.is_directory (Filename.concat session_dir failed_id));
  check string "canonical remains available in returned inventory" "available"
    (json |> member "inventory" |> member "current_status" |> to_string);
  check_preserved ();
  let status, repeated = post_checkpoint_history state ~keeper_name [ selected_id ] in
  check int "repeated deletion HTTP status" 200 status;
  check (list string) "repeat deletes nothing" [] (ids "deleted_snapshot_ids" repeated);
  check (list string) "repeat reports the absent archive" [ selected_id ]
    (ids "missing_snapshot_ids" repeated);
  check (list string) "repeat refuses nothing" [] (ids "refused_snapshot_ids" repeated);
  check (list string) "repeat fails nothing" [] (ids "failed_snapshot_ids" repeated);
  check_preserved ()
;;

let test_history_archive_identity_excludes_canonical_filename () =
  with_temp_dir @@ fun dir ->
  let module Store = Keeper_checkpoint_store in
  let session_id = "agent-core-snapshot-0000000000001" in
  let session_dir = Filename.concat dir session_id in
  let checkpoint =
    make_inventory_checkpoint ~session_id ~turn_count:1 ~created_at:2.0
  in
  (match Store.save_agent_core_classified ~session_dir ~history_retained:0 checkpoint with
   | Ok (Store.Saved _) -> ()
   | Ok (Store.Stale_noop _) -> fail "fresh canonical checkpoint was stale"
   | Error detail -> fail detail);
  let canonical = Store.agent_core_checkpoint_path ~session_dir ~session_id in
  check bool "canonical checkpoint exists" true (Sys.file_exists canonical);
  check (list string)
    "canonical name shaped like an archive is not listed"
    []
    (Store.list_agent_core_history_files ~session_dir);
  (match
     Store.delete_agent_core_history_files
       ~session_dir
       ~snapshot_ids:[ Filename.basename canonical ]
   with
   | [ Store.History_refused id ] ->
     check string "canonical filename is the refused input" (Filename.basename canonical) id
   | _ -> fail "archive-shaped canonical filename was not refused");
  check bool "refused canonical remains" true (Sys.file_exists canonical)
;;

let check_checkpoint_error_projection error ~status ~kind ~detail =
  let open Yojson.Safe.Util in
  let json = Checkpoints.checkpoint_load_error_json error in
  check string "checkpoint status" status (json |> member "status" |> to_string);
  check string "checkpoint error kind" kind (json |> member "error_kind" |> to_string);
  check (option string)
    "checkpoint error detail"
    detail
    (json |> member "error_detail" |> to_string_option)
;;

let test_checkpoint_load_error_projection_is_total () =
  let module Store = Keeper_checkpoint_store in
  check_checkpoint_error_projection
    Store.Not_found
    ~status:"missing"
    ~kind:"not_found"
    ~detail:None;
  check_checkpoint_error_projection
    (Store.Store_error "store unavailable")
    ~status:"unavailable"
    ~kind:"store_error"
    ~detail:(Some "store unavailable");
  check_checkpoint_error_projection
    (Store.Parse_error "invalid checkpoint")
    ~status:"unavailable"
    ~kind:"parse_error"
    ~detail:(Some "invalid checkpoint");
  check_checkpoint_error_projection
    (Store.Newer_version { expected = 2; got = 3 })
    ~status:"unavailable"
    ~kind:"parse_error"
    ~detail:(Some "version mismatch: expected 2, got 3");
  check_checkpoint_error_projection
    (Store.Io_error "permission denied")
    ~status:"unavailable"
    ~kind:"io_error"
    ~detail:(Some "permission denied");
  check_checkpoint_error_projection
    (Store.Agent_core_error "agent core failure")
    ~status:"unavailable"
    ~kind:"agent_core_error"
    ~detail:(Some "agent core failure")
;;

(* The caller that splices this projection into a larger row used to take the
   JSON back apart, with the non-object case as `assert false`. That branch was
   unreachable because this projection is an object for every constructor.
   Pinned through the public entry point so the helper behind it stays private:
   if the projection ever grows a non-object shape, this fails here instead of
   resurrecting an impossible case at a call site. *)
let test_checkpoint_load_error_projection_is_always_an_object () =
  let module Store = Keeper_checkpoint_store in
  List.iter
    (fun error ->
      check bool "the load-error projection is an object" true
        (match Checkpoints.checkpoint_load_error_json error with
         | `Assoc _ -> true
         | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null
           -> false))
    [ Store.Not_found;
      Store.Store_error "store unavailable";
      Store.Parse_error "invalid checkpoint";
      Store.Newer_version { expected = 2; got = 3 };
      Store.Io_error "permission denied";
      Store.Agent_core_error "agent core failure";
    ]
;;

let test_checkpoint_inventory_preserves_partial_load_failures () =
  with_temp_dir @@ fun dir ->
  let config = Workspace.default_config dir in
  let keeper_name = "checkpoint-inventory" in
  let trace_id = "trace-checkpoint-inventory" in
  Keeper_meta_store.replace_snapshot
    config
    (make_checkpoint_inventory_meta ~name:keeper_name ~trace_id)
  |> Result.map_error (fun detail -> fail ("checkpoint inventory meta write failed: " ^ detail))
  |> Result.get_ok;
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  let current = make_inventory_checkpoint ~session_id:trace_id ~turn_count:2 ~created_at:2.0 in
  (match Keeper_checkpoint_store.save_agent_core_classified
    ~history_retained:(history_retained ()) ~session_dir current with
   | Ok _ -> ()
   | Error detail -> fail ("checkpoint inventory current save failed: " ^ detail));
  let corrupt_history =
    make_inventory_checkpoint ~session_id:trace_id ~turn_count:1 ~created_at:1.0
  in
  let corrupt_snapshot_id =
    Keeper_checkpoint_store.agent_core_history_snapshot_id_of_checkpoint corrupt_history
  in
  let corrupt_path =
    Keeper_checkpoint_store.agent_core_history_path
      ~session_dir
      ~snapshot_id:corrupt_snapshot_id
  in
  Fs_compat.mkdir_p (Filename.dirname corrupt_path);
  Fs_compat.save_file corrupt_path "{not-a-checkpoint";
  let status, json = Checkpoints.inventory_json config keeper_name in
  check bool "partial checkpoint inventory remains HTTP 200" true (status = `OK);
  let open Yojson.Safe.Util in
  check string
    "current checkpoint remains available"
    "available"
    (json |> member "current_status" |> to_string);
  check bool "available current has no error" true
    (json |> member "current_error" = `Null);
  let history = json |> member "history" |> to_list in
  check int "corrupt history is not mixed with summaries" 0 (List.length history);
  let history_errors = json |> member "history_errors" |> to_list in
  check int "corrupt history remains visible" 1 (List.length history_errors);
  let failed = List.hd history_errors in
  check string
    "history failure is unavailable"
    "unavailable"
    (failed |> member "status" |> to_string);
  check string
    "history failure preserves typed parse kind"
    "parse_error"
    (failed |> member "error_kind" |> to_string);
  check bool
    "history failure preserves diagnostic detail"
    true
    (failed |> member "error_detail" |> to_string |> String.length > 0)
;;

let test_checkpoint_inventory_projects_missing_current () =
  with_temp_dir @@ fun dir ->
  let config = Workspace.default_config dir in
  let keeper_name = "checkpoint-missing" in
  let trace_id = "trace-checkpoint-missing" in
  Keeper_meta_store.replace_snapshot
    config
    (make_checkpoint_inventory_meta ~name:keeper_name ~trace_id)
  |> Result.map_error (fun detail -> fail ("checkpoint inventory meta write failed: " ^ detail))
  |> Result.get_ok;
  let status, json = Checkpoints.inventory_json config keeper_name in
  check bool "missing current inventory remains HTTP 200" true (status = `OK);
  let open Yojson.Safe.Util in
  check bool "missing current remains null" true (json |> member "current" = `Null);
  check string
    "missing current is explicit"
    "missing"
    (json |> member "current_status" |> to_string);
  check bool "normal missing current has no error" true
    (json |> member "current_error" = `Null)
;;

let with_input_wait_inventory ?(install_owner=true) ?(prior_unavailable=false) f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  with_temp_dir @@ fun dir ->
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let module Store = Keeper_checkpoint_store in
  let ok = function Ok value -> value | Error detail -> fail detail in
  let state = Mcp_server.For_testing.create_state ~base_path:dir in
  let config = Mcp_server.workspace_config state in
  let keeper_name = "input-observation" in
  let trace_id = "trace-input-observation" in
  let meta = make_checkpoint_inventory_meta ~name:keeper_name ~trace_id in
  let meta = {meta with Keeper_meta_contract.activation_mode=Keeper_activation_mode.Manual} in
  Keeper_meta_store.replace_snapshot config meta |> ok;
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:dir in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file (Filename.concat keepers_dir (keeper_name ^ ".toml"))
    "[keeper]\ninstructions = \"Input observation fixture\"\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
  if prior_unavailable then begin
    let module Journal = Keeper_chat_operation_store in
    let path=Journal.path_for_keeper ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config) ~keeper_name in
    Fs_compat.mkdir_p (Filename.dirname path);
    let journal=Journal.open_or_create ~path |> Result.map_error Journal.error_to_string |> ok in
    Journal.close journal |> Result.map_error Journal.error_to_string |> ok;
    let db=Sqlite3.db_open ~mode:`NO_CREATE path in
    Fun.protect ~finally:(fun () -> check bool "close prior input fixture" true (Sqlite3.db_close db)) (fun () ->
      check bool "establish actual unavailable prior history" true
        (Sqlite3.exec db "UPDATE input_history SET basis='prior_unavailable' WHERE singleton=1"=Sqlite3.Rc.OK))
  end;
  let owner_stop=ref None in
  let start_owner () =
    let installed,resolve_installed=Eio.Promise.create () in
    let stop,resolve_stop=Eio.Promise.create () in
    let ended,resolve_ended=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve resolve_ended ()) (fun () ->
        Eio.Switch.run (fun owner_sw ->
          let result=Keeper_owner_registry.install_from_store ~sw:owner_sw ~operation_runner:None
            ~on_turn_slot_released:None config in
          Eio.Promise.resolve resolve_installed result;
          Eio.Promise.await stop)));
    match Eio.Promise.await installed with
    | Ok _ -> owner_stop:=Some (resolve_stop,ended)
    | Error error -> fail (Keeper_owner_registry.install_error_to_string error) in
  let stop_owner () = match !owner_stop with
    | None -> ()
    | Some (resolve_stop,ended) ->
      owner_stop:=None; Eio.Promise.resolve resolve_stop (); Eio.Promise.await ended in
  let drain () =
    match Keeper_owner_registry.begin_stopping_all ~base_path:dir with
     | Ok results -> List.iter (fun result -> ignore (result |> Result.map_error Keeper_owner.error_to_string |> ok)) results
     | Error error -> fail (Keeper_owner_registry.lookup_error_to_string error) in
  let restart () = drain ();stop_owner ();start_owner () in
  if install_owner then start_owner ();
  let session_dir=Keeper_types_support.keeper_session_dir config trace_id in
  let canonical=Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  let current=ref None in
  let reference () = match Keeper_owner_registry.input_checkpoint ~base_path:dir ~keeper_name ~trace_id:meta.runtime.trace_id
      |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok with
    | Keeper_chat_operation_store.Input_observed reference -> reference
    | Input_unobserved | Prior_input_unavailable -> fail "fixture has no owned input" in
  let publish checkpoint =
    let result=Keeper_owner_registry.run_autonomous_if_idle ~base_path:dir ~keeper_name (fun () ->
      let producer=Keeper_input_checkpoint_producer.prepare ~base_path:dir ~keeper_name ~session_dir
        ~trace_id:meta.runtime.trace_id ~source:!current
        |> Result.map_error Keeper_input_checkpoint_producer.error_to_string |> ok in
      ignore (Keeper_input_checkpoint_producer.publish_autonomous producer checkpoint
        |> Result.map_error Keeper_input_checkpoint_producer.error_to_string |> ok)) in
    (match result with
     | Ok (`Ran ()) -> current:=Some checkpoint
     | Ok (`Busy _ | `Interrupted) -> fail "fixture input publisher did not run"
     | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
    reference () in
  let consume pending =
    let expected_source_ref=reference () in
    let source=Store.load_retained_exact_snapshot ~session_dir ~reference:expected_source_ref
      |> function Ok source -> source | Error _ -> fail "fixture retained source unavailable" in
    match Keeper_input_wait_response.prepare ~net:(Eio.Stdenv.net env) ~expected_source_ref ~source ~pending
        ~response:Agent_core.Hooks.Declined with
    | Ok response -> Keeper_input_wait_response.checkpoint response
    | Error _ -> fail "actual Agent input response was refused" in
  let read () =
    let status,body=get_checkpoint_inventory state ~keeper_name in
    check int "checkpoint GET succeeds" 200 status;
    Yojson.Safe.Util.member "input_wait_observation" body in
  let save checkpoint = match Store.save_agent_core_classified ~history_retained:2 ~session_dir checkpoint with
    | Ok (Store.Saved _) -> () | Ok (Store.Stale_noop _) -> fail "canonical fixture was stale"
    | Error detail -> fail detail in
  let change_trace trace_id =
    let runtime={meta.runtime with trace_id=Keeper_id.Trace_id.of_string trace_id |> ok} in
    Keeper_meta_store.replace_snapshot config {meta with runtime} |> ok in
  Fun.protect ~finally:stop_owner (fun () ->
    f ~trace_id ~session_dir ~canonical ~read ~save ~publish ~consume ~reference ~restart ~change_trace ~drain)
;;

let inventory_pending ~run_id ~request_id ~question =
  Agent_core.Agent_input_request.
    { run_id
    ; request =
        { request_id; participant_name=Some "operator"; question
        ; schema=Some (`Assoc ["type",`String "object"])
        ; timeout_s=None; created_at=10.0 }
    }
;;

let replace_inventory_checkpoint_bytes path bytes =
  match Fs_compat.save_file_atomic path bytes with
  | Ok () -> () | Error detail -> fail ("checkpoint fixture replacement failed: " ^ detail)
;;

let check_owned_inventory ~status ~pending ~reference observed =
  let open Yojson.Safe.Util in
  check string "host observation schema" "masc.keeper.input-wait.observation.v2" (observed |> member "schema" |> to_string);
  check string "authoritative input source" "retained_input_owner" (observed |> member "source" |> to_string);
  check string "owned input status" status (observed |> member "status" |> to_string);
  check bool "pending reflects owned bytes" true (observed |> member "pending_input"=pending);
  check bool "owned read has no error" true (observed |> member "error"=`Null);
  let actual=observed |> member "checkpoint_ref" in
  check string "owned trace" (Keeper_id.Trace_id.to_string reference.Keeper_checkpoint_ref.trace_id)
    (actual |> member "trace_id" |> to_string);
  check int "owned turn" reference.turn_count (actual |> member "turn_count" |> to_int);
  check string "exact retained hash" reference.sha256 (actual |> member "sha256" |> to_string)
;;

let check_unavailable_inventory kind observed =
  let open Yojson.Safe.Util in
  check string "unavailable source" "unavailable" (observed |> member "status" |> to_string);
  check bool "no invented input reference" true (observed |> member "checkpoint_ref"=`Null);
  check bool "no borrowed question" true (observed |> member "pending_input"=`Null);
  check string "exact unavailable category" kind (observed |> member "error" |> member "kind" |> to_string)
;;

type response_commit_fault = No_response_fault | Before_response_intent | After_response_intent
  | Before_response_resolution | After_response_resolution

let test_input_response_http_accepts_only_original_wait ~commit_fault () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  with_temp_dir @@ fun dir -> Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs env#fs;
  let ok = function Ok value -> value | Error detail -> fail detail in
  let module Journal=Keeper_chat_operation_store in
  let module Native=Keeper_native_call in
  let state=Mcp_server.create_state_eio ~sw
      ~proc_mgr:(Eio.Stdenv.process_mgr env) ~fs:(Eio.Stdenv.fs env)
      ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~net:(Eio.Stdenv.net env) ~base_path:dir in
  let config=Mcp_server.workspace_config state in
  let keeper_name="http-original-input-response" and trace_id="trace-http-original-response" in
  let meta=make_checkpoint_inventory_meta ~name:keeper_name ~trace_id in
  let meta={meta with Keeper_meta_contract.activation_mode=Keeper_activation_mode.Manual} in
  Keeper_meta_store.replace_snapshot config meta |> ok;
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path:dir in
  Fs_compat.mkdir_p keepers_dir;
  Fs_compat.save_file (Filename.concat keepers_dir (keeper_name ^ ".toml"))
    "[keeper]\ninstructions = \"Input response fixture\"\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n";
  let operation_id=Keeper_chat_operation.Operation_id.of_string "original-http-wait" |> ok in
  let pending=inventory_pending ~run_id:"lifecycle-http-original" ~request_id:"http-request-original" ~question:"Original HTTP question?" in
  let checkpoint={ (make_inventory_checkpoint ~session_id:trace_id ~turn_count:2 ~created_at:10.) with pending_input=Some pending } in
  let frame=Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
      (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation operation_id)) |> Result.get_ok in
  Keeper_repetition_context.save checkpoint.context frame;
  let session_dir=Keeper_types_support.keeper_session_dir config trace_id in
  Fs_compat.mkdir_p session_dir;
  let snapshot=Keeper_checkpoint_store.exact_snapshot_of_value ~expected_session_id:meta.runtime.trace_id checkpoint |> Result.get_ok in
  let reference=Keeper_checkpoint_store.retain_exact_snapshot ~session_dir snapshot
      |> Keeper_checkpoint_store.require_confirmed_installation |> Result.get_ok in
  (match Keeper_checkpoint_store.save_agent_core_classified ~session_dir ~history_retained:0 checkpoint with
   | Ok (Keeper_checkpoint_store.Saved _) -> () | Ok (Stale_noop _) | Error _ -> fail "HTTP response canonical fixture was not installed");
  let path=Journal.path_for_keeper ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config) ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  let journal=Journal.open_or_create ~path |> Result.map_error Journal.error_to_string |> ok in
  let journal_ok x=Result.map_error Journal.error_to_string x |> ok in
  let original_input=`Assoc ["message",`String "original HTTP admitted input"] in
  Journal.submit journal ~now:1. ~operation_id ~source:(`Assoc []) ~input:original_input |> journal_ok |> ignore;
  let operation=Journal.claim_next journal ~now:2. |> journal_ok |> Option.get in
  let call_id="019a0010-1000-7000-8000-000000000041" in
  let locator=Agent_core.Agent.execution_locator_of_yojson
      (`Assoc ["version",`Int 1;"run_id",`String "execution-run-http-original"]) |> ok in
  let call=Native.create ~call_id ~runtime_id:"native.primary" ~operation_digest:operation.execution_digest
      ~api:(Native.New_input {seed_message_count=List.length checkpoint.messages}) ~seed_checkpoint:reference ~locator |> ok in
  Journal.update_direct_native_call journal ~now:3. ~operation_id ~execution_digest:operation.execution_digest
    (Native.Bind {observed=Native.No_native_call;call}) |> journal_ok;
  Journal.update_direct_input_checkpoint journal ~now:4. ~operation_id ~execution_digest:operation.execution_digest
    ~call_id ~observed:reference ~observed_input:None ~checkpoint:reference |> journal_ok |> ignore;
  Journal.update_direct_native_call journal ~now:5. ~operation_id ~execution_digest:operation.execution_digest
    (Native.Terminal {call_id;disposition={Agent_core.Agent.outcome=Agent_core.Agent.Terminal_succeeded;recovery=Agent_core.Agent.Retire}}) |> journal_ok;
  let waiting=Keeper_semantic_execution.input_wait ~checkpoint:reference ~pending |> ok in
  Journal.defer_direct_input_wait journal ~now:6. ~operation_id ~execution_digest:operation.execution_digest ~waiting |> journal_ok |> ignore;
  let partial=match commit_fault with
    | No_response_fault | Before_response_intent | After_response_intent -> None
    | Before_response_resolution | After_response_resolution ->
      (* Real retained/canonical installation plus a real SQLite resolution fault.
         Startup below receives persisted crash facts, not a fake Owner receipt. *)
      let module Response=Keeper_input_wait_response in
      let context=Agent_core.Context.copy checkpoint.context in
      let messages=checkpoint.messages @ [Agent_core.Types.assistant_msg "validated later source history"] in
      (match Agent_core.Context.get_scoped context Session "message_count" with None -> ()
       | Some _ -> Agent_core.Context.set_scoped context Session "message_count" (`Int (List.length messages)));
      (* This is a canonical history extension with global input still W, not
         an independent Producer G lineage integration fixture. *)
      Fs_compat.save_file (Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id)
        (Agent_core.Checkpoint.to_string {checkpoint with context;messages});
      let authority=Response.authorize ~session_root:(Filename.dirname session_dir) ~operation_id ~waiting ~recorded:None in
      let plan=Response.prepare_installation ~net:env#net ~authority ~response:Agent_core.Hooks.Declined
        |> Result.map_error Response.installation_error_to_string |> ok in
      let intent=Response.planned_intent plan in
      Journal.prepare_direct_input_response journal ~now:7. ~operation_id ~execution_digest:operation.execution_digest ~intent |> journal_ok;
      let receipt=Response.install plan |> Result.map_error Response.installation_error_to_string |> ok in
      Fun.protect ~finally:Journal.For_testing.clear_commit_fault (fun () ->
        Journal.For_testing.fail_next_commit (match commit_fault with After_response_resolution -> Fail_after_commit
          | No_response_fault | Before_response_intent | After_response_intent | Before_response_resolution -> Fail_before_commit);
        match Journal.resolve_direct_input_wait journal ~now:8. ~operation_id ~execution_digest:operation.execution_digest
            ~observed:waiting ~checkpoint:(Response.installed_checkpoint receipt) with
        | Error (Journal.Store_unavailable _) -> () | Error _ | Ok () -> fail "real resolution fault reported acceptance");
      Some intent in
  Journal.close journal |> journal_ok;
  let owner_stop=ref None in
  let start_owner () =
    let installed,resolve_installed=Eio.Promise.create () in
    let stop,resolve_stop=Eio.Promise.create () in
    let ended,resolve_ended=Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect ~finally:(fun () -> Eio.Promise.resolve resolve_ended ()) (fun () ->
        Eio.Switch.run (fun owner_sw ->
          let result=Keeper_owner_registry.install_from_store ~sw:owner_sw ~operation_runner:None
            ~on_turn_slot_released:None config in
          Eio.Promise.resolve resolve_installed result;Eio.Promise.await stop)));
    match Eio.Promise.await installed with
    | Ok _ -> owner_stop:=Some (resolve_stop,ended)
    | Error error -> fail (Keeper_owner_registry.install_error_to_string error) in
  let stop_owner ()=match !owner_stop with
    | None -> () | Some (stop,ended) -> owner_stop:=None;Eio.Promise.resolve stop ();Eio.Promise.await ended in
  let restart ()=stop_owner ();start_owner () in
  start_owner ();
  Fun.protect ~finally:stop_owner (fun () ->
  let fields=["action",`String "respond_input";
    "operation_id",`String (Keeper_chat_operation.Operation_id.to_string operation_id);
    "checkpoint_ref",`Assoc ["trace_id",`String trace_id;"turn_count",`Int reference.turn_count;"sha256",`String reference.sha256];
    "pending_input",Agent_core.Agent_input_request.pending_to_json pending;"response",`Assoc ["kind",`String "declined"]] in
  let post_fields fields =
    let body=Yojson.Safe.to_string (`Assoc fields) in
    checkpoint_http_response ~meth:"POST" ~keeper_name ~body (fun reqd ->
      Server_dashboard_http_keeper_api_post.handle_keeper_checkpoints_post state (Httpun.Reqd.request reqd) reqd body) in
  let post ()=post_fields fields in
  let wrong_response ()=post_fields (("response",`Assoc ["kind",`String "timeout"])::List.remove_assoc "response" fields) in
  (match commit_fault with
   | No_response_fault ->
     let canonical_path=Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
     let canonical_bytes=Fs_compat.load_file canonical_path in
     let displaced=canonical_path ^ ".fixture-unavailable" in
     Unix.rename canonical_path displaced;
     Fun.protect ~finally:(fun () -> Unix.rename displaced canonical_path) (fun () ->
       let status,_=post () in
       check int "unavailable canonical is a server failure, not a stale response" 500 status;
       check bool "failed response cannot recreate an unavailable canonical" false (Sys.file_exists canonical_path);
       check bool "failed response preserves original input relation" true
         (Keeper_owner_registry.input_checkpoint ~base_path:dir ~keeper_name ~trace_id:meta.runtime.trace_id
           |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok
           |> fun observed -> observed=Journal.Input_observed reference);
       check bool "unavailable canonical preserves original wait" true
         (Option.equal Keeper_semantic_execution.equal_input_wait (Some waiting)
           (Keeper_owner_registry.direct_input_wait ~base_path:dir ~keeper_name ~operation_id
             |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok)));
     check string "failed response preserves canonical bytes" canonical_bytes (Fs_compat.load_file canonical_path)
   | Before_response_resolution ->
     let canonical_path=Keeper_checkpoint_store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
     let before=Fs_compat.load_file canonical_path in
     let status,_=wrong_response () in check int "consumed canonical cannot authorize another response kind" 409 status;
     check string "wrong recovery response preserves consumed canonical evidence" before (Fs_compat.load_file canonical_path)
   | Before_response_intent | After_response_intent | After_response_resolution -> ());
  let status,json=Fun.protect ~finally:Journal.For_testing.clear_commit_fault (fun () ->
    (* Intent confirmation is now the first journal commit of an actual response.
       Resolution faults were established explicitly with real SQLite above. *)
    (match commit_fault with
     | No_response_fault | Before_response_resolution | After_response_resolution -> ()
     | Before_response_intent -> Journal.For_testing.fail_next_commit Fail_before_commit
     | After_response_intent -> Journal.For_testing.fail_next_commit Fail_after_commit);
    post ()) in
  (match commit_fault with
   | Before_response_intent | After_response_intent ->
     check int "unconfirmed intent is a server failure before canonical mutation" 500 status;
     check bool "uncertain intent is not acceptance" false Yojson.Safe.Util.(json |> member "ok" |> to_bool);
     let canonical=Keeper_checkpoint_store.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id |> Result.get_ok in
     check bool "intent failure leaves canonical W unchanged" true
       (Keeper_checkpoint_ref.equal reference (Keeper_checkpoint_store.exact_snapshot_reference canonical));
     check bool "intent failure keeps original wait blocked" true
       (Option.equal Keeper_semantic_execution.equal_input_wait (Some waiting)
         (Keeper_owner_registry.direct_input_wait ~base_path:dir ~keeper_name ~operation_id
           |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok));
     stop_owner ();
     let journal=Journal.open_or_create ~path |> journal_ok in
     let intent=Journal.direct_input_response_intent journal ~operation_id |> journal_ok in
     check bool "actual intent commit survives actual Owner/store close" (commit_fault=After_response_intent) (Option.is_some intent);
     Option.iter (fun intent -> List.iter (fun reference ->
       ignore (Keeper_checkpoint_store.load_retained_exact_snapshot ~session_dir ~reference |> Result.get_ok))
       [intent.Keeper_semantic_execution.source;intent.candidate]) intent;
     Journal.close journal |> journal_ok;start_owner ();
     (match intent with None -> () | Some _ ->
       let status,_=wrong_response () in check int "fresh Owner refuses another recorded response kind" 409 status);
     let status,_=post () in check int "fresh Owner accepts only exact original response after actual read" 200 status
   | Before_response_resolution ->
     check int "fresh Owner reconciles retained intent against already consumed canonical" 200 status;
     let intent=Option.get partial in
     let installed=Keeper_checkpoint_store.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id |> Result.get_ok in
     check bool "fresh confirmed rewrite keeps exact recorded C" true
       (Keeper_checkpoint_ref.equal intent.candidate (Keeper_checkpoint_store.exact_snapshot_reference installed));
     restart ();
     check bool "resolved original stays consumed across actual Owner reopen" true
       (Keeper_owner_registry.direct_input_wait ~base_path:dir ~keeper_name ~operation_id
        |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok=None);
     let status,_=post () in check int "recovered response cannot be admitted twice" 409 status
   | After_response_resolution ->
     check int "actual committed resolution is observed as duplicate, not reaccepted" 409 status;
     check bool "actual postcommit continuation is preserved" true
       (Option.is_some (Keeper_owner_registry.direct_checkpoint ~base_path:dir ~keeper_name ~operation_id
         |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok));
     let intent=Option.get partial in
     check bool "actual consumed input relation survives original uncertain acknowledgement" true
       (Keeper_owner_registry.input_checkpoint ~base_path:dir ~keeper_name ~trace_id:meta.runtime.trace_id
         |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok=Journal.Input_observed intent.candidate)
   | No_response_fault ->
     check int "actual HTTP Registry Owner response accepts original wait" 200 status;
     let result=Keeper_owner_registry.direct_input_wait ~base_path:dir ~keeper_name ~operation_id
       |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok in
     check bool "HTTP acceptance consumes original durable wait" true (result=None);
     let next=Keeper_owner_registry.direct_checkpoint ~base_path:dir ~keeper_name ~operation_id
       |> Result.map_error Keeper_owner_registry.command_error_to_string |> ok in
     check bool "HTTP acceptance enables only original checkpoint continuation" true (Option.is_some next);
     let status,json=get_checkpoint_inventory state ~keeper_name in check int "current input remains observable" 200 status;
     check string "host snapshot agrees input consumed" "owned_none"
       Yojson.Safe.Util.(json |> member "input_wait_observation" |> member "status" |> to_string);
     let status,_=post () in check int "same HTTP response is not admitted twice" 409 status))

;;

let test_input_response_http_requires_explicit_exact_proof () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  with_temp_dir @@ fun dir -> Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs env#fs;
  let state=Mcp_server.create_state_eio ~sw
      ~proc_mgr:(Eio.Stdenv.process_mgr env) ~fs:(Eio.Stdenv.fs env)
      ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~net:(Eio.Stdenv.net env) ~base_path:dir in
  let checkpoint=Keeper_checkpoint_ref.create
      ~trace_id:(Keeper_id.Trace_id.of_string "original-http-response-trace" |> Result.get_ok)
      ~turn_count:2 ~canonical_checkpoint_bytes:"original input bytes" |> Result.get_ok in
  let pending=inventory_pending ~run_id:"original-run" ~request_id:"original-request" ~question:"Original question?" in
  let fields=["action",`String "respond_input";"operation_id",`String "original-http-response";
    "checkpoint_ref",`Assoc ["trace_id",`String (Keeper_id.Trace_id.to_string checkpoint.trace_id);
      "turn_count",`Int checkpoint.turn_count;"sha256",`String checkpoint.sha256];
    "pending_input",Agent_core.Agent_input_request.pending_to_json pending;
    "response",`Assoc ["kind",`String "declined"]] in
  let post fields =
    let body=Yojson.Safe.to_string (`Assoc fields) in
    checkpoint_http_response ~meth:"POST" ~keeper_name:"missing-response-owner" ~body (fun reqd ->
      Server_dashboard_http_keeper_api_post.handle_keeper_checkpoints_post
        state (Httpun.Reqd.request reqd) reqd body) in
  let status,_=post fields in
  check int "unavailable Owner inventory is a service failure" 503 status;
  Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None
      (Mcp_server.workspace_config state)
    |> Result.map_error Keeper_owner_registry.install_error_to_string |> Result.get_ok |> ignore;
  let status,_=post fields in
  check int "valid response cannot create a missing Owner in an available inventory" 409 status;
  List.iter (fun invalid -> let status,_=post invalid in
    check int "malformed response is rejected before Owner lookup" 400 status)
    [("operation_id",`String "duplicate")::fields;
     ("unknown",`Bool true)::fields;
     ("response",`Assoc ["kind",`String "timeout";"value",`String "not an answer"])::List.remove_assoc "response" fields;
     List.remove_assoc "pending_input" fields]
;;

let test_input_wait_inventory_tracks_exact_replacements () =
  with_input_wait_inventory @@ fun ~trace_id ~session_dir:_ ~canonical:_ ~read ~save ~publish ~consume
      ~reference:_ ~restart ~change_trace:_ ~drain:_ ->
  let initial=make_inventory_checkpoint ~session_id:trace_id ~turn_count:4 ~created_at:10.0 in
  let a=inventory_pending ~run_id:"run-a" ~request_id:"request-a" ~question:"First question?" in
  let waiting_a={initial with pending_input=Some a} in
  save waiting_a;
  let unobserved=read () in
  check string "canonical pending is not an owned observation" "unobserved"
    Yojson.Safe.Util.(unobserved |> member "status" |> to_string);
  check bool "fresh Owner does not borrow canonical question" true
    Yojson.Safe.Util.(unobserved |> member "pending_input"=`Null);
  let ref_a=publish waiting_a in
  check_owned_inventory ~status:"owned_pending" ~pending:(Agent_core.Agent_input_request.pending_to_json a)
    ~reference:ref_a (read ());
  let b=inventory_pending ~run_id:"run-b" ~request_id:"request-b" ~question:"Replacement question?" in
  let ref_b=publish {initial with pending_input=Some b;created_at=11.0} in
  check bool "same-turn input replacement has new exact reference" false (Keeper_checkpoint_ref.equal ref_a ref_b);
  check_owned_inventory ~status:"owned_pending" ~pending:(Agent_core.Agent_input_request.pending_to_json b)
    ~reference:ref_b (read ());
  let consumed=consume b in
  check bool "actual Core response consumed the pending input" true (Option.is_none consumed.pending_input);
  let ref_none=publish consumed in
  check bool "consumption changes the owned reference at the same turn" false (Keeper_checkpoint_ref.equal ref_b ref_none);
  check_owned_inventory ~status:"owned_none" ~pending:`Null ~reference:ref_none (read ());
  restart ();
  check_owned_inventory ~status:"owned_none" ~pending:`Null ~reference:ref_none (read ())
;;

let test_input_wait_inventory_ignores_canonical_drift () =
  with_input_wait_inventory @@ fun ~trace_id ~session_dir:_ ~canonical ~read ~save ~publish ~consume
      ~reference:_ ~restart ~change_trace:_ ~drain:_ ->
  let pending=inventory_pending ~run_id:"run-retained" ~request_id:"request-retained" ~question:"Owned question?" in
  let waiting={ (make_inventory_checkpoint ~session_id:trace_id ~turn_count:2 ~created_at:10.0) with pending_input=Some pending } in
  save waiting;
  let owned=publish waiting in
  let inspect reference status pending=check_owned_inventory ~status ~pending ~reference (read ()) in
  let question=Agent_core.Agent_input_request.pending_to_json pending in
  replace_inventory_checkpoint_bytes canonical "{corrupt canonical";
  inspect owned "owned_pending" question;
  Sys.remove canonical;
  inspect owned "owned_pending" question;
  let consumed=publish (consume pending) in
  save waiting;
  inspect consumed "owned_none" `Null;
  replace_inventory_checkpoint_bytes canonical "{still corrupt";
  inspect consumed "owned_none" `Null;
  Sys.remove canonical;
  restart ();
  inspect consumed "owned_none" `Null
;;

let test_input_wait_inventory_refuses_unavailable_retained () =
  with_input_wait_inventory @@ fun ~trace_id ~session_dir ~canonical:_ ~read ~save ~publish ~consume:_
      ~reference:_ ~restart:_ ~change_trace:_ ~drain:_ ->
  let module Store=Keeper_checkpoint_store in
  let pending=inventory_pending ~run_id:"run-old" ~request_id:"request-old" ~question:"Retained question?" in
  let waiting={ (make_inventory_checkpoint ~session_id:trace_id ~turn_count:2 ~created_at:10.0) with pending_input=Some pending } in
  save waiting;
  let reference=publish waiting in
  (* Valid canonical and a historical pending request remain readable while
     the owned retained artifact is unavailable. Neither can replace it. *)
  save {waiting with created_at=11.0};
  check bool "readable canonical history cannot replace missing owned bytes" true
    (Store.list_agent_core_history_files ~session_dir |> List.exists (fun snapshot_id ->
      match Store.load_agent_core_history_file ~session_dir ~snapshot_id with
      | Ok old -> old.pending_input=Some pending | Error _ -> false));
  let retained=Filename.concat (Filename.concat session_dir Store.retained_dirname) (reference.sha256 ^ ".json") in
  let bytes=Fs_compat.load_file retained in
  Sys.remove retained;
  check_unavailable_inventory "retained_unavailable" (read ());
  replace_inventory_checkpoint_bytes retained "{invalid retained bytes";
  check_unavailable_inventory "retained_unavailable" (read ());
  replace_inventory_checkpoint_bytes retained ("\n" ^ bytes);
  check_unavailable_inventory "retained_unavailable" (read ());
  replace_inventory_checkpoint_bytes retained bytes;
  check_owned_inventory ~status:"owned_pending" ~pending:(Agent_core.Agent_input_request.pending_to_json pending)
    ~reference (read ())
;;

let test_input_wait_inventory_observes_draining_owner () =
  with_input_wait_inventory @@ fun ~trace_id ~session_dir:_ ~canonical:_ ~read ~save:_ ~publish ~consume:_
      ~reference:_ ~restart:_ ~change_trace:_ ~drain ->
  let pending=inventory_pending ~run_id:"run-draining" ~request_id:"request-draining" ~question:"Still observed?" in
  let reference=publish { (make_inventory_checkpoint ~session_id:trace_id ~turn_count:1 ~created_at:10.0) with pending_input=Some pending } in
  drain ();
  check_owned_inventory ~status:"owned_pending" ~pending:(Agent_core.Agent_input_request.pending_to_json pending)
    ~reference (read ())
;;

let test_input_wait_inventory_refuses_missing_owner () =
  with_input_wait_inventory ~install_owner:false @@ fun ~trace_id ~session_dir:_ ~canonical:_ ~read ~save
      ~publish:_ ~consume:_ ~reference:_ ~restart:_ ~change_trace:_ ~drain:_ ->
  let pending=inventory_pending ~run_id:"run-unowned" ~request_id:"request-unowned" ~question:"Unowned question?" in
  save { (make_inventory_checkpoint ~session_id:trace_id ~turn_count:1 ~created_at:10.0) with pending_input=Some pending };
  check_unavailable_inventory "owner_unavailable" (read ())
;;

let test_input_wait_inventory_refuses_prior_unavailable () =
  with_input_wait_inventory ~prior_unavailable:true @@ fun ~trace_id ~session_dir:_ ~canonical:_ ~read ~save
      ~publish:_ ~consume:_ ~reference:_ ~restart:_ ~change_trace:_ ~drain:_ ->
  let pending=inventory_pending ~run_id:"run-prior" ~request_id:"request-prior" ~question:"Prior unknown question?" in
  save { (make_inventory_checkpoint ~session_id:trace_id ~turn_count:1 ~created_at:10.0) with pending_input=Some pending };
  check_unavailable_inventory "prior_input_unavailable" (read ())
;;

let test_input_wait_inventory_refuses_trace_drift () =
  with_input_wait_inventory @@ fun ~trace_id ~session_dir:_ ~canonical:_ ~read ~save:_ ~publish ~consume:_
      ~reference:_ ~restart:_ ~change_trace ~drain:_ ->
  let pending=inventory_pending ~run_id:"run-original" ~request_id:"request-original" ~question:"Original trace?" in
  ignore (publish { (make_inventory_checkpoint ~session_id:trace_id ~turn_count:1 ~created_at:10.0) with pending_input=Some pending });
  change_trace "trace-observation-external-change";
  check_unavailable_inventory "trace_changed" (read ())
;;

(* Clock groups fold the edge stream into a table of per-group accumulators.
   The records are immutable, so each edge rebinds its entry; two edges in the
   same turn must still land in one group with the count advanced and the
   observed-at window spanning both. *)
(* RFC librarian-lifecycle §10-2 through the dashboard action. The preview
   says why an apply would be refused; the apply refuses while an atom is
   unread and writes nothing; an apply at the end installs the checkpoint,
   keeps every message and the position where it was (the purge keeps the
   history's end), and leaves [boundary_lines_seen] alone. The server-owned
   Librarian lane is closed to new units and cancelled for the apply; here it
   has no unit, so cancellation returns at once. *)
let test_purge_keeps_the_librarian_position_and_every_message () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  with_temp_dir @@ fun dir ->
  Eio_main.run @@ fun _env ->
  let module Store = Keeper_checkpoint_store in
  let module Progress = Keeper_librarian_progress in
  let module Purge = Keeper_checkpoint_purge in
  let state = Mcp_server.For_testing.create_state ~base_path:dir in
  let config = Mcp_server.workspace_config state in
  let keeper_name = "checkpoint-purge" in
  let trace_id = Keeper_identity.generate_trace_id ~now:1.0 () in
  Keeper_meta_store.replace_snapshot config
    (make_checkpoint_inventory_meta ~name:keeper_name ~trace_id)
  |> Result.map_error (fun detail -> fail detail) |> Result.get_ok;
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  (* Ahead of the protected tail: repeated wakes, a reply with unsigned
     reasoning and a closed tool cycle. The fixed policy strips the reasoning
     and clears the result, and keeps every message. *)
  let wake = Agent_core.Types.user_msg "(autonomous wake)" in
  let assistant content =
    { Agent_core.Types.role = Agent_core.Types.Assistant
    ; content
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let messages =
    [ wake
    ; assistant
        [ Agent_core.Types.Thinking { content = "unsigned"; signature = None }
        ; Agent_core.Types.Text "reply-a"
        ]
    ; wake
    ; assistant
        [ Agent_core.Types.ToolUse { id = "tool-a"; name = "test_tool"; input = `Assoc [] } ]
    ; Agent_core.Types.tool_result_msg ~tool_use_id:"tool-a" ~content:"raw output" ()
    ; wake
    ; wake
    ]
    @ List.init Purge.default_config.keep_recent_messages (fun i ->
        Agent_core.Types.user_msg (Printf.sprintf "recent %d" i))
  in
  let checkpoint =
    { (make_inventory_checkpoint ~session_id:trace_id ~turn_count:3 ~created_at:3.0) with
      Agent_core.Checkpoint.messages }
  in
  (match Store.save_agent_core_classified ~session_dir ~history_retained:2 checkpoint with
   | Ok (Store.Saved _) -> ()
   | Ok (Store.Stale_noop _) -> fail "fixture checkpoint was stale"
   | Error detail -> fail detail);
  let keepers_dir = Workspace.keepers_runtime_dir config in
  let atoms messages = snd (Runtime_model_input_tail_window.annotate messages) in
  let boundary_lines_seen = 7 in
  let write_position ~end_atom =
    let last_atom_digest =
      match Runtime_model_input_tail_window.atom_opening_digest messages (end_atom - 1) with
      | Some digest -> digest
      | None -> failf "fixture history has no atom %d" (end_atom - 1)
    in
    match
      Progress.write ~keepers_dir ~keeper_id:keeper_name
        { position = { trace_id; end_atom; last_atom_digest }; boundary_lines_seen }
    with
    | Ok () -> ()
    | Error error -> fail (Progress.write_error_to_string error)
  in
  let canonical = Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  let count = atoms messages in
  write_position ~end_atom:(count - 1);
  let original = Fs_compat.load_file canonical in
  (match Checkpoints.purge_current config ~keeper_name ~apply:false with
   | Ok preview ->
     check bool "preview: apply is not allowed" false preview.apply_allowed;
     check int "preview: the refusal is the one warning" 1 (List.length preview.warnings)
   | Error error -> fail (Checkpoints.purge_error_to_string error));
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Error
       (Checkpoints.Purge_librarian_rebase_refused
          (Purge.Unread_atoms_present { end_atom; atom_count })) ->
     check int "refused at the position" (count - 1) end_atom;
     check int "against the history's atoms" count atom_count
   | Error error -> fail (Checkpoints.purge_error_to_string error)
   | Ok _ -> fail "an apply over an unread atom was allowed");
  check string "a refused apply leaves the checkpoint" original (Fs_compat.load_file canonical);
  write_position ~end_atom:count;
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Ok result ->
     check bool "applied" true result.applied;
     check bool "the reasoning was stripped" true
       (result.report.reasoning_blocks_stripped > 0);
     check bool "the result was cleared" true (result.report.tool_results_cleared > 0);
     (* Sound tool cycles drop nothing at a structural break, and the gap
        between the counts is exactly that field. A transcript that does break
        is the case below. *)
     check int "no message is dropped at a structural break" 0
       result.report.messages_dropped_at_structural_break;
     check int "the message gap is the dropped count"
       (result.report.messages_before - result.report.messages_after)
       result.report.messages_dropped_at_structural_break
   | Error error -> fail (Checkpoints.purge_error_to_string error));
  (match Checkpoints.purge_current config ~keeper_name ~apply:true with
   | Ok again -> check bool "a second apply changes nothing" false again.applied
   | Error error -> fail (Checkpoints.purge_error_to_string error));
  let purged =
    match Store.load_agent_core ~session_dir ~session_id:trace_id with
    | Ok purged -> purged
    | Error _ -> fail "the installed checkpoint is not readable"
  in
  check int "every message is kept" (List.length messages)
    (List.length purged.messages);
  check int "and every atom" count (atoms purged.messages);
  match Progress.read ~keepers_dir ~keeper_id:keeper_name with
  | Ok (Some progress) ->
    check int "the position stays at the end" count progress.position.end_atom;
    check (option string) "with the digest it had"
      (Runtime_model_input_tail_window.atom_opening_digest messages (count - 1))
      (Some progress.position.last_atom_digest);
    check int "boundary_lines_seen is untouched" boundary_lines_seen
      progress.boundary_lines_seen
  | Ok None -> fail "the position is gone"
  | Error error -> fail (Progress.read_error_to_string error)
;;

let test_clock_groups_accumulate_edges_per_turn () =
  with_temp_dir @@ fun dir ->
  let config = Workspace.default_config dir in
  let keeper_name = "clock-group-keeper" in
  let trace_id = "trace-clock-groups" in
  let row event =
    Keeper_runtime_manifest.make
      ~keeper_name
      ~trace_id
      ~keeper_turn_id:7
      ~event
      ~status:"observed"
      ()
    |> Keeper_runtime_manifest.to_json
  in
  let path = Keeper_runtime_manifest.path_for_trace config ~keeper_name ~trace_id in
  Fs_compat.mkdir_p (Filename.dirname path);
  let channel = open_out path in
  List.iter
    (fun json -> Printf.fprintf channel "%s\n" (Yojson.Safe.to_string json))
    [ row Keeper_runtime_manifest.Turn_started
    ; row Keeper_runtime_manifest.Turn_finished
    ];
  close_out channel;
  let scan =
    Runtime_lens_scan.read_runtime_manifest_scan
      ~config
      ~keeper_name
      ~trace_id
      ~limit:8
      ()
  in
  check int "both rows decoded" 2 scan.total_rows;
  let open Yojson.Safe.Util in
  let groups =
    match
      Server_dashboard_http_keeper_runtime_lens_clock_groups
      .runtime_lens_clock_groups_json
        scan
    with
    | `List groups -> groups
    | _ -> fail "clock groups projection must be a list"
  in
  let turn_groups =
    List.filter (fun g -> g |> member "group_type" |> to_string = "turn") groups
  in
  check int "one turn group" 1 (List.length turn_groups);
  match turn_groups with
  | [ group ] ->
    check int "both edges folded into it" 2 (group |> member "edge_count" |> to_int);
    check bool
      "the terminal event closes the group"
      true
      (group |> member "closed" |> to_bool);
    check bool
      "distinct events are kept"
      true
      (List.length (group |> member "events" |> to_list) >= 2)
  | _ -> fail "expected exactly one turn group"
;;

(* A transcript whose tool cycles overlap is what the purge is reached for. The
   preview has to say what recovering it costs, and through the real
   [purge_current] the HTTP report's count has to be the core's, not a default
   (#32462). The cost is exactly the gap between the message counts. *)
let test_purge_preview_reports_what_a_structural_break_drops () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  with_temp_dir @@ fun dir ->
  Eio_main.run @@ fun _env ->
  let module Store = Keeper_checkpoint_store in
  let state = Mcp_server.For_testing.create_state ~base_path:dir in
  let config = Mcp_server.workspace_config state in
  let keeper_name = "checkpoint-purge-broken" in
  let trace_id = Keeper_identity.generate_trace_id ~now:1.0 () in
  Keeper_meta_store.replace_snapshot config
    (make_checkpoint_inventory_meta ~name:keeper_name ~trace_id)
  |> Result.map_error (fun detail -> fail detail) |> Result.get_ok;
  let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
  let assistant content =
    { Agent_core.Types.role = Agent_core.Types.Assistant
    ; content
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let tool_use id =
    Agent_core.Types.ToolUse { id; name = "test_tool"; input = `Assoc [] }
  in
  (* Two tool cycles open before either is answered. *)
  let messages =
    [ Agent_core.Types.user_msg "(autonomous wake)"
    ; assistant [ tool_use "c1" ]
    ; assistant [ tool_use "c2" ]
    ; Agent_core.Types.tool_result_msg ~tool_use_id:"c1" ~content:"one" ()
    ; Agent_core.Types.tool_result_msg ~tool_use_id:"c2" ~content:"two" ()
    ]
    @ List.init Keeper_checkpoint_purge.default_config.keep_recent_messages (fun i ->
        Agent_core.Types.user_msg (Printf.sprintf "recent %d" i))
  in
  let checkpoint =
    { (make_inventory_checkpoint ~session_id:trace_id ~turn_count:3 ~created_at:3.0) with
      Agent_core.Checkpoint.messages }
  in
  (* Simulate an already-corrupt checkpoint on disk. The normal save boundary
     rejects overlapping tool cycles before the recovery preview can read them. *)
  let canonical = Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id in
  Fs_compat.mkdir_p (Filename.dirname canonical);
  Fs_compat.save_file canonical (Agent_core.Checkpoint.to_string checkpoint);
  match Checkpoints.purge_current config ~keeper_name ~apply:false with
  | Error error -> fail (Checkpoints.purge_error_to_string error)
  | Ok preview ->
    check bool "the broken cycles cost messages" true
      (preview.report.messages_dropped_at_structural_break > 0);
    check int "the gap between the counts is that cost"
      (preview.report.messages_before - preview.report.messages_after)
      preview.report.messages_dropped_at_structural_break

(* The purge drops everything from the first broken tool cycle on. Without this
   count in the response, [messages_before] - [messages_after] has a gap no
   other field explains (#32462). *)
let test_purge_report_json_carries_the_dropped_count () =
  let result : Checkpoints.purge_result =
    { keeper = "alder"
    ; trace_id = "trace-alder"
    ; apply_allowed = false
    ; applied = false
    ; backup_path = None
    ; report =
        { messages_before = 500
        ; messages_after = 2
        ; bytes_before = 4096
        ; bytes_after = 512
        ; reasoning_blocks_stripped = 0
        ; tool_results_cleared = 0
        ; messages_dropped_at_structural_break = 498
        }
    ; warnings = []
    }
  in
  let json = Checkpoints.purge_result_json ~action:"preview_purge" result in
  check int "the dropped count rides the report" 498
    Yojson.Safe.Util.(
      json |> member "report" |> member "messages_dropped_at_structural_break" |> to_int)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run
    "Server_dashboard_http_keeper_api_trace"
    [ ( "dedupe_thinking_lines"
      , [ test_case "preserves first order" `Quick test_dedupe_preserves_first_order
        ; test_case
            "distinguishes turn identity"
            `Quick
            test_dedupe_distinguishes_turn_identity
        ] )
    ; ( "chat_trace_block_by_turn_ref"
       , [ test_case
             "reads allowed trace ids"
             `Quick
             test_chat_trace_block_by_turn_ref_reads_allowed_trace_ids
         ; test_case "retained payload and per-render snapshot" `Quick
             test_chat_trace_window_preserves_payload_and_snapshot
         ] )
    ; ( "runtime_lens_swimlane"
      , [ test_case
            "tool_runtime zero-event lane is not observed"
            `Quick
            test_tool_runtime_zero_event_lane_is_not_observed
        ; test_case
            "manifest event vocabulary is pinned"
            `Quick
            test_manifest_event_vocabulary_is_pinned
        ; test_case
            "the runtime lane asserts dispatch closure"
            `Quick
            test_runtime_lane_asserts_dispatch_closure
        ; test_case
            "no lane policy names the retired provider lane"
            `Quick
            test_no_lane_policy_names_a_retired_provider_lane
        ] )
    ; ( "history_projection_context_diagnostics"
      , [ test_case "projection preserves injected context" `Quick
            test_history_projection_preserves_context_diagnostics ] )
    ; ( "runtime_manifest_scan"
      , [ test_case
            "surfaces unsupported rows without repeated warnings"
            `Quick
            test_runtime_manifest_scan_surfaces_diagnostics_without_repeat_warnings
        ; test_case
            "folding a row leaves the argument scan untouched"
            `Quick
            test_runtime_manifest_scan_fold_leaves_input_untouched
        ; test_case
            "clock groups accumulate edges per turn"
            `Quick
            test_clock_groups_accumulate_edges_per_turn
        ] )
    ; ( "checkpoint_inventory"
      , [ test_case
            "history deletion preserves canonical and conversation files"
            `Quick
            test_history_delete_preserves_session_files
        ; test_case
            "archive-shaped canonical is never history"
            `Quick
            test_history_archive_identity_excludes_canonical_filename
        ; test_case
            "projects every typed checkpoint load error"
            `Quick
            test_checkpoint_load_error_projection_is_total
        ; test_case
            "the load-error projection is always an object"
            `Quick
            test_checkpoint_load_error_projection_is_always_an_object
        ; test_case
            "preserves partial history failures with HTTP 200"
            `Quick
            test_checkpoint_inventory_preserves_partial_load_failures
        ; test_case
            "projects missing current without failing inventory"
            `Quick
            test_checkpoint_inventory_projects_missing_current
        ; test_case
            "input wait follows exact same-turn replacement and settlement"
            `Quick
            test_input_wait_inventory_tracks_exact_replacements
        ; test_case "HTTP accepts only original durable wait and snapshot observes consumption" `Quick (test_input_response_http_accepts_only_original_wait ~commit_fault:No_response_fault)
        ; test_case "HTTP intent precommit failure preserves canonical and recovers under fresh Owner" `Quick
            (test_input_response_http_accepts_only_original_wait ~commit_fault:Before_response_intent)
        ; test_case "HTTP uncertain intent persists and resumes only its exact response after restart" `Quick
            (test_input_response_http_accepts_only_original_wait ~commit_fault:After_response_intent)
        ; test_case "fresh Owner reconciles actually consumed canonical after failed SQLite resolution" `Quick
            (test_input_response_http_accepts_only_original_wait ~commit_fault:Before_response_resolution)
        ; test_case "fresh Owner observes actually committed uncertain SQLite resolution" `Quick
            (test_input_response_http_accepts_only_original_wait ~commit_fault:After_response_resolution)
        ; test_case "input response requires exact explicit proof and an existing Owner" `Quick test_input_response_http_requires_explicit_exact_proof
        ; test_case "owned input ignores missing corrupt or stale canonical" `Quick test_input_wait_inventory_ignores_canonical_drift
        ; test_case "input wait never borrows unavailable retained or historical state" `Quick test_input_wait_inventory_refuses_unavailable_retained
        ; test_case "input wait remains observable during Owner drain" `Quick test_input_wait_inventory_observes_draining_owner
        ; test_case "input wait refuses unavailable Owner" `Quick test_input_wait_inventory_refuses_missing_owner
        ; test_case "input wait refuses unavailable prior input history" `Quick test_input_wait_inventory_refuses_prior_unavailable
        ; test_case "input wait refuses changed Owner trace" `Quick test_input_wait_inventory_refuses_trace_drift
        ] )
    ; ( "checkpoint_purge"
      , [ test_case
            "purge keeps the Librarian position and every message"
            `Quick
            test_purge_keeps_the_librarian_position_and_every_message
        ; test_case
            "the report carries the count dropped at a structural break"
            `Quick
            test_purge_report_json_carries_the_dropped_count
        ; test_case
            "a preview reports what a structural break drops"
            `Quick
            test_purge_preview_reports_what_a_structural_break_drops
        ] )
    ]
;;
