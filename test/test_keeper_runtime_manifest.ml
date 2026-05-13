module M = Masc_mcp.Keeper_runtime_manifest

let read_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let body = really_input_string ic len in
  close_in ic;
  body

let temp_path () =
  let path = Filename.temp_file "keeper-runtime-manifest-" ".jsonl" in
  Sys.remove path;
  path

let temp_dir () =
  let dir = Filename.temp_file "keeper-runtime-manifest-dir-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()

let with_env name value f =
  let saved = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.clear_fs ();
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio.Switch.run @@ fun sw ->
  Masc_mcp.Masc_eio_env.reset_for_test ();
  Fun.protect
    ~finally:Masc_mcp.Masc_eio_env.reset_for_test
    (fun () ->
      Masc_mcp.Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env) ();
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () ->
          f ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)))

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
      | () -> (
          match Unix.getsockname socket with
          | Unix.ADDR_INET (_, port) -> Some port
          | _ -> Alcotest.fail "unexpected socket address")
      | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
          None)

let openai_usage =
  `Assoc
    [
      ("prompt_tokens", `Int 10);
      ("completion_tokens", `Int 3);
      ("total_tokens", `Int 13);
    ]

let openai_tool_call_response ~tool_name ~arguments =
  `Assoc
    [
      ("id", `String "chatcmpl-tool");
      ("object", `String "chat.completion");
      ("model", `String "mock-runtime-manifest");
      ( "choices",
        `List
          [
            `Assoc
              [
                ("index", `Int 0);
                ( "message",
                  `Assoc
                    [
                      ("role", `String "assistant");
                      ("content", `Null);
                      ( "tool_calls",
                        `List
                          [
                            `Assoc
                              [
                                ("id", `String "call_keeper_tool_search");
                                ("type", `String "function");
                                ( "function",
                                  `Assoc
                                    [
                                      ("name", `String tool_name);
                                      ("arguments", `String arguments);
                                    ] );
                              ];
                          ] );
                    ] );
                ("finish_reason", `String "tool_calls");
              ];
          ] );
      ("usage", openai_usage);
    ]
  |> Yojson.Safe.to_string

let openai_text_response text =
  `Assoc
    [
      ("id", `String "chatcmpl-final");
      ("object", `String "chat.completion");
      ("model", `String "mock-runtime-manifest");
      ( "choices",
        `List
          [
            `Assoc
              [
                ("index", `Int 0);
                ( "message",
                  `Assoc
                    [ ("role", `String "assistant"); ("content", `String text) ] );
                ("finish_reason", `String "stop");
              ];
          ] );
      ("usage", openai_usage);
    ]
  |> Yojson.Safe.to_string

let start_multi_mock ~sw ~net ~port responses =
  let idx = Atomic.make 0 in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let n = List.length responses in
    let i = Atomic.fetch_and_add idx 1 in
    let response = List.nth responses (i mod n) in
    let headers = Cohttp.Header.init_with "content-type" "application/json" in
    Cohttp_eio.Server.respond_string ~headers ~status:`OK ~body:response ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port, fun () -> Atomic.get idx

let start_delayed_mock ~sw ~net ~clock ~port ~delay_s response =
  let calls = Atomic.make 0 in
  let handler _conn _req body =
    ignore (Atomic.fetch_and_add calls 1);
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    Eio.Time.sleep clock delay_s;
    let headers = Cohttp.Header.init_with "content-type" "application/json" in
    Cohttp_eio.Server.respond_string ~headers ~status:`OK ~body:response ()
  in
  let socket =
    Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port, fun () -> Atomic.get calls

let rec find_repo_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project") then
    dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      Alcotest.fail "could not locate dune-project ancestor of cwd"
    else
      find_repo_root parent

let source_path rel =
  Filename.concat (find_repo_root (Sys.getcwd ())) rel

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  loop 0

let check_source_contains rel needle =
  let body = read_file (source_path rel) in
  Alcotest.(check bool)
    (rel ^ " contains " ^ needle)
    true
    (contains_substring body needle)

let check_source_omits rel needle =
  let body = read_file (source_path rel) in
  Alcotest.(check bool)
    (rel ^ " omits " ^ needle)
    false
    (contains_substring body needle)

let test_event_kind_roundtrip () =
  List.iter
    (fun kind ->
      let wire = M.event_kind_to_string kind in
      Alcotest.(check (option string))
        ("event parses: " ^ wire) (Some wire)
        (Option.map M.event_kind_to_string (M.event_kind_of_string wire)))
    M.all_event_kinds;
  Alcotest.(check (option string))
    "unknown event is rejected" None
    (Option.map M.event_kind_to_string (M.event_kind_of_string "not_real"))

let test_json_roundtrip () =
  let manifest =
    M.make ~ts:"2026-05-12T00:00:00Z" ~keeper_name:"sangsu"
      ~agent_name:"keeper-sangsu-agent" ~trace_id:"trace-1" ~generation:7
      ~keeper_turn_id:11 ~oas_turn_count:3 ~event:M.Provider_attempt_finished
      ~cascade_name:"default" ~provider_kind:"openai" ~model_id:"gpt-test"
      ~status:"ok"
      ~decision:
        (`Assoc
          [
            ("phase", `String "work");
            ("attempt", `Int 2);
            ("tool_surface", `String "inline");
          ])
      ~receipt_path:"/tmp/receipt.jsonl" ~checkpoint_path:"/tmp/checkpoint.json"
      ~tool_call_log_path:"/tmp/tool-calls.jsonl" ()
  in
  match M.of_json (M.to_json manifest) with
  | Error msg -> Alcotest.fail ("roundtrip failed: " ^ msg)
  | Ok parsed ->
      Alcotest.(check int) "schema_version" 1 parsed.schema_version;
      Alcotest.(check string) "keeper_name" "sangsu" parsed.keeper_name;
      Alcotest.(check string) "trace_id" "trace-1" parsed.trace_id;
      Alcotest.(check string) "event"
        (M.event_kind_to_string M.Provider_attempt_finished)
        (M.event_kind_to_string parsed.event);
      Alcotest.(check string) "status" "ok" parsed.status;
      Alcotest.(check (option string))
        "receipt link" (Some "/tmp/receipt.jsonl")
        parsed.links.receipt_path;
      Alcotest.(check (option int)) "oas turns" (Some 3)
        parsed.oas_turn_count

let test_of_json_rejects_unknown_event () =
  let json =
    `Assoc
      [
        ("schema_version", `Int 1);
        ("ts", `String "2026-05-12T00:00:00Z");
        ("keeper_name", `String "sangsu");
        ("trace_id", `String "trace-1");
        ("event", `String "bad_event");
        ("status", `String "ok");
        ("decision", `Assoc []);
        ("links", `Assoc []);
      ]
  in
  match M.of_json json with
  | Ok _ -> Alcotest.fail "unknown event parsed successfully"
  | Error msg ->
      Alcotest.(check string) "error" "unknown event: \"bad_event\"" msg

let test_append_to_path_preserves_order () =
  let path = temp_path () in
  let first =
    M.make ~ts:"2026-05-12T00:00:00Z" ~keeper_name:"sangsu"
      ~trace_id:"trace/order" ~event:M.Turn_started
      ~decision:(`Assoc [ ("seq", `Int 1) ]) ()
  in
  let second =
    M.make ~ts:"2026-05-12T00:00:01Z" ~keeper_name:"sangsu"
      ~trace_id:"trace/order" ~event:M.Turn_finished
      ~decision:(`Assoc [ ("seq", `Int 2) ]) ()
  in
  begin
    match M.append_to_path path first with
    | Ok () -> ()
    | Error msg -> Alcotest.fail ("first append failed: " ^ msg)
  end;
  begin
    match M.append_to_path path second with
    | Ok () -> ()
    | Error msg -> Alcotest.fail ("second append failed: " ^ msg)
  end;
  let rows =
    read_file path |> String.split_on_char '\n'
    |> List.filter (fun line -> not (String.equal line ""))
    |> List.map Yojson.Safe.from_string
  in
  Sys.remove path;
  match rows with
  | [ first_json; second_json ] -> (
      match M.of_json first_json, M.of_json second_json with
      | Ok first_parsed, Ok second_parsed ->
          Alcotest.(check string) "first event"
            (M.event_kind_to_string M.Turn_started)
            (M.event_kind_to_string first_parsed.event);
          Alcotest.(check string) "second event"
            (M.event_kind_to_string M.Turn_finished)
            (M.event_kind_to_string second_parsed.event)
      | Error msg, _ | _, Error msg -> Alcotest.fail msg)
  | _ -> Alcotest.fail "expected exactly two JSONL rows"

let make_meta ?(name = "runtime-manifest-pre-dispatch") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String (name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "runtime manifest fixture");
        ])
  with
  | Ok meta -> meta
  | Error msg -> Alcotest.fail ("meta fixture failed: " ^ msg)

let read_jsonl path =
  read_file path
  |> String.split_on_char '\n'
  |> List.filter (fun line -> not (String.equal line ""))
  |> List.map Yojson.Safe.from_string

let append_raw_line path line =
  let oc = open_out_gen [ Open_append; Open_creat; Open_text ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc line;
      output_char oc '\n')

let parsed_manifest_rows path =
  read_jsonl path
  |> List.map (fun json ->
       match M.of_json json with
       | Ok row -> row
       | Error msg -> Alcotest.fail ("manifest row did not parse: " ^ msg))

let require_manifest_event event rows =
  match List.find_opt (fun row -> row.M.event = event) rows with
  | Some row -> row
  | None ->
      Alcotest.fail
        ("missing manifest event: " ^ M.event_kind_to_string event)

let json_string_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> Some value
  | _ -> None

let json_int_member name json =
  match Yojson.Safe.Util.member name json with
  | `Int value -> value
  | `Intlit raw -> Option.value ~default:0 (int_of_string_opt raw)
  | _ -> 0

let json_int_list_member name json =
  match Yojson.Safe.Util.member name json with
  | `List values ->
      values
      |> List.filter_map (function
        | `Int value -> Some value
        | `Intlit raw -> int_of_string_opt raw
        | _ -> None)
  | _ -> []

let json_list_length name json =
  match Yojson.Safe.Util.member name json with
  | `List values -> List.length values
  | _ -> 0

let json_bool_member name json =
  match Yojson.Safe.Util.member name json with
  | `Bool value -> value
  | _ -> false

let require_some label = function
  | Some value -> value
  | None -> Alcotest.fail ("missing " ^ label)

let make_tool name : Agent_sdk.Tool.t =
  Agent_sdk.Tool.create ~name ~description:("test tool " ^ name)
    ~parameters:[] (fun _input -> Ok { content = "ok" })

let runtime_mcp_policy allowed_tool_names =
  { Llm_provider.Llm_transport.empty_runtime_mcp_policy with
    allowed_tool_names
  }

let test_pre_dispatch_terminal_observation_emits_manifest_rows () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let meta = make_meta () in
      let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
      Masc_mcp.Keeper_turn_helpers.record_pre_dispatch_terminal_observation
        ~config
        ~meta
        ~generation:meta.runtime.generation
        ~cascade_name:
          (Masc_mcp.Keeper_execution_receipt.cascade_name_of_string "default")
        ~outcome:`Skipped
        ~terminal_reason_code:"phase_not_executable"
        ~activity_kind:"keeper.turn_skipped"
        ~trajectory_outcome:(Masc_mcp.Trajectory.Gated "phase_not_executable")
        ~keeper_turn_id
        ();
      let trace_id =
        Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id
      in
      let manifest_path =
        M.path_for_trace config ~keeper_name:meta.name ~trace_id
      in
      let receipt_path =
        M.execution_receipt_path_for_today config ~keeper_name:meta.name
      in
      Alcotest.(check bool) "manifest path exists" true (Sys.file_exists manifest_path);
      Alcotest.(check bool) "receipt path exists" true (Sys.file_exists receipt_path);
      let rows = parsed_manifest_rows manifest_path in
      let events = List.map (fun row -> row.M.event) rows in
      Alcotest.(check (list string))
        "pre-dispatch manifest events"
        [
          M.event_kind_to_string M.Pre_dispatch_blocked;
          M.event_kind_to_string M.Receipt_appended;
          M.event_kind_to_string M.Turn_finished;
        ]
        (List.map M.event_kind_to_string events);
      List.iter
        (fun row ->
          Alcotest.(check (option int))
            "keeper turn id"
            (Some keeper_turn_id)
            row.M.keeper_turn_id;
          Alcotest.(check (option string))
            "receipt link"
            (Some receipt_path)
            row.M.links.receipt_path)
        rows;
      match rows with
      | first :: _ ->
        Alcotest.(check string)
          "terminal reason recorded"
          "phase_not_executable"
          Yojson.Safe.Util.(
            first.M.decision |> member "terminal_reason_code" |> to_string)
      | [] -> Alcotest.fail "expected manifest rows")

let test_runtime_trace_api_links_manifest_and_receipt_rows () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let meta = make_meta ~name:"runtime-trace-api" () in
      let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
      Masc_mcp.Keeper_turn_helpers.record_pre_dispatch_terminal_observation
        ~config
        ~meta
        ~generation:meta.runtime.generation
        ~cascade_name:
          (Masc_mcp.Keeper_execution_receipt.cascade_name_of_string "default")
        ~outcome:`Skipped
        ~terminal_reason_code:"phase_not_executable"
        ~activity_kind:"keeper.turn_skipped"
        ~trajectory_outcome:(Masc_mcp.Trajectory.Gated "phase_not_executable")
        ~keeper_turn_id
        ();
      let trace_id =
        Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id
      in
      let status, json =
        Masc_mcp.Server_dashboard_http_keeper_api.keeper_runtime_trace_json
          config meta.name ~trace_id ~turn_id:keeper_turn_id ()
      in
      Alcotest.(check string)
        "runtime trace status"
        "ok"
        (match status with `OK -> "ok" | `Not_found -> "not_found");
      Alcotest.(check string)
        "runtime trace health"
        "ok"
        Yojson.Safe.Util.(json |> member "health" |> to_string);
      Alcotest.(check int)
        "manifest rows"
        3
        (json_int_member "manifest_total_rows" json);
      Alcotest.(check int)
        "receipt rows"
        1
        (json_int_member "receipt_returned_rows" json);
      let turn_identity =
        Yojson.Safe.Util.(json |> member "turn_identity")
      in
      Alcotest.(check int)
        "identity requested turn"
        keeper_turn_id
        (json_int_member "requested_keeper_turn_id" turn_identity);
      Alcotest.(check (list int))
        "identity manifest turn ids"
        [ keeper_turn_id ]
        (json_int_list_member "manifest_keeper_turn_ids" turn_identity);
      Alcotest.(check (list int))
        "identity receipt turn counts"
        [ keeper_turn_id ]
        (json_int_list_member "receipt_turn_counts" turn_identity);
      Alcotest.(check int)
        "identity has no provider attempts for pre-dispatch"
        0
        (json_int_member "provider_attempt_started_count" turn_identity);
      let manifest_events =
        Yojson.Safe.Util.(
          json |> member "manifest_rows" |> to_list
          |> List.map (fun row -> row |> member "event" |> to_string))
      in
      Alcotest.(check (list string))
        "api manifest events"
        [
          "pre_dispatch_blocked";
          "receipt_appended";
          "turn_finished";
        ]
        manifest_events;
      let linked_receipts =
        Yojson.Safe.Util.(
          json |> member "linked_artifacts" |> member "receipts" |> to_list)
      in
      Alcotest.(check int)
        "linked receipt artifact"
        1
        (List.length linked_receipts);
      match linked_receipts with
      | receipt :: _ ->
          Alcotest.(check bool)
            "linked receipt present"
            true
            Yojson.Safe.Util.(receipt |> member "present" |> to_bool)
      | [] -> Alcotest.fail "expected linked receipt")

let test_runtime_trace_api_bounds_rows_but_counts_full_manifest () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let meta = make_meta ~name:"runtime-trace-bounded" () in
      let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
      Masc_mcp.Keeper_turn_helpers.record_pre_dispatch_terminal_observation
        ~config
        ~meta
        ~generation:meta.runtime.generation
        ~cascade_name:
          (Masc_mcp.Keeper_execution_receipt.cascade_name_of_string "default")
        ~outcome:`Skipped
        ~terminal_reason_code:"phase_not_executable"
        ~activity_kind:"keeper.turn_skipped"
        ~trajectory_outcome:(Masc_mcp.Trajectory.Gated "phase_not_executable")
        ~keeper_turn_id
        ();
      let trace_id =
        Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id
      in
      let status, json =
        Masc_mcp.Server_dashboard_http_keeper_api.keeper_runtime_trace_json
          config meta.name ~trace_id ~turn_id:keeper_turn_id ~limit:2 ()
      in
      Alcotest.(check string)
        "bounded runtime trace status"
        "ok"
        (match status with `OK -> "ok" | `Not_found -> "not_found");
      Alcotest.(check int)
        "bounded trace total rows"
        3
        (json_int_member "manifest_total_rows" json);
      Alcotest.(check int)
        "bounded trace returned rows"
        2
        (json_int_member "manifest_returned_rows" json);
      Alcotest.(check int)
        "bounded trace manifest rows array"
        2
        (json_list_length "manifest_rows" json);
      let turn_identity =
        Yojson.Safe.Util.(json |> member "turn_identity")
      in
      Alcotest.(check int)
        "bounded trace counts terminal row from full scan"
        1
        (json_int_member "turn_finished_count" turn_identity);
      Alcotest.(check int)
        "bounded trace counts receipt append from full scan"
        1
        (json_int_member "receipt_appended_count" turn_identity))

let test_runtime_trace_api_surfaces_meta_read_error_without_trace_id () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let keeper_name = "runtime-trace-corrupt-meta" in
      let meta_path = Masc_mcp.Keeper_types.keeper_meta_path config keeper_name in
      Fs_compat.mkdir_p (Filename.dirname meta_path);
      append_raw_line meta_path "{not-json";
      let status, json =
        Masc_mcp.Server_dashboard_http_keeper_api.keeper_runtime_trace_json
          config keeper_name ()
      in
      Alcotest.(check string)
        "corrupt meta status"
        "not_found"
        (match status with `OK -> "ok" | `Not_found -> "not_found");
      Alcotest.(check string)
        "corrupt meta error kind"
        "keeper_meta_read_failed"
        Yojson.Safe.Util.(json |> member "error_kind" |> to_string);
      let error = Yojson.Safe.Util.(json |> member "error" |> to_string) in
      Alcotest.(check bool)
        "corrupt meta error is explicit"
        true
        (contains_substring error "metadata read failed");
      Alcotest.(check bool)
        "corrupt meta is not collapsed into missing trace_id"
        false
        (contains_substring error "trace_id query param was not supplied"))

let test_unfinished_provider_attempt_repair_skips_malformed_manifest_rows () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Masc_mcp.Coord.default_config base_dir in
      let ctx =
        {
          M.manifest_keeper_name = "runtime-manifest-repair";
          manifest_agent_name = Some "runtime-manifest-repair-agent";
          manifest_trace_id = "trace-runtime-manifest-repair";
          manifest_generation = Some 3;
          manifest_keeper_turn_id = Some 11;
        }
      in
      let started =
        M.make_for_context ctx ~event:M.Provider_attempt_started
          ~provider_kind:"openai_compat" ~model_id:"model-a" ()
      in
      begin
        match M.append config started with
        | Ok () -> ()
        | Error msg -> Alcotest.fail ("started append failed: " ^ msg)
      end;
      let manifest_path =
        M.path_for_trace config ~keeper_name:ctx.manifest_keeper_name
          ~trace_id:ctx.manifest_trace_id
      in
      append_raw_line manifest_path "{not-json";
      M.append_unfinished_provider_attempt_finished_best_effort config ctx
        ~status:"timeout" ~error:"Timeout after 1s" ();
      let valid_rows =
        read_file manifest_path
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
             if String.equal line "" then None
             else
               match Yojson.Safe.from_string line with
               | exception _ -> None
               | json -> (
                   match M.of_json json with
                   | Ok row -> Some row
                   | Error _ -> None))
      in
      let finished = require_manifest_event M.Provider_attempt_finished valid_rows in
      Alcotest.(check string) "repair status" "timeout" finished.M.status;
      Alcotest.(check (option string))
        "repair error"
        (Some "Timeout after 1s")
        (json_string_member_opt "error" finished.M.decision))

let test_successful_provider_turn_links_runtime_artifacts () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_env "MASC_BASE_PATH" base_dir @@ fun () ->
      with_env "MASC_CDAL_ENABLED" "false" @@ fun () ->
      with_env "MASC_CASCADE_ATTEMPT_LIVENESS" "off" @@ fun () ->
      Masc_mcp.Cascade_attempt_liveness_config.reset_cache_for_test ();
      Fun.protect
        ~finally:Masc_mcp.Cascade_attempt_liveness_config.reset_cache_for_test
        (fun () ->
      with_eio @@ fun ~sw ~net ~clock:_ ->
      let port =
        match find_free_port () with
        | Some port -> port
        | None -> Alcotest.skip ()
      in
      let base_url, request_count =
        start_multi_mock ~sw ~net ~port
          [
            openai_tool_call_response ~tool_name:"keeper_tool_search"
              ~arguments:
                {|{"query":"context","max_results":1}|};
            openai_text_response "context checked; runtime artifacts should persist.";
          ]
      in
      let config = Masc_mcp.Coord.default_config base_dir in
      Masc_test_deps.init_keeper_tool_registry ();
      Masc_mcp.Keeper_tool_call_log.reset_for_testing ();
      Fun.protect
        ~finally:Masc_mcp.Keeper_tool_call_log.reset_for_testing
        (fun () ->
          Masc_mcp.Keeper_tool_call_log.init ~base_path:base_dir ();
          let meta = make_meta ~name:"runtime-manifest-success" () in
          let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
          let session_base_dir = Filename.concat base_dir "sessions" in
          Fs_compat.mkdir_p session_base_dir;
          let model_string =
            Printf.sprintf "custom:remote-model@%s" base_url
          in
          let parsed_providers =
            Masc_mcp.Cascade_config.parse_model_strings [ model_string ]
          in
          let provider_cfg =
            match parsed_providers with
            | [ provider_cfg ] -> provider_cfg
            | [] -> Alcotest.fail "custom model string parsed to no providers"
            | _ -> Alcotest.fail "custom model string parsed to multiple providers"
          in
          Alcotest.(check bool)
            "custom provider supports inline tools"
            true
            (Masc_mcp.Provider_tool_support.provider_supports_inline_tools
               provider_cfg);
          let provider_caps =
            Masc_mcp.Provider_tool_support.capabilities_of_config provider_cfg
          in
          Alcotest.(check bool)
            "custom provider supports inline tool choice"
            true
            provider_caps.supports_inline_tool_choice;
          Alcotest.(check int)
            "direct model string remains tool-choice capable"
            1
            (List.length
               (Masc_mcp.Cascade_runtime.resolve_providers_from_model_strings
                  ~require_tool_choice_support:true
                  ~require_tool_support:true
                  [ model_string ]));
          let build_turn_prompt ~base_system_prompt ~messages:_ =
            { Masc_mcp.Keeper_agent_run.system_prompt =
                base_system_prompt ^ "\nReturn a concise final answer."
            ; dynamic_context = "runtime manifest success fixture"
            }
          in
          let result =
            Masc_mcp.Keeper_agent_run.run_turn
              ~config
              ~meta:{ meta with models = [ model_string ] }
              ~base_dir:session_base_dir
              ~max_context:16_000
              ~build_turn_prompt
              ~user_message:"Call keeper_tool_search once, then answer."
              ~cascade_name:(Masc_mcp.Keeper_cascade_profile.runtime_name_of_string "fixture")
              ~generation:meta.runtime.generation
              ~max_turns:3
              ~max_idle_turns:2
              ~oas_timeout_s:10.0
              ()
          in
          let result =
            match result with
            | Ok result -> result
            | Error err ->
                Alcotest.fail
                  (Printf.sprintf "run_turn failed after %d provider calls: %s"
                     (request_count ())
                     (Agent_sdk.Error.to_string err))
          in
          Alcotest.(check int) "provider calls" 2 (request_count ());
          Alcotest.(check bool)
            "keeper_tool_search used"
            true
            (List.mem "keeper_tool_search" result.tools_used);
          let latest_tool =
            Masc_mcp.Keeper_tool_call_log.read_latest
              ~keeper_name:meta.name ()
          in
          let latest_tool = require_some "latest tool-call log" latest_tool in
          Alcotest.(check string)
            "latest tool name"
            "keeper_tool_search"
            Yojson.Safe.Util.(latest_tool |> member "tool" |> to_string);
          let trace_id =
            Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id
          in
          let manifest_path =
            M.path_for_trace config ~keeper_name:meta.name ~trace_id
          in
          Alcotest.(check bool)
            "manifest path exists"
            true
            (Sys.file_exists manifest_path);
          let rows = parsed_manifest_rows manifest_path in
          List.iter
            (fun event -> ignore (require_manifest_event event rows))
            [
              M.Checkpoint_loaded;
              M.Context_compacted;
              M.Context_injected;
              M.Memory_injected;
              M.Memory_flushed;
              M.Tool_surface_selected;
              M.Provider_attempt_started;
              M.Provider_lane_resolved;
              M.Provider_attempt_finished;
              M.Checkpoint_saved;
              M.State_snapshot_sidecar_saved;
              M.Receipt_appended;
              M.Turn_finished;
            ];
          let provider_lane_row =
            require_manifest_event M.Provider_lane_resolved rows
          in
          Alcotest.(check (option string))
            "provider lane records keeper cascade engine"
            (Some
               (Masc_mcp.Keeper_cascade_engine.to_string
                  Masc_mcp.Keeper_cascade_engine.keeper_managed))
            (json_string_member_opt "cascade_engine"
               provider_lane_row.M.decision);
          Alcotest.(check (option string))
            "provider lane records OAS dispatch mode"
            (Some "single_provider_agent_run")
            (json_string_member_opt "oas_dispatch_mode"
               provider_lane_row.M.decision);
          Alcotest.(check bool)
            "provider lane disables OAS internal cascade"
            false
            (json_bool_member "oas_internal_cascade_allowed"
               provider_lane_row.M.decision);
          let checkpoint_row = require_manifest_event M.Checkpoint_saved rows in
          let checkpoint_path =
            require_some "checkpoint manifest link"
              checkpoint_row.M.links.checkpoint_path
          in
          Alcotest.(check bool)
            "checkpoint file exists"
            true
            (Sys.file_exists checkpoint_path);
          let receipt_row = require_manifest_event M.Receipt_appended rows in
          let receipt_path =
            require_some "receipt manifest link" receipt_row.M.links.receipt_path
          in
          Alcotest.(check bool)
            "receipt file exists"
            true
            (Sys.file_exists receipt_path);
          let finished_row = require_manifest_event M.Turn_finished rows in
          let tool_call_log_path =
            require_some "tool-call manifest link"
              finished_row.M.links.tool_call_log_path
          in
          Alcotest.(check bool)
            "tool-call log file exists"
            true
            (Sys.file_exists tool_call_log_path);
          let state_row =
            rows
            |> List.find_opt (fun row ->
              row.M.event = M.State_snapshot_sidecar_saved
              && Option.is_some
                   (json_string_member_opt
                      "state_snapshot_sidecar_path"
                      row.M.decision))
            |> require_some "state sidecar manifest row"
          in
          let state_path =
            require_some "state sidecar path"
              (json_string_member_opt
                 "state_snapshot_sidecar_path"
                 state_row.M.decision)
          in
          let latest_state_path =
            require_some "latest state sidecar path"
              (json_string_member_opt
                 "latest_state_snapshot_sidecar_path"
                 state_row.M.decision)
          in
          Alcotest.(check bool)
            "state sidecar exists"
            true
            (Sys.file_exists state_path);
          Alcotest.(check bool)
            "latest state sidecar exists"
            true
            (Sys.file_exists latest_state_path);
          let status, api_json =
            Masc_mcp.Server_dashboard_http_keeper_api.keeper_runtime_trace_json
              config meta.name ~trace_id ~turn_id:keeper_turn_id ()
          in
          Alcotest.(check string)
            "provider runtime trace status"
            "ok"
            (match status with `OK -> "ok" | `Not_found -> "not_found");
          let turn_identity =
            Yojson.Safe.Util.(api_json |> member "turn_identity")
          in
          Alcotest.(check (list int))
            "provider identity manifest turn ids"
            [ keeper_turn_id ]
            (json_int_list_member "manifest_keeper_turn_ids" turn_identity);
          Alcotest.(check (list int))
            "provider identity receipt turn counts"
            [ result.turn_count ]
            (json_int_list_member "receipt_turn_counts" turn_identity);
          Alcotest.(check int)
            "provider identity lane count"
            1
            (json_int_member "provider_lane_resolved_count" turn_identity);
          Alcotest.(check int)
            "provider identity attempt starts"
            1
            (json_int_member "provider_attempt_started_count" turn_identity);
          Alcotest.(check int)
            "provider identity attempt finishes"
            1
            (json_int_member "provider_attempt_finished_count" turn_identity);
          Alcotest.(check bool)
            "provider identity memory injection"
            true
            (json_int_member "memory_injected_count" turn_identity > 0);
          Alcotest.(check bool)
            "provider identity memory flush"
            true
            (json_int_member "memory_flushed_count" turn_identity > 0);
	          Alcotest.(check bool)
	            "provider identity has OAS turn count"
	            true
	            (json_int_member "max_oas_turn_count" turn_identity
	             = result.turn_count);
	          let provider_attempts =
	            Yojson.Safe.Util.(api_json |> member "provider_attempts")
	          in
	          Alcotest.(check int)
	            "provider attempts summary started"
	            1
	            (json_int_member "started_count" provider_attempts);
	          Alcotest.(check (option string))
	            "provider attempts summary terminal status"
	            (Some "provider_returned")
	            (json_string_member_opt
	               "terminal_status"
	               provider_attempts))))

let test_provider_attempt_finish_recorded_on_oas_timeout () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      with_env "MASC_BASE_PATH" base_dir @@ fun () ->
      with_env "MASC_CDAL_ENABLED" "false" @@ fun () ->
      with_env "MASC_CASCADE_ATTEMPT_LIVENESS" "off" @@ fun () ->
      Masc_mcp.Cascade_attempt_liveness_config.reset_cache_for_test ();
      Fun.protect
        ~finally:Masc_mcp.Cascade_attempt_liveness_config.reset_cache_for_test
        (fun () ->
          with_eio @@ fun ~sw ~net ~clock ->
          let port =
            match find_free_port () with
            | Some port -> port
            | None -> Alcotest.skip ()
          in
          let base_url, request_count =
            try
              start_delayed_mock ~sw ~net ~clock ~port ~delay_s:0.4
                (openai_text_response "this response should arrive after timeout")
            with
            | Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) ->
                Alcotest.skip ()
          in
          let config = Masc_mcp.Coord.default_config base_dir in
          Masc_test_deps.init_keeper_tool_registry ();
          Masc_mcp.Keeper_tool_call_log.reset_for_testing ();
          Fun.protect
            ~finally:Masc_mcp.Keeper_tool_call_log.reset_for_testing
            (fun () ->
              Masc_mcp.Keeper_tool_call_log.init ~base_path:base_dir ();
	              let meta =
	                make_meta ~name:"runtime-manifest-provider-timeout" ()
	              in
	              let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
	              let session_base_dir = Filename.concat base_dir "sessions" in
              Fs_compat.mkdir_p session_base_dir;
              let model_string =
                Printf.sprintf "custom:slow-timeout@%s" base_url
              in
              let build_turn_prompt ~base_system_prompt ~messages:_ =
                { Masc_mcp.Keeper_agent_run.system_prompt =
                    base_system_prompt ^ "\nReturn a concise final answer."
                ; dynamic_context = "runtime manifest timeout fixture"
                }
              in
              let result =
                Masc_mcp.Keeper_agent_run.run_turn
                  ~config
                  ~meta:{ meta with models = [ model_string ] }
                  ~base_dir:session_base_dir
                  ~max_context:16_000
                  ~build_turn_prompt
                  ~user_message:"Say hello slowly."
                  ~cascade_name:
                    (Masc_mcp.Keeper_cascade_profile.runtime_name_of_string
                       "fixture")
                  ~generation:meta.runtime.generation
                  ~max_turns:1
                  ~max_idle_turns:1
                  ~oas_timeout_s:0.1
                  ()
              in
              (match result with
               | Ok _ -> Alcotest.fail "expected OAS bridge timeout"
               | Error err ->
                 Alcotest.(check bool)
                   "timeout surfaced to keeper turn"
                   true
                   (contains_substring
                      (Agent_sdk.Error.to_string err)
                      "Timeout after"));
              Alcotest.(check bool)
                "provider request was attempted"
                true
                (request_count () > 0);
              let trace_id =
                Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id
              in
              let manifest_path =
                M.path_for_trace config ~keeper_name:meta.name ~trace_id
              in
              Alcotest.(check bool)
                "manifest path exists"
                true
                (Sys.file_exists manifest_path);
              let rows = parsed_manifest_rows manifest_path in
              ignore (require_manifest_event M.Provider_attempt_started rows);
              let finished_row =
                require_manifest_event M.Provider_attempt_finished rows
              in
              Alcotest.(check string)
                "provider timeout closes attempt"
                "timeout"
                finished_row.M.status;
	              Alcotest.(check (option string))
	                "provider timeout records exception kind"
	                (Some "outer_oas_timeout")
	                (json_string_member_opt "exception_kind" finished_row.M.decision);
	              Alcotest.(check bool)
	                "provider timeout records timeout error"
	                true
	                (match json_string_member_opt "error" finished_row.M.decision with
	                 | Some error -> contains_substring error "Timeout after"
	                 | None -> false);
	              let status, api_json =
	                Masc_mcp.Server_dashboard_http_keeper_api.keeper_runtime_trace_json
	                  config meta.name ~trace_id ~turn_id:keeper_turn_id ()
	              in
	              Alcotest.(check string)
	                "timeout runtime trace status"
	                "ok"
	                (match status with `OK -> "ok" | `Not_found -> "not_found");
	              let provider_attempts =
	                Yojson.Safe.Util.(api_json |> member "provider_attempts")
	              in
	              Alcotest.(check (option string))
	                "timeout provider attempts summary terminal status"
	                (Some "timeout")
	                (json_string_member_opt
	                   "terminal_status"
	                   provider_attempts);
	              Alcotest.(check (option string))
	                "timeout provider attempts summary exception"
	                (Some "outer_oas_timeout")
	                (json_string_member_opt
	                   "terminal_exception_kind"
	                   provider_attempts))))

let test_state_sidecar_hydrates_checkpoint_continuity () =
  let module KMP = Masc_mcp.Keeper_memory_policy in
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let trace_id = "trace-sidecar-hydration" in
      let session =
        Masc_mcp.Keeper_exec_context.create_session ~session_id:trace_id
          ~base_dir
      in
      let assistant_without_state =
        Agent_sdk.Types.make_message ~role:Agent_sdk.Types.Assistant
          [ Agent_sdk.Types.Text "visible assistant reply without state block" ]
      in
      let checkpoint : Agent_sdk.Checkpoint.t =
        {
          version = Agent_sdk.Checkpoint.checkpoint_version;
          session_id = trace_id;
          agent_name = "runtime-manifest-sidecar-agent";
          model = "mock-model";
          system_prompt = Some "system";
          messages =
            [
              Agent_sdk.Types.make_message ~role:Agent_sdk.Types.User
                [ Agent_sdk.Types.Text "continue" ];
              assistant_without_state;
            ];
          usage = Agent_sdk.Types.empty_usage;
          turn_count = 1;
          created_at = 1.0;
          tools = [];
          tool_choice = None;
          disable_parallel_tool_use = false;
          temperature = None;
          top_p = None;
          top_k = None;
          min_p = None;
          enable_thinking = None;
          response_format = Agent_sdk.Types.Off;
          thinking_budget = None;
          cache_system_prompt = false;
          max_input_tokens = None;
          max_total_tokens = Some 16_000;
          context = Agent_sdk.Context.create ();
          mcp_sessions = [];
          working_context = None;
        }
      in
      begin
        match
          Masc_mcp.Keeper_checkpoint_store.save_oas
            ~session_dir:session.session_dir checkpoint
        with
        | Ok () -> ()
        | Error msg -> Alcotest.fail ("checkpoint save failed: " ^ msg)
      end;
      let snapshot =
        { KMP.empty_keeper_state_snapshot with
          goal = Some "sidecar goal";
          progress = Some "sidecar progress";
          next_items = [ "resume from sidecar" ];
        }
      in
      let sidecar_payload =
        `Assoc
          [
            ("schema_version", `Int 1);
            ("ts", `String "2026-05-12T00:00:00Z");
            ("keeper_name", `String "runtime-manifest-sidecar");
            ("agent_name", `String "runtime-manifest-sidecar-agent");
            ("trace_id", `String trace_id);
            ("generation", `Int 1);
            ("oas_turn_count", `Int 1);
            ("state_snapshot", KMP.keeper_state_snapshot_to_json snapshot);
          ]
      in
      let sidecar_path =
        Filename.concat session.session_dir "state-snapshot.latest.json"
      in
      begin
        match
          Fs_compat.save_file_atomic sidecar_path
            (Yojson.Safe.pretty_to_string sidecar_payload)
        with
        | Ok () -> ()
        | Error msg -> Alcotest.fail ("sidecar save failed: " ^ msg)
      end;
      let _, loaded =
        Masc_mcp.Keeper_exec_context.load_context_from_checkpoint
          ~max_checkpoint_messages:16
          ~trace_id
          ~primary_model_max_tokens:16_000
          ~base_dir
      in
      let loaded = require_some "loaded checkpoint context" loaded in
      let loaded_messages = Masc_mcp.Keeper_exec_context.messages_of_context loaded in
      let hydrated_snapshot =
        KMP.latest_state_snapshot_from_messages loaded_messages
        |> require_some "hydrated sidecar snapshot"
      in
      Alcotest.(check (option string))
        "sidecar goal wins"
        (Some "sidecar goal")
        hydrated_snapshot.goal;
      Alcotest.(check (list string))
        "sidecar next items"
        [ "resume from sidecar" ]
        hydrated_snapshot.next_items;
      let loaded_text =
        loaded_messages
        |> List.map Agent_sdk.Types.text_of_message
        |> String.concat "\n"
      in
      Alcotest.(check bool)
        "visible text remains state-free"
        false
        (contains_substring loaded_text "[STATE]"))

let test_safe_segment () =
  Alcotest.(check string) "slash" "trace_abc" (M.safe_segment "trace/abc");
  Alcotest.(check string) "backslash" "trace_abc" (M.safe_segment "trace\\abc");
  Alcotest.(check string) "colon" "trace_abc" (M.safe_segment "trace:abc");
  Alcotest.(check string) "empty" "unknown" (M.safe_segment "   ")

let test_wired_manifest_sites () =
  List.iter
    (fun (rel, needles) ->
      List.iter (check_source_contains rel) needles)
    [
      ( "lib/keeper/keeper_unified_turn.ml",
        [
          "let keeper_turn_id = meta.runtime.usage.total_turns + 1";
          "Keeper_runtime_manifest.Turn_started";
          "Keeper_runtime_manifest.Phase_gate_decided";
          "Keeper_runtime_manifest.Cascade_routed";
          "Keeper_runtime_manifest.Event_bus_correlated";
          "turn_event_bus_manifest_decision";
        ] );
      ( "lib/memory_hooks.ml",
        [
          "Keeper_runtime_manifest.Memory_injected";
          "Keeper_runtime_manifest.Memory_flushed";
        ] );
      ( "lib/keeper/keeper_turn_helpers.ml",
        [
          "Keeper_runtime_manifest.Pre_dispatch_blocked";
          "Keeper_runtime_manifest.Receipt_appended";
          "Keeper_runtime_manifest.Turn_finished";
        ] );
      ( "lib/keeper/keeper_agent_run.ml",
        [
          "Keeper_runtime_manifest.Context_compacted";
          "Keeper_runtime_manifest.Context_injected";
          "Keeper_runtime_manifest.State_snapshot_sidecar_saved";
          "Keeper_runtime_manifest.Checkpoint_loaded";
          "Keeper_runtime_manifest.Tool_surface_selected";
          "Keeper_runtime_manifest.Checkpoint_saved";
          "Keeper_runtime_manifest.Receipt_appended";
          "Keeper_runtime_manifest.Turn_finished";
          "state-snapshots";
          "state-snapshot.latest.json";
        ] );
      ( "lib/keeper/keeper_turn_driver.ml",
        [
          "Keeper_cascade_engine.guard_keeper_hot_path";
          "cascade_engine;";
          "Keeper_cascade_engine.manifest_fields";
          "Keeper_runtime_manifest.Provider_attempt_started";
          "Keeper_runtime_manifest.Provider_attempt_finished";
        ] );
      ( "lib/keeper/keeper_turn_driver_try_provider.ml",
        [
          "cascade_engine : Keeper_cascade_engine.t";
          "Keeper_cascade_engine.manifest_fields";
          "Keeper_runtime_manifest.Provider_lane_resolved";
        ] );
      ( "lib/keeper/keeper_cascade_engine.ml",
        [
          "single_provider_agent_run";
          "oas_internal_cascade_allowed";
          "guard_keeper_hot_path";
        ] );
      ( "lib/keeper/keeper_runtime_manifest.ml",
        [ "Telemetry_coverage_gap.record"; "runtime_manifest_append_failed" ]
      );
      ( "lib/server/server_dashboard_http_keeper_api.ml",
        [ "keeper_runtime_trace_json"; "/runtime-trace" ] );
      ( "bin/masc_trace.ml",
        [
          "runtime-manifests";
          "dump_runtime_manifests";
          "[manifest ";
        ] );
      ( "scripts/keeper-runtime-truth-gate.sh",
        [
          "provider_lane_resolved";
          "event_bus_correlated";
          "memory_injected";
          "cascade_engine";
          "runtime-trace";
          "--self-test";
        ] );
    ]

let test_context_helper () =
  let ctx : M.turn_context =
    { manifest_keeper_name = "sangsu"
    ; manifest_agent_name = Some "keeper-sangsu-agent"
    ; manifest_trace_id = "trace-context"
    ; manifest_generation = Some 4
    ; manifest_keeper_turn_id = Some 9
    }
  in
  let manifest =
    M.make_for_context ctx ~event:M.Provider_attempt_started
      ~oas_turn_count:2 ~cascade_name:"default" ~provider_kind:"openai"
      ~model_id:"gpt-test" ~status:"started"
      ~decision:(`Assoc [ ("provider_health_key", `String "openai:gpt-test") ])
      ()
  in
  Alcotest.(check string) "keeper" "sangsu" manifest.keeper_name;
  Alcotest.(check (option string))
    "agent" (Some "keeper-sangsu-agent") manifest.agent_name;
  Alcotest.(check (option int)) "generation" (Some 4) manifest.generation;
  Alcotest.(check (option int)) "keeper_turn_id" (Some 9)
    manifest.keeper_turn_id;
  Alcotest.(check (option int)) "oas_turn_count" (Some 2)
    manifest.oas_turn_count;
  Alcotest.(check (option string))
    "provider_kind" (Some "openai") manifest.provider_kind

let test_required_tool_lane_missing_names () =
  let module FT = Masc_mcp.Keeper_turn_driver_helpers in
  let missing =
    FT.missing_required_tool_names_after_lane_by_name
      ~required_tool_names:[ "keeper_task_done"; "keeper_task_done"; "read_file" ]
      ~materialized_tool_names:[ "read_file"; "list_dir" ]
  in
  Alcotest.(check (list string))
    "deduped missing required tools" [ "keeper_task_done" ] missing;
  let satisfied =
    FT.missing_required_tool_names_after_lane_by_name
      ~required_tool_names:[ "keeper_task_done" ]
      ~materialized_tool_names:[ "keeper_task_done"; "read_file" ]
  in
  Alcotest.(check (list string)) "all required tools materialized" [] satisfied

let test_required_tool_lane_matrix_materialization () =
  let module FT = Masc_mcp.Keeper_turn_driver_helpers in
  let cases =
    [
      ( "inline-only"
      , [ make_tool "inline_tool" ]
      , None
      , [ "inline_tool" ]
      , "inline"
      , [ "inline_tool" ]
      , [] );
      ( "runtime-mcp-only"
      , []
      , Some (runtime_mcp_policy [ "runtime_tool" ])
      , [ "runtime_tool" ]
      , "runtime_mcp"
      , [ "runtime_tool" ]
      , [] );
      ( "mixed"
      , [ make_tool "inline_tool" ]
      , Some (runtime_mcp_policy [ "runtime_tool" ])
      , [ "inline_tool"; "runtime_tool" ]
      , "mixed"
      , [ "inline_tool"; "runtime_tool" ]
      , [] );
      ( "no-tool-lane"
      , []
      , None
      , [ "required_tool" ]
      , "none"
      , []
      , [ "required_tool" ] );
      ( "runtime-mcp-connect-only"
      , []
      , Some (runtime_mcp_policy [])
      , [ "required_tool" ]
      , "runtime_mcp_connect_only"
      , []
      , [ "required_tool" ] );
    ]
  in
  List.iter
    (fun ( label
         , effective_tools
         , runtime_mcp_policy
         , required_tool_names
         , expected_lane
         , expected_materialized
         , expected_missing ) ->
      Alcotest.(check string)
        (label ^ " lane")
        expected_lane
        (FT.resolved_tool_lane_label ~effective_tools ~runtime_mcp_policy);
      let materialized =
        FT.materialized_tool_names_after_lane ~effective_tools
          ~runtime_mcp_policy
      in
      Alcotest.(check (list string))
        (label ^ " materialized tools")
        expected_materialized materialized;
      Alcotest.(check (list string))
        (label ^ " missing required tools")
        expected_missing
        (FT.missing_required_tool_names_after_lane ~required_tool_names
           ~effective_tools ~runtime_mcp_policy))
    cases

let test_keeper_cascade_engine_boundary () =
  let module E = Masc_mcp.Keeper_cascade_engine in
  let engine = E.keeper_managed in
  Alcotest.(check string)
    "engine id" "masc_keeper_named_cascade" (E.to_string engine);
  Alcotest.(check string)
    "dispatch mode"
    "single_provider_agent_run"
    (E.oas_dispatch_mode_to_string (E.oas_dispatch_mode engine));
  Alcotest.(check bool)
    "OAS internal cascade disabled"
    false
    (E.allows_oas_internal_cascade engine);
  (match E.guard_keeper_hot_path engine with
   | Ok () -> ()
   | Error msg -> Alcotest.fail msg);
  let fields = E.manifest_fields engine in
  let field key =
    match List.assoc_opt key fields with
    | Some value -> value
    | None -> Alcotest.fail ("missing engine field: " ^ key)
  in
  Alcotest.(check string)
    "manifest engine"
    "masc_keeper_named_cascade"
    Yojson.Safe.Util.(field "cascade_engine" |> to_string);
  Alcotest.(check string)
    "manifest dispatch mode"
    "single_provider_agent_run"
    Yojson.Safe.Util.(field "oas_dispatch_mode" |> to_string);
  Alcotest.(check bool)
    "manifest internal cascade flag"
    false
    Yojson.Safe.Util.(field "oas_internal_cascade_allowed" |> to_bool)

let test_keeper_hot_path_avoids_oas_complete_cascade () =
  List.iter
    (fun rel ->
      check_source_omits rel "Complete_cascade";
      check_source_omits rel "complete_cascade")
    [
      "lib/keeper/keeper_unified_turn.ml";
      "lib/keeper/keeper_agent_run.ml";
      "lib/keeper/keeper_turn_driver.ml";
      "lib/keeper/keeper_turn_driver_try_provider.ml";
      "lib/keeper/keeper_turn_driver_wrappers.ml";
    ]

let () =
  Alcotest.run "keeper_runtime_manifest"
    [
      ( "schema",
        [
          Alcotest.test_case "event kind roundtrip" `Quick
            test_event_kind_roundtrip;
          Alcotest.test_case "json roundtrip" `Quick test_json_roundtrip;
          Alcotest.test_case "unknown event rejected" `Quick
            test_of_json_rejects_unknown_event;
          Alcotest.test_case "safe path segment" `Quick test_safe_segment;
          Alcotest.test_case "context helper" `Quick test_context_helper;
        ] );
      ( "append",
        [
          Alcotest.test_case "append preserves order" `Quick
            test_append_to_path_preserves_order;
          Alcotest.test_case "pre-dispatch emits manifest rows" `Quick
            test_pre_dispatch_terminal_observation_emits_manifest_rows;
          Alcotest.test_case
            "runtime trace API links manifest and receipt rows"
            `Quick test_runtime_trace_api_links_manifest_and_receipt_rows;
          Alcotest.test_case
            "runtime trace API bounds rows while counting full manifest"
            `Quick test_runtime_trace_api_bounds_rows_but_counts_full_manifest;
          Alcotest.test_case
            "runtime trace API surfaces corrupt meta without trace id"
            `Quick
            test_runtime_trace_api_surfaces_meta_read_error_without_trace_id;
          Alcotest.test_case
            "provider attempt repair skips malformed manifest rows"
            `Quick
            test_unfinished_provider_attempt_repair_skips_malformed_manifest_rows;
        ] );
      ( "runtime",
        [
	          Alcotest.test_case
	            "successful provider turn links runtime artifacts"
	            `Quick
	            test_successful_provider_turn_links_runtime_artifacts;
	          Alcotest.test_case
	            "provider timeout closes runtime manifest attempt"
	            `Quick
	            test_provider_attempt_finish_recorded_on_oas_timeout;
	          Alcotest.test_case
	            "state sidecar hydrates checkpoint continuity"
	            `Quick test_state_sidecar_hydrates_checkpoint_continuity;
        ] );
      ( "wiring",
        [
          Alcotest.test_case "manifest events are wired" `Quick
            test_wired_manifest_sites;
          Alcotest.test_case "required tool lane mismatch is detected" `Quick
            test_required_tool_lane_missing_names;
          Alcotest.test_case "required tool lane matrix materializes tools"
            `Quick test_required_tool_lane_matrix_materialization;
          Alcotest.test_case "keeper cascade engine boundary is typed"
            `Quick test_keeper_cascade_engine_boundary;
          Alcotest.test_case "keeper hot path avoids OAS Complete_cascade"
            `Quick test_keeper_hot_path_avoids_oas_complete_cascade;
        ] );
    ]
