open Alcotest
open Masc
module P = Keeper_recovery_projection
module View = Keeper_recovery_transmission
module Checkpoint = Keeper_checkpoint_store
module J = Yojson.Safe.Util

let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready () |> Result.get_ok
let evidence = ref None

let get = function
  | Ok x -> x
  | Error e -> fail (View.error_to_string e)
;;

let write path body =
  let ch = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out ch) (fun () -> output_string ch body)
;;

let msg role content =
  Agent_core.Types.{ role; content; name = None; tool_call_id = None; metadata = [] }
;;

let original marker =
  let open Agent_core.Types in
  [ msg User [ Text "Required original instruction: retain the precise request." ]
  ; msg
      Assistant
      [ ToolUse { id = "original-call"; name = "keeper_artifact_read"; input = `Assoc [] }
      ]
  ; msg
      Tool
      [ ToolResult
          { tool_use_id = "original-call"
          ; content = marker
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  ]
;;

let checkpoint messages =
  Agent_core.Checkpoint.
    { version = checkpoint_version
    ; session_id = "transmission-source"
    ; agent_name = "transmission"
    ; model = "transmission-fixture"
    ; system_prompt = None
    ; messages
    ; usage = Agent_core.Types.empty_usage
    ; turn_count = 1
    ; created_at = 1000.
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

let save session_dir checkpoint =
  (match Checkpoint.save_agent_core_classified ~session_dir checkpoint with
   | Ok _ -> ()
   | Error e -> fail e);
  match
    Checkpoint.load_agent_core_exact_snapshot
      ~session_dir
      ~session_id:checkpoint.Agent_core.Checkpoint.session_id
  with
  | Ok s -> s
  | Error _ -> fail "canonical checkpoint unavailable"
;;

let reader base_path =
  let s = Keeper_runtime_schemas_toml.artifact_read in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~base_path
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name:s.name
    ~description:s.description
    ~input_schema:s.input_schema
    (fun _ args ->
       let execution = Keeper_artifact_read.handle ~base_path ~args in
       match execution.disposition with
       | Tool_result.Completed () ->
         Tool_result.make_ok
           ~tool_name:s.name
           ~start_time:(Time_compat.now ())
           ?data:execution.data
           ()
       | Tool_result.Failed class_ ->
         Tool_result.make_err
           ~tool_name:s.name
           ~class_
           ~start_time:(Time_compat.now ())
           execution.raw_output
       | Tool_result.Deferred () -> fail "artifact read unexpectedly deferred")
;;

let tool_response sha =
  Yojson.Safe.to_string
    (`Assoc
        [ "id", `String "fixture"
        ; "model", `String "transmission-fixture"
        ; ( "choices"
          , `List
              [ `Assoc
                  [ "index", `Int 0
                  ; ( "message"
                    , `Assoc
                        [ "role", `String "assistant"
                        ; "content", `Null
                        ; ( "tool_calls"
                          , `List
                              [ `Assoc
                                  [ "id", `String "source-read-exact"
                                  ; "type", `String "function"
                                  ; ( "function"
                                    , `Assoc
                                        [ "name", `String "keeper_artifact_read"
                                        ; ( "arguments"
                                          , `String
                                              (Yojson.Safe.to_string
                                                 (`Assoc
                                                     [ "sha256", `String sha
                                                     ; "offset", `Int 0
                                                     ])) )
                                        ] )
                                  ]
                              ] )
                        ] )
                  ; "finish_reason", `String "tool_calls"
                  ]
              ] )
        ; ( "usage"
          , `Assoc
              [ "prompt_tokens", `Int 1
              ; "completion_tokens", `Int 1
              ; "total_tokens", `Int 2
              ] )
        ])
;;

let with_fixture ?(with_image = false) f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let old_runtime = Runtime.For_testing.snapshot ()
  and old_catalog = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_file "recovery-transmission-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore old_runtime;
    (match old_catalog with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some c -> Llm_provider.Model_catalog.set_global c);
    Fs_compat.remove_tree base_path);
  let session_dir = Filename.concat base_path "source" in
  let cp =
    checkpoint
      (original
         ("Exact old Tool output "
          ^ String.make (4 * Keeper_artifact_read.maximum_max_bytes) 'x'))
  in
  let cp =
    if with_image
    then (
      match cp.Agent_core.Checkpoint.messages with
      | [ user; call; result ] ->
        let image =
          Agent_core.Types.Image
            { source_type = Base64
            ; media_type = "image/png"
            ; data =
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            }
        in
        { cp with
          messages = [ user; { call with content = image :: call.content }; result ]
        }
      | _ -> fail "unexpected original fixture shape")
    else cp
  in
  let source = save session_dir cp in
  let canonical = Checkpoint.exact_snapshot_canonical_bytes source in
  let artifact =
    Tool_blob_store.put_durable
      (Tool_blob_store.create ~base_path)
      ~bytes:canonical
      ~mime:"application/json"
  in
  let index =
    P.index ~source ~required:P.[ { message_index = 0; reason = User_instruction } ]
    |> Result.get_ok
  in
  let validated =
    P.validate
      ~source:index
      P.
        { source_sha256 = artifact.sha256
        ; steps =
            [ Retain 0
            ; Summarize
                { first_atom = 1
                ; last_atom = 1
                ; text =
                    "The old artifact Tool returned a source marker followed by repeated \
                     x bytes."
                }
            ]
        }
    |> Result.get_ok
  in
  let view = View.create ~source ~validated |> get in
  let responses =
    [ tool_response artifact.sha256
    ; Exact_output_fixture.openai_response
        (`Assoc [ "answer", `String "source reviewed" ])
    ]
  in
  let server =
    Exact_output_fixture.start_server
      ~sw
      ~net:env#net
      ~clock:env#clock
      (Exact_output_fixture.Replies (responses @ responses))
  in
  let catalog_path = Filename.concat base_path "models.toml" in
  write
    catalog_path
    {|[[models]]
id_prefix = "transmission-fixture"
provider_name = "fixture"
base = "openai_chat"
max_context_tokens = 1048576
max_output_tokens = 4096
supports_tools = true
supports_native_streaming = false
[[models]]
id_prefix = "no-tools-fixture"
provider_name = "fixture"
base = "openai_chat"
max_context_tokens = 1048576
max_output_tokens = 4096
supports_tools = false
supports_native_streaming = false
|};
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Ok c -> Llm_provider.Model_catalog.set_global c
   | Error e -> fail e);
  let config_path = Filename.concat base_path "runtime.toml" in
  let config_text cap =
    Printf.sprintf
      {|[runtime]
default = "fixture.sample"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "transmission-fixture"
streaming = false
[models.no_tools]
api-name = "no-tools-fixture"
streaming = false
[fixture.no_tools]
[runtime.lanes.recovery_tools]
candidates = ["fixture.no_tools", "fixture.sample"]
[fixture.sample]
%s|}
      server.base_url
      (Option.fold ~none:"" ~some:(Printf.sprintf "max-request-body-bytes = %d") cap)
  in
  write config_path (config_text None);
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> fail "fixture catalog unavailable"
   | Error e -> fail (Runtime.strict_init_error_to_string e));
  let configure cap =
    match Runtime.save_config_text ~runtime_config_path:config_path (config_text cap) with
    | Ok _ -> ()
    | Error e -> fail e
  in
  f env sw base_path session_dir cp source canonical artifact view server configure
;;

let run
      env
      sw
      base_path
      view
      cp
      ?(runtime_id = "fixture.sample")
      ?on_runtime_attempt_error
      ?(tools = [ reader base_path ])
      ?checkpoint_sink
      ?on_request_wire_observation
      ?model_input_projection
      ()
  =
  Keeper_turn_driver.run_named
    ~runtime_id
    ?on_runtime_attempt_error
    ~keeper_name:"transmission"
    ~base_path
    ~system_prompt:"Continue the exact original request using the source-bound context."
    ~goal:"New pending user stimulus: inspect the original artifact and continue."
    ~agent_core_checkpoint:cp
    ~agent_core_tools:tools
    ~tools
    ~recovery_view:view
    ?checkpoint_sink
    ?on_request_wire_observation
    ?model_input_projection
    ~sw
    ~net:env#net
    ()
;;

let prefix_exact prefix list =
  let rec loop a b =
    match a, b with
    | [], _ -> true
    | x :: xs, y :: ys when x = y -> loop xs ys
    | _ -> false
  in
  loop prefix list
;;

let test_actual_transmission_cap_metrics_checkpoint_and_reader () =
  with_fixture
    (fun
        env sw base_path session_dir cp source canonical artifact view server configure ->
       let snapshots = ref []
       and wire = ref []
       and metrics = ref [] in
       let observe ~runtime_id ~max_request_body_bytes ~body_bytes ~serialized =
         wire
         := (runtime_id, max_request_body_bytes, body_bytes, Option.is_some serialized)
            :: !wire
       in
       let project messages =
         metrics
         := Keeper_agent_prompt_metrics.provider_content_messages
              ~prompt_context_present:false
              ~projection_input:messages
              ~projected_messages:messages
            :: !metrics;
         Ok messages
       in
       let sink (s : Agent_core.Agent.checkpoint_snapshot) =
         (* The AGENT_CORE mutation callback carries no persistence session.
            Match the production Keeper sink: bind the snapshot to the exact
            source session before saving, without changing its messages. *)
         let checkpoint =
           { s.checkpoint with session_id = cp.Agent_core.Checkpoint.session_id }
         in
         snapshots := checkpoint :: !snapshots;
         Checkpoint.save_agent_core_classified ~session_dir checkpoint
         |> Result.map (fun _ -> ())
       in
       (match
          run
            env
            sw
            base_path
            view
            cp
            ~checkpoint_sink:sink
            ~on_request_wire_observation:observe
            ~model_input_projection:project
            ()
        with
        | Ok _ -> ()
        | Error e -> fail (Agent_core.Error.to_string e));
       let bodies = Exact_output_fixture.request_bodies server in
       check int "real source-read and final model response" 2 (List.length bodies);
       let first =
         Yojson.Safe.from_string (List.hd bodies)
         |> J.member "messages"
         |> J.to_list
         |> List.filter (fun m -> J.member "role" m <> `String "system")
       in
       check
         string
         "required original remains the first provider message"
         "Required original instruction: retain the precise request."
         J.(List.hd first |> member "content" |> to_string);
       let expected =
         View.project
           view
           (cp.messages
            @ [ msg
                  Agent_core.Types.User
                  [ Agent_core.Types.Text
                      "New pending user stimulus: inspect the original artifact and \
                       continue."
                  ]
              ])
         |> get
       in
       check
         (list string)
         "wire preserves original, derived User context and exact new suffix"
         (List.map
            (fun (m : Agent_core.Types.message) ->
               match m.content with
               | [ Agent_core.Types.Text s ] -> s
               | _ -> fail "expected text projected message")
            expected)
         (List.map (fun m -> J.(m |> member "content" |> to_string)) first);
       check
         (list string)
         "derived context never impersonates Assistant or Tool"
         [ "user"; "user"; "user" ]
         (List.map (fun m -> J.(m |> member "role" |> to_string)) first);
       check
         bool
         "metrics callback receives an attributable post-view prefix"
         true
         (List.length !metrics = 2 && List.for_all Result.is_ok !metrics);
       let second =
         Yojson.Safe.from_string (List.nth bodies 1) |> J.member "messages" |> J.to_list
       in
       let page =
         List.find
           (fun m -> J.member "tool_call_id" m = `String "source-read-exact")
           second
         |> J.member "content"
         |> J.to_string
         |> Yojson.Safe.from_string
       in
       check
         string
         "original source remains directly readable"
         artifact.Tool_output.sha256
         J.(page |> member "sha256" |> to_string);
       let next = J.(page |> member "next_offset" |> to_int) in
       check
         string
         "actual Tool reply carries old source bytes"
         (String.sub canonical 0 next)
         J.(page |> member "content" |> to_string);
       check bool "canonical checkpoints were actually produced" true (!snapshots <> []);
       List.iter
         (fun (s : Agent_core.Checkpoint.t) ->
            check
              bool
              "durable checkpoint preserves original exact Tool pair and content"
              true
              (prefix_exact cp.messages s.messages);
            check
              bool
              "derived context is never written as canonical history"
              false
              (List.exists
                 (fun (m : Agent_core.Types.message) ->
                    List.mem_assoc "masc.recovery_derived_context" m.metadata)
                 s.messages))
         !snapshots;
       let continued =
         match
           Checkpoint.load_agent_core_exact_snapshot
             ~session_dir
             ~session_id:cp.session_id
         with
         | Ok s -> s
         | Error _ -> fail "continued durable checkpoint unavailable"
       in
       check
         bool
         "reload keeps canonical source prefix"
         true
         (prefix_exact cp.messages (Checkpoint.exact_snapshot_messages continued));
       check
         string
         "immutable original checkpoint artifact is unchanged"
         canonical
         (Tool_blob_store.fetch
            (Tool_blob_store.create ~base_path)
            ~sha256:artifact.sha256
          |> Result.get_ok
          |> Option.get);
       let cap = List.fold_left (fun n s -> max n (String.length s)) 0 bodies in
       check
         bool
         "explicit cap is smaller than canonical history, yet admits its view"
         true
         (cap < String.length canonical);
       configure (Some cap);
       (match run env sw base_path view cp ~on_request_wire_observation:observe () with
        | Ok _ -> ()
        | Error e -> fail (Agent_core.Error.to_string e));
       check
         int
         "explicit-cap view is not cut again before its reader call"
         4
         (Exact_output_fixture.post_count server);
       let first_bytes = String.length (List.hd bodies) in
       configure (Some (first_bytes - 1));
       (match run env sw base_path view cp ~on_request_wire_observation:observe () with
        | Error
            (Agent_core.Error.Api
               (Agent_core.Retry.InvalidRequest
                  { reason =
                      Agent_core.Retry.Request_body_too_large
                        { actual_bytes; limit_bytes }
                  ; _
                  })) ->
          check
            int
            "final serializer measures the projected envelope exactly"
            first_bytes
            actual_bytes;
          check int "operator cap remains exact" (first_bytes - 1) limit_bytes
        | Error e -> fail (Agent_core.Error.to_string e)
        | Ok _ -> fail "oversized final wire admitted");
       check
         int
         "explicit exceeded cap performs no provider I/O"
         4
         (Exact_output_fixture.post_count server);
       check
         bool
         "refused exact wire observation remains explicit"
         true
         (List.nth_opt !wire 0
          = Some ("fixture.sample", Some (first_bytes - 1), first_bytes, false));
       evidence
       := Some
            (`Assoc
                [ "scope", `String "actual scripted HTTP; no external model"
                ; "source_sha256", `String (View.source_reference view).sha256
                ; "original_bytes", `Int (String.length canonical)
                ; "accepted_cap_bytes", `Int cap
                ; "first_wire_bytes", `Int first_bytes
                ; "provider_requests", `Int 4
                ; "source_read_sha256", J.member "sha256" page
                ; "canonical_prefix_preserved", `Bool true
                ; "native_clients", `String "integration unimplemented"
                ; "scheduler", `String "not connected"
                ]);
       ignore source)
;;

let test_missing_reader_and_changed_prefix_perform_no_io () =
  with_fixture (fun env sw base_path _ cp _ _ _ view server _ ->
    let reject expected = function
      | Error e ->
        check
          bool
          "exact typed transmission refusal"
          true
          (expected (View.of_core_error e))
      | Ok _ -> fail "invalid transmission reached provider"
    in
    run env sw base_path view cp ~tools:[] ()
    |> reject (function
      | Some View.Source_reader_unavailable -> true
      | _ -> false);
    let changed =
      { cp with
        Agent_core.Checkpoint.messages =
          msg Agent_core.Types.User [ Agent_core.Types.Text "Changed instruction" ]
          :: List.tl cp.messages
      }
    in
    run env sw base_path view changed ()
    |> reject (function
      | Some (View.Source_prefix_changed { message_index = 0 }) -> true
      | _ -> false);
    run env sw base_path view cp ~model_input_projection:(fun _ -> Ok []) ()
    |> reject (function
      | Some (View.After_projection_rejected _) -> true
      | _ -> false);
    check
      int
      "reader absence, changed source or destructive after never sends a request"
      0
      (Exact_output_fixture.post_count server))
;;

let test_real_result_completes_open_source_tail () =
  with_fixture (fun _ _ base_path _ _ _ _ _ _ _ _ ->
    let open Agent_core.Types in
    let messages =
      [ msg User [ Text "Exact instruction" ]
      ; msg
          Assistant
          [ ToolUse { id = "pending-exact"; name = "read"; input = `Assoc [] } ]
      ]
    in
    let source = save (Filename.concat base_path "pending") (checkpoint messages) in
    let index = P.index ~source ~required:[] |> Result.get_ok in
    let validated =
      P.validate
        ~source:index
        P.
          { source_sha256 = (Checkpoint.exact_snapshot_reference source).sha256
          ; steps = [ Retain 0; Retain 1 ]
          }
      |> Result.get_ok
    in
    let view = View.create ~source ~validated |> get in
    let runtime_view = View.runtime_projection view in
    (match runtime_view.Runtime_recovery_projection.project messages with
     | Error error ->
       (match View.of_core_error error with
        | Some (View.Incomplete_transmission _) -> ()
        | _ -> fail "runtime boundary lost the typed open Tool refusal")
     | Ok _ -> fail "open Tool call was transmitted");
    let completed =
      messages
      @ [ msg
            Tool
            [ ToolResult
                { tool_use_id = "pending-exact"
                ; content = "Actual recorded result"
                ; outcome = Tool_succeeded
                ; json = None
                ; content_blocks = None
                }
            ]
        ]
    in
    check
      bool
      "real appended result is retained without synthesized closer"
      true
      (runtime_view.Runtime_recovery_projection.project completed |> Result.get_ok
       = completed))
;;

let test_recovery_requires_actual_binding_tool_support () =
  with_fixture (fun env sw base_path _ cp _ _ _ view server _ ->
    let attempts = ref [] in
    (match
       run
         env
         sw
         base_path
         view
         cp
         ~runtime_id:"recovery_tools"
         ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch:_ error ->
           attempts
           := (runtime_id, Keeper_required_tools.of_core_error error) :: !attempts)
         ()
     with
     | Ok _ -> ()
     | Error e -> fail (Agent_core.Error.to_string e));
    (match !attempts with
     | [ ( "fixture.no_tools"
         , Some { Keeper_required_tools.reason = Binding_tools_unsupported; _ } )
       ] -> ()
     | _ ->
       fail "view with default Optional must produce typed unsupported-binding evidence");
    check
      int
      "only capable candidate sends its read and completion requests"
      2
      (Exact_output_fixture.post_count server);
    List.iter
      (fun body ->
         check
           string
           "unsupported model performs no HTTP"
           "transmission-fixture"
           J.(Yojson.Safe.from_string body |> member "model" |> to_string))
      (Exact_output_fixture.request_bodies server))
;;

let test_summarized_image_reaches_text_runtime_without_source_rewrite () =
  with_fixture
    ~with_image:true
    (fun env sw base_path _ cp source canonical artifact view server _ ->
       let before = Checkpoint.exact_snapshot_messages source in
       (match run env sw base_path view cp () with
        | Ok _ -> ()
        | Error e -> fail (Agent_core.Error.to_string e));
       check
         int
         "summarized image reaches actual text-only HTTP candidate"
         2
         (Exact_output_fixture.post_count server);
       let first =
         List.hd (Exact_output_fixture.request_bodies server) |> Yojson.Safe.from_string
       in
       check
         bool
         "provider receives only text projection content"
         true
         (List.for_all
            (fun m ->
               match J.member "content" m with
               | `String _ -> true
               | _ -> false)
            J.(first |> member "messages" |> to_list));
       check
         bool
         "canonical Image and Tool call records stay identical"
         true
         (cp.messages = before);
       check
         string
         "original image-containing checkpoint artifact stays readable"
         canonical
         (Tool_blob_store.fetch
            (Tool_blob_store.create ~base_path)
            ~sha256:artifact.Tool_output.sha256
          |> Result.get_ok
          |> Option.get))
;;

let () =
  Alcotest.run
    ~and_exit:false
    "keeper_recovery_transmission"
    [ ( "actual-view"
      , [ test_case
            "projected wire and cap preserve canonical history and original access"
            `Quick
            test_actual_transmission_cap_metrics_checkpoint_and_reader
        ; test_case
            "reader absence and source mismatch refuse before I/O"
            `Quick
            test_missing_reader_and_changed_prefix_perform_no_io
        ; test_case
            "real appended result completes an open source Tool tail"
            `Quick
            test_real_result_completes_open_source_tail
        ; test_case
            "recovery view requires actual binding Tool support"
            `Quick
            test_recovery_requires_actual_binding_tool_support
        ; test_case
            "summarized Image reaches text runtime with canonical source intact"
            `Quick
            test_summarized_image_reaches_text_runtime_without_source_rewrite
        ] )
    ];
  Option.iter
    (fun value ->
       Printf.printf
         "RECOVERY_TRANSMISSION_HTTP_EVIDENCE %s\n%!"
         (Yojson.Safe.to_string value))
    !evidence
;;
