open Alcotest

(* A scripted [muse serve]. The runtime spawns [cli_path serve]; with
   [cli_path = "/bin/sh"] and the script saved as [serve] in the spawn
   directory, [/bin/sh serve] runs it. The shell reads the file rather than
   exec'ing it, so a freshly written script is never busy. *)

module Serve = Runtime_muse_serve
module Msp = Runtime_muse_msp

let shell_quote text = Filename.quote text

type step =
  | Read  (** Read one request line and record it. *)
  | Write of string  (** Write one frame. *)
  | Stderr of string
  | Exit_with of int
  | Mark_spawned of string
  | Trap_term of { marker : string; exit_delay_s : float }
      (** On SIGTERM, touch [marker], take [exit_delay_s] to exit, then exit. *)
  | Idle_until_killed
  | Sleep of float  (** Read nothing for this long. *)
  | Expect_launch of { home : string; native_read : bool }
  | Expect_arguments of string list
      (** Exit 95 unless the arguments after [serve] are exactly these. *)

let init_frame ~granted =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"muse-session-server","version":"1.3.0"},"userAgent":"muse/1.3.0","museHome":"/tmp/muse","platformFamily":"unix","platformOs":"linux","schema":{"version":1,"fingerprint":"sha256:fixture"},"grantedCapabilities":[%s],"experimentalApi":false,"sessionDurability":"durable"}}|}
    (String.concat "," (List.map (Printf.sprintf "%S") granted))
;;

let effective_mode mode =
  `Assoc ["mode", `String (Msp.approval_mode_to_string mode);
          "source", `String "startup"; "lastCommandId", `Null]
;;

let session_result_for_mode mode =
  Yojson.Safe.to_string (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 2;
    "result", `Assoc ["session", `Assoc ["sessionId", `String "s-1";
      "status", `String "idle"; "turnCount", `Int 0; "modelId", `String "muse-spark-1.3";
      "workspaceRoot", `String "/w"; "approvalMode", effective_mode mode];
      "viewCursor", `String "v:1"]])
;;

let session_result = session_result_for_mode Msp.Prompt_unmatched
;;

let approval_mode_result ~id mode =
  Yojson.Safe.to_string (`Assoc ["jsonrpc", `String "2.0"; "id", `Int id;
    "result", `Assoc ["status", `String "accepted"; "commandId", `String "fixture-command";
      "applyOutcome", `String "noop"; "effectiveMode", effective_mode mode]])
;;

let turn_ack =
  {|{"jsonrpc":"2.0","id":3,"result":{"commandId":"c","status":"accepted","turnId":"t-1","startedNewTurn":true,"disposition":"started"}}|}
;;

let turn_started =
  {|{"jsonrpc":"2.0","method":"turn/started","params":{"sessionId":"s-1","turnId":"t-1","commandId":"c","viewCursor":"v:2"}}|}
;;

let agent_started =
  {|{"jsonrpc":"2.0","method":"item/started","params":{"sessionId":"s-1","viewCursor":"v:3","item":{"itemId":"m-1","kind":"agentMessage","turnId":"t-1","revision":1,"status":"inProgress","text":""}}}|}
;;

let delta text =
  Printf.sprintf
    {|{"jsonrpc":"2.0","method":"item/delta","params":{"sessionId":"s-1","viewCursor":"v:4","itemId":"m-1","field":"text","delta":%S}}|}
    text
;;

let tool_started =
  {|{"jsonrpc":"2.0","method":"item/started","params":{"sessionId":"s-1","viewCursor":"v:5","item":{"itemId":"tc-1","kind":"toolCall","turnId":"t-1","revision":1,"status":"inProgress","tool":"write_file","callId":"call_1","args":"{}"}}}|}
;;

let approval_request =
  {|{"jsonrpc":"2.0","id":1,"method":"approval/request","params":{"sessionId":"s-1","approvalId":"a-1","currentRequirementId":{"approvalId":"a-1","sourceIndex":0},"turnId":"t-1","itemId":"tc-1","toolCallId":"call_1","toolName":"write_file","rawArgs":"{}","subject":{"kind":"fileAccess","access":"write"},"availableChoices":[{"choiceId":"allow_once","decision":"approved","label":"Allow","scope":"once"},{"choiceId":"deny","decision":"denied","label":"Deny","scope":"once"}],"judgeEscalated":false,"protectedWrite":false,"taskId":"tc-1","viewCursor":"v:6"}}|}
;;

let decide_result =
  {|{"jsonrpc":"2.0","id":4,"result":{"commandId":"c","status":"accepted","approvalId":"a-1","terminal":true}}|}
;;

let tool_completed =
  {|{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"s-1","viewCursor":"v:7","item":{"itemId":"tc-1","kind":"toolCall","turnId":"t-1","revision":2,"status":"rejected","tool":"write_file","callId":"call_1","args":"{}"}}}|}
;;

let agent_completed =
  {|{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"s-1","viewCursor":"agent-final","item":{"itemId":"m-1","kind":"agentMessage","turnId":"t-1","revision":2,"status":"completed","text":"MASC_MUSE_OK"}}}|}
;;

let turn_completed =
  {|{"jsonrpc":"2.0","method":"turn/completed","params":{"sessionId":"s-1","turnId":"t-1","terminal":"completed","viewCursor":"terminal-final","usage":{"inputTokens":100,"outputTokens":7,"cachedTokens":50,"reasoningTokens":3}}}|}
;;

let turn_auth_failed =
  {|{"jsonrpc":"2.0","method":"turn/completed","params":{"sessionId":"s-1","turnId":"t-1","terminal":"failed","viewCursor":"v:9","error":{"kind":"authRequired","message":"run muse login","retryable":false}}}|}
;;

let handshake_and_session_with_mode ~granted ~approval_mode =
  [ Read
  ; Write (init_frame ~granted)
  ; Read (* initialized *)
  ; Read (* session/start *)
  ; Write (session_result_for_mode approval_mode)
  ; Read (* turn/start *)
  ; Write turn_ack
  ; Write turn_started
  ]
;;

let handshake_and_session ~granted =
  handshake_and_session_with_mode ~granted ~approval_mode:Msp.Prompt_unmatched
;;

let script_text ~capture ~storage steps =
  let buffer = Buffer.create 1024 in
  let durable = ref [] in
  let retain frame =
    match Yojson.Safe.from_string frame with
    | `Assoc fields ->
      (match List.assoc_opt "method" fields, List.assoc_opt "params" fields with
       | Some (`String method_), Some (`Assoc params)
         when List.mem method_ ["turn/started"; "item/started"; "item/completed"; "item/updated"; "session/tokenUsage"] ->
         let position = `Assoc ["id", `String "fixture-record"; "sequence", `Int 1] in
         let source_range = `Assoc ["first", position; "last", position;
           "stream", `Assoc ["kind", `String "run"; "id", `String "fixture-run"]] in
         let event = `Assoc ["method", `String method_;
           "params", `Assoc (("sourceRange", source_range) :: List.remove_assoc "sourceRange" params)] in
         if not (List.mem event !durable) then durable := event :: !durable
       | _ -> ())
    | _ -> ()
    | exception Yojson.Json_error _ -> ()
  in
  let line text =
    Buffer.add_string buffer text;
    Buffer.add_char buffer '\n'
  in
  line "#!/bin/sh";
  List.iter
    (function
      | Read ->
        line "IFS= read -r request || exit 98";
        line (Printf.sprintf "printf '%%s\\n' \"$request\" >> %s" (shell_quote capture))
      | Write frame ->
        retain frame;
        line (Printf.sprintf "printf '%%s\\n' %s" (shell_quote frame))
      | Stderr text -> line (Printf.sprintf "printf '%%s\\n' %s >&2" (shell_quote text))
      | Exit_with code -> line (Printf.sprintf "exit %d" code)
      | Mark_spawned path -> line (Printf.sprintf "touch %s" (shell_quote path))
      | Trap_term { marker; exit_delay_s } ->
        line
          (Printf.sprintf "trap 'touch %s; sleep %g; exit 0' TERM" (shell_quote marker)
             exit_delay_s)
      | Idle_until_killed -> line "while :; do sleep 0.05; done"
      | Sleep seconds -> line (Printf.sprintf "sleep %g" seconds)
      | Expect_launch { home; native_read } ->
        let home = Unix.realpath home in
        List.iter
          (fun (key, expected) ->
             line (Printf.sprintf "[ \"$%s\" = %s ] || exit 97" key (shell_quote expected)))
          [ "HOME", home
          ; "XDG_DATA_HOME", Filename.concat storage "data"
          ; "XDG_CACHE_HOME", Filename.concat storage "cache"
          ; "XDG_STATE_HOME", Filename.concat storage "state"
          ; "XDG_RUNTIME_DIR", Filename.concat storage "run"
          ; "TMPDIR", Filename.concat storage "tmp"
          ];
        line "[ -z \"${META_API_KEY+x}\" ] || exit 96";
        line "[ \"$TBH_CREDENTIAL_BACKEND\" = file ] || exit 93";
        line (Printf.sprintf "case \"$XDG_CONFIG_HOME\" in %s/*) ;; *) exit 94 ;; esac"
          (shell_quote (Filename.concat (Unix.realpath home) ".local/state/masc/muse-config")));
        line "[ -r \"$XDG_CONFIG_HOME/muse/auth.json\" ] || exit 94";
        line "[ -r \"$XDG_CONFIG_HOME/muse/settings.json\" ] || exit 94";
        line "[ -d \"$TMPDIR\" ] || exit 94";
        if native_read then (
          line "[ \"$#\" = 2 ] || exit 95";
          line "[ \"$1\" = --disable-write ] || exit 95";
          line "[ \"$2\" = --disable-shell ] || exit 95")
        else line "[ \"$#\" = 0 ] || exit 95"
      | Expect_arguments arguments ->
        line (Printf.sprintf "[ \"$*\" = %s ] || exit 95"
          (shell_quote (String.concat " " arguments))))
    steps;
  let page_host = {|import json, sys
events = json.loads(sys.argv[1])
for line in sys.stdin:
    request = json.loads(line)
    with open(sys.argv[2], "a") as capture:
        capture.write(line)
    assert request["method"] == "view/page", request
    assert request["params"]["direction"] == "backward", request
    assert request["params"]["limit"] == 1000, request
    selected = [event for event in events if event["params"]["sessionId"] == request["params"]["sessionId"]]
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                      "result": {"events": selected, "nextCursor": None}}), flush=True)
|} in
  line ("exec python3 -c " ^ shell_quote page_host ^ " "
        ^ shell_quote (Yojson.Safe.to_string (`List (List.rev !durable))) ^ " "
        ^ shell_quote capture);
  Buffer.contents buffer
;;

let native_root dir = Filename.concat dir "native"
let native_storage dir = Serve.Keeper_owned (native_root dir)

let with_script steps f =
  let dir = Filename.temp_dir "masc-muse-serve-" "" in
  let capture = Filename.concat dir "requests.jsonl" in
  let storage = native_root dir in
  Serve.ensure_storage_dirs storage;
  Out_channel.with_open_bin (Filename.concat dir "serve") (fun output ->
    output_string output (script_text ~capture ~storage steps));
  let requests () =
    if Sys.file_exists capture
    then
      In_channel.with_open_bin capture In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (fun line -> line <> "")
      |> List.map Yojson.Safe.from_string
    else []
  in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () -> f ~dir ~requests)
;;

let config
      ?(native = Runtime_native_tools.Native_read)
      ?(admission_timeout_s = 10.)
      ?(timeout_s = 10.)
      ()
  =
  { (Serve.default_config ()) with
    cli_path = "/bin/sh"
  ; native
  ; admission_timeout_s
  ; timeout_s = Some timeout_s
  }
;;

(* The account of the caller's environment, which the scripted host runs on
   unless a test declares a home. *)
let environment_account () =
  Masc_test_deps.authorized_muse Runtime_account_access.Process_environment
;;

let run_scripted ?model ?(workspace_root = "/w") ?storage ?session_mode ?account_home ?prepared_home ?mcp_servers ?workspace_origin ?on_session_ready ?on_prompt_sent ?on_stream_event ?native steps check_result =
  with_script steps (fun ~dir ~requests ->
    Eio_main.run (fun env ->
      let run (type where) (account : where Runtime_account_access.muse_authorized) =
        Serve.run_turn
          ~storage:(Option.value storage ~default:(native_storage dir))
          ?session_mode
          ?mcp_servers
          ?workspace_origin
          ?on_session_ready
          ?on_prompt_sent
          ?on_stream_event
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
          ~account
          {(config ?native ()) with prepared_home; model}
          ~workspace_root
          ~prompt:"say MASC_MUSE_OK"
          ~images:[]
      in
      let result =
        match account_home with
        | None -> run (environment_account ())
        | Some home ->
          run
            (Masc_test_deps.authorized_muse
               (Runtime_account_access.Declared_home (Masc_test_deps.muse_home home)))
      in
      check_result result (requests ())))
;;

let request_with_method method_ requests =
  match
    List.find_opt
      (fun json -> Yojson.Safe.Util.member "method" json = `String method_)
      requests
  with
  | Some json -> json
  | None -> failf "no %s request was written" method_
;;

let params_member name json =
  Yojson.Safe.Util.(json |> member "params" |> member name)
;;

(* A whole turn: text streamed and completed, a built-in tool item, and an
   approval the host asked for anyway, answered from the read posture. *)
let test_native_tool_completion_preserves_vendor_evidence () =
  List.iter (fun (status, expected) ->
    let observed = ref [] in
    let args = {|{"query":"coordination"}|} in
    let output = "vendor-local tool failure: exact output" in
    let frame = Yojson.Safe.to_string (`Assoc
      ["jsonrpc", `String "2.0"; "method", `String "item/completed";
       "params", `Assoc ["sessionId", `String "s-1"; "viewCursor", `String "v:3";
         "item", `Assoc ["itemId", `String "tc-1"; "kind", `String "toolCall";
           "turnId", `String "t-1"; "revision", `Int 2; "status", `String status;
           "tool", `String "unregistered-native-tool"; "callId", `String "call_1";
           "args", `String args; "visibleOutput", `String output]]]) in
    run_scripted
      ~on_stream_event:(function
        | Serve.Native_tool_finished {observation; completion; args; visible_output} ->
          observed := (observation, completion, args, visible_output) :: !observed
        | _ -> ())
      (handshake_and_session ~granted:["eventStream"]
       @ [Write turn_started; Write frame; Write turn_completed])
      (fun result _requests ->
        (match result with Ok _ -> () | Error error -> fail (Serve.error_to_string error));
        match !observed with
        | [(observation, completion, actual_args, actual_output)] ->
          check (option string) "exact vendor tool id" (Some "unregistered-native-tool") observation.tool_name;
          check bool status true (completion.outcome = expected);
          check (option int) "no fabricated exit status" None completion.exit_code;
          check (option string) "arguments" (Some args) actual_args;
          check (option string) "output" (Some output) actual_output
        | _ -> fail "native-only completed item lost its evidence"))
    [ "completed", Runtime_native_tools.Completion_reported
    ; "failed", Runtime_native_tools.Error_reported
    ; "timedOut", Runtime_native_tools.Error_reported
    ; "rejected", Runtime_native_tools.Decline_reported
    ; "cancelled", Runtime_native_tools.Unrecognized_status "cancelled"
    ; "newVendorStatus", Runtime_native_tools.Unrecognized_status "newVendorStatus" ]
;;

let test_turn_with_tool_and_approval () =
  let deltas = Buffer.create 16 in
  let decisions = ref [] in
  let tools = ref 0 in
  let session_ready = ref None in
  let terminal_events = ref [] in
  run_scripted
    ~on_session_ready:(fun ~session_id ~last_turn:_ ->
      session_ready := Some session_id;
      Ok ())
    ~on_stream_event:(function
      | Serve.Text_delta {text; _} -> Buffer.add_string deltas text
      | Serve.Approval_decided { decision; _ } -> decisions := decision :: !decisions
      | Serve.Native_tool_finished _ -> incr tools
      | Serve.Turn_terminal_received Msp.Terminal_completed -> terminal_events := "receipt" :: !terminal_events
      | Serve.Usage_reported _ -> terminal_events := "usage" :: !terminal_events
      | Serve.Turn_finished _ -> terminal_events := "finish" :: !terminal_events
      | _ -> ())
    (handshake_and_session ~granted:[]
     @ [ Write agent_started
       ; Write (delta "MASC_")
       ; Write tool_started
       ; Write approval_request
       ; Read (* approval ack *)
       ; Read (* approval/decide *)
       ; Write decide_result
       ; Write tool_completed
       ; Write (delta "MUSE_OK")
       ; Write agent_completed
       ; Write turn_completed
       ])
    (fun result requests ->
       match result with
       | Error error -> fail (Serve.error_to_string error)
       | Ok turn ->
         check (option string) "reply" (Some "MASC_MUSE_OK") turn.text;
         check string "streamed" "MASC_MUSE_OK" (Buffer.contents deltas);
         check (option string) "session ready" (Some "s-1") !session_ready;
         check int "tool calls" 1 turn.tool_calls;
         check int "tool finished events" 1 !tools;
         check int "approvals" 1 turn.approvals_decided;
         check bool "denied" true (!decisions = [ Msp.Denied ]);
         check bool "resumed" false turn.resumed;
         check (list string) "terminal receipt precedes usage and output finish"
           ["receipt"; "usage"; "finish"] (List.rev !terminal_events);
         (match turn.usage with
          | Some usage -> check int "input tokens" 100 usage.input_tokens
          | None -> fail "usage missing");
         let initialize = request_with_method "initialize" requests in
         check
           bool
           "no user-input dialogs"
           true
           (Yojson.Safe.Util.(
              initialize |> member "params" |> member "capabilities" |> member "userInputDialogs")
            = `Bool false);
         let start = request_with_method "session/start" requests in
         check
           bool
           "read posture selects promptUnmatched"
           true
           (params_member "approvalMode" start = `String "promptUnmatched");
         check bool "no bridge, no config" true (params_member "config" start = `Null);
         check
           bool
           "workspace root"
           true
           (params_member "workspaceRoot" start <> `Null);
         let decide = request_with_method "approval/decide" requests in
         check bool "deny choice" true (params_member "choiceId" decide = `String "deny"))
;;

(* The host compacted the turn's input and still completed it: the event is
   the only trace, so it must reach the stream with its members. Frame shape
   from Muse Code 1.4.0 against a synthetic endpoint (2026-09-28). *)
let compaction_completed =
  {|{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"s-1","viewCursor":"v:6","item":{"itemId":"c-1","kind":"compaction","turnId":"t-1","revision":2,"status":"completed","outcome":"compacted","trigger":"auto","strategyId":"summary-preserved-suffix/v1","tokensBefore":1761964,"tokensAfter":12941}}}|}
;;

(* The receipt is of the [turn/start] line the host read: its count and
   hash, and the prompt as the turn's one text slot. It reaches its observer
   before the prompt-sent report. *)
let test_turn_start_receipt_is_the_line_the_host_read () =
  let receipts = ref [] and sent = ref 0 in
  with_script
    (handshake_and_session ~granted:[]
     @ [ Write agent_started; Write (delta "MASC_MUSE_OK"); Write agent_completed; Write turn_completed ])
    (fun ~dir ~requests:_ ->
      Eio_main.run (fun env ->
        match
          Serve.run_turn
            ~storage:(native_storage dir)
            ~on_prompt_sent:(fun () -> incr sent)
            ~on_context_submission:(fun submission -> receipts := (submission, !sent) :: !receipts)
            ~mgr:(Eio.Stdenv.process_mgr env)
            ~clock:(Eio.Stdenv.clock env)
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
            ~account:(environment_account ())
            (config ())
            ~workspace_root:"/w"
            ~prompt:"say \"MASC\"\nMUSE_OK"
            ~images:[]
        with
        | Error error -> fail (Serve.error_to_string error)
        | Ok _ -> ());
      let line =
        In_channel.with_open_bin (Filename.concat dir "requests.jsonl") In_channel.input_all
        |> String.split_on_char '\n'
        |> List.find (fun line ->
          line <> ""
          && Yojson.Safe.Util.member "method" (Yojson.Safe.from_string line) = `String "turn/start")
      in
      match !receipts with
      | [ ((submission : Serve.context_submission), 0) ] ->
        check int "the receipt names the written request id"
          (Yojson.Safe.Util.(member "id" (Yojson.Safe.from_string line) |> to_int))
          submission.request_id;
        check int "the receipt counts the line the host read" (String.length line)
          submission.write.bytes;
        check string "the receipt hashes the line the host read"
          Agent_core_sha256.(digest_string line |> to_hex) submission.write.sha256;
        check bool "the prompt is the turn's text slot" true
          (Option.is_some
             (Runtime_official_client_write.matching_fragment submission.write
                ~slot:(Turn_text 0) "say \"MASC\"\nMUSE_OK"))
      | receipts ->
        failf "expected one receipt before the prompt-sent report, got %d" (List.length receipts))
;;

let test_compaction_reaches_the_stream () =
  let observed = ref [] in
  run_scripted
    ~on_stream_event:(function
      | Serve.Compaction_observed compaction -> observed := compaction :: !observed
      | _ -> ())
    (handshake_and_session ~granted:[]
     @ [ Write compaction_completed
       ; Write agent_started
       ; Write agent_completed
       ; Write turn_completed
       ])
    (fun result _requests ->
       match result, !observed with
       | Error error, _ -> fail (Serve.error_to_string error)
       | Ok turn, [ compaction ] ->
         check (option string) "the turn still completes" (Some "MASC_MUSE_OK") turn.text;
         check bool "automatic compaction" true
           (compaction.Msp.trigger = Some Msp.Compaction_auto
            && compaction.Msp.outcome = Some Msp.Compaction_compacted);
         check (option int) "tokens before" (Some 1761964) compaction.Msp.tokens_before;
         check (option int) "tokens after" (Some 12941) compaction.Msp.tokens_after
       | Ok _, observed ->
         failf "expected one compaction event, saw %d" (List.length observed))
;;

let test_auth_required () =
  run_scripted
    (handshake_and_session ~granted:[] @ [ Write turn_auth_failed ])
    (fun result _ ->
       match result with
       | Error (Serve.Auth_required message) -> check string "message" "run muse login" message
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "a turn that needs a login must fail")
;;

(* The documented exit codes name why the host stopped. *)
let test_exit_code_is_typed () =
  run_scripted
    [ Read; Stderr "no credentials"; Exit_with 3 ]
    (fun result _ ->
       match result with
       (* Only the status is asserted: stdout can close before the stderr
          drain has read the message. *)
       | Error
           (Serve.Process_exited
             { status = Some Serve.Exit_config_or_credential; turn_accepted = false; _ })
         -> ()
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "an exited host must fail the turn")
;;

let test_bridge_needs_session_mcp () =
  run_scripted
    ~mcp_servers:
      [ { Serve.name = "masc_keeper"
        ; server = Msp.Streamable_http
            { url = "http://127.0.0.1:1/mcp"; headers = []; required = true }; tool_names = [] }
      ]
    [ Read; Write (init_frame ~granted:[]) ]
    (fun result requests ->
       (match result with
        | Error (Serve.Capability_not_granted Msp.Session_mcp) -> ()
        | Error error -> fail (Serve.error_to_string error)
        | Ok _ -> fail "a bridge without sessionMcp must fail");
       let initialize = request_with_method "initialize" requests in
       check
         bool
         "requested sessionMcp"
         true
         (Yojson.Safe.Util.(
            initialize
            |> member "params"
            |> member "capabilities"
            |> member "requestedCapabilities")
          = `List [ `String "sessionMcp" ]))
;;

let probe_mcp_server =
  { Serve.name = "masc_keeper"
  ; server = Msp.Streamable_http
      { url = "http://127.0.0.1:1/mcp"; headers = []; required = true }
  ; tool_names = []
  }
;;

(* Muse Code connects a session's MCP servers only on a host started with
   [--trust-workspace], which also makes it load the workspace's skills and
   rules. Only a directory MASC made, that no session can write, is trusted. *)
let test_trust_needs_a_masc_workspace_no_session_can_write () =
  List.iter
    (fun (workspace_origin, native, mcp_servers, expected) ->
       check bool "workspace trust" expected
         (Serve.trusts_workspace (config ~native ()) ~workspace_origin ~mcp_servers))
    [ Serve.Masc_private, Runtime_native_tools.Native_read, [ probe_mcp_server ], true
    ; Serve.Masc_private, Runtime_native_tools.Native_none, [ probe_mcp_server ], true
    ; Serve.Masc_private, Runtime_native_tools.Native_read, [], false
    ; Serve.Masc_private, Runtime_native_tools.Native_full, [ probe_mcp_server ], false
    ; Serve.Other_tree, Runtime_native_tools.Native_read, [ probe_mcp_server ], false
    ; Serve.Other_tree, Runtime_native_tools.Native_none, [ probe_mcp_server ], false
    ; Serve.Other_tree, Runtime_native_tools.Native_full, [ probe_mcp_server ], false
    ]
;;

(* The host that withholds sessionMcp ends the turn after the launch check,
   so a wrong argument list shows as an exited process instead. *)
let test_launch_arguments_follow_workspace_trust () =
  List.iter
    (fun (workspace_origin, arguments) ->
       run_scripted ~workspace_origin ~mcp_servers:[ probe_mcp_server ]
         [ Expect_arguments arguments; Read; Write (init_frame ~granted:[]) ]
         (fun result _ ->
            match result with
            | Error (Serve.Capability_not_granted Msp.Session_mcp) -> ()
            | Error error -> fail (Serve.error_to_string error)
            | Ok _ -> fail "a host that withholds sessionMcp must fail the turn"))
    [ Serve.Masc_private, [ "--disable-write"; "--disable-shell"; "--trust-workspace" ]
    ; Serve.Other_tree, [ "--disable-write"; "--disable-shell" ]
    ]
;;

let test_native_none_is_config_error () =
  match
    Serve.validate_turn
      (config ~native:Runtime_native_tools.Native_none ())
      ~workspace_root:"/tmp"
      ~prompt:"x"
      ~images:[]
  with
  | Error (Serve.Invalid_config _) -> ()
  | Error error -> fail (Serve.error_to_string error)
  | Ok () -> fail "native posture none must be refused"
;;

let test_selected_homes_do_not_inherit_other_account_roots () =
  let injected =
    [ "HOME", "/synthetic/ambient"
    ; "XDG_CONFIG_HOME", "/synthetic/ambient-config"
    ; "XDG_DATA_HOME", "/synthetic/ambient-data"
    ; "XDG_CACHE_HOME", "/synthetic/ambient-cache"
    ; "XDG_STATE_HOME", "/synthetic/ambient-state"
    ; "XDG_RUNTIME_DIR", "/synthetic/ambient-run"
    ; "META_API_KEY", "synthetic-payg-key"
    ; "TBH_CREDENTIAL_BACKEND", "keychain"
    ]
  in
  let previous = List.map (fun (key, _) -> key, Sys.getenv_opt key) injected in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (key, value) ->
           match value with
           | Some value -> Unix.putenv key value
           | None -> Unix.unsetenv key)
        previous)
    (fun () ->
      List.iter (fun (key, value) -> Unix.putenv key value) injected;
      List.iter
        (fun (native, native_read) ->
           let home = Filename.temp_dir "masc-muse-selected-account-" "" in
           Fun.protect ~finally:(fun () -> Fs_compat.remove_tree home) (fun () ->
             Fs_compat.mkdir_p (Filename.concat home ".config/muse");
             let auth = Filename.concat home ".config/muse/auth.json" in
             let channel = open_out_gen [Open_wronly; Open_creat; Open_excl] 0o600 auth in
             Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
               output_string channel
                 {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-LOCAL-ONLY"}}}|});
             run_scripted ~account_home:home ~native
               (Expect_launch { home; native_read }
                :: handshake_and_session_with_mode ~granted:[]
                     ~approval_mode:(if native_read then Msp.Prompt_unmatched else Msp.Allow_all)
                @ [ Write agent_completed; Write turn_completed ])
               (fun result _ ->
                  match result with
                  | Ok turn -> check (option string) "selected account turn completed" (Some "MASC_MUSE_OK") turn.text
                  | Error error -> fail (Serve.error_to_string error))))
        [ Runtime_native_tools.Native_read, true
        ; Runtime_native_tools.Native_full, false
        ])
;;

let test_prepared_home_is_bound_to_exact_selected_account () =
  let root = Filename.temp_dir "muse-prepared-account-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let account name =
      let home = Filename.concat root name in
      Fs_compat.mkdir_p (Filename.concat home ".config/muse");
      let channel = open_out_gen [Open_wronly; Open_creat; Open_excl] 0o600
        (Filename.concat home ".config/muse/auth.json") in
      Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
        output_string channel {|{"schema_version":1,"providers":{"meta":{"api_key":"SYNTHETIC-ONLY"}}}|});
      home in
    let home_a = account "a" and home_b = account "b" in
    let alias_a = Filename.concat root "alias-a" in
    Unix.symlink home_a alias_a;
    let prepare home = Eio_main.run (fun _ ->
      match Runtime_muse_home.prepare ~account_home:home with
      | Ok value -> value | Error error -> fail (Runtime_muse_home.error_to_string error)) in
    let prepared = prepare home_a and prepared_alias = prepare alias_a in
    check string "configured alias is retained separately" alias_a (Runtime_muse_home.account_home prepared_alias);
    let spawn_marker = Filename.concat root "unexpected-spawn" in
    List.iter (fun account_home ->
      run_scripted ~account_home ~prepared_home:prepared [Mark_spawned spawn_marker] (fun result requests ->
        (match result with
         | Error (Serve.Invalid_config detail) -> check string "account mismatch is explicit"
             "prepared_home does not match the selected account_home" detail
         | Error error -> fail (Serve.error_to_string error)
         | Ok _ -> fail "mixed-account configuration launched");
        check int "mismatch sends no initialize or session request" 0 (List.length requests);
        check bool "mismatch never starts the child process" false (Sys.file_exists spawn_marker)))
      [home_b; alias_a];
    List.iter (fun (home, prepared_home) ->
      run_scripted ~account_home:home ~prepared_home
        (Expect_launch {home; native_read=true} :: handshake_and_session ~granted:[]
         @ [Write agent_completed; Write turn_completed])
        (fun result _ -> match result with
         | Ok turn -> check (option string) "matching account completes" (Some "MASC_MUSE_OK") turn.text
         | Error error -> fail (Serve.error_to_string error)))
      [home_a, prepared; alias_a, prepared_alias];
    Unix.unlink alias_a;
    Unix.symlink home_b alias_a;
    check string "retargeted alias keeps configured identity" alias_a
      (Runtime_muse_home.account_home prepared_alias);
    check string "prepared generation keeps physical account" (Unix.realpath home_a)
      (Runtime_muse_home.physical_home prepared_alias);
    run_scripted ~account_home:alias_a ~prepared_home:prepared_alias
      (Expect_launch {home=home_a; native_read=true} :: handshake_and_session ~granted:[]
       @ [Write agent_completed; Write turn_completed])
      (fun result _ -> match result with
       | Ok turn -> check (option string) "retarget cannot split child roots from auth" (Some "MASC_MUSE_OK") turn.text
       | Error error -> fail (Serve.error_to_string error)))
;;

(* A per-call root is removed once the call returns, so no session in it can
   be resumed; a relative root would resolve against the server's cwd. Both
   are refused before the host is spawned. *)
let test_storage_that_cannot_hold_the_session_is_refused_before_spawn () =
  let root = Filename.temp_dir "muse-storage-refusal-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let spawn_marker = Filename.concat root "unexpected-spawn" in
    let resume = Serve.Resume { session_id = "s-1"; expected_last_turn = Serve.Exactly None } in
    List.iter
      (fun (storage, session_mode) ->
         run_scripted ~storage ~session_mode [ Mark_spawned spawn_marker ] (fun result requests ->
           (match result with
            | Error (Serve.Invalid_config _) -> ()
            | Error error -> fail (Serve.error_to_string error)
            | Ok _ -> fail "refused storage reached the client");
           check int "nothing dispatched" 0 (List.length requests);
           check bool "the host was never spawned" false (Sys.file_exists spawn_marker)))
      [ Serve.Stateless root, resume
      ; Serve.Stateless "relative-root", Serve.Start
      ; Serve.Keeper_owned "relative-root", resume
      ])
;;

(* A Muse process starts only on an authorized account, which is made from a
   declared home, so a malformed home is refused before any process exists. *)
let test_invalid_account_home_is_refused () =
  List.iter (fun account_home ->
    match Runtime_account_access.declare_muse_home account_home with
    | Error (_ : string) -> ()
    | Ok (_ : Runtime_account_access.muse_home) ->
      failf "the malformed account home %S was declared" account_home)
    [ "relative-account"; "/absolute/account "; " /absolute/account" ]
;;

let test_valid_image_inputs_use_shared_official_media_contract () =
  List.iter (fun media_type ->
    let images = [{Serve.media_type; base64_data="aGVsbG8="}] in
    match Serve.validate_turn (config ()) ~workspace_root:"/w" ~prompt:"Inspect image" ~images with
    | Ok () -> ()
    | Error error -> fail (Serve.error_to_string error))
    Runtime_official_client_tool.official_client_image_media_types
;;

(* The host reads one JSON line per request, so a string that is not UTF-8 is
   refused before the shared media type and Base64 rules look at the image. *)
let test_refused_images_name_the_image_and_the_reason () =
  let refusal images =
    match Serve.validate_turn (config ()) ~workspace_root:"/w" ~prompt:"Inspect image" ~images with
    | Ok () -> fail "the images were accepted"
    | Error (Serve.Invalid_config detail) -> detail
    | Error other -> fail (Serve.error_to_string other)
  in
  let image media_type base64_data : Serve.image_input = { media_type; base64_data } in
  check string "a media type outside the set"
    ("images[1].media_type \"image/tiff\" is not one of "
     ^ String.concat ", " Runtime_official_client_tool.official_client_image_media_types)
    (refusal [ image "image/png" "aGVsbG8="; image "image/tiff" "aGVsbG8=" ]);
  check string "data that is not Base64"
    "images[0].base64_data must contain valid Base64 data"
    (refusal [ image "image/png" "not base64!" ]);
  check string "a media type that is not UTF-8"
    "images[0].media_type is not valid UTF-8"
    (refusal [ image "image/png\xff" "aGVsbG8=" ])
;;

let test_session_identity_is_verified_before_admission () =
  let frame ~model ~workspace =
    Yojson.Safe.to_string (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 2;
      "result", `Assoc ["session", `Assoc ["sessionId", `String "s-1";
        "turnCount", `Int 0; "modelId", model; "workspaceRoot", workspace;
        "approvalMode", effective_mode Msp.Prompt_unmatched]]]) in
  let with_id id source = match Yojson.Safe.from_string source with
    | `Assoc fields -> Yojson.Safe.to_string (`Assoc (("id", `Int id) :: List.remove_assoc "id" fields))
    | _ -> fail "fixture response must be an object" in
  List.iter (fun session_mode ->
    let prefix result = [Read; Write (init_frame ~granted:[]); Read; Read; Write result] in
    List.iter (fun (model, workspace, expected) ->
      let ready = ref false and sent = ref false in
      run_scripted ~model:"requested-model" ~workspace_root:"/requested-workspace" ~session_mode
        ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> ready := true; Ok ())
        ~on_prompt_sent:(fun () -> sent := true)
        (prefix (frame ~model ~workspace))
        (fun result requests ->
          (match expected, result with
           | `Model reported, Error (Serve.Session_model_mismatch {requested; resumed}) ->
             check string "requested model" "requested-model" requested;
             check (option string) "reported model" reported resumed
           | `Workspace reported, Error (Serve.Session_workspace_mismatch {requested; reported=actual}) ->
             check string "requested workspace" "/requested-workspace" requested;
             check (option string) "reported workspace" reported actual
           | _, Error error -> fail (Serve.error_to_string error)
           | _, Ok _ -> fail "mismatched session dispatched a turn");
          check bool "identity mismatch never persists session" false !ready;
          check bool "identity mismatch never acknowledges a prompt" false !sent;
          check int "only initialize, initialized and session open are sent" 3 (List.length requests)))
      ((match session_mode with
        (* A resumed session's model is selected, not checked, see
           test_resumed_session_model_is_selected_before_admission. *)
        | Serve.Resume _ -> []
        | Serve.Start ->
          [`String "wrong-model", `String "/requested-workspace", `Model (Some "wrong-model");
           `Null, `String "/requested-workspace", `Model None])
       @ [`String "requested-model", `String "/wrong-workspace", `Workspace (Some "/wrong-workspace");
          `String "requested-model", `Null, `Workspace None]);
    let ready = ref 0 in
    let resume_steps, turn_id = match session_mode with
      | Serve.Start -> [], 3
      | Serve.Resume _ ->
        [Read; Write {|{"jsonrpc":"2.0","id":3,"result":{"commandId":"c-model","status":"accepted"}}|};
         Read; Write (approval_mode_result ~id:4 Msp.Prompt_unmatched)], 5 in
    run_scripted ~model:"requested-model" ~workspace_root:"/requested-workspace" ~session_mode
      ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> incr ready; Ok ())
      (prefix (frame ~model:(`String "requested-model") ~workspace:(`String "/requested-workspace"))
       @ resume_steps @ [Read; Write (with_id turn_id turn_ack); Write turn_started;
                          Write agent_completed; Write turn_completed])
      (fun result requests ->
        (match result with Ok turn -> check (option string) "matching session completes" (Some "MASC_MUSE_OK") turn.text
         | Error error -> fail (Serve.error_to_string error));
        check int "matching identity persists once" 1 !ready;
        check bool "only a resume selects the model"
          (match session_mode with Serve.Resume _ -> true | Serve.Start -> false)
          (List.exists (fun json ->
             Yojson.Safe.Util.member "method" json = `String "session/setModel") requests);
        ignore (request_with_method "turn/start" requests)))
    [Serve.Start; Serve.Resume {session_id="s-1"; expected_last_turn=Serve.Exactly None}]
;;

(* Frames shaped as Muse Code 1.4.0 answered them on 2026-09-28. A session
   started on muse-spark-1.3 resumes reporting the account default
   muse-spark-1.3-contributor, which is the host's metadata, not the model it
   runs. setModel is accepted with a bare ack either way: after a
   session/modelChanged notification when the selection changes the model
   (no turn had run yet), or alone when the host answers noop because that
   model already runs (a turn had). The model is selected before the approval
   mode, so the verified approval ack is the last session command before the
   turn. *)
let test_resumed_session_model_is_selected_before_admission () =
  let requested = "muse-spark-1.3" and host_default = "muse-spark-1.3-contributor" in
  let session_frame ~id model = Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "id", `Int id;
        "result", `Assoc ["session", `Assoc ["sessionId", `String "s-1";
          "status", `String "idle"; "turnCount", `Int 0; "modelId", model;
          "providerId", `String "meta"; "workspaceRoot", `String "/w";
          "approvalMode", effective_mode Msp.Prompt_unmatched];
          "viewCursor", `String "v:2"]]) in
  let set_model_ack ~status = Printf.sprintf
      {|{"jsonrpc":"2.0","id":3,"result":{"commandId":"c-model","status":%S}}|} status in
  let model_changed = Printf.sprintf
      {|{"jsonrpc":"2.0","method":"session/modelChanged","params":{"sessionId":"s-1","viewCursor":"v:2","sourceRange":{"stream":{"kind":"session","id":"s-1"},"first":{"id":"r-13","sequence":13},"last":{"id":"r-13","sequence":13}},"modelId":%S,"providerId":"meta","source":"user"},"emittedAtMs":1790589987517}|}
      requested in
  let with_id id source = match Yojson.Safe.from_string source with
    | `Assoc fields -> Yojson.Safe.to_string (`Assoc (("id", `Int id) :: List.remove_assoc "id" fields))
    | _ -> fail "fixture response must be an object" in
  let resumed reported = [Read; Write (init_frame ~granted:[]); Read; Read;
                          Write (session_frame ~id:2 reported)] in
  let run steps check_result =
    let ready = ref 0 and sent = ref false in
    run_scripted ~model:requested ~session_mode:(Serve.Resume {session_id="s-1"; expected_last_turn=Serve.Exactly None})
      ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> incr ready; Ok ())
      ~on_prompt_sent:(fun () -> sent := true)
      steps (fun result requests -> check_result result requests ~ready:!ready ~sent:!sent) in
  let refused ~name ~request_count steps check_error =
    run steps (fun result requests ~ready ~sent ->
      (match result with
       | Error error -> check_error error
       | Ok _ -> failf "%s dispatched a turn" name);
      check int (name ^ " never persists session") 0 ready;
      check bool (name ^ " never sends a prompt") false sent;
      check int (name ^ " request count") request_count (List.length requests)) in
  (* An accepted selection, changed or noop, whatever the session reports
     (another model, none, or the requested one): setModel, then the approval
     mode, then the turn on the requested model. *)
  List.iter (fun (reported, ack) ->
    run (resumed reported @ [Read] @ List.map (fun frame -> Write frame) ack
         @ [Read; Write (approval_mode_result ~id:4 Msp.Prompt_unmatched);
            Read; Write (with_id 5 turn_ack); Write turn_started;
            Write agent_completed; Write turn_completed])
      (fun result requests ~ready ~sent:_ ->
        (match result with
         | Ok turn ->
           check (option string) "re-selected session completes" (Some "MASC_MUSE_OK") turn.text;
           check (option string) "the turn names the selected model" (Some requested) turn.model
         | Error error -> fail (Serve.error_to_string error));
        check int "re-selected session persists once" 1 ready;
        let set_model = request_with_method "session/setModel" requests in
        let params = Yojson.Safe.Util.member "params" set_model in
        check string "setModel names the resumed session" "s-1"
          Yojson.Safe.Util.(params |> member "sessionId" |> to_string);
        check string "setModel names the configured model" requested
          Yojson.Safe.Util.(params |> member "model" |> member "modelId" |> to_string);
        let methods = List.map (fun json ->
          Yojson.Safe.Util.(json |> member "method" |> to_string_option)) requests in
        check (list (option string)) "selection, then approval mode, then the turn"
          [Some "initialize"; Some "initialized"; Some "session/resume";
           Some "session/setModel"; Some "session/setApprovalMode"; Some "turn/start";
           Some "view/page"]
          methods))
    [ `String host_default, [model_changed; set_model_ack ~status:"accepted"]
    ; `String host_default, [set_model_ack ~status:"accepted"]
    ; `Null, [model_changed; set_model_ack ~status:"accepted"]
    ; `String requested, [set_model_ack ~status:"accepted"] ];
  refused ~name:"unaccepted selection" ~request_count:4
    (resumed (`String host_default) @ [Read; Write (set_model_ack ~status:"rejected")])
    (function
      | Serve.Protocol_error {stage="session/setModel"; _} -> ()
      | error -> fail (Serve.error_to_string error));
  refused ~name:"setModel rpc error" ~request_count:4
    (resumed (`String host_default)
     @ [Read; Write {|{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"unknown model"}}|}])
    (function
      | Serve.Rpc_error {method_="session/setModel"; code = -32602; _} -> ()
      | error -> fail (Serve.error_to_string error));
  (* The approval mode is still verified after the selection. *)
  refused ~name:"approval mode after selection" ~request_count:5
    (resumed (`String host_default) @ [Read; Write (set_model_ack ~status:"accepted");
       Read; Write (approval_mode_result ~id:4 Msp.Allow_all)])
    (function
      | Serve.Session_approval_mode_mismatch {requested=asked; reported} ->
        check bool "requested mode" true (asked = Msp.Prompt_unmatched);
        check bool "reported mode" true (reported = Some Msp.Allow_all)
      | error -> fail (Serve.error_to_string error))
;;

(* The model each call ran on is what the host names in session/tokenUsage.
   The turn keeps the session's selection in [model] and lists what the host
   reported for its calls in [call_models], in call order: a named model, or
   [Unnamed] when a call's usage names none. A call like the one before it
   adds nothing, and another session's frames are not the turn's. A last call
   without a model leaves the turn's reported model unknown, not the model an
   earlier call named. *)
let test_call_usage_is_counted_once_in_its_turn () =
  let usage_frame ~cursor ~session ~turn = Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "method", `String "session/tokenUsage";
        "params", `Assoc
          [ "sessionId", `String session; "turnId", `String turn
          ; "viewCursor", `String cursor; "modelId", `String "muse-spark-1.3"
          ; "promptTokens", `Int 150; "totalTokens", `Int 157
          ; "usage", `Assoc
              [ "inputTokens", `Int 100; "outputTokens", `Int 7
              ; "cachedTokens", `Int 50; "reasoningTokens", `Int 3
              ; "cacheReadTokens", `Int 40; "cacheWriteTokens", `Int 10 ] ] ]) in
  let frame cursor = usage_frame ~cursor ~session:"s-1" ~turn:"t-1" in
  let completion usage = Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "method", `String "turn/completed";
        "params", `Assoc
          (["sessionId", `String "s-1"; "turnId", `String "t-1";
            "terminal", `String "completed"; "viewCursor", `String "terminal"] @ usage)]) in
  let terminal_sum = ["usage", `Assoc
      [ "inputTokens", `Int 200; "outputTokens", `Int 14
      ; "cachedTokens", `Int 100; "reasoningTokens", `Int 6 ]] in
  List.iter (fun terminal ->
    let reports = ref [] in
    run_scripted ~on_stream_event:(function
      | Serve.Usage_reported {usage; _} -> reports := usage :: !reports
      | _ -> ())
      (handshake_and_session ~granted:[] @
       [ Write (frame "v:5"); Write (frame "v:5")
       ; Write (usage_frame ~cursor:"v:6" ~session:"other" ~turn:"t-1")
       ; Write (usage_frame ~cursor:"v:7" ~session:"s-1" ~turn:"previous")
       ; Write (frame "v:8"); Write agent_completed; Write (completion terminal) ])
      (fun result _ ->
        match result with
        | Ok {usage=Some usage; _} ->
          check (option int) "counted-once prompt sum" (Some 300) usage.prompt_tokens;
          check int "raw input retained separately" 200 usage.input_tokens;
          check int "output never doubled by terminal aggregate" 14 usage.output_tokens;
          check (option int) "explicit cache reads" (Some 80) usage.cache_read_tokens;
          check int "one terminal observation" 1 (List.length !reports)
        | Ok _ -> fail "missing per-call usage"
        | Error error -> fail (Serve.error_to_string error))) [ []; terminal_sum ]
;;

let test_view_gap_does_not_fabricate_a_turn_total () =
  let frame ?(turn_id = "t-1") cursor = Yojson.Safe.to_string (`Assoc
    [ "jsonrpc", `String "2.0"; "method", `String "session/tokenUsage"
    ; "params", `Assoc
        [ "sessionId", `String "s-1"; "turnId", `String turn_id
        ; "viewCursor", `String cursor; "promptTokens", `Int 150
        ; "usage", `Assoc ["inputTokens", `Int 100; "outputTokens", `Int 7;
                            "cachedTokens", `Int 50; "reasoningTokens", `Int 3] ] ]) in
  let gap session = Yojson.Safe.to_string (`Assoc
    [ "jsonrpc", `String "2.0"; "method", `String "view/gap"
    ; "params", `Assoc (["after", `String "v:5"; "next", `String "v:8"]
        @ match session with None -> [] | Some value -> ["sessionId", value]) ]) in
  let completed aggregate = Yojson.Safe.to_string (`Assoc
    [ "jsonrpc", `String "2.0"; "method", `String "turn/completed"
    ; "params", `Assoc (["sessionId", `String "s-1"; "turnId", `String "t-1";
                         "terminal", `String "completed"; "viewCursor", `String "terminal"] @
        if aggregate then ["usage", `Assoc ["inputTokens", `Int 200;
          "outputTokens", `Int 14; "cachedTokens", `Int 100; "reasoningTokens", `Int 6]]
        else []) ]) in
  List.iter (fun (session, before_ack, aggregate) ->
    let reports = ref [] in
    let handshake = handshake_and_session ~granted:[] in
    let steps = if before_ack then
        List.take 6 handshake @ [Write (gap session)] @ List.drop 6 handshake
        @ [Write (frame "v:5"); Write (frame "v:8")]
      else handshake @ [Write (frame "v:5"); Write (gap session); Write (frame "v:8")] in
    run_scripted ~on_stream_event:(function
      | Serve.Usage_reported {usage; _} -> reports := usage :: !reports
      | _ -> ())
      (steps @ [Write agent_completed; Write (completed aggregate)])
      (fun result _ -> match result with
        | Error error -> fail (Serve.error_to_string error)
        | Ok turn ->
          check bool "durable calls prove the complete turn total" true
            (Option.is_some turn.usage);
          check int "usage stream matches turn result" 1 (List.length !reports);
          Option.iter (fun (usage : Msp.token_usage) ->
            check int "terminal raw input is preserved" 200 usage.input_tokens;
            check (option int) "durable counted-once prompts are recovered"
              (Some 300) usage.prompt_tokens) turn.usage))
    [ Some (`String "s-1"), false, false
    ; None, false, false
    ; Some `Null, false, false
    ; Some (`String "s-1"), true, false
    ; Some (`String "s-1"), false, true
    ; None, true, true
    ; Some (`String "another-session"), false, false
    ; Some (`String "another-session"), true, true
    ];
  List.iter (fun (turn_id, aggregate) ->
    let reports = ref [] in
    let handshake = handshake_and_session ~granted:[] in
    run_scripted ~on_stream_event:(function
      | Serve.Usage_reported {usage; _} -> reports := usage :: !reports
      | _ -> ())
      (List.take 6 handshake @ [Write turn_started; Write (frame ~turn_id "v:3")]
       @ List.drop 6 handshake
       @ [Write (frame "v:5"); Write (frame "v:8");
          Write agent_completed; Write (completed aggregate)])
      (fun result _ -> match result with
        | Error error -> fail (Serve.error_to_string error)
        | Ok turn ->
          check bool "durable pre-ack calls are recovered for this turn" true
            (Option.is_some turn.usage);
          check int "one authoritative usage event escapes" 1 (List.length !reports);
          Option.iter (fun (usage : Msp.token_usage) ->
            let calls = if turn_id = "t-1" then 3 else 2 in
            check int "explicit aggregate remains authoritative"
              (if aggregate then 200 else calls * 100) usage.input_tokens;
            check (option int) "only a matching aggregate gains counted-once prompts"
              (if aggregate && calls = 3 then None else Some (calls * 150)) usage.prompt_tokens) turn.usage))
    [ "t-1", false; "t-1", true
    ; "another-turn", false; "another-turn", true ]
;;

(* The turn keeps its newest call's own counts: that request's counted-once
   prompt is the context it carried. Another session's frame is not the
   turn's. Durable history recovers the newest call across live delivery gaps. *)
let test_turn_keeps_its_newest_call_usage () =
  let frame ?(session = "s-1") ~cursor ~prompt ~output () = Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "method", `String "session/tokenUsage";
        "params", `Assoc
          [ "sessionId", `String session; "turnId", `String "t-1"
          ; "viewCursor", `String cursor; "promptTokens", `Int prompt
          ; "totalTokens", `Int (prompt + output)
          ; "usage", `Assoc
              [ "inputTokens", `Int prompt; "outputTokens", `Int output
              ; "cachedTokens", `Int 0; "reasoningTokens", `Int 0 ] ] ]) in
  let gap = Yojson.Safe.to_string (`Assoc
    [ "jsonrpc", `String "2.0"; "method", `String "view/gap"
    ; "params", `Assoc ["after", `String "v:5"; "next", `String "v:9";
                        "sessionId", `String "s-1"] ]) in
  List.iter (fun (name, frames, expected) ->
    run_scripted
      (handshake_and_session ~granted:[] @ List.map (fun frame -> Write frame) frames
       @ [Write agent_completed; Write turn_completed])
      (fun result _ ->
        match result with
        | Error error -> fail (Serve.error_to_string error)
        | Ok turn ->
          check (option (pair int int)) name expected
            (Option.map (fun (usage : Msp.token_usage) ->
               Option.value usage.prompt_tokens ~default:(-1), usage.output_tokens)
               turn.last_call_usage)))
    [ "no call reported", [], None
    ; "the newest of two calls",
      [ frame ~cursor:"v:5" ~prompt:150 ~output:7 ()
      ; frame ~cursor:"v:8" ~prompt:400 ~output:9 () ],
      Some (400, 9)
    ; "another session's later frame is not the turn's",
      [ frame ~cursor:"v:5" ~prompt:150 ~output:7 ()
      ; frame ~session:"s-2" ~cursor:"v:6" ~prompt:999 ~output:1 () ],
      Some (150, 7)
    ; "a repeated cursor does not replace the newest call",
      [ frame ~cursor:"v:5" ~prompt:150 ~output:7 ()
      ; frame ~cursor:"v:8" ~prompt:400 ~output:9 ()
      ; frame ~cursor:"v:5" ~prompt:150 ~output:7 () ],
      Some (400, 9)
    ; "durable history proves the newest call despite a live gap",
      [ frame ~cursor:"v:5" ~prompt:150 ~output:7 (); gap ],
      Some (150, 7)
    ; "a call after the gap is the newest",
      [ frame ~cursor:"v:5" ~prompt:150 ~output:7 (); gap
      ; frame ~cursor:"v:9" ~prompt:500 ~output:11 () ],
      Some (500, 11)
    ]
;;

let test_turn_lists_the_models_its_calls_ran_on () =
  let token_usage ?(session_id = "s-1") ?(cursor = "v:5") model = Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "method", `String "session/tokenUsage";
        "params", `Assoc (["sessionId", `String session_id; "turnId", `String "t-1";
          "viewCursor", `String cursor;
          "usage", `Assoc ["inputTokens", `Int 10; "outputTokens", `Int 2;
                            "cachedTokens", `Int 0; "reasoningTokens", `Int 0];
          "promptTokens", `Int 10; "totalTokens", `Int 12]
          @ match model with None -> [] | Some model -> ["modelId", model])]) in
  let named ?cursor model = token_usage ?cursor (Some (`String model)) in
  let shown = List.map (function Serve.Named model -> model | Serve.Unnamed -> "<unnamed>") in
  List.iter (fun (frames, expected, reported) ->
    let events = ref [] in
    run_scripted ~model:"muse-spark-1.3"
      ~on_stream_event:(function
        | Serve.Model_call_reported { model; _ } -> events := model :: !events
        | _ -> ())
      (handshake_and_session ~granted:[] @ List.map (fun frame -> Write frame) frames
       @ [Write agent_completed; Write turn_completed])
      (fun result _ ->
        match result with
        | Ok turn ->
          check (option string) "the selection stays the session's"
            (Some "muse-spark-1.3") turn.model;
          check (list string) "what the calls reported" expected (shown turn.call_models);
          check (list string) "one event per change" expected
            (List.rev_map (function Some model -> model | None -> "<unnamed>") !events);
          check (option string) "the model the turn is named after" reported
            (Serve.reported_model turn)
        | Error error -> fail (Serve.error_to_string error)))
    [ [], [], Some "muse-spark-1.3"
    ; [named "muse-spark-1.3"], ["muse-spark-1.3"], Some "muse-spark-1.3"
    ; [ named "muse-spark-1.3-contributor"
      ; token_usage ~session_id:"s-2" ~cursor:"v:6" (Some (`String "other-model"))
      ; named ~cursor:"v:7" "muse-spark-1.3-contributor"
      ; named ~cursor:"v:8" "muse-spark-1.3" ],
      ["muse-spark-1.3-contributor"; "muse-spark-1.3"], Some "muse-spark-1.3"
    ; [named "muse-spark-1.3"; named ~cursor:"v:6" "muse-spark-1.3-contributor";
       named ~cursor:"v:7" "muse-spark-1.3"],
      ["muse-spark-1.3"; "muse-spark-1.3-contributor"; "muse-spark-1.3"], Some "muse-spark-1.3"
    (* Replaying A after B neither adds counts nor rewinds the latest model. *)
    ; [named "muse-spark-1.3"; named ~cursor:"v:6" "muse-spark-1.3-contributor";
       named "muse-spark-1.3"],
      ["muse-spark-1.3"; "muse-spark-1.3-contributor"], Some "muse-spark-1.3-contributor"
    (* Named, then a call with no model, then the terminal. *)
    ; [named "muse-spark-1.3-contributor"; token_usage ~cursor:"v:6" (Some `Null)],
      ["muse-spark-1.3-contributor"; "<unnamed>"], None
    ; [token_usage None; token_usage ~cursor:"v:6" (Some `Null)], ["<unnamed>"], None
    ; [token_usage None; named ~cursor:"v:6" "muse-spark-1.3"], ["<unnamed>"; "muse-spark-1.3"],
      Some "muse-spark-1.3" ]
;;

let test_session_approval_mode_is_verified_before_admission () =
  let frame id result = Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "id", `Int id; "result", result]) in
  let session mode =
    let fields = Yojson.Safe.Util.(Yojson.Safe.from_string session_result
      |> member "result" |> member "session" |> to_assoc) |> List.remove_assoc "approvalMode" in
    `Assoc ["session", `Assoc (match mode with
      | None -> fields | Some value -> ("approvalMode", value) :: fields)] in
  let prefix opened = [Read; Write (init_frame ~granted:[]); Read; Read; Write (frame 2 opened)] in
  let malformed = [Some `Null; Some (`String "promptUnmatched"); Some (`Assoc []);
    Some (`Assoc ["mode", `String "futureMode"]); Some (`Assoc ["mode", `Bool true])] in
  List.iter (fun (native, requested, other) ->
    let refused ~session_mode ~expected ~request_count steps =
      let ready = ref false and sent = ref false in
      run_scripted ~native ~session_mode
        ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> ready := true; Ok ())
        ~on_prompt_sent:(fun () -> sent := true) steps (fun result requests ->
          (match expected, result with
           | `Mismatch reported, Error (Serve.Session_approval_mode_mismatch actual) ->
             check bool "requested posture retained" true (actual.requested = requested);
             check bool "returned mode retained" true (actual.reported = reported)
           | `Protocol stage, Error (Serve.Protocol_error actual) ->
             check string "invalid approval evidence is explicit" stage actual.stage
           | _, Error error -> fail (Serve.error_to_string error)
           | _, Ok _ -> fail "unverified approval mode admitted a turn");
          check bool "unverified mode never persists session" false !ready;
          check bool "unverified mode never dispatches prompt" false !sent;
          check int "only admission requests sent" request_count (List.length requests)) in
    List.iter (fun (mode, expected) ->
      refused ~session_mode:Serve.Start ~expected ~request_count:3
        (prefix (session mode)))
      ((None, `Mismatch None) :: (Some (effective_mode other), `Mismatch (Some other))
       :: List.map (fun mode -> mode, `Protocol "session/start") malformed);
    let resumed = Serve.Resume {session_id="s-1"; expected_last_turn=Serve.Exactly None} in
    List.iter (fun (result, expected) ->
      refused ~session_mode:resumed ~expected ~request_count:4
        (prefix (session (Some (effective_mode other))) @ [Read; Write (frame 3 result)]))
      ((`Assoc ["status", `String "accepted"; "effectiveMode", effective_mode other],
        `Mismatch (Some other))
       :: (`Assoc ["status", `String "rejected"; "effectiveMode", effective_mode requested],
           `Protocol "session/setApprovalMode")
       :: List.map (fun mode ->
           `Assoc (("status", `String "accepted") :: (match mode with
             | None -> [] | Some value -> ["effectiveMode", value])),
           `Protocol "session/setApprovalMode") (None :: malformed));
    (* Resume can correct a prior mode, or establish one the snapshot omitted.
       Only the accepted effective result permits persistence and turn/start. *)
    List.iter (fun (session_mode, prior) ->
      let ready = ref 0 and sent = ref 0 in
      let suffix, turn_id = match session_mode with
        | Serve.Start -> [], 3
        | Serve.Resume _ -> [Read; Write (approval_mode_result ~id:3 requested)], 4 in
      let ack = Yojson.Safe.Util.(Yojson.Safe.from_string turn_ack |> member "result") in
      run_scripted ~native ~session_mode
        ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> incr ready; Ok ())
        ~on_prompt_sent:(fun () -> incr sent)
        (prefix (session prior) @ suffix @ [Read; Write (frame turn_id ack);
          Write turn_started; Write agent_completed; Write turn_completed])
        (fun result requests ->
          (match result with
           | Ok turn -> check (option string) "verified mode completes" (Some "MASC_MUSE_OK") turn.text
           | Error error -> fail (Serve.error_to_string error));
          check int "verified mode persists once" 1 !ready;
          check int "verified mode dispatches once" 1 !sent;
          (match session_mode with
           | Serve.Start -> ()
           | Serve.Resume _ ->
             let change = request_with_method "session/setApprovalMode" requests in
             check bool "resume requests the configured posture" true
               (params_member "mode" change = `String (Msp.approval_mode_to_string requested)))))
      [Serve.Start, Some (effective_mode requested);
       resumed, Some (effective_mode other); resumed, None])
    [Runtime_native_tools.Native_read, Msp.Prompt_unmatched, Msp.Allow_all;
     Runtime_native_tools.Native_full, Msp.Allow_all, Msp.Prompt_unmatched]
;;

let test_nondurable_handshake_never_begins_a_session () =
  let frame = Yojson.Safe.from_string (init_frame ~granted:[]) in
  let frame_fields = Yojson.Safe.Util.to_assoc frame in
  let result_fields = Yojson.Safe.Util.(frame |> member "result" |> to_assoc) in
  List.iter
    (fun session_mode ->
       List.iter
         (fun durability ->
            let fields = List.remove_assoc "sessionDurability" result_fields in
            let fields = match durability with
              | None -> fields
              | Some value -> ("sessionDurability", value) :: fields in
            let response =
              `Assoc (("result", `Assoc fields) :: List.remove_assoc "result" frame_fields)
              |> Yojson.Safe.to_string in
            let session_ready = ref false in
            run_scripted ~session_mode
              ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> session_ready := true; Ok ())
              [ Read; Write response ]
              (fun result requests ->
                 (match durability, result with
                  | Some (`String "ephemeral"), Error Serve.Session_not_durable -> ()
                  | (Some `Null | Some (`String "future")),
                    Error (Serve.Protocol_error { stage = "initialize"; _ }) -> ()
                  | _, Error error -> fail (Serve.error_to_string error)
                  | _, Ok _ -> fail "non-durable host started a session");
                 check bool "session callback not reached" false !session_ready;
                 check int "initialize is the only dispatched request" 1 (List.length requests)))
         [ Some (`String "ephemeral"); Some `Null; Some (`String "future") ])
    [ Serve.Start; Serve.Resume { session_id = "retained-session"; expected_last_turn=Serve.Exactly None } ]
;;

let resume_frame ?(count = 0) last_turn =
  Yojson.Safe.to_string (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 2;
    "result", `Assoc
      (["session", `Assoc
          ["sessionId", `String "s-1"; "workspaceRoot", `String "/w";
           "approvalMode", effective_mode Msp.Prompt_unmatched; "turnCount", `Int count]]
       @ (match last_turn with None -> [] | Some json -> ["lastTurn", json]))])

(* [host_died] is the failed terminal a host synthesizes when it died mid-turn:
   it carries [reason] instead of [error]. *)
let last_turn_json turn_id terminal =
  match terminal with
  | "host_died" ->
    `Assoc ["turnId", `String turn_id; "terminal", `String "failed"; "reason", `String "crash"]
  | "failed" ->
    `Assoc ["turnId", `String turn_id; "terminal", `String terminal;
            "error", `Assoc ["kind", `String "modelError"; "message", `String "fixture";
                             "retryable", `Bool true]]
  | _ -> `Assoc ["turnId", `String turn_id; "terminal", `String terminal]

let resumed_turn_frames =
  let acknowledged_turn = match Yojson.Safe.from_string turn_ack with
    | `Assoc fields -> Yojson.Safe.to_string (`Assoc (("id", `Int 4) :: List.remove_assoc "id" fields))
    | _ -> fail "fixture acknowledgement is not an object" in
  [Read; Write (approval_mode_result ~id:3 Msp.Prompt_unmatched);
   Read; Write acknowledged_turn; Write turn_started; Write agent_completed; Write turn_completed]

let ended turn_id ending = Some ({ Serve.turn_id; ending } : Serve.ended_turn)

(* A resume names the session MASC settled by its last ended turn. A missing,
   malformed or different last turn is refused before anything changes, and
   the host's completed-turn count is not read: a compacted session that
   counts again from 0 still resumes when its last turn is the settled one. *)
let test_resume_requires_the_retained_last_turn () =
  let prefix last_turn =
    [Read; Write (init_frame ~granted:[]); Read; Read; Write (resume_frame last_turn)] in
  let session_mode = Serve.Resume {session_id="s-1";
    expected_last_turn=Serve.Exactly (ended "t-1" Serve.Ended_completed)} in
  List.iter (fun (label, last_turn) ->
    let ready = ref false and sent = ref false in
    run_scripted ~session_mode
      ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> ready := true; Ok ())
      ~on_prompt_sent:(fun () -> sent := true)
      (prefix last_turn)
      (fun result requests ->
        (match result with
         | Error (Serve.Protocol_error {stage="session/resume"; _}) -> ()
         | Error error -> failf "%s: %s" label (Serve.error_to_string error)
         | Ok _ -> failf "%s: an unknown or changed last turn dispatched a turn" label);
        check bool (label ^ ": unverified history never persists admission") false !ready;
        check bool (label ^ ": unverified history never dispatches prompt") false !sent;
        check (list string) (label ^ ": no approval mutation or turn after refused resume")
          ["initialize"; "initialized"; "session/resume"]
          (List.map (fun request -> Yojson.Safe.Util.(request |> member "method" |> to_string)) requests)))
    [ "no last turn", None
    ; "null last turn", Some `Null
    ; "another turn", Some (last_turn_json "t-2" "completed")
    ; "the turn ended otherwise", Some (last_turn_json "t-1" "failed")
    ; "no turn id", Some (`Assoc ["terminal", `String "completed"])
    ; "an unrecognized terminal", Some (last_turn_json "t-1" "paused")
    ; "a failed terminal with neither error nor reason",
      Some (`Assoc ["turnId", `String "t-1"; "terminal", `String "failed"]) ];
  run_scripted ~session_mode
    ([Read; Write (init_frame ~granted:[]); Read; Read;
      Write (resume_frame ~count:0 (Some (last_turn_json "t-1" "completed")))]
     @ resumed_turn_frames)
    (fun result requests ->
      (match result with
       | Ok turn -> check bool "a compacted session with the settled last turn resumes" true turn.resumed
       | Error error -> fail (Serve.error_to_string error));
      ignore (request_with_method "turn/start" requests))
;;

(* [Exactly] admits only the last turn MASC knows of. After a turn whose
   ending MASC did not observe, [Last_or_dispatched] also admits that turn
   however it ended, and any turn while MASC never learned its id; after an
   operator retry, [Last_or_uncompleted] admits the failed turn only if it
   ended uncompleted, and never a host that reports no last turn. Every other
   last turn is refused before admission, and an admitted one reaches the
   caller to be stored. *)
let test_resume_admits_only_the_last_turns_its_expectation_names () =
  let t7 = ended "t-7" Serve.Ended_completed in
  List.iter (fun (label, expected_last_turn, reported, admitted) ->
    let ready = ref None and sent = ref false in
    run_scripted ~session_mode:(Serve.Resume {session_id="s-1"; expected_last_turn})
      ~on_session_ready:(fun ~session_id:_ ~last_turn ->
        ready := Some last_turn; Ok ())
      ~on_prompt_sent:(fun () -> sent := true)
      ([Read; Write (init_frame ~granted:[]); Read; Read;
        Write (resume_frame (Option.map (fun (turn_id, terminal) -> last_turn_json turn_id terminal) reported))]
       @ if admitted then resumed_turn_frames else [])
      (fun result requests ->
        match admitted, result with
        | true, Ok turn ->
          check bool (label ^ " resumes") true turn.resumed;
          let handed = match !ready with
            | Some (Some ({ turn_id; ending } : Serve.ended_turn)) ->
              Some (turn_id, (match ending with
                | Serve.Ended_completed -> "completed" | Serve.Ended_uncompleted -> "uncompleted"))
            | Some None -> Some ("none", "none")
            | None -> None in
          let reported = match reported with
            | Some (turn_id, "completed") -> Some (turn_id, "completed")
            | Some (turn_id, _) -> Some (turn_id, "uncompleted")
            | None -> Some ("none", "none") in
          check (option (pair string string)) (label ^ " hands the host's last turn to the caller")
            reported handed
        | false, Error (Serve.Protocol_error {stage="session/resume"; _}) ->
          check bool (label ^ " never persists admission") true (Option.is_none !ready);
          check bool (label ^ " never dispatches a prompt") false !sent;
          check (list string) (label ^ " sends nothing after the refused resume")
            ["initialize"; "initialized"; "session/resume"]
            (List.map (fun request -> Yojson.Safe.Util.(request |> member "method" |> to_string))
               requests)
        | true, Error error -> failf "%s: %s" label (Serve.error_to_string error)
        | false, Error error -> failf "%s: refused for another reason: %s" label
            (Serve.error_to_string error)
        | false, Ok _ -> failf "%s dispatched a turn" label))
    [ "none, host none", Serve.Exactly None, None, true
    ; "none, host t-1", Serve.Exactly None, Some ("t-1", "completed"), false
    ; "t-7, host t-7", Serve.Exactly t7, Some ("t-7", "completed"), true
    ; "t-7, host t-7 failed", Serve.Exactly t7, Some ("t-7", "failed"), false
    ; "t-7, host t-8", Serve.Exactly t7, Some ("t-8", "completed"), false
    ; "t-7, host none", Serve.Exactly t7, None, false
    ; "t-7 or t-8, host t-7", Serve.Last_or_dispatched {last=t7; dispatched=Some "t-8"},
      Some ("t-7", "completed"), true
    ; "t-7 or t-8, host t-8", Serve.Last_or_dispatched {last=t7; dispatched=Some "t-8"},
      Some ("t-8", "completed"), true
    ; "t-7 or t-8, host t-8 failed", Serve.Last_or_dispatched {last=t7; dispatched=Some "t-8"},
      Some ("t-8", "failed"), true
    ; "t-7 or t-8, host t-9", Serve.Last_or_dispatched {last=t7; dispatched=Some "t-8"},
      Some ("t-9", "completed"), false
    ; "t-7 or an unacknowledged turn, host t-8",
      Serve.Last_or_dispatched {last=t7; dispatched=None}, Some ("t-8", "completed"), true
    ; "t-7 or an unacknowledged turn, host none",
      Serve.Last_or_dispatched {last=t7; dispatched=None}, None, false
    ; "none or an unacknowledged turn, host none",
      Serve.Last_or_dispatched {last=None; dispatched=None}, None, true
    ; "retry after t-7, host t-7", Serve.Last_or_uncompleted {last=t7; failed=Some "t-8"},
      Some ("t-7", "completed"), true
    ; "retry after t-7, host t-8 failed", Serve.Last_or_uncompleted {last=t7; failed=Some "t-8"},
      Some ("t-8", "failed"), true
    ; "retry after t-7, host t-8 cancelled", Serve.Last_or_uncompleted {last=t7; failed=Some "t-8"},
      Some ("t-8", "cancelled"), true
    ; "retry after t-7, host t-8 completed", Serve.Last_or_uncompleted {last=t7; failed=Some "t-8"},
      Some ("t-8", "completed"), false
    ; "retry after t-7, host t-9 failed", Serve.Last_or_uncompleted {last=t7; failed=Some "t-8"},
      Some ("t-9", "failed"), false
    ; "retry after t-7, host t-8 died", Serve.Last_or_uncompleted {last=t7; failed=Some "t-8"},
      Some ("t-8", "host_died"), true
    ; "retry after none, host none", Serve.Last_or_uncompleted {last=None; failed=Some "t-8"},
      None, false
    ; "retry of an unacknowledged turn, host t-9 failed",
      Serve.Last_or_uncompleted {last=t7; failed=None}, Some ("t-9", "failed"), true
    ; "retry of an unacknowledged turn, host t-9 completed",
      Serve.Last_or_uncompleted {last=t7; failed=None}, Some ("t-9", "completed"), false ];
  List.iter (fun expected_last_turn ->
    match Serve.validate_turn ~session_mode:(Serve.Resume {session_id="s-1"; expected_last_turn})
            (config ()) ~workspace_root:"/w" ~prompt:"p" ~images:[] with
    | Error (Serve.Invalid_config _) -> ()
    | Error error -> fail (Serve.error_to_string error)
    | Ok () -> fail "an empty expected turn id was admitted")
    [ Serve.Exactly (ended "" Serve.Ended_completed)
    ; Serve.Last_or_dispatched {last=None; dispatched=Some " "}
    ; Serve.Last_or_uncompleted {last=t7; failed=Some ""} ];
  (* Control: the same request with turn ids is admitted. *)
  match Serve.validate_turn
          ~session_mode:(Serve.Resume {session_id="s-1";
            expected_last_turn=Serve.Last_or_dispatched {last=t7; dispatched=Some "t-8"}})
          (config ()) ~workspace_root:"/w" ~prompt:"p" ~images:[] with
  | Ok () -> ()
  | Error error -> fail (Serve.error_to_string error)
;;

let test_start_requires_an_empty_session () =
  let frame count =
    Yojson.Safe.to_string (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 2;
      "result", `Assoc ["session", `Assoc
        (["sessionId", `String "s-1"; "workspaceRoot", `String "/w";
          "approvalMode", effective_mode Msp.Prompt_unmatched]
         @ (match count with None -> [] | Some count -> ["turnCount", count]))]]) in
  let prefix count = [Read; Write (init_frame ~granted:[]); Read; Read; Write (frame count)] in
  List.iter (fun count ->
    let ready = ref false and sent = ref false in
    run_scripted ~session_mode:Serve.Start
      ~on_session_ready:(fun ~session_id:_ ~last_turn:_ -> ready := true; Ok ())
      ~on_prompt_sent:(fun () -> sent := true)
      (prefix count)
      (fun result requests ->
        (match result with
         | Error (Serve.Protocol_error {stage="session/start"; _}) -> ()
         | Error error -> fail (Serve.error_to_string error)
         | Ok _ -> fail "a non-empty start dispatched a turn");
        check bool "unverified start never persists admission" false !ready;
        check bool "unverified start never dispatches prompt" false !sent;
        check (list string) "no turn after refused start"
          ["initialize"; "initialized"; "session/start"]
          (List.map (fun request -> Yojson.Safe.Util.(request |> member "method" |> to_string)) requests)))
    [None; Some `Null; Some (`String "0"); Some (`Int (-1)); Some (`Int 1); Some (`Int 2)];
  run_scripted ~session_mode:Serve.Start
    (prefix (Some (`Int 0)) @ [Read; Write turn_ack; Write turn_started;
      Write agent_completed; Write turn_completed])
    (fun result requests ->
      (match result with
       | Ok turn -> check bool "empty start completes" false turn.resumed
       | Error error -> fail (Serve.error_to_string error));
      ignore (request_with_method "turn/start" requests))
;;

let test_absent_durability_admits_the_v1_durable_host () =
  let frame = Yojson.Safe.from_string (init_frame ~granted:[]) in
  let fields = Yojson.Safe.Util.to_assoc frame in
  let result = Yojson.Safe.Util.(frame |> member "result" |> to_assoc) in
  let response =
    `Assoc (("result", `Assoc (List.remove_assoc "sessionDurability" result))
            :: List.remove_assoc "result" fields)
    |> Yojson.Safe.to_string in
  run_scripted
    ([ Read; Write response ]
     @ List.drop 2 (handshake_and_session ~granted:[])
     @ [ Write agent_completed; Write turn_completed ])
    (fun result _ ->
       match result with
       | Ok turn -> check (option string) "v1 durable turn completed" (Some "MASC_MUSE_OK") turn.text
       | Error error -> fail (Serve.error_to_string error))
;;

let test_completed_message_presence () =
  let blank = {|{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"s-1","viewCursor":"v:8","item":{"itemId":"m-1","kind":"agentMessage","turnId":"t-1","revision":2,"status":"completed","text":""}}}|} in
  List.iter (fun (frames, expected) ->
    run_scripted (handshake_and_session ~granted:[] @ frames @ [Write turn_completed])
      (fun result _ -> match result with
       | Ok turn -> check (option string) "completed message presence" expected turn.text
       | Error error -> fail (Serve.error_to_string error)))
    [[], None; [Write blank], Some ""]
;;

let phased_message ~item_id ?phase ?(truncated = false) text =
  let phase =
    match phase with
    | None -> ""
    | Some phase -> Printf.sprintf {|,"messagePhase":%S|} phase
  in
  Printf.sprintf
    {|{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"s-1","viewCursor":%S,"item":{"itemId":%S,"kind":"agentMessage","turnId":"t-1","revision":2,"status":"completed","text":%S%s,"truncated":%b}}}|}
    ("item-" ^ item_id) item_id text phase truncated
;;

(* Muse 1.4.11 declares each agent message's phase; the phase, not the
   message's position, marks the answer. Narration still reaches the stream. *)
let test_message_phase_marks_the_answer () =
  let narration = phased_message ~item_id:"m-c" ~phase:"commentary" "Running the suite now." in
  let answer = phased_message ~item_id:"m-a" ~phase:"finalAnswer" "Suite passed." in
  List.iter
    (fun (name, frames, expected) ->
       let completed = ref [] in
       run_scripted
         ~on_stream_event:(function
           | Serve.Text_completed { item_id; _ } -> completed := item_id :: !completed
           | _ -> ())
         (handshake_and_session ~granted:[] @ List.map (fun frame -> Write frame) frames
          @ [ Write turn_completed ])
         (fun result _ ->
            match result with
            | Ok turn ->
              check (option string) name expected turn.text;
              check bool (name ^ ": narration reaches the stream") true
                (List.mem "m-c" !completed)
            | Error error -> fail (Serve.error_to_string error)))
    [ "narration then a tool call gives no answer"
    , [ narration; tool_started; tool_completed ]
    , None
    ; "the answer after narration", [ narration; answer ], Some "Suite passed."
    ; "the answer before trailing narration", [ answer; narration ], Some "Suite passed."
    ; "truncated narration cannot hide a full answer"
    , [ phased_message ~item_id:"m-c" ~phase:"commentary" ~truncated:true "Checking"; answer ]
    , Some "Suite passed."
    ; "a truncated older answer cannot hide the full latest answer"
    , [ narration; phased_message ~item_id:"m-old" ~truncated:true "Earlier"; answer ]
    , Some "Suite passed."
    ; "an unrecognized phase reads as an answer"
    , [ narration; phased_message ~item_id:"m-r" ~phase:"recap" "Recap." ]
    , Some "Recap."
    ];
  run_scripted
    (handshake_and_session ~granted:[]
     @ [ Write (phased_message ~item_id:"m-1" "checking.")
       ; Write (phased_message ~item_id:"m-2" "MASC_MUSE_OK")
       ; Write turn_completed
       ])
    (fun result _ ->
       match result with
       | Ok turn -> check (option string) "no phase keeps the newest message" (Some "MASC_MUSE_OK") turn.text
       | Error error -> fail (Serve.error_to_string error));
  let started ~item_id cursor =
    Printf.sprintf
      {|{"jsonrpc":"2.0","method":"item/started","params":{"sessionId":"s-1","viewCursor":%S,"item":{"itemId":%S,"kind":"agentMessage","turnId":"t-1","revision":1,"status":"inProgress","text":""}}}|}
      cursor item_id
  in
  run_scripted
    (handshake_and_session ~granted:[]
     @ [ Write (started ~item_id:"m-1" "v:3")
       ; Write (phased_message ~item_id:"m-2" ~phase:"finalAnswer" "Earlier completed")
       ; Write (phased_message ~item_id:"m-1" ~phase:"finalAnswer" "Completed later")
       ; Write turn_completed
       ])
    (fun result _ ->
       match result with
       | Ok turn ->
         check (option string) "completion order selects the newest answer"
           (Some "Completed later") turn.text
       | Error error -> fail (Serve.error_to_string error));
  let terminal_start =
    {|{"jsonrpc":"2.0","method":"item/started","params":{"sessionId":"s-1","viewCursor":"v:3","item":{"itemId":"m-1","kind":"agentMessage","turnId":"t-1","revision":1,"status":"completed","text":"bad"}}}|}
  in
  run_scripted
    (handshake_and_session ~granted:[]
     @ [ Write terminal_start
       ; Write agent_completed
       ; Write turn_completed
       ])
    (fun result _ ->
       match result with
       | Error (Serve.Protocol_error { stage = "view/page"; detail }) ->
         check string "terminal item/started is rejected" "agent item start is terminal" detail
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "terminal item/started must be rejected");
  let reupdated_after_complete =
    {|{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"s-1","viewCursor":"agent-final-2","item":{"itemId":"m-1","kind":"agentMessage","turnId":"t-1","revision":3,"status":"completed","text":"overwritten"}}}|}
  in
  run_scripted
    (handshake_and_session ~granted:[]
     @ [ Write agent_completed
       ; Write reupdated_after_complete
       ; Write turn_completed
       ])
    (fun result _ ->
       match result with
       | Error (Serve.Protocol_error { stage = "view/page"; detail }) ->
         check string "post-completion revision is rejected" "agent item updated after completion" detail
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "revision after completion must be rejected")
;;

let test_pending_approval_decision_response_during_view_page () =
  let gaps = ref 0 in
  let gap =
    {|{"jsonrpc":"2.0","method":"view/gap","params":{"after":"v:6","next":"v:7","sessionId":"s-1"}}|}
  in
  run_scripted
    ~on_stream_event:(function
      | Serve.View_gap_observed -> incr gaps
      | _ -> ())
    (handshake_and_session ~granted:[]
     @ [ Write agent_started
       ; Write tool_started
       ; Write approval_request
       ; Read (* approval ack *)
       ; Read (* approval/decide *)
       ; Write tool_completed
       ; Write agent_completed
       ; Write turn_completed
       ; Write gap
       ; Write decide_result
       ])
    (fun result _ ->
       match result with
       | Error error -> fail (Serve.error_to_string error)
       | Ok turn ->
         check (option string) "reply survives late approval/decide response"
           (Some "MASC_MUSE_OK") turn.text;
         check int "approval counted" 1 turn.approvals_decided;
         check int "view gap during history page observed" 1 !gaps);
  let decide_error =
    {|{"jsonrpc":"2.0","id":4,"error":{"code":-32603,"message":"decision persistence failed"}}|}
  in
  run_scripted
    (handshake_and_session ~granted:[]
     @ [ Write agent_started
       ; Write tool_started
       ; Write approval_request
       ; Read (* approval ack *)
       ; Read (* approval/decide *)
       ; Write tool_completed
       ; Write agent_completed
       ; Write turn_completed
       ; Write decide_error
       ])
    (fun result _ ->
       match result with
       | Error (Serve.Rpc_error { method_ = "approval/decide"; code = -32603; message }) ->
         check string "late approval/decide rpc error surfaces" "decision persistence failed" message
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "failed approval/decide response must fail the turn")
;;

let test_stream_callback_preserves_reserved_controls () =
  let event = Serve.Turn_finished { text = "" } in
  let propagated name exn =
    match Serve.emit_stream_event (Some (fun _ -> raise exn)) event with
    | () -> fail (name ^ " was swallowed by the stream callback boundary")
    | exception observed -> check bool ("same " ^ name ^ " propagates") true (observed == exn)
  in
  propagated "operator interrupt" Keeper_operator_interrupt.Operator_interrupt;
  propagated "timeout" Eio.Time.Timeout;
  propagated "cancellation" (Eio.Cancel.Cancelled (Failure "stream observer cancelled"));
  propagated "out of memory" Out_of_memory;
  propagated "stack overflow" Stack_overflow;
  propagated "break" Sys.Break;
  (* Ordinary callback failures stay isolated: the turn continues. *)
  Serve.emit_stream_event (Some (fun _ -> raise (Failure "buggy observer"))) event;
  Serve.emit_stream_event None event
;;

let test_history_failure_usage_observer_preserves_reserved_controls () =
  List.iter (fun (name, reserved) ->
    let usage_seen = ref false in
    (match run_scripted
       ~on_stream_event:(function
         | Serve.Usage_reported _ -> usage_seen := true; raise reserved
         | _ -> ())
       (handshake_and_session ~granted:[]
        @ [Write agent_completed; Write turn_completed; Read;
           Write {|{"jsonrpc":"2.0","id":4,"error":{"code":-32040,"message":"history unavailable"}}|}])
       (fun _ _ -> fail "reserved aggregate observer control was swallowed") with
     | () -> fail "reserved aggregate observer returned"
     | exception observed ->
       check bool ("same aggregate observer " ^ name ^ " propagates") true (observed == reserved));
    check bool "known aggregate reaches the observer despite failed history" true !usage_seen)
    [ "operator interrupt", Keeper_operator_interrupt.Operator_interrupt
    ; "timeout", Eio.Time.Timeout
    ; "cancellation", Eio.Cancel.Cancelled (Failure "aggregate observer cancelled")
    ; "out of memory", Out_of_memory
    ; "stack overflow", Stack_overflow
    ; "break", Sys.Break ]
;;

(* The owner is cancelled while the host is still exiting after its turn ended.
   The cleanup is cancel-protected, so a [run_turn] that does not return cannot
   be interrupted from inside the process: the alarm turns that hang into a
   failed suite. It ends the whole test process with exit code 2 instead of an
   alcotest report, which is why a hang here shows up as a suite that exits
   quietly. *)
let fail_if_blocked_for seconds f =
  Sys.set_signal
    Sys.sigalrm
    (Sys.Signal_handle
       (fun _ ->
         prerr_endline "run_turn did not return after the owner was cancelled";
         exit 2));
  ignore (Unix.alarm seconds);
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigalrm Sys.Signal_default)
    f
;;

let host_exit_delay_s = 0.5
let run_turn_return_deadline_s = 20
let sigterm_wait_deadline_s = 15.
let marker_poll_s = 0.01

(* The host installs its trap before it ends the turn, and the owner is
   cancelled once the trap has run: the cancel arrives while the host is
   exiting, after the cleanup began, whatever the machine's speed. *)
let test_run_turn_returns_when_the_owner_is_cancelled_while_the_host_exits () =
  let marker = Filename.temp_file "masc-muse-term-" "" in
  Sys.remove marker;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists marker then Sys.remove marker)
    (fun () ->
      with_script
        (handshake_and_session ~granted:[]
         @ [ Write agent_started
           ; Trap_term { marker; exit_delay_s = host_exit_delay_s }
           ; Write agent_completed
           ; Write turn_completed
           ; Idle_until_killed
           ])
        (fun ~dir ~requests:_ ->
          fail_if_blocked_for run_turn_return_deadline_s (fun () ->
            Eio_main.run (fun env ->
              let clock = Eio.Stdenv.clock env in
              let rec wait_for_sigterm () =
                if not (Sys.file_exists marker)
                then (
                  Eio.Time.sleep clock marker_poll_s;
                  wait_for_sigterm ())
              in
              let cancelled_the_owner =
                Eio.Fiber.first
                  (fun () ->
                    let (_ : (Serve.turn_result, Serve.error) result) =
                      Serve.run_turn
                        ~storage:(native_storage dir)
                        ~mgr:(Eio.Stdenv.process_mgr env)
                        ~clock
                        ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
                        ~account:(environment_account ())
                        (config ())
                        ~workspace_root:"/w"
                        ~prompt:"say MASC_MUSE_OK"
                        ~images:[]
                    in
                    false)
                  (fun () ->
                    match
                      Eio.Time.with_timeout clock sigterm_wait_deadline_s (fun () ->
                        wait_for_sigterm ();
                        Ok ())
                    with
                    | Ok () -> true
                    | Error `Timeout -> false)
              in
              check bool
                "the owner was cancelled after the host received SIGTERM"
                true
                cancelled_the_owner))))
;;

(* A write inside the turn that outlasts its window: the host took the
   [turn/start] line before it answered, so it may be running the turn, and a
   caller that retries on [turn_accepted = false] would run it twice. The
   approval decision echoes the host's own approval id; the host sends a long
   one and stops reading, so the write cannot finish. The approval arrives
   while a tool item is open, or while the model is still working. *)
let an_approval_write_that_times_out_reports_the_turn_as_accepted ~tool_item_open () =
  let long_id = String.make 300_000 'x' in
  let approval_with_long_id =
    match Yojson.Safe.from_string approval_request with
    | `Assoc fields ->
      let id_field = function
        | "approvalId", _ -> "approvalId", `String long_id
        | field -> field
      in
      `Assoc
        (List.map
           (function
             | "params", `Assoc params ->
               ( "params"
               , `Assoc
                   (List.map
                      (function
                        | "currentRequirementId", `Assoc requirement ->
                          "currentRequirementId", `Assoc (List.map id_field requirement)
                        | field -> id_field field)
                      params) )
             | field -> field)
           fields)
      |> Yojson.Safe.to_string
    | _ -> fail "the approval request fixture is not an object"
  in
  with_script
    (handshake_and_session ~granted:[]
     @ [ Write agent_started ]
     @ (if tool_item_open then [ Write tool_started ] else [])
     @ [ Write approval_with_long_id
       ; Read (* approval ack *)
       ; Sleep 1.0
       ])
    (fun ~dir ~requests:_ ->
      Eio_main.run (fun env ->
        match
          Serve.run_turn
            ~storage:(native_storage dir)
            ~mgr:(Eio.Stdenv.process_mgr env)
            ~clock:(Eio.Stdenv.clock env)
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
            ~account:(environment_account ())
            (config ~admission_timeout_s:0.3 ())
            ~workspace_root:"/w"
            ~prompt:"say MASC_MUSE_OK"
            ~images:[]
        with
        | Error (Serve.Timeout { turn_accepted; _ }) ->
          check bool "the turn was accepted before the write timed out" true turn_accepted
        | Ok _ -> fail "the approval decision cannot have been written"
        | Error error -> fail (Serve.error_to_string error)))
;;

(* The write that outlasts its window comes before the turn exists: the
   [session/start] request names a workspace root too long for the pipe and the
   host reads nothing after its handshake. Nothing was started, so the caller
   may try again. *)
let test_a_session_start_write_that_times_out_reports_the_turn_as_not_accepted () =
  let long_workspace_root = "/" ^ String.make 300_000 'w' in
  with_script
    [ Read
    ; Write (init_frame ~granted:[])
    ; Read (* initialized *)
    ; Sleep 1.0
    ]
    (fun ~dir ~requests:_ ->
      Eio_main.run (fun env ->
        match
          Serve.run_turn
            ~storage:(native_storage dir)
            ~mgr:(Eio.Stdenv.process_mgr env)
            ~clock:(Eio.Stdenv.clock env)
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
            ~account:(environment_account ())
            (config ~admission_timeout_s:0.3 ())
            ~workspace_root:long_workspace_root
            ~prompt:"say MASC_MUSE_OK"
            ~images:[]
        with
        | Error (Serve.Timeout { turn_accepted; _ }) ->
          check bool "no turn had started when the write timed out" false turn_accepted
        | Ok _ -> fail "the session/start request cannot have been written"
        | Error error -> fail (Serve.error_to_string error)))
;;

(* A host that goes quiet or exits is judged by whether [turn/start] had left
   this process when the read ended, the same boundary the write timeouts use.
   Once it was written the host takes the command in durably, so the turn may
   have run and a caller that retries on [turn_accepted = false] would run it
   twice. *)
let run_against_script steps ~config =
  with_script steps (fun ~dir ~requests:_ ->
    Eio_main.run (fun env ->
      Serve.run_turn
        ~storage:(native_storage dir)
        ~mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env)
        ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
        ~account:(environment_account ())
        config
        ~workspace_root:"/w"
        ~prompt:"say MASC_MUSE_OK"
        ~images:[]))
;;

let test_a_host_that_goes_quiet_in_the_model_turn_reports_the_turn_as_accepted () =
  match
    run_against_script
      (handshake_and_session ~granted:[] @ [ Write agent_started; Sleep 1.0 ])
      ~config:(config ~timeout_s:0.3 ())
  with
  | Error (Serve.Timeout { turn_accepted; _ }) ->
    check bool "the turn was accepted before the read timed out" true turn_accepted
  | Ok _ -> fail "a silent host cannot have finished the turn"
  | Error error -> fail (Serve.error_to_string error)
;;

let test_a_host_that_exits_in_the_model_turn_reports_the_turn_as_accepted () =
  match
    run_against_script
      (handshake_and_session ~granted:[] @ [ Write agent_started; Exit_with 3 ])
      ~config:(config ())
  with
  | Error (Serve.Process_exited { turn_accepted; _ }) ->
    check bool "the turn was accepted before the host exited" true turn_accepted
  | Ok _ -> fail "an exited host cannot have finished the turn"
  | Error error -> fail (Serve.error_to_string error)
;;

let test_a_host_that_goes_quiet_before_the_turn_reports_the_turn_as_not_accepted () =
  match
    run_against_script
      [ Read; Write (init_frame ~granted:[]); Read (* initialized *); Read (* session/start *); Sleep 1.0 ]
      ~config:(config ~admission_timeout_s:0.3 ())
  with
  | Error (Serve.Timeout { turn_accepted; _ }) ->
    check bool "no turn had started when the read timed out" false turn_accepted
  | Ok _ -> fail "a silent host cannot have started a session"
  | Error error -> fail (Serve.error_to_string error)
;;

let test_a_host_that_exits_before_the_turn_reports_the_turn_as_not_accepted () =
  match
    run_against_script
      [ Read; Write (init_frame ~granted:[]); Read (* initialized *); Exit_with 3 ]
      ~config:(config ())
  with
  | Error (Serve.Process_exited { turn_accepted; _ }) ->
    check bool "no turn had started when the host exited" false turn_accepted
  | Ok _ -> fail "an exited host cannot have started a session"
  | Error error -> fail (Serve.error_to_string error)
;;

let () =
  run
    "runtime_muse_serve"
    [ ( "turn"
      , [ test_case "completed message presence" `Quick test_completed_message_presence
        ; test_case "message phase marks the answer" `Quick test_message_phase_marks_the_answer
        ; test_case "pending approval/decide response during view/page" `Quick
            test_pending_approval_decision_response_during_view_page
        ; test_case "stream callback preserves reserved controls" `Quick
            test_stream_callback_preserves_reserved_controls
        ; test_case "history failure aggregate observer preserves reserved controls" `Quick
            test_history_failure_usage_observer_preserves_reserved_controls
        ; test_case "native-only tool completion keeps status, arguments and output" `Quick
            test_native_tool_completion_preserves_vendor_evidence
        ; test_case "turn with tool and approval" `Quick test_turn_with_tool_and_approval
        ; test_case "turn/start receipt is the line the host read" `Quick
            test_turn_start_receipt_is_the_line_the_host_read
        ; test_case "auth required" `Quick test_auth_required
        ; test_case "compaction reaches the stream" `Quick test_compaction_reaches_the_stream
        ; test_case "exit code is typed" `Quick test_exit_code_is_typed
        ; test_case "bridge needs sessionMcp" `Quick test_bridge_needs_session_mcp
        ; test_case "native none is config error" `Quick test_native_none_is_config_error
        ; test_case "trust needs a MASC workspace no session can write" `Quick
            test_trust_needs_a_masc_workspace_no_session_can_write
        ; test_case "launch arguments follow workspace trust" `Quick
            test_launch_arguments_follow_workspace_trust
        ; test_case "selected account home isolates child roots and posture" `Quick
            test_selected_homes_do_not_inherit_other_account_roots
        ; test_case "valid images use shared official media contract" `Quick test_valid_image_inputs_use_shared_official_media_contract
        ; test_case "refused images name the image and the reason" `Quick test_refused_images_name_the_image_and_the_reason
        ; test_case "session identity is verified before admission" `Quick test_session_identity_is_verified_before_admission
        ; test_case "resumed session model is selected before admission" `Quick
            test_resumed_session_model_is_selected_before_admission
        ; test_case "turn lists the models its calls ran on" `Quick
            test_turn_lists_the_models_its_calls_ran_on
        ; test_case "call usage counted once in its turn" `Quick test_call_usage_is_counted_once_in_its_turn
        ; test_case "view gap does not fabricate a turn total" `Quick test_view_gap_does_not_fabricate_a_turn_total
        ; test_case "turn keeps its newest call usage" `Quick test_turn_keeps_its_newest_call_usage
        ; test_case "effective approval mode is verified before admission" `Quick test_session_approval_mode_is_verified_before_admission
        ; test_case "prepared HOME matches selected account" `Quick test_prepared_home_is_bound_to_exact_selected_account
        ; test_case "invalid account home is refused" `Quick test_invalid_account_home_is_refused
        ; test_case "storage that cannot hold the session is refused before spawn" `Quick
            test_storage_that_cannot_hold_the_session_is_refused_before_spawn
        ; test_case "non-durable host is refused before session admission" `Quick
            test_nondurable_handshake_never_begins_a_session
        ; test_case "absent durability admits the v1 durable host" `Quick
            test_absent_durability_admits_the_v1_durable_host
        ; test_case "resume requires the retained last turn" `Quick
            test_resume_requires_the_retained_last_turn
        ; test_case "resume admits only the last turns its expectation names" `Quick
            test_resume_admits_only_the_last_turns_its_expectation_names
        ; test_case "start requires an empty session" `Quick
            test_start_requires_an_empty_session
        ; test_case "run_turn returns when the owner is cancelled while the host exits" `Quick
            test_run_turn_returns_when_the_owner_is_cancelled_while_the_host_exits
        ; test_case "an approval write that times out with a tool item open reports the turn as accepted" `Quick
            (an_approval_write_that_times_out_reports_the_turn_as_accepted ~tool_item_open:true)
        ; test_case "an approval write that times out during the model turn reports the turn as accepted" `Quick
            (an_approval_write_that_times_out_reports_the_turn_as_accepted ~tool_item_open:false)
        ; test_case "a session start write that times out reports the turn as not accepted" `Quick
            test_a_session_start_write_that_times_out_reports_the_turn_as_not_accepted
        ; test_case
            "a host that goes quiet in the model turn reports the turn as accepted"
            `Quick
            test_a_host_that_goes_quiet_in_the_model_turn_reports_the_turn_as_accepted
        ; test_case
            "a host that exits in the model turn reports the turn as accepted"
            `Quick
            test_a_host_that_exits_in_the_model_turn_reports_the_turn_as_accepted
        ; test_case
            "a host that goes quiet before the turn reports the turn as not accepted"
            `Quick
            test_a_host_that_goes_quiet_before_the_turn_reports_the_turn_as_not_accepted
        ; test_case
            "a host that exits before the turn reports the turn as not accepted"
            `Quick
            test_a_host_that_exits_before_the_turn_reports_the_turn_as_not_accepted
        ] )
    ]
;;
