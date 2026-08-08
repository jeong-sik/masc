open Alcotest
open Agent_sdk
module Internal = Agent_sdk__
module Runtime_internal = Internal.Execution_runtime
module Event = Internal.Execution_event
module Codec = Internal.Execution_codec_executor
module Journal = Internal.Execution_journal
module Store = Internal.Execution_event_store

exception Cancel_before_append
exception Store_scope_failed

let require_store = function
  | Ok value -> value
  | Error error -> fail (Store.error_to_string error)
;;

let require_journal = function
  | Ok value -> value
  | Error error -> fail (Journal.error_to_string error)
;;

let require_runtime = function
  | Ok value -> value
  | Error error -> fail (Runtime_internal.create_error_to_string error)
;;

let create_store ~codec ~sw ~dir =
  if not (Eio.Path.is_directory dir) then Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  let store, initialization = require_store (Store.create ~sw ~codec ~dir ()) in
  (match initialization with
   | Store.Fresh -> ()
   | Store.Recovered_uncommitted_initialization ->
     fail "unexpected uncommitted initialization recovery");
  store
;;

let open_store ~codec ~sw ~dir =
  Store.open_existing ~sw ~codec ~dir
  |> Result.map (fun (opened : Store.opened) -> opened.store, opened.recovery)
;;

let attach_store store = require_store (Store.attach store)

let with_temp_dir env f =
  Eio.Switch.run (fun codec_sw ->
    let runtime =
      require_runtime
        (Runtime_internal.create
           ~sw:codec_sw
           ~domain_mgr:(Eio.Stdenv.domain_mgr env)
           ~domain_count:1)
    in
    let codec = Codec.of_runtime runtime in
    let native_path = Filename.temp_file "oas-execution-store-" ".dir" in
    Sys.remove native_path;
    let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
    Fun.protect
      ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
      (fun () -> f codec dir))
;;

let read_all store =
  match Store.last_seq store with
  | Error _ as error -> error
  | Ok last_seq ->
    Store.read_page store ~after:(Store.beginning_cursor store) ~limit:(last_seq + 1) ()
    |> Result.map (fun (page : Store.page) -> page.events)
;;

let directory_snapshot dir =
  Eio.Path.read_dir dir
  |> List.sort String.compare
  |> List.map (fun name -> name, Eio.Path.load Eio.Path.(dir / name))
;;

let authority_with_format_version ~version payload =
  let authority =
    match Yojson.Safe.from_string payload with
    | `Assoc fields ->
      (match List.assoc_opt "authority" fields with
       | Some (`Assoc authority_fields) ->
         `Assoc
           (List.map
              (function
                | "format_version", _ -> "format_version", `Int version
                | field -> field)
              authority_fields)
       | Some _ | None -> fail "authority fixture has no object payload")
    | _ -> fail "authority fixture is not an object"
  in
  let authority_bytes = Yojson.Safe.to_string authority in
  let authority_sha256 = Digestif.SHA256.(to_hex (digest_string authority_bytes)) in
  Yojson.Safe.to_string
    (`Assoc [ "authority", authority; "authority_sha256", `String authority_sha256 ])
;;

let make_four_events correlation_id =
  let journal = require_journal (Journal.create ~correlation_id ()) in
  let run, _opened =
    require_journal (Journal.start_run journal ~agent_name:"store-test")
  in
  let turn, _opened =
    require_journal
      (Journal.open_node
         journal
         ~run
         ~parent:(Journal.run_root run)
         ~kind:(Event.Agent_turn { ordinal = 0 }))
  in
  ignore (require_journal (Journal.close_node journal ~node:turn Event.Succeeded));
  ignore (require_journal (Journal.finish_run journal ~run Event.Succeeded));
  Journal.events journal
;;

let check_events message expected actual =
  check bool message true (List.equal Event.equal expected actual)
;;

let require_event = function
  | Ok event -> event
  | Error detail -> fail detail
;;

let fresh identity = require_event (identity ())

let manual_event ~correlation_id ~run_id ~seq ?parent_event_id payload =
  let event_id = fresh Event.Event_id.fresh in
  let envelope =
    Event_envelope.make
      ~event_id:(Event.Event_id.to_string event_id)
      ~correlation_id:(Event.Correlation_id.to_string correlation_id)
      ~run_id:(Event.Run_id.to_string run_id)
      ~seq
      ?parent_event_id
      ()
  in
  require_event (Event.make ~envelope payload)
;;

let legacy_recursive_events correlation_id =
  let journal = require_journal (Journal.create ~correlation_id ()) in
  let parent_run, _ =
    require_journal (Journal.start_run journal ~agent_name:"legacy-parent")
  in
  let turn, _ =
    require_journal
      (Journal.open_node
         journal
         ~run:parent_run
         ~parent:(Journal.run_root parent_run)
         ~kind:(Event.Agent_turn { ordinal = 0 }))
  in
  let config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_kind.OpenAI_compat
      ~provider_id:"legacy-provider"
      ~model_id:"legacy-model"
      ~base_url:"https://provider.test"
      ()
  in
  let binding =
    Binding_identity.of_provider_config
      ~transport:(Binding_identity.transport_for_call ~injected:false)
      config
    |> require_event
  in
  let provider_kind = require_event (Event.provider_attempt ~ordinal:0 binding) in
  let provider, _ =
    require_journal
      (Journal.open_node journal ~run:parent_run ~parent:turn ~kind:provider_kind)
  in
  let invocation, _ =
    require_journal
      (Journal.open_node
         journal
         ~run:parent_run
         ~parent:provider
         ~kind:
           (Event.Tool_invocation
              { provider_tool_use_id = Some "legacy-tool-use"
              ; tool_name = "legacy-tool"
              ; schedule =
                  { planned_index = 0
                  ; batch_index = 0
                  ; batch_size = 1
                  ; execution_mode = Tool_contract.Serial
                  }
              ; completion = Tool_contract.Continue_after_success
              }))
  in
  let input_materialized =
    require_journal
      (Journal.update_node
         journal
         ~node:invocation
         (Event.Tool_input_snapshot
            (Llm_provider.Types.ToolUse
               { id = "legacy-tool-use"; name = "legacy-tool"; input = `Assoc [] })))
  in
  let child_run_id = fresh Event.Run_id.fresh in
  let child_root_id = fresh Event.Node_id.fresh in
  let child_root =
    require_event
      (Event.make_node
         ~node_id:child_root_id
         ~run_id:child_run_id
         ~parent_node_id:(Some invocation)
         ~kind:(Event.Agent_run { agent_name = "legacy-child" }))
  in
  let child_opened =
    manual_event
      ~correlation_id
      ~run_id:child_run_id
      ~seq:(Journal.last_seq journal + 1)
      ~parent_event_id:(Event.Event_id.to_string (Event.event_id input_materialized))
      (Event.Node_opened child_root)
  in
  Journal.events journal @ [ child_opened ]
;;

let rec reverse_failure_data = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, value) ->
            if String.equal name "data"
            then (
              match value with
              | `Assoc fields -> name, `Assoc (List.rev fields)
              | _ -> name, reverse_failure_data value)
            else name, reverse_failure_data value)
         fields)
  | `List values -> `List (List.map reverse_failure_data values)
  | value -> value
;;

let rewrite_cursor cursor ~scope_id ~seq =
  let json = Store.cursor_to_yojson cursor in
  match json with
  | `Assoc fields ->
    let fields =
      ("scope_id", `String scope_id)
      :: ("seq", `Int seq)
      :: List.remove_assoc "scope_id" (List.remove_assoc "seq" fields)
    in
    (match Store.cursor_of_yojson (`Assoc fields) with
     | Ok cursor -> cursor
     | Error detail -> fail detail)
  | _ -> fail "cursor encoder did not produce an object"
;;

let rewrite_event_seq event seq =
  match Event.to_yojson event with
  | `Assoc fields ->
    (match List.assoc_opt "envelope" fields with
     | Some (`Assoc envelope) ->
       let envelope = ("seq", `Int seq) :: List.remove_assoc "seq" envelope in
       let json =
         `Assoc (("envelope", `Assoc envelope) :: List.remove_assoc "envelope" fields)
       in
       require_event (Event.of_yojson json)
     | Some _ | None -> fail "event encoder did not return an envelope object")
  | _ -> fail "event encoder did not return an object"
;;

let test_append_reopen_idempotency_and_paging () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    let expected = ref [] in
    let first_cursor = ref None in
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      expected := events;
      let first, second, remaining =
        match events with
        | first :: second :: remaining -> first, second, remaining
        | _ -> fail "fixture did not produce four events"
      in
      (match Store.append_batch writer ~expected_next_seq:1 [ first ] with
       | Ok Store.Stored -> ()
       | _ -> fail "first batch was not stored");
      (match Store.append_batch writer ~expected_next_seq:2 [ second ] with
       | Ok Store.Stored -> ()
       | _ -> fail "second batch was not stored");
      (match Store.append_batch writer ~expected_next_seq:1 [ first ] with
       | Ok Store.Already_committed -> ()
       | _ -> fail "byte-identical retry was not idempotent");
      let page =
        require_store
          (Store.read_page store ~after:(Store.beginning_cursor store) ~limit:1 ())
      in
      check int "page size" 1 (List.length page.events);
      check int "captured high watermark" 2 (Store.cursor_seq page.high_watermark);
      check int "next cursor" 1 (Store.cursor_seq page.next_cursor);
      check bool "more committed data" true page.has_more;
      check (option int) "earliest retained sequence" (Some 1) page.earliest_available_seq;
      first_cursor := Some page.next_cursor;
      ignore (require_store (Store.append_batch writer ~expected_next_seq:3 remaining));
      let frozen =
        require_store
          (Store.read_page
             store
             ~after:page.next_cursor
             ~through:page.high_watermark
             ~limit:8
             ())
      in
      check int "frozen watermark excludes later appends" 1 (List.length frozen.events);
      check
        int
        "frozen watermark remains stable"
        2
        (Store.cursor_seq frozen.high_watermark);
      check bool "frozen snapshot complete" false frozen.has_more;
      let other = List.hd (make_four_events (Store.correlation_id store)) in
      match Store.append_batch writer ~expected_next_seq:1 [ other ] with
      | Error (Store.Committed_content_conflict { first_seq = 1; last_seq = 1 }) -> ()
      | _ -> fail "different bytes reused a committed sequence");
    Eio.Switch.run (fun sw ->
      let store, recovery = require_store (open_store ~codec ~sw ~dir) in
      (match recovery with
       | Store.Clean -> ()
       | _ -> fail "clean WAL reported recovery");
      check int "recovered sequence" 4 (require_store (Store.last_seq store));
      check_events "full replay" !expected (require_store (read_all store));
      let after = Option.get !first_cursor in
      let page = require_store (Store.read_page store ~after ~limit:8 ()) in
      check int "exclusive second page" 3 (List.length page.events);
      check int "second page cursor" 4 (Store.cursor_seq page.next_cursor);
      check bool "captured page complete" false page.has_more))
;;

let test_idempotent_retry_requires_exact_canonical_bytes () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let journal =
        require_journal (Journal.create ~correlation_id:(Store.correlation_id store) ())
      in
      let run, opened =
        require_journal (Journal.start_run journal ~agent_name:"byte-identity")
      in
      let closed =
        match
          require_journal
            (Journal.abort_run
               journal
               ~run
               (Event.Failed
                  { kind = Event.Internal_failure
                  ; detail = "fixture"
                  ; data = Some (`Assoc [ "first", `Int 1; "second", `Int 2 ])
                  }))
        with
        | [ event ] -> event
        | _ -> fail "single-node failed run did not emit one close event"
      in
      let reordered =
        closed
        |> Event.to_yojson
        |> reverse_failure_data
        |> Event.of_yojson
        |> require_event
      in
      check
        bool
        "semantic event equality ignores object order"
        true
        (Event.equal closed reordered);
      check
        bool
        "canonical bytes retain opaque object order"
        false
        (String.equal (Event.to_json_string closed) (Event.to_json_string reordered));
      ignore
        (require_store
           (Store.append_batch writer ~expected_next_seq:1 [ opened; closed ]));
      match
        Store.append_batch writer ~expected_next_seq:(Event.seq reordered) [ reordered ]
      with
      | Error (Store.Committed_content_conflict { first_seq = 2; last_seq = 2 }) -> ()
      | _ -> fail "semantic-only equality admitted a non-byte-identical retry"))
;;

let test_old_store_format_is_explicitly_rejected () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = legacy_recursive_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events)));
    Eio.Switch.run (fun sw ->
      match Journal.open_durable_writer ~sw ~codec ~dir with
      | Error (Journal.Invariant_violation (Journal.Child_run_parent_not_tool_attempt _))
        -> ()
      | Error error ->
        fail ("legacy fixture failed elsewhere: " ^ Journal.error_to_string error)
      | Ok _ ->
        fail "legacy recursive fixture did not reach the changed reducer invariant");
    let wal = Eio.Path.(dir / "events.v1.wal") in
    let authority = Eio.Path.(dir / "events.v1.commit") in
    let wal_before = Eio.Path.load wal in
    let old_authority =
      Eio.Path.load authority |> authority_with_format_version ~version:1
    in
    Eio.Path.with_open_out ~create:(`Or_truncate 0o600) authority (fun file ->
      Eio.Flow.copy_string old_authority file;
      Eio.File.sync file);
    Eio.Switch.run (fun sw ->
      match Journal.open_durable_writer ~sw ~codec ~dir with
      | Error
          (Journal.Persistence_failure
             (Store.Unsupported_store_version { expected = 2; actual = 1 })) -> ()
      | Error error ->
        fail ("unexpected journal failure: " ^ Journal.error_to_string error)
      | Ok _ -> fail "old recursive execution store was reopened");
    check string "rejected store remains untouched" wal_before (Eio.Path.load wal))
;;

let test_torn_tail_is_explicitly_truncated () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    let expected = ref [] in
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      expected := events;
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events)));
    let wal = Eio.Path.(dir / "events.v1.wal") in
    Eio.Path.with_open_out ~append:true ~create:`Never wal (fun file ->
      Eio.Flow.copy_string "OASE" file;
      Eio.File.sync file);
    Eio.Switch.run (fun sw ->
      let store, recovery = require_store (open_store ~codec ~sw ~dir) in
      (match recovery with
       | Store.Recovered
           [ Store.Truncated_uncommitted_tail
               { removed_bytes = 4L; last_committed_seq = 4; _ }
           ] -> ()
       | _ -> fail "incomplete tail was not reported exactly");
      check_events "committed prefix survives" !expected (require_store (read_all store)));
    Eio.Switch.run (fun sw ->
      let _store, recovery = require_store (open_store ~codec ~sw ~dir) in
      match recovery with
      | Store.Clean -> ()
      | _ -> fail "repaired WAL was not clean on the next open"))
;;

let test_partial_final_batch_is_rolled_back_to_committed_prefix () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec root ->
    let run_case case_name cutoff_of_sizes =
      let dir = Eio.Path.(root / case_name) in
      Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
      let prefix_size = ref 0 in
      let prefix_authority = ref "" in
      let full_wal = ref "" in
      let expected_prefix = ref [] in
      Eio.Switch.run (fun sw ->
        let store = create_store ~codec ~sw ~dir in
        let writer = attach_store store in
        let events = make_four_events (Store.correlation_id store) in
        let first, rest =
          match events with
          | first :: rest -> first, rest
          | [] -> fail "fixture did not produce events"
        in
        expected_prefix := [ first ];
        ignore (require_store (Store.append_batch writer ~expected_next_seq:1 [ first ]));
        let wal = Eio.Path.(dir / "events.v1.wal") in
        let authority = Eio.Path.(dir / "events.v1.commit") in
        prefix_size := String.length (Eio.Path.load wal);
        prefix_authority := Eio.Path.load authority;
        ignore (require_store (Store.append_batch writer ~expected_next_seq:2 rest));
        full_wal := Eio.Path.load wal);
      let cutoff = cutoff_of_sizes !prefix_size (String.length !full_wal) in
      let truncated = String.sub !full_wal 0 cutoff in
      let wal = Eio.Path.(dir / "events.v1.wal") in
      Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
        Eio.Flow.copy_string truncated file;
        Eio.File.sync file);
      let authority = Eio.Path.(dir / "events.v1.commit") in
      Eio.Path.with_open_out ~create:(`Or_truncate 0o600) authority (fun file ->
        Eio.Flow.copy_string !prefix_authority file;
        Eio.File.sync file);
      Eio.Switch.run (fun sw ->
        let store, recovery = require_store (open_store ~codec ~sw ~dir) in
        (match recovery with
         | Store.Recovered
             [ Store.Truncated_uncommitted_tail
                 { committed_offset; removed_bytes; last_committed_seq = 1 }
             ] ->
           check
             int64
             "rollback begins at committed prefix"
             (Int64.of_int !prefix_size)
             committed_offset;
           check
             int64
             "reported removed partial batch bytes"
             (Int64.of_int (cutoff - !prefix_size))
             removed_bytes
         | _ -> fail "partial final batch was not explicitly rolled back");
        check_events
          "only the committed prefix remains"
          !expected_prefix
          (require_store (read_all store)))
    in
    run_case "mid-batch" (fun prefix full -> prefix + ((full - prefix) / 2));
    run_case "mid-commit" (fun _prefix full -> full - 1))
;;

let test_committed_corruption_is_rejected_without_truncation () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events)));
    let wal = Eio.Path.(dir / "events.v1.wal") in
    let bytes = Bytes.of_string (Eio.Path.load wal) in
    let final_index = Bytes.length bytes - 1 in
    Bytes.set
      bytes
      final_index
      (Char.chr (Char.code (Bytes.get bytes final_index) lxor 1));
    Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
      Eio.Flow.copy_string (Bytes.unsafe_to_string bytes) file;
      Eio.File.sync file);
    let corrupted_size = (Eio.Path.stat ~follow:true wal).size in
    Eio.Switch.run (fun sw ->
      match open_store ~codec ~sw ~dir with
      | Error (Store.Corrupt_store _) -> ()
      | _ -> fail "committed checksum corruption was silently accepted");
    check
      int64
      "corrupt WAL was not truncated"
      (Optint.Int63.to_int64 corrupted_size)
      (Optint.Int63.to_int64 (Eio.Path.stat ~follow:true wal).size))
;;

let test_authoritative_incomplete_frame_is_not_truncated () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    let middle_payload = ref "" in
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      middle_payload := Event.to_json_string (List.nth events 1);
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events)));
    let wal = Eio.Path.(dir / "events.v1.wal") in
    let bytes = Bytes.of_string (Eio.Path.load wal) in
    let payload_offset =
      try
        Str.search_forward (Str.regexp_string !middle_payload) (Bytes.to_string bytes) 0
      with
      | Not_found -> fail "middle event payload was not found in WAL fixture"
    in
    let frame_header_bytes = 4 + 2 + 1 + 1 + 8 + 32 in
    let frame_offset = payload_offset - frame_header_bytes in
    let declared_length = Bytes.length bytes - payload_offset + 1 in
    for index = 0 to 7 do
      let shift = (7 - index) * 8 in
      Bytes.set
        bytes
        (frame_offset + 8 + index)
        (Char.chr ((declared_length lsr shift) land 0xff))
    done;
    Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
      Eio.Flow.copy_string (Bytes.unsafe_to_string bytes) file;
      Eio.File.sync file);
    let corrupted_size = (Eio.Path.stat ~follow:true wal).size in
    Eio.Switch.run (fun sw ->
      match open_store ~codec ~sw ~dir with
      | Error (Store.Corrupt_store _) -> ()
      | _ -> fail "authoritative incomplete frame was treated as an uncommitted tail");
    check
      int64
      "authoritative corruption was not truncated"
      (Optint.Int63.to_int64 corrupted_size)
      (Optint.Int63.to_int64 (Eio.Path.stat ~follow:true wal).size))
;;

let test_foreign_authority_cannot_truncate_wal () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec root ->
    let target = Eio.Path.(root / "target") in
    let foreign = Eio.Path.(root / "foreign") in
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir:target in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events)));
    Eio.Switch.run (fun sw -> ignore (create_store ~codec ~sw ~dir:foreign));
    let target_wal = Eio.Path.(target / "events.v1.wal") in
    let target_authority = Eio.Path.(target / "events.v1.commit") in
    let foreign_authority = Eio.Path.(foreign / "events.v1.commit") in
    let original_size = (Eio.Path.stat ~follow:true target_wal).size in
    Eio.Path.with_open_out ~create:(`Or_truncate 0o600) target_authority (fun file ->
      Eio.Flow.copy_string (Eio.Path.load foreign_authority) file;
      Eio.File.sync file);
    Eio.Switch.run (fun sw ->
      match open_store ~codec ~sw ~dir:target with
      | Error (Store.Corrupt_store _) -> ()
      | _ -> fail "foreign authority was accepted for the target WAL");
    check
      int64
      "foreign authority did not truncate target WAL"
      (Optint.Int63.to_int64 original_size)
      (Optint.Int63.to_int64 (Eio.Path.stat ~follow:true target_wal).size))
;;

let test_detected_committed_corruption_poisons_writer () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events));
      let first = List.hd events in
      let first_payload = Event.to_json_string first in
      let wal = Eio.Path.(dir / "events.v1.wal") in
      let bytes = Bytes.of_string (Eio.Path.load wal) in
      let payload_offset =
        try
          Str.search_forward (Str.regexp_string first_payload) (Bytes.to_string bytes) 0
        with
        | Not_found -> fail "committed event payload was not found in WAL fixture"
      in
      Bytes.set
        bytes
        payload_offset
        (Char.chr (Char.code (Bytes.get bytes payload_offset) lxor 1));
      Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
        Eio.Flow.copy_string (Bytes.unsafe_to_string bytes) file;
        Eio.File.sync file);
      (match read_all store with
       | Error (Store.Corrupt_store _) -> ()
       | _ -> fail "same-size committed corruption was not detected");
      (match Store.read_page store ~after:(Store.beginning_cursor store) ~limit:1 () with
       | Error (Store.Store_poisoned _) -> ()
       | _ -> fail "projection read ignored the known poisoned store");
      match Store.append_batch writer ~expected_next_seq:1 [ first ] with
      | Error (Store.Store_poisoned _) -> ()
      | _ -> fail "writer remained usable after committed corruption was detected"))
;;

let test_projection_detects_middle_event_corruption () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events));
      let first = List.hd events in
      let middle = List.nth events 1 in
      let middle_payload = Event.to_json_string middle in
      let wal = Eio.Path.(dir / "events.v1.wal") in
      let bytes = Bytes.of_string (Eio.Path.load wal) in
      let payload_offset =
        try
          Str.search_forward (Str.regexp_string middle_payload) (Bytes.to_string bytes) 0
        with
        | Not_found -> fail "middle event payload was not found in WAL fixture"
      in
      Bytes.set
        bytes
        payload_offset
        (Char.chr (Char.code (Bytes.get bytes payload_offset) lxor 1));
      Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
        Eio.Flow.copy_string (Bytes.unsafe_to_string bytes) file;
        Eio.File.sync file);
      (match read_all store with
       | Error (Store.Corrupt_store _) -> ()
       | _ -> fail "projection ignored corrupted middle event bytes");
      match Store.append_batch writer ~expected_next_seq:1 [ first ] with
      | Error (Store.Store_poisoned _) -> ()
      | _ -> fail "projection corruption did not fence the writer"))
;;

let test_retry_validates_later_frames_after_content_mismatch () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events));
      let later_payload = Event.to_json_string (List.nth events 1) in
      let wal = Eio.Path.(dir / "events.v1.wal") in
      let bytes = Bytes.of_string (Eio.Path.load wal) in
      let payload_offset =
        try
          Str.search_forward (Str.regexp_string later_payload) (Bytes.to_string bytes) 0
        with
        | Not_found -> fail "later event payload was not found in WAL fixture"
      in
      Bytes.set
        bytes
        payload_offset
        (Char.chr (Char.code (Bytes.get bytes payload_offset) lxor 1));
      Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
        Eio.Flow.copy_string (Bytes.unsafe_to_string bytes) file;
        Eio.File.sync file);
      let different_events = make_four_events (Store.correlation_id store) in
      (match Store.append_batch writer ~expected_next_seq:1 different_events with
       | Error (Store.Corrupt_store _) -> ()
       | Error (Store.Committed_content_conflict _) ->
         fail "retry stopped at the first content mismatch before later corruption"
       | Error error -> fail ("unexpected retry failure: " ^ Store.error_to_string error)
       | Ok _ -> fail "corrupt committed range was accepted as an idempotent retry");
      match Store.append_batch writer ~expected_next_seq:1 different_events with
      | Error (Store.Store_poisoned _) -> ()
      | _ -> fail "retry corruption did not fence the writer"))
;;

let test_projection_verifies_middle_event_frame_header () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events));
      let first = List.hd events in
      let middle_payload = Event.to_json_string (List.nth events 1) in
      let wal = Eio.Path.(dir / "events.v1.wal") in
      let bytes = Bytes.of_string (Eio.Path.load wal) in
      let payload_offset =
        try
          Str.search_forward (Str.regexp_string middle_payload) (Bytes.to_string bytes) 0
        with
        | Not_found -> fail "middle event payload was not found in WAL fixture"
      in
      (* The independent v1 wire-format oracle is 4 magic + 2 version + 1 kind
         + 1 reserved + 8 length + 32 SHA-256 bytes. *)
      let event_frame_offset = payload_offset - (4 + 2 + 1 + 1 + 8 + 32) in
      Bytes.set bytes event_frame_offset 'X';
      Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
        Eio.Flow.copy_string (Bytes.unsafe_to_string bytes) file;
        Eio.File.sync file);
      (match read_all store with
       | Error (Store.Corrupt_store _) -> ()
       | _ -> fail "projection ignored a corrupted middle event frame header");
      match Store.append_batch writer ~expected_next_seq:1 [ first ] with
      | Error (Store.Store_poisoned _) -> ()
      | _ -> fail "event frame header corruption did not fence the writer"))
;;

let test_uncommitted_initialization_is_explicitly_recovered () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let initializing = Eio.Path.(dir / "events.v1.wal.initializing") in
    Eio.Path.with_open_out ~create:(`Exclusive 0o600) initializing (fun file ->
      Eio.Flow.copy_string "incomplete metadata" file;
      Eio.File.sync file);
    Eio.Switch.run (fun sw ->
      match open_store ~codec ~sw ~dir with
      | Error Store.Store_initialization_incomplete -> ()
      | _ -> fail "orphan initialization was not reported");
    Eio.Switch.run (fun sw ->
      let store, initialization = require_store (Store.create ~sw ~codec ~dir ()) in
      (match initialization with
       | Store.Recovered_uncommitted_initialization -> ()
       | Store.Fresh -> fail "orphan initialization recovery was silent");
      check int "recovered store begins empty" 0 (require_store (Store.last_seq store)));
    Eio.Switch.run (fun sw ->
      let store, recovery = require_store (open_store ~codec ~sw ~dir) in
      check int "recovered store reopens" 0 (require_store (Store.last_seq store));
      match recovery with
      | Store.Clean -> ()
      | _ -> fail "recovered initialization did not produce a clean WAL"))
;;

let test_initial_commit_authority_is_rebuilt_explicitly () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw -> ignore (create_store ~codec ~sw ~dir));
    let authority = Eio.Path.(dir / "events.v1.commit") in
    let initializing = Eio.Path.(dir / "events.v1.commit.initializing") in
    Eio.Path.rename authority initializing;
    Eio.Switch.run (fun sw ->
      let store, recovery = require_store (open_store ~codec ~sw ~dir) in
      check
        int
        "rebuilt authority keeps the empty store"
        0
        (require_store (Store.last_seq store));
      match recovery with
      | Store.Recovered
          [ Store.Discarded_uncommitted_authority; Store.Rebuilt_initial_authority ] -> ()
      | _ -> fail "initial authority recovery was not reported exactly");
    Eio.Switch.run (fun sw ->
      let _store, recovery = require_store (open_store ~codec ~sw ~dir) in
      match recovery with
      | Store.Clean -> ()
      | _ -> fail "rebuilt authority was not clean on the next open"))
;;

let test_failed_create_releases_writer_immediately () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let wal = Eio.Path.(dir / "events.v1.wal") in
    Eio.Path.save ~create:(`Exclusive 0o600) wal "preexisting";
    Eio.Switch.run (fun sw ->
      (match Store.create ~sw ~codec ~dir () with
       | Error Store.Store_already_exists -> ()
       | _ -> fail "preexisting WAL was not rejected");
      Eio.Path.unlink wal;
      match Store.create ~sw ~codec ~dir () with
      | Ok (_store, Store.Fresh) -> ()
      | Error Store.Writer_already_active ->
        fail "failed create leaked its writer claim until switch release"
      | _ -> fail "create did not recover after its prior explicit failure"))
;;

let test_failed_journal_replay_releases_store_immediately () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let invalid = List.nth (make_four_events (Store.correlation_id store)) 1 in
      let invalid = rewrite_event_seq invalid 1 in
      match Store.append_batch writer ~expected_next_seq:1 [ invalid ] with
      | Ok Store.Stored -> ()
      | Ok Store.Already_committed -> fail "invalid fixture was already committed"
      | Error error -> fail (Store.error_to_string error));
    Eio.Switch.run (fun sw ->
      let expect_semantic_replay_failure () =
        match Journal.open_durable_writer ~sw ~codec ~dir with
        | Error
            (Journal.Invariant_violation
               (Journal.Unknown_parent_event _ | Journal.Unknown_parent_node _)) -> ()
        | Error error -> fail (Journal.error_to_string error)
        | Ok _ -> fail "semantically invalid WAL opened as a journal"
      in
      expect_semantic_replay_failure ();
      expect_semantic_replay_failure ()))
;;

let test_create_unknown_outcome_reconciles_through_open () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let blocker = Eio.Path.(dir / "events.v1.commit.initializing") in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 blocker;
    Eio.Switch.run (fun sw ->
      match Store.create ~sw ~codec ~dir () with
      | Error (Store.Commit_outcome_unknown _) -> ()
      | _ -> fail "post-WAL create failure was not classified as outcome unknown");
    Eio.Path.rmtree ~missing_ok:false blocker;
    Eio.Switch.run (fun sw ->
      let store, recovery = require_store (open_store ~codec ~sw ~dir) in
      check
        int
        "reconciled unknown create is empty"
        0
        (require_store (Store.last_seq store));
      match recovery with
      | Store.Recovered [ Store.Rebuilt_initial_authority ] -> ()
      | _ -> fail "unknown create was not reconciled explicitly by open"))
;;

let test_append_failure_rolls_back_before_authority () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      let blocker = Eio.Path.(dir / "events.v1.commit.initializing") in
      Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 blocker;
      (match Store.append_batch writer ~expected_next_seq:1 events with
       | Error (Store.Io_failure _) -> ()
       | _ -> fail "pre-authority append failure did not surface its I/O error");
      check
        int
        "failed append did not advance store"
        0
        (require_store (Store.last_seq store));
      Eio.Path.rmtree ~missing_ok:false blocker;
      (match Store.append_batch writer ~expected_next_seq:1 events with
       | Ok Store.Stored -> ()
       | _ -> fail "append could not retry after proven rollback");
      check int "retried append committed" 4 (require_store (Store.last_seq store)));
    Eio.Switch.run (fun sw ->
      let store, recovery = require_store (open_store ~codec ~sw ~dir) in
      check int "retried append reopens" 4 (require_store (Store.last_seq store));
      match recovery with
      | Store.Clean -> ()
      | _ -> fail "proven append rollback left recovery residue"))
;;

let test_cancelled_append_does_not_mutate_store () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let events = make_four_events (Store.correlation_id store) in
      let wal = Eio.Path.(dir / "events.v1.wal") in
      let authority = Eio.Path.(dir / "events.v1.commit") in
      let wal_before = Eio.Path.load wal in
      let authority_before = Eio.Path.load authority in
      let cancelled =
        match
          Eio.Cancel.sub (fun cancel_context ->
            Eio.Cancel.cancel cancel_context Cancel_before_append;
            ignore (Store.append_batch writer ~expected_next_seq:1 events))
        with
        | () -> false
        | exception Eio.Cancel.Cancelled _ -> true
      in
      check bool "append observed pre-existing cancellation" true cancelled;
      check
        int
        "cancelled append did not publish"
        0
        (require_store (Store.last_seq store));
      check string "cancelled append did not mutate WAL" wal_before (Eio.Path.load wal);
      check
        string
        "cancelled append did not replace authority"
        authority_before
        (Eio.Path.load authority);
      match Store.append_batch writer ~expected_next_seq:1 events with
      | Ok Store.Stored -> ()
      | _ -> fail "store did not accept append after cancelled caller detached"))
;;

let test_journal_persists_before_publish_and_replays () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let run_handle = ref None in
    let opened_event = ref None in
    Eio.Switch.run (fun sw ->
      let writer, initialization =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir ())
      in
      (match initialization with
       | Store.Fresh -> ()
       | Store.Recovered_uncommitted_initialization ->
         fail "new durable journal recovered an unexpected initialization");
      let journal = Journal.durable_writer_journal writer in
      let batch, (run, opened) =
        require_journal
          (Journal.stage
             (Journal.begin_durable_batch writer)
             (Journal.Transaction.start_run ~agent_name:"durable-journal" ()))
      in
      run_handle := Some run;
      opened_event := Some opened;
      check_events
        "durable commit returns the staged event"
        [ opened ]
        (require_journal (Journal.commit_durable_batch writer batch));
      check int "journal published one event" 1 (Journal.length journal));
    Eio.Switch.run (fun sw ->
      let writer, recovery =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir)
      in
      (match recovery with
       | Store.Clean -> ()
       | _ -> fail "unexpected recovery");
      let journal = Journal.durable_writer_journal writer in
      check int "journal reducer replayed" 1 (Journal.length journal);
      check_events
        "replayed exact event"
        [ Option.get !opened_event ]
        (Journal.events journal);
      let batch, _closed =
        require_journal
          (Journal.stage
             (Journal.begin_durable_batch writer)
             (Journal.Transaction.finish_run
                ~run:(Option.get !run_handle)
                Event.Succeeded))
      in
      ignore (require_journal (Journal.commit_durable_batch writer batch));
      check int "finish durably committed" 2 (Journal.last_seq journal));
    Eio.Switch.run (fun sw ->
      let writer, _recovery =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir)
      in
      let journal = Journal.durable_writer_journal writer in
      check int "finished scope fully replayed" 2 (Journal.length journal);
      match
        Journal.stage
          (Journal.begin_durable_batch writer)
          (Journal.Transaction.start_run ~agent_name:"second-top-level" ())
      with
      | Error (Journal.Invariant_violation Journal.Top_level_run_already_exists) -> ()
      | _ -> fail "recovered scope admitted a second top-level run"))
;;

let test_durable_journal_batch_commits_one_exact_authority_step () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let exact_events = ref [] in
    Eio.Switch.run (fun sw ->
      let writer, initialization =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir ())
      in
      (match initialization with
       | Store.Fresh -> ()
       | Store.Recovered_uncommitted_initialization ->
         fail "new durable journal recovered an unexpected initialization");
      let journal = Journal.durable_writer_journal writer in
      let volatile = require_journal (Journal.create ()) in
      let foreign_batch, _ =
        require_journal
          (Journal.stage
             (Journal.begin_batch volatile)
             (Journal.Transaction.start_run ~agent_name:"volatile" ()))
      in
      (match Journal.commit_durable_batch writer foreign_batch with
       | Error Journal.Durable_batch_owner_mismatch -> ()
       | Error error -> fail (Journal.error_to_string error)
       | Ok _ -> fail "durable capability accepted another journal's batch");
      check
        int
        "ownership rejection leaves durable journal empty"
        0
        (Journal.length journal);
      check
        int
        "ownership rejection leaves volatile batch unpublished"
        0
        (Journal.length volatile);
      let beginning = Journal.beginning_cursor journal in
      let batch, (run, opened_run) =
        require_journal
          (Journal.stage
             (Journal.begin_durable_batch writer)
             (Journal.Transaction.start_run ~agent_name:"durable-batch" ()))
      in
      let batch, (turn, opened_turn) =
        require_journal
          (Journal.stage
             batch
             (Journal.Transaction.open_node
                ~run
                ~parent:(Journal.run_root run)
                ~kind:(Event.Agent_turn { ordinal = 0 })
                ()))
      in
      let batch, closed_turn =
        require_journal
          (Journal.stage
             batch
             (Journal.Transaction.close_node ~node:turn Event.Succeeded))
      in
      let batch, closed_run =
        require_journal
          (Journal.stage batch (Journal.Transaction.finish_run ~run Event.Succeeded))
      in
      check int "no durable prefix is published before commit" 0 (Journal.length journal);
      let committed = require_journal (Journal.commit_durable_batch writer batch) in
      let expected = [ opened_run; opened_turn; closed_turn; closed_run ] in
      check_events "durable commit keeps exact staged events" expected committed;
      let page =
        require_journal (Journal.read_page journal ~after:beginning ~limit:4 ())
      in
      check_events "authority exposes the entire semantic batch" expected page.events;
      check
        int
        "authority advances from zero through all four events"
        4
        (Journal.cursor_seq page.next_cursor);
      exact_events := expected);
    Eio.Switch.run (fun sw ->
      let writer, recovery =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir)
      in
      (match recovery with
       | Store.Clean -> ()
       | Store.Recovered _ -> fail "clean durable batch required recovery");
      let journal = Journal.durable_writer_journal writer in
      check int "reopened authority retains final sequence" 4 (Journal.last_seq journal);
      check_events
        "reopen replays the exact atomic batch"
        !exact_events
        (Journal.events journal)))
;;

let test_external_wal_mutation_fails_without_journal_publish () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    Eio.Switch.run (fun sw ->
      let writer, _initialization =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir ())
      in
      let journal = Journal.durable_writer_journal writer in
      let batch, (run, _opened) =
        require_journal
          (Journal.stage
             (Journal.begin_durable_batch writer)
             (Journal.Transaction.start_run ~agent_name:"mutation-fence" ()))
      in
      ignore (require_journal (Journal.commit_durable_batch writer batch));
      let before = Journal.events journal in
      let wal = Eio.Path.(dir / "events.v1.wal") in
      Eio.Path.with_open_out ~create:(`Or_truncate 0o600) wal (fun file ->
        Eio.File.sync file);
      let finish_batch, _closed =
        require_journal
          (Journal.stage
             (Journal.begin_durable_batch writer)
             (Journal.Transaction.finish_run ~run Event.Succeeded))
      in
      (match Journal.commit_durable_batch writer finish_batch with
       | Error (Journal.Persistence_failure (Store.Corrupt_store _)) -> ()
       | _ -> fail "physical WAL drift did not surface as persistence failure");
      check_events "failed persistence did not publish" before (Journal.events journal);
      check int "failed persistence did not advance reducer" 1 (Journal.length journal);
      match Journal.commit_durable_batch writer finish_batch with
      | Error (Journal.Persistence_failure (Store.Store_poisoned _)) -> ()
      | _ -> fail "detected physical WAL drift did not fence later journal writes"))
;;

let test_cursor_scope_and_writer_exclusivity () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      (match open_store ~codec ~sw ~dir with
       | Error Store.Writer_already_active -> ()
       | _ -> fail "a second in-process writer acquired the same scope");
      ignore (attach_store store);
      (match Store.attach store with
       | Error Store.Store_already_attached -> ()
       | _ -> fail "store minted more than one semantic writer capability");
      let cursor = Store.beginning_cursor store in
      let foreign = rewrite_cursor cursor ~scope_id:"execution-scope-foreign" ~seq:0 in
      (match Store.read_page store ~after:foreign ~limit:1 () with
       | Error Store.Cursor_scope_mismatch -> ()
       | _ -> fail "foreign cursor scope was accepted");
      let ahead =
        rewrite_cursor
          cursor
          ~scope_id:(Store.Scope_id.to_string (Store.scope_id store))
          ~seq:1
      in
      (match Store.read_page store ~after:ahead ~limit:1 () with
       | Error (Store.Cursor_ahead { after_seq = 1; high_watermark = 0 }) -> ()
       | _ -> fail "cursor ahead of the store was accepted");
      match Store.read_page store ~after:cursor ~limit:0 () with
      | Error (Store.Invalid_argument _) -> ()
      | _ -> fail "non-positive page size was accepted"))
;;

let stage_started_batch writer agent_name =
  Journal.stage
    (Journal.begin_durable_batch writer)
    (Journal.Transaction.start_run ~agent_name ())
  |> require_journal
;;

let stage_finished_batch writer agent_name =
  let batch, (run, opened_run) = stage_started_batch writer agent_name in
  let batch, (turn, opened_turn) =
    require_journal
      (Journal.stage
         batch
         (Journal.Transaction.open_node
            ~run
            ~parent:(Journal.run_root run)
            ~kind:(Event.Agent_turn { ordinal = 0 })
            ()))
  in
  let batch, closed_turn =
    require_journal
      (Journal.stage batch (Journal.Transaction.close_node ~node:turn Event.Succeeded))
  in
  let batch, closed_run =
    require_journal
      (Journal.stage batch (Journal.Transaction.finish_run ~run Event.Succeeded))
  in
  batch, [ opened_run; opened_turn; closed_turn; closed_run ]
;;

let test_durable_writer_rejects_direct_mutation () =
  Eio_main.run
  @@ fun env ->
  (match
     Journal.commit_error_disposition
       (Journal.Persistence_failure (Store.Commit_outcome_unknown "test fence"))
   with
   | Journal.Reconcile_required -> ()
   | Journal.Final_failure ->
     fail "unknown commit outcome was not routed to reconciliation");
  (match Journal.commit_error_disposition Journal.Direct_mutation_forbidden with
   | Journal.Final_failure -> ()
   | Journal.Reconcile_required ->
     fail "definite writer conflict requested reconciliation");
  with_temp_dir env (fun codec dir ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    Eio.Switch.run (fun sw ->
      let writer, _initialization =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir ())
      in
      let journal = Journal.durable_writer_journal writer in
      (match Journal.start_run journal ~agent_name:"bypass" with
       | Error Journal.Direct_mutation_forbidden -> ()
       | Error error -> fail (Journal.error_to_string error)
       | Ok _ -> fail "start_run bypassed the durable actor claim");
      let batch, (run, _opened) = stage_started_batch writer "claimed" in
      let metadata = Journal.batch_metadata batch in
      check int "durable batch base cursor" 0 (Journal.cursor_seq metadata.base_cursor);
      check int "durable batch final cursor" 1 (Journal.cursor_seq metadata.final_cursor);
      (match Journal.commit_batch batch with
       | Error Journal.Direct_mutation_forbidden -> ()
       | Error error -> fail (Journal.error_to_string error)
       | Ok _ -> fail "commit_batch bypassed the durable actor claim");
      check int "rejected direct commits do not publish" 0 (Journal.length journal);
      ignore (require_journal (Journal.commit_durable_batch writer batch));
      (match Journal.finish_run journal ~run Event.Succeeded with
       | Error Journal.Direct_mutation_forbidden -> ()
       | Error error -> fail (Journal.error_to_string error)
       | Ok _ -> fail "finish_run bypassed the durable actor claim");
      (match
         Journal.abort_run
           journal
           ~run
           (Event.Cancelled { reason = Some "bypass"; data = None })
       with
       | Error Journal.Direct_mutation_forbidden -> ()
       | Error error -> fail (Journal.error_to_string error)
       | Ok _ -> fail "abort_run bypassed the durable actor claim");
      check int "rejected direct paths do not publish" 1 (Journal.length journal)))
;;

let test_reopened_writer_reconciles_only_exact_batch () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec root ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 root;
    let applied_dir = Eio.Path.(root / "applied") in
    let sequence_dir = Eio.Path.(root / "sequence") in
    let content_dir = Eio.Path.(root / "content") in
    let foreign_dir = Eio.Path.(root / "foreign") in
    List.iter
      (fun dir -> Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir)
      [ applied_dir; sequence_dir; content_dir; foreign_dir ];
    let applied_batch = ref None in
    let applied_events = ref [] in
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir:applied_dir ())
      in
      let batch, (_run, opened) = stage_started_batch writer "reconcile-applied" in
      applied_batch := Some batch;
      applied_events := [ opened ]);
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir:applied_dir)
      in
      match
        require_journal
          (Journal.reconcile_durable_batch writer (Option.get !applied_batch))
      with
      | Journal.Applied events ->
        check_events "reconcile applies exact staged events" !applied_events events
      | Journal.Already_durable _ -> fail "uncommitted batch was reported durable");
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir:applied_dir)
      in
      match
        require_journal
          (Journal.reconcile_durable_batch writer (Option.get !applied_batch))
      with
      | Journal.Already_durable events ->
        check_events "reconcile compares the exact committed range" !applied_events events
      | Journal.Applied _ -> fail "committed batch was applied twice");
    let sequence_batch = ref None in
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir:sequence_dir ())
      in
      sequence_batch := Some (fst (stage_finished_batch writer "four-events"));
      let winner, _ = stage_started_batch writer "one-event" in
      ignore (require_journal (Journal.commit_durable_batch writer winner)));
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir:sequence_dir)
      in
      match Journal.reconcile_durable_batch writer (Option.get !sequence_batch) with
      | Error
          (Journal.Reconciliation_conflict
             { base_seq = 0; final_seq = 4; current_seq = 1 }) -> ()
      | Error error -> fail (Journal.error_to_string error)
      | Ok _ -> fail "reconcile guessed across an intermediate sequence");
    let conflicting_batch = ref None in
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir:content_dir ())
      in
      conflicting_batch := Some (fst (stage_started_batch writer "candidate"));
      let winner, _ = stage_started_batch writer "different-bytes" in
      ignore (require_journal (Journal.commit_durable_batch writer winner)));
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir:content_dir)
      in
      match Journal.reconcile_durable_batch writer (Option.get !conflicting_batch) with
      | Error (Journal.Reconciliation_content_conflict { first_seq = 1; last_seq = 1 }) ->
        ()
      | Error error -> fail (Journal.error_to_string error)
      | Ok _ -> fail "reconcile accepted different canonical event bytes");
    Eio.Switch.run (fun sw ->
      let writer, _ =
        require_journal (Journal.create_durable_writer ~sw ~codec ~dir:foreign_dir ())
      in
      match Journal.reconcile_durable_batch writer (Option.get !applied_batch) with
      | Error Journal.Reconciliation_scope_mismatch -> ()
      | Error error -> fail (Journal.error_to_string error)
      | Ok _ -> fail "reconcile accepted a batch from another scope"))
;;

let test_store_lifecycle_transition_matrix () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      ignore (require_store (Store.release_unpublished store));
      ignore (require_store (Store.release_unpublished store));
      (match Store.attach store with
       | Error Store.Store_released -> ()
       | Error error -> fail (Store.error_to_string error)
       | Ok _ -> fail "released unpublished store minted a writer");
      let reopened, _recovery = require_store (open_store ~codec ~sw ~dir) in
      let writer = attach_store reopened in
      (match Store.release_unpublished reopened with
       | Error Store.Store_release_forbidden -> ()
       | Error error -> fail (Store.error_to_string error)
       | Ok () -> fail "published store released switch-owned resources");
      let events = make_four_events (Store.correlation_id reopened) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 events));
      check
        int
        "published store remains writable"
        4
        (require_store (Store.last_seq reopened))))
;;

let test_explicit_release_removes_long_lived_switch_hooks () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    Eio.Switch.run (fun sw ->
      let release_and_keep_only_weak_reference () =
        let store = create_store ~codec ~sw ~dir in
        let weak = Weak.create 1 in
        Weak.set weak 0 (Some store);
        ignore (require_store (Store.release_unpublished store));
        weak
      in
      let released = release_and_keep_only_weak_reference () in
      Gc.full_major ();
      (match Weak.get released 0 with
       | None -> ()
       | Some _ -> fail "released store remained retained by a long-lived switch hook");
      let reopened, _recovery = require_store (open_store ~codec ~sw ~dir) in
      ignore (require_store (Store.release_unpublished reopened))))
;;

let test_unpublished_store_is_released_with_switch () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    let escaped = ref None in
    Eio.Switch.run (fun sw -> escaped := Some (create_store ~codec ~sw ~dir));
    let store = Option.get !escaped in
    (match Store.attach store with
     | Error Store.Store_released -> ()
     | Error error -> fail (Store.error_to_string error)
     | Ok _ -> fail "switch-released store minted a writer");
    (match Store.last_seq store with
     | Error Store.Store_released -> ()
     | Error error -> fail (Store.error_to_string error)
     | Ok _ -> fail "switch-released store exposed a stale sequence");
    Eio.Switch.run (fun sw ->
      let reopened, _recovery = require_store (open_store ~codec ~sw ~dir) in
      ignore (attach_store reopened)))
;;

let test_unpublished_store_is_released_with_failed_switch () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    let escaped = ref None in
    (match
       Eio.Switch.run (fun sw ->
         escaped := Some (create_store ~codec ~sw ~dir);
         Eio.Switch.fail sw Store_scope_failed)
     with
     | () -> fail "failed switch returned normally"
     | exception Store_scope_failed -> ()
     | exception exn -> raise exn);
    let store = Option.get !escaped in
    (match Store.last_seq store with
     | Error Store.Store_released -> ()
     | Error error -> fail (Store.error_to_string error)
     | Ok _ -> fail "failed-switch store exposed a stale sequence");
    Eio.Switch.run (fun sw ->
      let reopened, _recovery = require_store (open_store ~codec ~sw ~dir) in
      ignore (attach_store reopened)))
;;

let test_published_store_rejects_use_after_switch () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    let escaped_store = ref None in
    let escaped_writer = ref None in
    let events = ref [] in
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      let writer = attach_store store in
      let committed = make_four_events (Store.correlation_id store) in
      ignore (require_store (Store.append_batch writer ~expected_next_seq:1 committed));
      escaped_store := Some store;
      escaped_writer := Some writer;
      events := committed);
    let store = Option.get !escaped_store in
    let writer = Option.get !escaped_writer in
    let next_events =
      List.mapi (fun index event -> rewrite_event_seq event (index + 5)) !events
    in
    let expect_released = function
      | Error Store.Store_released -> ()
      | Error error -> fail (Store.error_to_string error)
      | Ok _ -> fail "switch-released store operation succeeded"
    in
    expect_released (Store.last_seq store);
    expect_released (Store.current_cursor store);
    expect_released (read_all store);
    expect_released
      (Store.read_page store ~after:(Store.beginning_cursor store) ~limit:1 ());
    expect_released (Store.append_batch writer ~expected_next_seq:5 next_events);
    Eio.Switch.run (fun sw ->
      let reopened, _recovery = require_store (open_store ~codec ~sw ~dir) in
      let current_writer = attach_store reopened in
      check
        int
        "new owner sees committed prefix"
        4
        (require_store (Store.last_seq reopened));
      expect_released (Store.append_batch writer ~expected_next_seq:5 next_events);
      check
        int
        "stale writer cannot move the new owner's authority"
        4
        (require_store (Store.last_seq reopened));
      (match Store.append_batch current_writer ~expected_next_seq:5 next_events with
       | Ok Store.Stored -> ()
       | Ok Store.Already_committed -> fail "valid next batch was already committed"
       | Error error -> fail (Store.error_to_string error));
      check
        int
        "new owner commits the valid next batch"
        8
        (require_store (Store.last_seq reopened))))
;;

let test_shared_codec_executor_routes_store_work () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    let caller = Domain.self () in
    let events = ref [] in
    Eio.Switch.run (fun sw ->
      let store = create_store ~codec ~sw ~dir in
      events := make_four_events (Store.correlation_id store);
      let writer = attach_store store in
      match Store.append_batch writer ~expected_next_seq:1 !events with
      | Ok Store.Stored -> ()
      | Ok Store.Already_committed -> fail "new batch was already committed"
      | Error error -> fail (Store.error_to_string error));
    let after_append = Codec.stats codec in
    check int "append submits one encode batch" 1 after_append.encode_events.requested;
    check int "append does not decode" 0 after_append.decode_canonical_event.requested;
    Eio.Switch.run (fun sw ->
      let durable_writer, _recovery =
        require_journal (Journal.open_durable_writer ~sw ~codec ~dir)
      in
      let journal = Journal.durable_writer_journal durable_writer in
      check_events
        "journal consumes open replay artifact"
        !events
        (Journal.events journal));
    let after_journal_open = Codec.stats codec in
    check
      int
      "journal open decodes each durable event once"
      (List.length !events)
      after_journal_open.decode_canonical_event.requested;
    Eio.Switch.run (fun sw ->
      let opened = require_store (Store.open_existing ~sw ~codec ~dir) in
      check_events "open replay artifact is exact" !events opened.replay_events;
      let writer = attach_store opened.store in
      (match Store.append_batch writer ~expected_next_seq:1 !events with
       | Ok Store.Already_committed -> ()
       | Ok Store.Stored -> fail "exact retry stored a duplicate batch"
       | Error error -> fail (Store.error_to_string error));
      let page =
        require_store
          (Store.read_page
             opened.store
             ~after:(Store.beginning_cursor opened.store)
             ~limit:(List.length !events)
             ())
      in
      check_events "page decode remains exact" !events page.events);
    let stats = Codec.stats codec in
    check int "retry reuses one encoded expected batch" 2 stats.encode_events.requested;
    check
      int
      "two opens plus one page decode each event without raw batch retention"
      (3 * List.length !events)
      stats.decode_canonical_event.requested;
    check
      int
      "exact retry compares each canonical payload without retaining committed batch"
      (List.length !events)
      stats.compare_canonical_payload.requested;
    let worker name (operation : Codec.operation_stats) =
      match operation.last_worker_domain with
      | None -> fail (name ^ " did not record a worker domain")
      | Some worker ->
        check bool (name ^ " is outside caller domain") true (worker <> caller);
        worker
    in
    let encode_worker = worker "encode" stats.encode_events in
    let decode_worker = worker "decode" stats.decode_canonical_event in
    let compare_worker = worker "compare" stats.compare_canonical_payload in
    check
      bool
      "encode/decode share the application worker"
      true
      (encode_worker = decode_worker);
    check
      bool
      "decode/compare share the application worker"
      true
      (decode_worker = compare_worker))
;;

let test_released_codec_fails_before_store_mutation () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun recovery_codec dir ->
    Eio.Switch.run (fun store_sw ->
      let store =
        Eio.Switch.run (fun codec_sw ->
          let runtime =
            require_runtime
              (Runtime_internal.create
                 ~sw:codec_sw
                 ~domain_mgr:(Eio.Stdenv.domain_mgr env)
                 ~domain_count:1)
          in
          create_store ~codec:(Codec.of_runtime runtime) ~sw:store_sw ~dir)
      in
      let events = make_four_events (Store.correlation_id store) in
      let writer = attach_store store in
      let before = directory_snapshot dir in
      (match Store.append_batch writer ~expected_next_seq:1 events with
       | Error
           (Store.Codec_failure
              (Codec.Executor_unavailable { operation = Codec.Encode_events; _ })) -> ()
       | Error error -> fail ("unexpected append failure: " ^ Store.error_to_string error)
       | Ok _ -> fail "append used a released codec executor");
      check
        (list (pair string string))
        "failed encode does not alter any store file"
        before
        (directory_snapshot dir);
      check
        int
        "failed encode does not advance store"
        0
        (require_store (Store.last_seq store)));
    Eio.Switch.run (fun sw ->
      let opened = require_store (Store.open_existing ~sw ~codec:recovery_codec ~dir) in
      check int "reopen remains empty" 0 (require_store (Store.last_seq opened.store));
      check int "replay remains empty" 0 (List.length opened.replay_events)))
;;

let () =
  run
    "Execution event store"
    [ ( "durability"
      , [ test_case
            "append, reopen, idempotency, and paging"
            `Quick
            test_append_reopen_idempotency_and_paging
        ; test_case
            "idempotent retry requires exact canonical bytes"
            `Quick
            test_idempotent_retry_requires_exact_canonical_bytes
        ; test_case
            "old store format is explicitly rejected"
            `Quick
            test_old_store_format_is_explicitly_rejected
        ; test_case
            "torn tail is explicitly truncated"
            `Quick
            test_torn_tail_is_explicitly_truncated
        ; test_case
            "partial final batch rolls back to committed prefix"
            `Quick
            test_partial_final_batch_is_rolled_back_to_committed_prefix
        ; test_case
            "committed corruption is rejected"
            `Quick
            test_committed_corruption_is_rejected_without_truncation
        ; test_case
            "authoritative incomplete frame is not truncated"
            `Quick
            test_authoritative_incomplete_frame_is_not_truncated
        ; test_case
            "foreign authority cannot truncate WAL"
            `Quick
            test_foreign_authority_cannot_truncate_wal
        ; test_case
            "detected committed corruption poisons writer"
            `Quick
            test_detected_committed_corruption_poisons_writer
        ; test_case
            "projection detects middle event corruption"
            `Quick
            test_projection_detects_middle_event_corruption
        ; test_case
            "retry validates later corruption after an earlier mismatch"
            `Quick
            test_retry_validates_later_frames_after_content_mismatch
        ; test_case
            "projection verifies middle event frame header"
            `Quick
            test_projection_verifies_middle_event_frame_header
        ; test_case
            "uncommitted initialization is explicitly recovered"
            `Quick
            test_uncommitted_initialization_is_explicitly_recovered
        ; test_case
            "initial commit authority is rebuilt explicitly"
            `Quick
            test_initial_commit_authority_is_rebuilt_explicitly
        ; test_case
            "failed create releases writer immediately"
            `Quick
            test_failed_create_releases_writer_immediately
        ; test_case
            "failed journal replay releases store immediately"
            `Quick
            test_failed_journal_replay_releases_store_immediately
        ; test_case
            "create unknown outcome reconciles through open"
            `Quick
            test_create_unknown_outcome_reconciles_through_open
        ; test_case
            "append failure rolls back before authority"
            `Quick
            test_append_failure_rolls_back_before_authority
        ; test_case
            "cancelled append does not mutate store"
            `Quick
            test_cancelled_append_does_not_mutate_store
        ; test_case
            "journal persists before publish and replays"
            `Quick
            test_journal_persists_before_publish_and_replays
        ; test_case
            "durable journal batch commits one exact authority step"
            `Quick
            test_durable_journal_batch_commits_one_exact_authority_step
        ; test_case
            "external WAL mutation fails without publish"
            `Quick
            test_external_wal_mutation_fails_without_journal_publish
        ; test_case
            "cursor scope and writer exclusivity"
            `Quick
            test_cursor_scope_and_writer_exclusivity
        ; test_case
            "durable writer rejects direct mutation"
            `Quick
            test_durable_writer_rejects_direct_mutation
        ; test_case
            "reopened writer reconciles only an exact batch"
            `Quick
            test_reopened_writer_reconciles_only_exact_batch
        ; test_case
            "store lifecycle transitions are explicit"
            `Quick
            test_store_lifecycle_transition_matrix
        ; test_case
            "explicit release removes long-lived switch hooks"
            `Quick
            test_explicit_release_removes_long_lived_switch_hooks
        ; test_case
            "unpublished store is released with switch"
            `Quick
            test_unpublished_store_is_released_with_switch
        ; test_case
            "unpublished store is released with failed switch"
            `Quick
            test_unpublished_store_is_released_with_failed_switch
        ; test_case
            "published store rejects use after switch"
            `Quick
            test_published_store_rejects_use_after_switch
        ; test_case
            "shared codec executor routes store work off-domain"
            `Quick
            test_shared_codec_executor_routes_store_work
        ; test_case
            "released codec fails before store mutation"
            `Quick
            test_released_codec_fails_before_store_mutation
        ] )
    ]
;;
