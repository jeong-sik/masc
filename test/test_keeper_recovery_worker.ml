open Alcotest
open Masc
module Work = Keeper_recovery_work
module Worker = Keeper_recovery_worker
module Projection = Keeper_recovery_projection
module Checkpoint = Keeper_checkpoint_store
module J = Yojson.Safe.Util

let fixture_evidence = ref None
let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready () |> Result.get_ok

let ok = function
  | Ok x -> x
  | Error e -> fail (Work.error_to_string e)
;;

let changed = function
  | { Work.value; lock_release_error = None } -> value
  | _ -> fail "unexpected lock release failure"
;;

let write path content =
  let ch = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out ch) (fun () -> output_string ch content)
;;

let digest s = Digestif.SHA256.(to_hex (digest_string s))

let checkpoint marker =
  let open Agent_core.Types in
  let message role content =
    { role; content; name = None; tool_call_id = None; metadata = [] }
  in
  let messages =
    [ message User [ Text "Keep the required task and its source" ]
    ; message
        Assistant
        [ ToolUse
            { id = "exact-call-1"; name = "keeper_artifact_read"; input = `Assoc [] }
        ]
    ; message
        Tool
        [ ToolResult
            { tool_use_id = "exact-call-1"
            ; content = marker
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ]
  in
  Agent_core.Checkpoint.
    { version = checkpoint_version
    ; session_id = "recovery-trace"
    ; agent_name = "recovery"
    ; model = "fixture"
    ; system_prompt = None
    ; messages
    ; usage = empty_usage
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
    ; response_format = Off
    ; thinking_budget = None
    ; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync ()
    ; mcp_sessions = []
    ; working_context = None
    }
;;

let tool_call id name args =
  Yojson.Safe.to_string
    (`Assoc
        [ "id", `String "fixture-response"
        ; "model", `String "recovery-fixture"
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
                                  [ "id", `String id
                                  ; "type", `String "function"
                                  ; ( "function"
                                    , `Assoc
                                        [ "name", `String name
                                        ; ( "arguments"
                                          , `String (Yojson.Safe.to_string args) )
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

let start_server ~sw ~net respond =
  let requests = ref [] in
  let callback _connection _request body =
    let body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let json = Yojson.Safe.from_string body in
    requests := json :: !requests;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:(respond json) ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, n) -> n
    | _ -> fail "expected TCP listener"
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun e -> raise e));
  Printf.sprintf "http://127.0.0.1:%d" port, requests
;;

let requirements =
  Worker.
    [ { reference_id = "task:required"
      ; positions = Projection.[ { message_index = 0; reason = Task_contract } ]
      }
    ; { reference_id = "user:direct"
      ; positions = Projection.[ { message_index = 0; reason = User_instruction } ]
      }
    ]
;;

let with_fixture f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  Fs_compat.set_fs env#fs;
  let saved_runtime = Runtime.For_testing.snapshot () in
  let saved_catalog = Llm_provider.Model_catalog.global () in
  let base_path = Filename.temp_file "recovery-worker-" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore saved_runtime;
    (match saved_catalog with
     | None -> Llm_provider.Model_catalog.clear_global ()
     | Some c -> Llm_provider.Model_catalog.set_global c);
    Fs_compat.remove_tree base_path);
  let config = Workspace.default_config base_path in
  ignore (Keeper_fs.ensure_dir (Workspace.masc_root_dir config));
  let session_dir = Filename.concat base_path "session" in
  let save marker =
    (match Checkpoint.save_agent_core_classified ~session_dir (checkpoint marker) with
     | Ok _ -> ()
     | Error e -> fail e);
    match
      Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id:"recovery-trace"
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "source checkpoint unavailable"
  in
  let referenced_body = "Actual stored Tool result: the source measurement was 37." in
  let referenced =
    Tool_blob_store.put_durable
      (Tool_blob_store.create ~base_path)
      ~bytes:referenced_body
      ~mime:"text/plain"
  in
  let source =
    save
      (Yojson.Safe.to_string
         (`Assoc
             [ ( "stored_output"
               , `String
                   (Tool_output.encode_for_agent_core (Tool_output.Stored referenced)) )
             ; ( "notes"
               , `String
                   ("한글 source marker "
                    ^ String.make (2 * Keeper_artifact_read.maximum_max_bytes) 'x') )
             ]))
  in
  let current = ref source in
  let path =
    Checkpoint.agent_core_checkpoint_path ~session_dir ~session_id:"recovery-trace"
  in
  let work =
    Work.create
      ~config
      ~keeper_name:(Keeper_id.Keeper_name.of_string "recovery" |> Result.get_ok)
      ~admission_id:"refused-admission"
      ~source
      ~failures:
        [ ( "fixture.sample"
          , Agent_core.Error.Api
              (Agent_core.Retry.ContextOverflow
                 { message = "observed refusal"; limit = Some 8192 }) )
        ]
      ~pending_stimulus_ids:[ "stimulus-a"; "stimulus-b" ]
      ~required_source_refs:[ "task:required"; "user:direct" ]
      ~source_watermark:"queue-revision-1"
    |> ok
    |> changed
  in
  let configure endpoint =
    let catalog_path = Filename.concat base_path "models.toml" in
    write
      catalog_path
      {|[[models]]
id_prefix = "recovery-fixture"
provider_name = "fixture"
base = "openai_chat"
max_context_tokens = 1048576
max_output_tokens = 4096
supports_tools = true
supports_native_streaming = false
|};
    (match Llm_provider.Model_catalog.load_file catalog_path with
     | Ok c -> Llm_provider.Model_catalog.set_global c
     | Error e -> fail e);
    let config_path = Filename.concat base_path "runtime.toml" in
    write
      config_path
      (Printf.sprintf
         {|[runtime]
default = "fixture.sample"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = %S
[models.sample]
api-name = "recovery-fixture"
streaming = false
[fixture.sample]
|}
         endpoint);
    match Runtime.init_default_degraded_report ~config_path with
    | Ok Runtime.Initialized -> ()
    | Ok (Runtime.Initialized_degraded _) -> fail "fixture catalog is unavailable"
    | Error e -> fail (Runtime.strict_init_error_to_string e)
  in
  f env sw config work source current path save configure (referenced, referenced_body)
;;

let run
      env
      sw
      config
      work
      current
      ?observe_current_source
      ?on_request_wire_observation
      ?on_observation
      ()
  =
  Worker.run
    ~config
    ~work_id:(Work.id work)
    ~expected_revision:(Work.revision work)
    ~instance_id:"worker-instance"
    ~runtime_id:"fixture.sample"
    ~purpose:"Preserve the required request and summarize the closed Tool result"
    ~requirements
    ~observe_current_source:
      (Option.value observe_current_source ~default:(fun () -> Ok !current))
    ?on_request_wire_observation
    ?on_observation
    ~sw
    ~net:env#net
    ()
;;

let proposal sha protect =
  `Assoc
    [ "source_sha256", `String sha
    ; ( "steps"
      , `List
          (let retain i =
             `Assoc
               [ "kind", `String "retain"
               ; "first_atom", `Int i
               ; "last_atom", `Int i
               ; "text", `Null
               ]
           in
           let summary first =
             `Assoc
               [ "kind", `String "summarize"
               ; "first_atom", `Int first
               ; "last_atom", `Int 1
               ; ( "text"
                 , `String
                     "The closed artifact read returned the source marker and repeated x \
                      bytes." )
               ]
           in
           if protect then [ retain 0; summary 1 ] else [ summary 0 ]) )
    ]
;;

let reload config work = Work.load ~config ~id:(Work.id work) |> ok |> Option.get

let test_one_worker_reads_pages_and_submits () =
  with_fixture
    (fun
        env
         sw
         config
         work
         source
         current
         path
         _
         configure
         (referenced, referenced_body)
       ->
       let canonical = Fs_compat.load_file path in
       (* Begin inside the Korean codepoint, so the actual page handler must return
     Base64. Then read from zero through the handler's exact next_offset. *)
       let split_offset = String.index canonical '\237' + 1 in
       let calls = ref 0
       and produced_pages = ref [] in
       let read ?(sha256 = Work.source_artifact_sha256 work) offset =
         incr calls;
         tool_call
           ("read-" ^ string_of_int !calls)
           "keeper_artifact_read"
           (`Assoc [ "sha256", `String sha256; "offset", `Int offset ])
       in
       let respond request =
         let messages = J.(request |> member "messages" |> to_list) in
         let tool_messages =
           List.filter (fun m -> J.member "role" m = `String "tool") messages
         in
         match List.rev tool_messages with
         | [] -> read split_offset
         | latest :: _ ->
           let page =
             J.(latest |> member "content" |> to_string |> Yojson.Safe.from_string)
           in
           produced_pages
           := (J.(latest |> member "tool_call_id" |> to_string), page) :: !produced_pages;
           if !calls = 1
           then read 0
           else if
             J.(page |> member "eof" |> to_bool)
             && J.member "sha256" page = `String (Work.source_artifact_sha256 work)
           then read ~sha256:referenced.Tool_output.sha256 0
           else if J.(page |> member "eof" |> to_bool)
           then
             tool_call
               "proposal-exact"
               "keeper_recovery_propose"
               (proposal (Work.source_artifact_sha256 work) true)
           else read J.(page |> member "next_offset" |> to_int)
       in
       let endpoint, requests = start_server ~sw ~net:env#net respond in
       configure endpoint;
       let wire = ref []
       and observed = ref [] in
       let outcome =
         run
           env
           sw
           config
           work
           current
           ~on_observation:(fun value -> observed := value :: !observed)
           ~on_request_wire_observation:
             (fun
               ~runtime_id ~max_request_body_bytes ~body_bytes ~serialized ->
             wire
             := (runtime_id, max_request_body_bytes, body_bytes, Option.is_some serialized)
                :: !wire)
           ()
       in
       let submitted =
         match outcome with
         | Worker.Proposal_recorded s -> s
         | Worker.Stopped s -> fail (Worker.cause_to_string s.cause)
       in
       (match submitted.execution with
        | Ok _ -> ()
        | Error e -> fail (Agent_core.Error.to_string e));
       check
         int
         "no second formatting model call after terminal submission"
         (!calls + 1)
         (List.length !requests);
       check int "one receipt per produced page" !calls (List.length submitted.reads);
       check
         int
         "page and terminal observations are forwarded"
         (!calls + 1)
         (List.length !observed);
       check
         int
         "existing final wire observer receives every model request"
         (List.length !requests)
         (List.length !wire);
       List.iter
         (fun (id, cap, bytes, serialized) ->
            check string "actual configured runtime" "fixture.sample" id;
            check (option int) "no invented cap" None cap;
            check bool "exact serialized wire observed" true (bytes > 0 && serialized))
         !wire;
       List.iter
         (fun (receipt : Worker.read_receipt) ->
            let page = List.assoc receipt.tool_use_id !produced_pages in
            check
              string
              "encoded content digest is exact"
              (digest J.(page |> member "content" |> to_string))
              receipt.returned_content_sha256;
            check
              int
              "receipt preserves source byte offset"
              J.(page |> member "offset" |> to_int)
              receipt.offset;
            check
              int
              "receipt preserves source next offset"
              J.(page |> member "next_offset" |> to_int)
              receipt.next_offset;
            check
              string
              "receipt retains recovery's immutable source binding"
              (Work.source_artifact_sha256 work)
              receipt.recovery_source_sha256;
            check
              string
              "receipt identifies the actual artifact read"
              J.(page |> member "sha256" |> to_string)
              receipt.artifact_sha256;
            check
              (option string)
              "receipt runtime correlation"
              (Some "fixture.sample")
              receipt.runtime_id;
            check
              string
              "encoding corresponds to the actual page"
              (match receipt.encoding with
               | Worker.Utf_8 -> "utf-8"
               | Worker.Base64 -> "base64")
              J.(page |> member "encoding" |> to_string))
         submitted.reads;
       check
         bool
         "mid-codepoint page is explicitly Base64"
         true
         (List.exists
            (fun (r : Worker.read_receipt) ->
               r.offset = split_offset && r.encoding = Worker.Base64)
            submitted.reads);
       let reference_receipt =
         List.find
           (fun (r : Worker.read_receipt) ->
              r.artifact_sha256 = referenced.Tool_output.sha256)
           submitted.reads
       in
       let reference_page = List.assoc reference_receipt.tool_use_id !produced_pages in
       check
         string
         "the referenced stored Tool result is actually read"
         referenced_body
         J.(reference_page |> member "content" |> to_string);
       (match Checkpoint.exact_snapshot_messages source with
        | [ _
          ; _
          ; { Agent_core.Types.content = [ Agent_core.Types.ToolResult result ]; _ }
          ] ->
          check
            string
            "canonical source actually contains the stored artifact reference"
            (Tool_output.encode_for_agent_core (Tool_output.Stored referenced))
            J.(
              Yojson.Safe.from_string result.content
              |> member "stored_output"
              |> to_string)
        | _ -> fail "canonical Tool pair shape changed");
       let first_request = List.hd (List.rev !requests) in
       let messages = J.(first_request |> member "messages" |> to_list) in
       let manifest =
         List.find (fun m -> J.member "role" m = `String "user") messages
         |> J.member "content"
         |> J.to_string
         |> Yojson.Safe.from_string
       in
       let source_index =
         Projection.index
           ~source
           ~required:
             (List.concat_map
                (fun (r : Worker.requirement_binding) -> r.positions)
                requirements)
         |> Result.get_ok
       in
       check
         (list string)
         "prompt contains manifest only, no canonical source field"
         [ "atoms"
         ; "pending_stimulus_ids"
         ; "purpose"
         ; "required_refs"
         ; "source_bytes"
         ; "source_sha256"
         ; "source_watermark"
         ; "work_id"
         ]
         (J.to_assoc manifest |> List.map fst |> List.sort String.compare);
       check
         string
         "manifest carries the exact atom metadata"
         (Yojson.Safe.to_string
            (`List (List.map Projection.atom_to_yojson (Projection.atoms source_index))))
         (Yojson.Safe.to_string (J.member "atoms" manifest));
       (match Projection.segments submitted.validated with
        | [ Projection.Original [ _ ]; Projection.Derived d ] ->
          check int "closed Tool pair starts at original assistant" 1 d.first_message;
          check int "closed Tool pair ends at original Tool result" 2 d.last_message
        | _ -> fail "required original and whole Tool pair projection were not preserved");
       let stored = reload config work in
       Work.verify_artifacts config stored |> ok;
       check
         (list string)
         "pending stimuli survive worker publication"
         [ "stimulus-a"; "stimulus-b" ]
         (Work.pending_stimulus_ids stored);
       let body =
         Tool_blob_store.fetch
           (Tool_blob_store.create ~base_path:config.base_path)
           ~sha256:submitted.receipt.proposal_artifact_sha256
         |> Result.get_ok
         |> Option.get
         |> Yojson.Safe.from_string
       in
       check
         string
         "durable envelope owns exact terminal invocation"
         "proposal-exact"
         J.(body |> member "proposal_invocation" |> member "tool_use_id" |> to_string);
       check
         string
         "durable envelope preserves actual page receipts"
         (Yojson.Safe.to_string
            (`List (List.map Worker.read_receipt_to_yojson submitted.reads)))
         (Yojson.Safe.to_string (J.member "handler_page_receipts" body));
       check
         string
         "canonical source bytes and Tool identity remain untouched"
         canonical
         (Fs_compat.load_file path);
       fixture_evidence
       := Some
            (`Assoc
                [ ( "scope"
                  , `String "actual local HTTP fixture; scripted peer, no external model"
                  )
                ; "canonical_sha256", `String (digest canonical)
                ; "http_requests", `Int (List.length !requests)
                ; ( "handler_page_receipts"
                  , `List (List.map Worker.read_receipt_to_yojson submitted.reads) )
                ; "proposal_receipt", Worker.proposal_receipt_to_yojson submitted.receipt
                ; "application", `String "not performed"
                ; "partial_restart", `String "not performed"
                ]))
;;

let test_proposal_cannot_publish_against_changed_source () =
  with_fixture (fun env sw config work _ current path save configure _ ->
    let endpoint, requests =
      start_server ~sw ~net:env#net (fun _ ->
        current := save "new canonical bytes";
        tool_call
          "stale-proposal"
          "keeper_recovery_propose"
          (proposal (Work.source_artifact_sha256 work) true))
    in
    configure endpoint;
    (match run env sw config work current () with
     | Worker.Stopped { cause = Worker.Projection_rejected Projection.Source_changed; _ }
       -> ()
     | Worker.Stopped s -> fail (Worker.cause_to_string s.cause)
     | Worker.Proposal_recorded _ -> fail "stale source proposal published");
    check int "one actual submission attempt" 1 (List.length !requests);
    (match Work.status (reload config work) with
     | Work.Failed (Work.Proposal_invalid _) -> ()
     | _ -> fail "typed proposal rejection missing from durable work");
    check
      string
      "new source is not overwritten by recovery"
      (Checkpoint.exact_snapshot_canonical_bytes !current)
      (Fs_compat.load_file path))
;;

let test_required_original_cannot_be_summarized () =
  with_fixture (fun env sw config work _ current _ _ configure _ ->
    let endpoint, _ =
      start_server ~sw ~net:env#net (fun _ ->
        tool_call
          "invalid-proposal"
          "keeper_recovery_propose"
          (proposal (Work.source_artifact_sha256 work) false))
    in
    configure endpoint;
    (match run env sw config work current () with
     | Worker.Stopped
         { cause = Worker.Projection_rejected (Projection.Protected_atom 0); _ } -> ()
     | Worker.Stopped s -> fail (Worker.cause_to_string s.cause)
     | Worker.Proposal_recorded _ -> fail "required source instruction was summarized");
    match Work.status (reload config work) with
    | Work.Failed (Work.Proposal_invalid _) -> ()
    | _ -> fail "required source rejection not durable")
;;

let test_source_io_failure_settles_claim () =
  with_fixture (fun env sw config work _ current path _ _ _ ->
    let before = Fs_compat.load_file path in
    (match
       run
         env
         sw
         config
         work
         current
         ~observe_current_source:(fun () ->
           raise (Sys_error "fixture source read failed"))
         ()
     with
     | Worker.Stopped
         { cause = Worker.Source_observation_failed "fixture source read failed"
         ; execution = None
         ; _
         } -> ()
     | _ -> fail "source I/O exception escaped without typed settlement");
    (match Work.status (reload config work) with
     | Work.Failed (Work.Source_access_unavailable _) -> ()
     | _ -> fail "claimed work remained running after source I/O failure");
    check
      string
      "source failure does not change canonical bytes"
      before
      (Fs_compat.load_file path))
;;

let test_published_proposal_survives_observer_failure () =
  with_fixture (fun env sw config work _ current path _ configure _ ->
    let before = Fs_compat.load_file path in
    let endpoint, requests =
      start_server ~sw ~net:env#net (fun _ ->
        tool_call
          "published-exact"
          "keeper_recovery_propose"
          (proposal (Work.source_artifact_sha256 work) true))
    in
    configure endpoint;
    let outcome =
      run
        env
        sw
        config
        work
        current
        ~on_observation:(function
          | Worker.Proposal_persisted _ -> failwith "fixture receipt delivery failed"
          | Worker.Page_produced _ -> ())
        ()
    in
    (match outcome with
     | Worker.Proposal_recorded { execution = Error _; receipt; _ } ->
       check
         string
         "publication receipt survives late delivery failure"
         "published-exact"
         receipt.tool_use_id
     | Worker.Proposal_recorded { execution = Ok _; _ } ->
       fail "late Tool result failure was hidden"
     | Worker.Stopped _ -> fail "durable proposal was discarded after observer failure");
    check
      int
      "failed receipt delivery does not redispatch proposal"
      1
      (List.length !requests);
    let stored = reload config work in
    (match Work.status stored with
     | Work.Proposal_recorded _ -> ()
     | _ -> fail "late observer failure overwrote durable publication");
    Work.verify_artifacts config stored |> ok;
    check
      string
      "late failure leaves canonical source untouched"
      before
      (Fs_compat.load_file path))
;;

let () =
  Alcotest.run
    "keeper_recovery_worker"
    [ ( "actual-worker"
      , [ test_case
            "one worker reads actual encoded pages and submits a bound proposal"
            `Quick
            test_one_worker_reads_pages_and_submits
        ; test_case
            "changed canonical source refuses publication"
            `Quick
            test_proposal_cannot_publish_against_changed_source
        ; test_case
            "required original cannot be summarized"
            `Quick
            test_required_original_cannot_be_summarized
        ; test_case
            "source I/O failure settles the owned work"
            `Quick
            test_source_io_failure_settles_claim
        ; test_case
            "durable proposal survives late observer failure"
            `Quick
            test_published_proposal_survives_observer_failure
        ] )
    ];
  Option.iter
    (fun json ->
       Printf.printf "RECOVERY_WORKER_HTTP_EVIDENCE %s\n%!" (Yojson.Safe.to_string json))
    !fixture_evidence
;;
