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
  | Expect_launch of { home : string; native_read : bool }

let init_frame ~granted =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"muse-session-server","version":"1.3.0"},"userAgent":"muse/1.3.0","museHome":"/tmp/muse","platformFamily":"unix","platformOs":"linux","schema":{"version":1,"fingerprint":"sha256:fixture"},"grantedCapabilities":[%s],"experimentalApi":false,"sessionDurability":"durable"}}|}
    (String.concat "," (List.map (Printf.sprintf "%S") granted))
;;

let session_result =
  {|{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":"s-1","status":"idle","turnCount":0,"modelId":"muse-spark-1.3","workspaceRoot":"/w"},"viewCursor":"v:1"}}|}
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
  {|{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"s-1","viewCursor":"v:8","item":{"itemId":"m-1","kind":"agentMessage","turnId":"t-1","revision":2,"status":"completed","text":"MASC_MUSE_OK"}}}|}
;;

let turn_completed =
  {|{"jsonrpc":"2.0","method":"turn/completed","params":{"sessionId":"s-1","turnId":"t-1","terminal":"completed","viewCursor":"v:9","usage":{"inputTokens":100,"outputTokens":7,"cachedTokens":50,"reasoningTokens":3}}}|}
;;

let turn_auth_failed =
  {|{"jsonrpc":"2.0","method":"turn/completed","params":{"sessionId":"s-1","turnId":"t-1","terminal":"failed","viewCursor":"v:9","error":{"kind":"authRequired","message":"run muse login","retryable":false}}}|}
;;

let handshake_and_session ~granted =
  [ Read
  ; Write (init_frame ~granted)
  ; Read (* initialized *)
  ; Read (* session/start *)
  ; Write session_result
  ; Read (* turn/start *)
  ; Write turn_ack
  ; Write turn_started
  ]
;;

let script_text ~capture steps =
  let buffer = Buffer.create 1024 in
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
      | Write frame -> line (Printf.sprintf "printf '%%s\\n' %s" (shell_quote frame))
      | Stderr text -> line (Printf.sprintf "printf '%%s\\n' %s >&2" (shell_quote text))
      | Exit_with code -> line (Printf.sprintf "exit %d" code)
      | Mark_spawned path -> line (Printf.sprintf "touch %s" (shell_quote path))
      | Expect_launch { home; native_read } ->
        let home = Unix.realpath home in
        List.iter
          (fun (key, expected) ->
             line (Printf.sprintf "[ \"$%s\" = %s ] || exit 97" key (shell_quote expected)))
          [ "HOME", home
          ; "XDG_DATA_HOME", Filename.concat home ".local/share"
          ; "XDG_CACHE_HOME", Filename.concat home ".cache"
          ; "XDG_STATE_HOME", Filename.concat home ".local/state"
          ; "XDG_RUNTIME_DIR", Filename.concat home ".local/run"
          ];
        line "[ -z \"${META_API_KEY+x}\" ] || exit 96";
        line (Printf.sprintf "case \"$XDG_CONFIG_HOME\" in %s/*) ;; *) exit 94 ;; esac"
          (shell_quote (Filename.concat (Unix.realpath home) ".local/state/masc/muse-config")));
        line "[ -r \"$XDG_CONFIG_HOME/muse/auth.json\" ] || exit 94";
        line "[ -r \"$XDG_CONFIG_HOME/muse/settings.json\" ] || exit 94";
        line "[ \"$TMPDIR\" = \"$XDG_CONFIG_HOME/tmp\" ] || exit 94";
        line "[ -d \"$TMPDIR\" ] || exit 94";
        if native_read then (
          line "[ \"$#\" = 2 ] || exit 95";
          line "[ \"$1\" = --disable-write ] || exit 95";
          line "[ \"$2\" = --disable-shell ] || exit 95")
        else line "[ \"$#\" = 0 ] || exit 95")
    steps;
  line "while IFS= read -r ignored; do :; done";
  Buffer.contents buffer
;;

let with_script steps f =
  let dir = Filename.temp_dir "masc-muse-serve-" "" in
  let capture = Filename.concat dir "requests.jsonl" in
  Out_channel.with_open_bin (Filename.concat dir "serve") (fun output ->
    output_string output (script_text ~capture steps));
  let requests () =
    if Sys.file_exists capture
    then
      In_channel.with_open_bin capture In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (fun line -> line <> "")
      |> List.map Yojson.Safe.from_string
    else []
  in
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
      Sys.rmdir dir)
    (fun () -> f ~dir ~requests)
;;

let config ?account_home ?(native = Runtime_native_tools.Native_read) () =
  { (Serve.default_config ()) with
    cli_path = "/bin/sh"
  ; account_home
  ; native
  ; admission_timeout_s = 10.
  ; timeout_s = Some 10.
  }
;;

let run_scripted ?model ?(workspace_root = "/w") ?session_mode ?account_home ?prepared_home ?mcp_servers ?on_session_ready ?on_prompt_sent ?on_stream_event ?native steps check_result =
  with_script steps (fun ~dir ~requests ->
    Eio_main.run (fun env ->
      let result =
        Serve.run_turn
          ?session_mode
          ?mcp_servers
          ?on_session_ready
          ?on_prompt_sent
          ?on_stream_event
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
          {(config ?account_home ?native ()) with prepared_home; model}
          ~workspace_root
          ~prompt:"say MASC_MUSE_OK"
          ~images:[]
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
let test_turn_with_tool_and_approval () =
  let deltas = Buffer.create 16 in
  let decisions = ref [] in
  let tools = ref 0 in
  let session_ready = ref None in
  run_scripted
    ~on_session_ready:(fun ~session_id ->
      session_ready := Some session_id;
      Ok ())
    ~on_stream_event:(function
      | Serve.Text_delta {text; _} -> Buffer.add_string deltas text
      | Serve.Approval_decided { decision; _ } -> decisions := decision :: !decisions
      | Serve.Native_tool_finished _ -> incr tools
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
         check string "reply" "MASC_MUSE_OK" turn.text;
         check string "streamed" "MASC_MUSE_OK" (Buffer.contents deltas);
         check (option string) "session ready" (Some "s-1") !session_ready;
         check int "tool calls" 1 turn.tool_calls;
         check int "tool finished events" 1 !tools;
         check int "approvals" 1 turn.approvals_decided;
         check bool "denied" true (!decisions = [ Msp.Denied ]);
         check bool "resumed" false turn.resumed;
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
                :: handshake_and_session ~granted:[]
                @ [ Write agent_completed; Write turn_completed ])
               (fun result _ ->
                  match result with
                  | Ok turn -> check string "selected account turn completed" "MASC_MUSE_OK" turn.text
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
         | Ok turn -> check string "matching account completes" "MASC_MUSE_OK" turn.text
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
       | Ok turn -> check string "retarget cannot split child roots from auth" "MASC_MUSE_OK" turn.text
       | Error error -> fail (Serve.error_to_string error)))
;;

let test_invalid_account_home_is_refused () =
  List.iter (fun account_home -> run_scripted ~account_home []
    (fun result requests ->
       (match result with
        | Error (Serve.Invalid_config _) -> ()
        | Error error -> fail (Serve.error_to_string error)
        | Ok _ -> fail "invalid account home reached the client");
       check int "nothing dispatched" 0 (List.length requests)))
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

let test_session_identity_is_verified_before_admission () =
  let frame ~model ~workspace =
    Yojson.Safe.to_string (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 2;
      "result", `Assoc ["session", `Assoc ["sessionId", `String "s-1";
        "modelId", model; "workspaceRoot", workspace]]]) in
  let with_id id source = match Yojson.Safe.from_string source with
    | `Assoc fields -> Yojson.Safe.to_string (`Assoc (("id", `Int id) :: List.remove_assoc "id" fields))
    | _ -> fail "fixture response must be an object" in
  List.iter (fun session_mode ->
    let prefix result = [Read; Write (init_frame ~granted:[]); Read; Read; Write result] in
    List.iter (fun (model, workspace, expected) ->
      let ready = ref false and sent = ref false in
      run_scripted ~model:"requested-model" ~workspace_root:"/requested-workspace" ~session_mode
        ~on_session_ready:(fun ~session_id:_ -> ready := true; Ok ())
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
      [`String "wrong-model", `String "/requested-workspace", `Model (Some "wrong-model");
       `Null, `String "/requested-workspace", `Model None;
       `String "requested-model", `String "/wrong-workspace", `Workspace (Some "/wrong-workspace");
       `String "requested-model", `Null, `Workspace None];
    let ready = ref 0 in
    let resume_steps, turn_id = match session_mode with
      | Serve.Start -> [], 3
      | Serve.Resume _ -> [Read; Write {|{"jsonrpc":"2.0","id":3,"result":{}}|}], 4 in
    run_scripted ~model:"requested-model" ~workspace_root:"/requested-workspace" ~session_mode
      ~on_session_ready:(fun ~session_id:_ -> incr ready; Ok ())
      (prefix (frame ~model:(`String "requested-model") ~workspace:(`String "/requested-workspace"))
       @ resume_steps @ [Read; Write (with_id turn_id turn_ack); Write turn_started;
                          Write agent_completed; Write turn_completed])
      (fun result requests ->
        (match result with Ok turn -> check string "matching session completes" "MASC_MUSE_OK" turn.text
         | Error error -> fail (Serve.error_to_string error));
        check int "matching identity persists once" 1 !ready;
        ignore (request_with_method "turn/start" requests)))
    [Serve.Start; Serve.Resume {session_id="s-1"}]
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
              ~on_session_ready:(fun ~session_id:_ -> session_ready := true; Ok ())
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
    [ Serve.Start; Serve.Resume { session_id = "retained-session" } ]
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
       | Ok turn -> check string "v1 durable turn completed" "MASC_MUSE_OK" turn.text
       | Error error -> fail (Serve.error_to_string error))
;;

let () =
  run
    "runtime_muse_serve"
    [ ( "turn"
      , [ test_case "turn with tool and approval" `Quick test_turn_with_tool_and_approval
        ; test_case "auth required" `Quick test_auth_required
        ; test_case "exit code is typed" `Quick test_exit_code_is_typed
        ; test_case "bridge needs sessionMcp" `Quick test_bridge_needs_session_mcp
        ; test_case "native none is config error" `Quick test_native_none_is_config_error
        ; test_case "selected account home isolates child roots and posture" `Quick
            test_selected_homes_do_not_inherit_other_account_roots
        ; test_case "valid images use shared official media contract" `Quick test_valid_image_inputs_use_shared_official_media_contract
        ; test_case "session identity is verified before admission" `Quick test_session_identity_is_verified_before_admission
        ; test_case "prepared HOME matches selected account" `Quick test_prepared_home_is_bound_to_exact_selected_account
        ; test_case "invalid account home is refused" `Quick test_invalid_account_home_is_refused
        ; test_case "non-durable host is refused before session admission" `Quick
            test_nondurable_handshake_never_begins_a_session
        ; test_case "absent durability admits the v1 durable host" `Quick
            test_absent_durability_admits_the_v1_durable_host
        ] )
    ]
;;
