(* RFC-0412 stage 1 — canonical keeper chat event log: codec, journal, and
   golden replay tests. *)

module E = Masc.Keeper_chat_events
module L = Masc.Keeper_chat_event_log
module Blocks = Masc.Keeper_chat_blocks
module Surface = Masc.Keeper_surface_post
module Outcome = Masc.Keeper_turn_outcome
module Projection = Server_keeper_chat_agui_projection

let occurrence : E.tool_stream_occurrence =
  { stream_scope = 7; provider_message_id = Some "pm-1"; block_index = 2 }

let occurrence_anon : E.tool_stream_occurrence =
  { stream_scope = 0; provider_message_id = None; block_index = 0 }

let usage_full : Agent_core.Types.api_usage =
  { input_tokens = 10
  ; output_tokens = 4
  ; cache_creation_input_tokens = 1
  ; cache_read_input_tokens = 2
  ; cost_usd = Some 0.001
  }

let delta_usage_partial : Agent_core.Types.delta_usage =
  { input_tokens = Some 10
  ; output_tokens = None
  ; cache_creation_input_tokens = Some 1
  ; cache_read_input_tokens = None
  }

let protocol_error_full : E.stream_protocol_error =
  { kind = E.Tool_args_without_start
  ; quarantined_occurrence = Some occurrence
  ; index = Some 2
  ; tool_call_id = Some "tc-1"
  ; event_type = Some "content_block_delta"
  ; reason = Some "args before start"
  ; raw_bytes = Some 128
  }

let protocol_error_sparse : E.stream_protocol_error =
  { kind = E.Sse_stream_repeating
  ; quarantined_occurrence = None
  ; index = None
  ; tool_call_id = None
  ; event_type = None
  ; reason = None
  ; raw_bytes = None
  }

(* One instance per [keeper_chat_event] constructor (33 total), covering both
   population variants of every option field. *)
let all_events : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-1"; thread_id = "thread-1" }
  ; E.Text_message_start { message_id = "msg-1"; role = E.User }
  ; E.Text_message_start { message_id = "msg-2"; role = E.Assistant }
  ; E.Text_delta "hello"
  ; E.Text_message_end
  ; E.External_effect_completed
      { target =
          Surface.Delivered_to_slack { channel_id = "C123"; thread_ts = Some "1700.5" }
      }
  ; E.External_effect_completed { target = Surface.Delivered_to_dashboard }
  ; E.Run_finished { run_id = "run-1" }
  ; E.Event_error { message = "boom" }
  ; E.Reply_details
      { reply = "done"
      ; turn_outcome = Outcome.Visible_reply
      ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:3
      }
  ; E.Continuation_checkpoint { message = "paused"; request_id = Some "req-9" }
  ; E.Continuation_checkpoint { message = "paused"; request_id = None }
  ; E.Agent_core_stream_connected
  ; E.Agent_core_runtime_attempt_started
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-1"; model = "kimi-for-coding"; usage = Some usage_full }
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-2"; model = "m"; usage = None }
  ; E.Agent_core_stream_message_delta
      { stop_reason = Some Agent_core.Types.EndTurn
      ; usage = Some delta_usage_partial
      }
  ; E.Agent_core_stream_message_delta { stop_reason = None; usage = None }
  ; E.Agent_core_stream_message_stop
  ; E.Agent_core_stream_ping
  ; E.Agent_core_content_block_start
      { index = 0
      ; content_type = "tool_use"
      ; tool_call_id = Some "tc-1"
      ; tool_call_name = Some "read_file"
      }
  ; E.Agent_core_content_block_start
      { index = 1; content_type = "text"; tool_call_id = None; tool_call_name = None }
  ; E.Agent_core_content_block_stop { index = 0 }
  ; E.Agent_core_thinking_delta { index = 3; delta = "pondering" }
  ; E.Agent_core_thinking_signature_delta { index = 3; signature_bytes = 42 }
  ; E.Agent_core_media_delta
      { index = 4
      ; media_type = "image/png"
      ; source_type = Agent_core.Types.Base64
      ; media_ref = "/api/v1/media/tok-1"
      }
  ; E.Agent_core_stream_protocol_error protocol_error_full
  ; E.Agent_core_stream_protocol_error protocol_error_sparse
  ; E.Tool_call_start
      { occurrence; tool_call_id = Some "tc-1"; tool_call_name = "read_file" }
  ; E.Tool_call_args
      { occurrence = occurrence_anon; tool_call_id = None; delta = "{\"path\":" }
  ; E.Tool_call_args_snapshot
      { occurrence; tool_call_id = None; snapshot = "{\"path\":\"/tmp\"}" }
  ; E.Tool_call_end { occurrence; tool_call_id = Some "tc-1" }
  ; E.Tool_approval_requested
      { tool_call_id = "tc-2"
      ; tool_call_name = "bash"
      ; args = "{\"cmd\":\"ls\"}"
      ; question = "allow?"
      ; because = "policy"
      }
  ; E.Tool_approval_settled { tool_call_id = "tc-2"; outcome = "approved" }
  ; E.Tool_result_ready
      { occurrence
      ; tool_call_id = Some "tc-1"
      ; execution_id = Ids.Execution_id.of_string "exec-1"
      }
  ; E.Link_block
      { url = "https://example.com"
      ; title = "Example"
      ; description = Some "desc"
      ; image = None
      }
  ; E.Image_block { url = "https://example.com/i.png"; caption = Some "cap" }
  ; E.Image_block { url = "https://example.com/j.png"; caption = None }
  ; E.Status_block { kind = Blocks.Continuation_checkpoint }
  ; E.Status_block { kind = Blocks.Awaiting_gate_approval }
  ; E.Audio_block
      { token = "aud-1"
      ; mime = "audio/ogg"
      ; message_text = "hi"
      ; duration_sec = Some 1.5
      }
  ; E.Audio_block { token = "aud-2"; mime = "audio/mp3"; message_text = "yo"; duration_sec = None }
  ; E.Tool_context_block
      { tool_call_id = "tc-3"
      ; name = "grep"
      ; args_summary = "pat x"
      ; result_summary = Some "3 hits"
      }
  ]

(* [keeper_chat_event] has no [equal]; JSON-level round-trip is the equality
   oracle: decode(encode(e)) re-encoded must be byte-identical to encode(e). *)
let test_codec_round_trip_all_constructors () =
  List.iteri
    (fun i event ->
       let encoded = L.keeper_chat_event_to_json event in
       match L.keeper_chat_event_of_json encoded with
       | Error detail ->
         Alcotest.failf "constructor %d failed to decode: %s\njson: %s"
           i detail (Yojson.Safe.to_string encoded)
       | Ok decoded ->
         Alcotest.(check string)
           (Printf.sprintf "constructor %d round-trips" i)
           (Yojson.Safe.to_string encoded)
           (Yojson.Safe.to_string (L.keeper_chat_event_to_json decoded)))
    all_events

let test_envelope_round_trip () =
  let entry : L.journaled_event =
    { seq = 3; ts = 1_762_300_000.25; event = E.Text_delta "hi" }
  in
  let encoded = L.journaled_event_to_json entry in
  match L.journaled_event_of_json encoded with
  | Error detail -> Alcotest.failf "envelope decode failed: %s" detail
  | Ok decoded ->
    Alcotest.(check int) "seq" 3 decoded.seq;
    Alcotest.(check (float 0.0)) "ts" 1_762_300_000.25 decoded.ts;
    Alcotest.(check string)
      "event"
      (Yojson.Safe.to_string (L.keeper_chat_event_to_json entry.event))
      (Yojson.Safe.to_string (L.keeper_chat_event_to_json decoded.event))

let test_envelope_rejects_unknown_version () =
  let json =
    `Assoc
      [ "v", `Int 99
      ; "seq", `Int 0
      ; "ts", `Float 1.0
      ; "event", `Assoc [ "type", `String "text_delta"; "delta", `String "x" ]
      ]
  in
  match L.journaled_event_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown codec version must be rejected"

let test_codec_rejects_unknown_tag () =
  match L.keeper_chat_event_of_json (`Assoc [ "type", `String "nope" ]) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unknown event tag must be rejected"

(* --- temp-dir idiom (same as test_keeper_chat_store_append_result.ml) --- *)

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let scripted_clock timestamps =
  let remaining = ref timestamps in
  fun () ->
    match !remaining with
    | ts :: rest ->
      remaining := rest;
      ts
    | [] -> failwith "scripted clock exhausted"

let test_journal_round_trip () =
  let base_dir = temp_base_path "keeper-chat-event-log" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let journal =
         L.open_journal ~base_dir ~keeper_name:"golden-keeper" ~operation_id:"op-1" ()
       in
       L.append journal ~seq:0 ~ts:1_762_300_000.0 (E.Text_delta "hello");
       L.append
         journal
         ~seq:1
         ~ts:1_762_300_000.25
         (E.Agent_core_thinking_delta { index = 0; delta = "hmm" });
       let journaled = L.read_journal journal in
       Alcotest.(check int) "two lines" 2 (List.length journaled);
       List.iteri
         (fun i (entry : L.journaled_event) ->
            Alcotest.(check int) "seq" i entry.seq)
         journaled;
       Alcotest.(check (float 0.0))
         "ts of first line"
         1_762_300_000.0
         (List.nth journaled 0).ts;
       Alcotest.(check string)
         "event payload round-trips through the journal"
         (Yojson.Safe.to_string (L.keeper_chat_event_to_json (E.Text_delta "hello")))
         (Yojson.Safe.to_string
            (L.keeper_chat_event_to_json (List.nth journaled 0).event)))

let test_journal_append_is_fail_open () =
  let file_path = temp_base_path "keeper-chat-event-log-file" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove file_path with _ -> ())
    (fun () ->
       let oc = open_out file_path in
       close_out oc;
       (* base_dir nested under a regular file: directory creation and the
          append both fail with ENOTDIR, and neither may raise. *)
       let journal =
         L.open_journal
           ~base_dir:(Filename.concat file_path "under-a-file")
           ~keeper_name:"k"
           ~operation_id:"op"
           ()
       in
       L.append
         journal
         ~seq:0
         ~ts:1_762_300_000.0
         (E.Text_delta "dropped, logged, live path unaffected");
       Alcotest.(check bool) "append did not raise" true true)

let test_journal_skips_non_finite_floats () =
  let base_dir = temp_base_path "keeper-chat-event-log-nan" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let journal =
         L.open_journal ~base_dir ~keeper_name:"k" ~operation_id:"op" ()
       in
       (* NaN [ts]: skipped. *)
       L.append journal ~seq:0 ~ts:Float.nan (E.Text_delta "nan ts");
       (* NaN [cost_usd]: skipped. *)
       L.append
         journal
         ~seq:1
         ~ts:1_762_300_000.0
         (E.Agent_core_stream_message_start
            { provider_message_id = "pm-1"
            ; model = "m"
            ; usage = Some { usage_full with Agent_core.Types.cost_usd = Some Float.nan }
            });
       (* Finite everywhere: journaled. *)
       L.append journal ~seq:2 ~ts:1_762_300_000.25 (E.Text_delta "fine");
       (* NaN [duration_sec]: skipped. *)
       L.append
         journal
         ~seq:3
         ~ts:1_762_300_000.5
         (E.Audio_block
            { token = "aud-1"
            ; mime = "audio/ogg"
            ; message_text = "x"
            ; duration_sec = Some Float.nan
            });
       let journaled = L.read_journal journal in
       Alcotest.(check int) "only the valid line was journaled" 1 (List.length journaled);
       Alcotest.(check int) "seq of the surviving line" 2 (List.nth journaled 0).seq)

let test_journal_path_sanitizes_segments () =
  let path =
    L.journal_path ~base_dir:"/tmp/base" ~keeper_name:"keeper/x" ~operation_id:"op/../../escape"
  in
  let stem = Filename.remove_extension (Filename.basename path) in
  let keeper_segment = Filename.basename (Filename.dirname path) in
  Alcotest.(check bool)
    "operation segment is traversal-free"
    true
    (stem <> ".."
     && (not (String.contains stem '/'))
     && not (String.contains stem '.'));
  Alcotest.(check bool)
    "keeper segment is traversal-free"
    true
    (keeper_segment <> ".."
     && (not (String.contains keeper_segment '/'))
     && not (String.contains keeper_segment '.'));
  Alcotest.(check string)
    "journal root is <base>/.masc/keeper_chat_events"
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path:"/tmp/base")
       "keeper_chat_events")
    (Filename.dirname (Filename.dirname path))

(* RFC-0412 stage 1 journals hold full reasoning text, so they age out with
   the shared JSONL prune: flat <operation_id>.jsonl under
   keeper_chat_events/<keeper>/, pruned by mtime like trajectories/. *)
let test_journal_files_age_out_with_shared_prune () =
  let base_dir = temp_base_path "keeper-chat-event-log-prune" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let masc_root = Common.masc_dir_from_base_path ~base_path:base_dir in
       let keeper_dir =
         Filename.concat (Filename.concat masc_root "keeper_chat_events") "keeper-a"
       in
       Fs_compat.mkdir_p keeper_dir;
       let write path =
         let oc = open_out path in
         output_string oc "{\"v\":1}\n";
         close_out oc
       in
       let old_file = Filename.concat keeper_dir "old-op.jsonl" in
       let fresh_file = Filename.concat keeper_dir "fresh-op.jsonl" in
       write old_file;
       write fresh_file;
       let old_ts = Unix.gettimeofday () -. (40. *. 86400.) in
       Unix.utimes old_file old_ts old_ts;
       let n =
         Server_runtime_startup_maintenance.prune_shared_jsonl_stores
           ~prune_dir:(fun _ -> 0)
           ~days:30
           ~masc_root
       in
       Alcotest.(check bool) "old journal pruned" false (Sys.file_exists old_file);
       Alcotest.(check bool) "fresh journal kept" true (Sys.file_exists fresh_file);
       Alcotest.(check int) "prune count includes the old journal" 1 n)

let test_on_publish_hook_receives_monotonic_seq () =
  let seen = ref [] in
  let bus =
    Masc.Keeper_chat_events.create
      ~on_publish:(fun ~seq ~ts:_ event -> seen := (seq, event) :: !seen)
      ()
  in
  List.iter
    (Masc.Keeper_chat_events.publish bus)
    [ E.Text_delta "a"; E.Text_delta "b"; E.Text_message_end ];
  Alcotest.(check (list int))
    "seq is 0-based and monotonic"
    [ 0; 1; 2 ]
    (List.rev_map fst !seen);
  (* publish order == subscribe order, hook or no hook *)
  (match Masc.Keeper_chat_events.subscribe bus with
   | E.Text_delta "a" -> ()
   | _ -> Alcotest.fail "first subscribed event mismatch")

let test_subscribe_published_returns_seq_and_publish_ts () =
  let bus =
    Masc.Keeper_chat_events.create ~now:(scripted_clock [ 10.0; 10.5 ]) ()
  in
  Masc.Keeper_chat_events.publish
    bus
    (E.Run_started { run_id = "run-seq"; thread_id = "keeper:seq" });
  Masc.Keeper_chat_events.publish bus E.Text_message_end;
  let p0 = Masc.Keeper_chat_events.subscribe_published bus in
  let p1 = Masc.Keeper_chat_events.subscribe_published bus in
  Alcotest.(check int) "first seq" 0 p0.seq;
  Alcotest.(check int) "second seq" 1 p1.seq;
  (* The clock is read once per publish, so the subscriber sees exactly the
     value the journal hook was given. *)
  Alcotest.(check (float 0.0)) "first ts is the publish-time reading" 10.0 p0.ts;
  Alcotest.(check (float 0.0)) "second ts is the next reading" 10.5 p1.ts;
  (match p0.event with
   | E.Run_started { run_id = "run-seq"; _ } -> ()
   | _ -> Alcotest.fail "first event mismatch");
  (match p1.event with
   | E.Text_message_end -> ()
   | _ -> Alcotest.fail "second event mismatch")

let test_event_to_sse_frame_carries_journal_seq () =
  let event =
    Ag_ui.make_event
      ~timestamp:13.0
      ~thread_id:"keeper:fixture"
      Ag_ui.Run_finished
  in
  let frame = Ag_ui.event_to_sse ~id:3 event in
  Alcotest.(check bool)
    "frame carries the journal seq as its SSE id"
    true
    (Astring.String.is_infix ~affix:"id: 3\n" frame);
  Alcotest.(check bool)
    "data line still present"
    true
    (Astring.String.is_infix ~affix:"data: " frame)

let test_on_publish_hook_failure_does_not_break_publish () =
  let bus =
    Masc.Keeper_chat_events.create
      ~on_publish:(fun ~seq:_ ~ts:_ _ -> failwith "journal exploded")
      ()
  in
  Masc.Keeper_chat_events.publish bus (E.Text_delta "still delivered");
  match Masc.Keeper_chat_events.subscribe bus with
  | E.Text_delta "still delivered" -> ()
  | _ -> Alcotest.fail "event lost after hook failure"

let test_full_bus_hook_runs_before_add () =
  let hook_calls = ref 0 in
  let last_seq = ref (-1) in
  let bus =
    Masc.Keeper_chat_events.create
      ~on_publish:(fun ~seq ~ts:_ _ ->
        incr hook_calls;
        last_seq := seq)
      ()
  in
  for _ = 1 to 512 do
    Masc.Keeper_chat_events.publish bus (E.Text_delta "filler")
  done;
  Alcotest.(check int) "512 publishes reached the hook" 512 !hook_calls;
  (* The 513th publish cannot complete normally: Eio.Stream.add on a full
     stream suspends the writer, and with no scheduler running (this test is
     a plain Alcotest function) the Suspend effect raises unhandled. Either
     way the hook has already run by then — that hook-before-add ordering is
     what this test pins. *)
  (match Masc.Keeper_chat_events.publish bus (E.Text_delta "overflow") with
   | () -> Alcotest.fail "publish on a full bus must not silently succeed"
   | exception _ -> ());
  Alcotest.(check int) "hook observed the overflowing publish" 513 !hook_calls;
  Alcotest.(check int) "hook saw seq = 512 for the overflowing publish" 512 !last_seq

let test_bus_journal_integration_records_all_events () =
  let base_dir = temp_base_path "keeper-chat-event-log-bus" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let journal =
         L.open_journal ~base_dir ~keeper_name:"k" ~operation_id:"op-9" ()
       in
       let bus =
         Masc.Keeper_chat_events.create ~on_publish:(L.append journal) ()
       in
       List.iter (Masc.Keeper_chat_events.publish bus) all_events;
       let journaled = L.read_journal journal in
       Alcotest.(check int)
         "every published event is journaled"
         (List.length all_events)
         (List.length journaled);
       List.iteri
         (fun i (entry : L.journaled_event) ->
            Alcotest.(check int) "seq" i entry.seq)
         journaled;
       (* The adapter-only block events are journaled even though they
          project to None on the AG-UI surface. [all_events] carries 8 such
          instances across the five kinds: 1 Link + 2 Image (caption
          populated/absent) + 2 Status + 2 Audio + 1 Tool_context. *)
       let adapter_blocks =
         List.filter
           (fun (entry : L.journaled_event) ->
              match entry.event with
              | E.Link_block _
              | E.Image_block _
              | E.Status_block _
              | E.Audio_block _
              | E.Tool_context_block _ -> true
              | _ -> false)
           journaled
       in
       Alcotest.(check int)
         "all adapter-only block instances are journaled"
         8
         (List.length adapter_blocks))

(* A well-formed turn exercising every constructor that produces SSE output
   plus the five adapter-only blocks (which must be journaled but project to
   [None]). [Event_error] is omitted: it is the alternative terminal, already
   covered by the codec round-trip. *)
let golden_events : E.keeper_chat_event list =
  [ E.Run_started { run_id = "run-golden"; thread_id = "keeper:golden" }
  ; E.Agent_core_stream_connected
  ; E.Agent_core_stream_message_start
      { provider_message_id = "pm-1"; model = "kimi-for-coding"; usage = Some usage_full }
  ; E.Agent_core_stream_ping
  ; E.Text_message_start { message_id = "msg-1"; role = E.Assistant }
  ; E.Agent_core_content_block_start
      { index = 0
      ; content_type = "thinking"
      ; tool_call_id = None
      ; tool_call_name = None
      }
  ; E.Agent_core_thinking_delta { index = 0; delta = "let me think" }
  ; E.Agent_core_thinking_signature_delta { index = 0; signature_bytes = 128 }
  ; E.Agent_core_content_block_stop { index = 0 }
  ; E.Text_delta "Hello"
  ; E.Text_delta ", world"
  ; E.Agent_core_content_block_start
      { index = 1
      ; content_type = "tool_use"
      ; tool_call_id = Some "tc-1"
      ; tool_call_name = Some "read_file"
      }
  ; E.Tool_call_start
      { occurrence; tool_call_id = Some "tc-1"; tool_call_name = "read_file" }
  ; E.Tool_call_args { occurrence; tool_call_id = Some "tc-1"; delta = "{\"path\":" }
  ; E.Tool_call_args_snapshot
      { occurrence; tool_call_id = Some "tc-1"; snapshot = "{\"path\":\"/tmp/x\"}" }
  ; E.Tool_call_end { occurrence; tool_call_id = Some "tc-1" }
  ; E.Agent_core_content_block_stop { index = 1 }
  ; E.Tool_approval_requested
      { tool_call_id = "tc-1"
      ; tool_call_name = "read_file"
      ; args = "{\"path\":\"/tmp/x\"}"
      ; question = "allow read?"
      ; because = "policy: fs read"
      }
  ; E.Tool_approval_settled { tool_call_id = "tc-1"; outcome = "approved" }
  ; E.Tool_result_ready
      { occurrence
      ; tool_call_id = Some "tc-1"
      ; execution_id = Ids.Execution_id.of_string "exec-golden-1"
      }
  ; E.Agent_core_media_delta
      { index = 2
      ; media_type = "image/png"
      ; source_type = Agent_core.Types.Url
      ; media_ref = "/api/v1/media/tok-golden"
      }
  ; E.Agent_core_stream_protocol_error protocol_error_full
  ; E.Agent_core_runtime_attempt_started
  ; E.Agent_core_stream_message_delta
      { stop_reason = Some Agent_core.Types.EndTurn
      ; usage = Some delta_usage_partial
      }
  ; E.Agent_core_stream_message_stop
  ; E.Text_message_end
  ; E.Link_block
      { url = "https://example.com"
      ; title = "Example"
      ; description = Some "desc"
      ; image = Some "https://example.com/i.png"
      }
  ; E.Image_block { url = "https://example.com/i.png"; caption = Some "cap" }
  ; E.Status_block { kind = Blocks.Awaiting_gate_approval }
  ; E.Audio_block
      { token = "aud-1"
      ; mime = "audio/ogg"
      ; message_text = "voice"
      ; duration_sec = Some 1.5
      }
  ; E.Tool_context_block
      { tool_call_id = "tc-1"
      ; name = "read_file"
      ; args_summary = "path /tmp/x"
      ; result_summary = Some "42 bytes"
      }
  ; E.Continuation_checkpoint { message = "checkpoint"; request_id = Some "req-golden" }
  ; E.External_effect_completed
      { target =
          Surface.Delivered_to_slack { channel_id = "C123"; thread_ts = Some "1700.5" }
      }
  ; E.Reply_details
      { reply = "Hello, world"
      ; turn_outcome = Outcome.Visible_reply
      ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-golden" ~absolute_turn:1
      }
  ; E.Run_finished { run_id = "run-golden" }
  ]

(* The exact fold the live Dashboard adapter performs
   (server_routes_http_keeper_stream.ml:2646-2668): project with a per-event
   injected timestamp, serialize projected events with Ag_ui.event_to_sse —
   the same serializer keeper_stream_send_event uses at :1017-1018 — and skip
   None projections. *)
let projected_sse_bytes timed_events =
  let _, rev_bytes =
    List.fold_left
      (fun (projection, acc) (ts, event) ->
         let projection, projected =
           Projection.project
             ~timestamp:ts
             ~redact_text:Fun.id
             ~redact_json:Fun.id
             projection
             event
         in
         ( projection
         , match projected with
           | Some ag_event -> Ag_ui.event_to_sse ag_event :: acc
           | None -> acc ))
      (Projection.initial, [])
      timed_events
  in
  String.concat "" (List.rev rev_bytes)

let test_golden_replay_matches_live_stream_bytes () =
  let base_dir = temp_base_path "keeper-chat-event-log-golden" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       (* Exact binary fractions: float -> JSON -> float is byte-exact for
          these values, and the per-line ts assert below catches drift. *)
       let timestamps =
         List.mapi (fun i _ -> 1_762_300_000.0 +. (float_of_int i *. 0.25)) golden_events
       in
       (* Live path: fold the in-memory events with scripted injected time. *)
       let live_bytes = projected_sse_bytes (List.combine timestamps golden_events) in
       (* Journal the whole turn through the real bus with a scripted clock. *)
       let journal =
         L.open_journal ~base_dir ~keeper_name:"golden" ~operation_id:"op-golden" ()
       in
       let bus =
         Masc.Keeper_chat_events.create
           ~now:(scripted_clock timestamps)
           ~on_publish:(L.append journal)
           ()
       in
       List.iter (Masc.Keeper_chat_events.publish bus) golden_events;
       (* Replay: decode the journal, re-fold from [initial] with the
          journaled ts. *)
       let journaled = L.read_journal journal in
       Alcotest.(check int)
         "journal holds the whole turn"
         (List.length golden_events)
         (List.length journaled);
       List.iter2
         (fun scripted_ts (entry : L.journaled_event) ->
            Alcotest.(check (float 0.0))
              "ts survives the journal"
              scripted_ts
              entry.ts)
         timestamps
         journaled;
       let replay_bytes =
         projected_sse_bytes
           (List.map (fun (entry : L.journaled_event) -> entry.ts, entry.event) journaled)
       in
       (* this check pins replay-consistency only: the journaled turn
          re-folded from [initial] must produce the same bytes as the live
          fold. drift in projection/serializer output is pinned by other
          tests, not this one. *)
       Alcotest.(check string)
         "replay reproduces the live SSE byte stream"
         live_bytes
         replay_bytes;
       (* The five adapter-only block events are invisible in the byte
          comparison (they project to None); pin their journal presence
          separately so the byte-equality green can never mask a journal
          gap. *)
       let adapter_blocks =
         List.filter
           (fun (entry : L.journaled_event) ->
              match entry.event with
              | E.Link_block _
              | E.Image_block _
              | E.Status_block _
              | E.Audio_block _
              | E.Tool_context_block _ -> true
              | _ -> false)
           journaled
       in
       Alcotest.(check int)
         "five adapter-only block events journaled"
         5
         (List.length adapter_blocks))

let () =
  Alcotest.run
    "keeper_chat_event_log"
    [ ( "codec"
      , [ Alcotest.test_case
            "round trip all constructors"
            `Quick
            test_codec_round_trip_all_constructors
        ; Alcotest.test_case "envelope round trip" `Quick test_envelope_round_trip
        ; Alcotest.test_case
            "envelope rejects unknown version"
            `Quick
            test_envelope_rejects_unknown_version
        ; Alcotest.test_case
            "codec rejects unknown tag"
            `Quick
            test_codec_rejects_unknown_tag
        ] )
    ; ( "journal"
      , [ Alcotest.test_case "round trip" `Quick test_journal_round_trip
        ; Alcotest.test_case
            "append is fail-open"
            `Quick
            test_journal_append_is_fail_open
        ; Alcotest.test_case
            "skips non-finite floats"
            `Quick
            test_journal_skips_non_finite_floats
        ; Alcotest.test_case
            "path sanitizes both segments"
            `Quick
            test_journal_path_sanitizes_segments
        ] )
    ; ( "retention"
      , [ Alcotest.test_case
            "journals age out with the shared prune"
            `Quick
            test_journal_files_age_out_with_shared_prune
        ] )
    ; ( "bus hook"
      , [ Alcotest.test_case
            "hook receives monotonic seq"
            `Quick
            test_on_publish_hook_receives_monotonic_seq
        ; Alcotest.test_case
            "subscribe_published returns seq and publish ts"
            `Quick
            test_subscribe_published_returns_seq_and_publish_ts
        ; Alcotest.test_case
            "SSE frame carries the journal seq as id"
            `Quick
            test_event_to_sse_frame_carries_journal_seq
        ; Alcotest.test_case
            "hook failure does not break publish"
            `Quick
            test_on_publish_hook_failure_does_not_break_publish
        ; Alcotest.test_case
            "full bus hook runs before add"
            `Quick
            test_full_bus_hook_runs_before_add
        ] )
    ; ( "integration"
      , [ Alcotest.test_case
            "bus journal records every published event"
            `Quick
            test_bus_journal_integration_records_all_events
        ] )
    ; ( "golden"
      , [ Alcotest.test_case
            "journal replay reproduces the live SSE byte stream"
            `Quick
            test_golden_replay_matches_live_stream_bytes
        ] )
    ]
