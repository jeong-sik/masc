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

let test_chat_trace_block_by_turn_ref_reads_allowed_trace_history () =
  with_temp_dir (fun dir ->
    let config = Workspace.default_config dir in
    let masc_root = Workspace.masc_root_dir config in
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
     | None -> fail "old trace_id from trace_history should enrich");
    let disallowed_ref =
      Ids.Turn_ref.make ~trace_id:"trace-unlisted" ~absolute_turn:42
    in
    check
      bool
      "unlisted trace_id is not used as a filesystem read key"
      true
      (Option.is_none (trace_block_by_turn_ref disallowed_ref)))
;;

let string_member key = function
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`String value) -> value
    | Some _ -> fail (Printf.sprintf "%s is not a string" key)
    | None -> fail (Printf.sprintf "%s missing" key))
  | _ -> fail "expected object"
;;

let runtime_manifest_json_with_field row_json field replacement =
  match row_json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
            if String.equal key field then key, replacement else key, value)
         fields)
  | _ -> fail "runtime manifest row must encode as an object"
;;

let runtime_manifest_json_with_event row_json event =
  runtime_manifest_json_with_field row_json "event" (`String event)
;;

let runtime_manifest_json_without_field row_json field =
  match row_json with
  | `Assoc fields -> `Assoc (List.remove_assoc field fields)
  | _ -> fail "runtime manifest row must encode as an object"
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
    ; runtime_manifest_json_with_field
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
    ; mcp_sessions = []
    ; working_context = None
    }
;;

(* Exercise the actual POST handler and its HTTP/JSON projection without a
   listening server. The transport fixture follows the tool-lookup tests. *)
let post_checkpoint_history state ~keeper_name snapshot_ids =
  let body = Yojson.Safe.to_string
      (`Assoc [ "action", `String "delete_history"
              ; "snapshot_ids", `List (List.map (fun id -> `String id) snapshot_ids) ]) in
  let output = Buffer.create 1024 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Server_dashboard_http_keeper_api_post.handle_keeper_checkpoints_post
      state (Httpun.Reqd.request reqd) reqd body) in
  let wire = Printf.sprintf
      "POST /api/v1/keepers/%s/checkpoints HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n%s"
      keeper_name (String.length body) body in
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

(* Clock groups fold the edge stream into a table of per-group accumulators.
   The records are immutable, so each edge rebinds its entry; two edges in the
   same turn must still land in one group with the count advanced and the
   observed-at window spanning both. *)
(* RFC librarian-lifecycle §10-2 through the dashboard action. The preview
   says why an apply would be refused; the apply refuses while an atom is
   unread and writes nothing; an apply at the end installs the checkpoint and
   moves the position after it, leaving [boundary_lines_seen] alone. The
   keeper's Librarian loop is retired around the writes; here it has none,
   so the retire returns at once and the wake after it finds no server
   switch and starts nothing. *)
let test_purge_moves_the_librarian_position_with_the_checkpoint () =
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
  (* Four identical wakes ahead of the protected tail: the fixed policy drops
     the two middle ones and keeps the twenty most recent messages. *)
  let wake = Agent_core.Types.user_msg "(autonomous wake)" in
  let messages =
    [ wake; Agent_core.Types.user_msg "reply-a"; wake; Agent_core.Types.user_msg "reply-b"
    ; wake; wake ]
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
   | Ok result -> check bool "applied" true result.applied
   | Error error -> fail (Checkpoints.purge_error_to_string error));
  let purged =
    match Store.load_agent_core ~session_dir ~session_id:trace_id with
    | Ok purged -> purged
    | Error _ -> fail "the installed checkpoint is not readable"
  in
  check int "the two middle wakes are gone" (List.length messages - 2)
    (List.length purged.messages);
  match Progress.read ~keepers_dir ~keeper_id:keeper_name with
  | Ok (Some progress) ->
    check int "the position moved to the rewritten end" (atoms purged.messages)
      progress.position.end_atom;
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
             "reads allowed trace_history trace ids"
             `Quick
             test_chat_trace_block_by_turn_ref_reads_allowed_trace_history
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
        ] )
    ; ( "checkpoint_purge"
      , [ test_case
            "purge moves the Librarian position with the checkpoint"
            `Quick
            test_purge_moves_the_librarian_position_with_the_checkpoint
        ] )
    ]
;;
