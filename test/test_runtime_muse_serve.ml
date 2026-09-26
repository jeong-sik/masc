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
  | Write_times of int * string
      (** Write one frame that many times, reading nothing between them. *)
  | Stderr of string
  | Exit_with of int

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

(* Where the script records its arguments after [serve] and the auto-update
   switch it inherited. *)
let argv_file = "argv.txt"
let auto_update_file = "auto-update.txt"

let script_text ~dir ~capture steps =
  let buffer = Buffer.create 1024 in
  let line text =
    Buffer.add_string buffer text;
    Buffer.add_char buffer '\n'
  in
  line "#!/bin/sh";
  line
    (Printf.sprintf
       "printf '%%s\\n' \"$@\" > %s"
       (shell_quote (Filename.concat dir argv_file)));
  line
    (Printf.sprintf
       "env | grep '^MUSE_NO_AUTO_UPDATE=' > %s"
       (shell_quote (Filename.concat dir auto_update_file)));
  List.iter
    (function
      | Read ->
        line "IFS= read -r request || exit 98";
        line (Printf.sprintf "printf '%%s\\n' \"$request\" >> %s" (shell_quote capture))
      | Write frame -> line (Printf.sprintf "printf '%%s\\n' %s" (shell_quote frame))
      | Write_times (count, frame) ->
        line
          (Printf.sprintf
             "i=0; while [ $i -lt %d ]; do printf '%%s\\n' %s; i=$((i+1)); done"
             count
             (shell_quote frame))
      | Stderr text -> line (Printf.sprintf "printf '%%s\\n' %s >&2" (shell_quote text))
      | Exit_with code -> line (Printf.sprintf "exit %d" code))
    steps;
  line "while IFS= read -r ignored; do :; done";
  Buffer.contents buffer
;;

let with_script steps f =
  let dir = Filename.temp_dir "masc-muse-serve-" "" in
  let capture = Filename.concat dir "requests.jsonl" in
  Out_channel.with_open_bin (Filename.concat dir "serve") (fun output ->
    output_string output (script_text ~dir ~capture steps));
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

let config ?(native = Runtime_native_tools.Native_read) ?model ?(admission_timeout_s = 10.) ()
  =
  { (Serve.default_config ()) with
    cli_path = "/bin/sh"
  ; model
  ; native
  ; admission_timeout_s
  ; timeout_s = Some 10.
  }
;;

let run_scripted
      ?session_mode
      ?(check_dir = fun (_ : string) -> ())
      ?mcp_servers
      ?on_session_ready
      ?on_stream_event
      ?native
      ?model
      ?admission_timeout_s
      steps
      check_result
  =
  with_script steps (fun ~dir ~requests ->
    Eio_main.run (fun env ->
      let result =
        Serve.run_turn
          ?session_mode
          ?mcp_servers
          ?on_session_ready
          ?on_stream_event
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / dir)
          (config ?native ?model ?admission_timeout_s ())
          ~workspace_root:dir
          ~prompt:"say MASC_MUSE_OK"
          ~images:[]
      in
      check_result result (requests ());
      check_dir dir))
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
      | Serve.Text_delta { item_id; text } ->
        check string "the delta names its agent message" "m-1" item_id;
        Buffer.add_string deltas text
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
         check bool "deny choice" true (params_member "choiceId" decide = `String "deny");
         check
           bool
           "no feedback on a choice that takes none"
           true
           (params_member "feedback" decide = `Null))
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
        ; server =
            Msp.Streamable_http
              { url = "http://127.0.0.1:1/mcp"; headers = []; required = true }
        ; tool_names = []
        }
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

(* A host that stops reading stdin while its turn runs blocks MASC's
   approval answers once the pipe is full. The turn/start line was written
   before that, so the silence leaves the turn accepted: the host may be
   running it. *)
let test_a_blocked_approval_answer_leaves_the_turn_accepted () =
  run_scripted
    ~admission_timeout_s:2.
    (handshake_and_session ~granted:[] @ [ Write_times (2000, approval_request) ])
    (fun result _ ->
       match result with
       | Error (Serve.Timeout { turn_accepted = true; _ }) -> ()
       | Error (Serve.Timeout { turn_accepted = false; _ }) ->
         fail "a silence after turn/start was reported as one before it"
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "a host that never reads its answers cannot complete the turn")
;;

let session_resumed ~model_id =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":"s-1","status":"idle","turnCount":1,"modelId":%s,"workspaceRoot":"/w"},"viewCursor":"v:1"}}|}
    model_id
;;

let approval_mode_set =
  {|{"jsonrpc":"2.0","id":3,"result":{"commandId":"c","status":"accepted","applyOutcome":"noop","effectiveMode":{"mode":"denyUnmatched","source":"approvalReconfigure","lastCommandId":"c"}}}|}
;;

let resumed_turn_ack =
  {|{"jsonrpc":"2.0","id":4,"result":{"commandId":"c","status":"accepted","turnId":"t-1","startedNewTurn":true,"disposition":"started"}}|}
;;

let resume_steps ~model_id rest =
  [ Read
  ; Write (init_frame ~granted:[])
  ; Read (* initialized *)
  ; Read (* session/resume *)
  ; Write (session_resumed ~model_id)
  ]
  @ rest
;;

(* A resumed session whose record names no model ([modelId] null) is not on
   another model, so its turn runs. One that names another model is refused
   before the turn is written. *)
let test_resume_reads_a_null_model_as_unnamed () =
  run_scripted
    ~session_mode:(Serve.Resume { session_id = "s-1" })
    ~model:"muse-spark-1.3"
    (resume_steps
       ~model_id:"null"
       [ Read (* session/setApprovalMode *)
       ; Write approval_mode_set
       ; Read (* turn/start *)
       ; Write resumed_turn_ack
       ; Write turn_started
       ; Write turn_completed
       ])
    (fun result _ ->
       match result with
       | Ok turn ->
         check bool "resumed" true turn.resumed;
         check (option string) "no model reported" None turn.model
       | Error error -> fail (Serve.error_to_string error));
  run_scripted
    ~session_mode:(Serve.Resume { session_id = "s-1" })
    ~model:"muse-spark-1.3"
    (resume_steps ~model_id:{|"muse-other"|} [])
    (fun result requests ->
       (match result with
        | Error
            (Serve.Session_model_mismatch
              { requested = "muse-spark-1.3"; reported = "muse-other" }) -> ()
        | Error error -> fail (Serve.error_to_string error)
        | Ok _ -> fail "a session on another model must not resume");
       check
         bool
         "no turn written"
         false
         (List.exists
            (fun json -> Yojson.Safe.Util.member "method" json = `String "turn/start")
            requests))
;;

(* [session/start] names the model it asked for, and the host answers with
   the model the session runs. A session on another model is refused before
   the turn is written, as a resumed one is. *)
let test_a_started_session_on_another_model_is_refused () =
  run_scripted
    ~model:"muse-other"
    [ Read
    ; Write (init_frame ~granted:[])
    ; Read (* initialized *)
    ; Read (* session/start *)
    ; Write session_result
    ]
    (fun result requests ->
       (match result with
        | Error
            (Serve.Session_model_mismatch
              { requested = "muse-other"; reported = "muse-spark-1.3" }) -> ()
        | Error error -> fail (Serve.error_to_string error)
        | Ok _ -> fail "a session on another model must not run the turn");
       check
         bool
         "the start asked for the configured model"
         true
         (params_member "modelId" (request_with_method "session/start" requests)
          = `String "muse-other");
       check
         bool
         "no turn written"
         false
         (List.exists
            (fun json -> Yojson.Safe.Util.member "method" json = `String "turn/start")
            requests))
;;

(* ── MASC tools only ───────────────────────────────────────────────── *)

(* The session's MASC server, serving [masc_status] and [ping]. *)
let masc_server =
  { Serve.name = "masc"
  ; server =
      Msp.Streamable_http { url = "http://127.0.0.1:1/mcp"; headers = []; required = true }
  ; tool_names = [ "masc_status"; "ping" ]
  }
;;

(* The choices muse 1.4.0 offered for [mcp__masc__ping] on 2026-09-26. *)
let real_choices =
  {|[{"choiceId":"allow_once","label":"Allow once","decision":"approved","scope":"once"},{"choiceId":"allow_session","label":"Allow for this session","decision":"approvedForSession","scope":"session","rulePreview":"tool `x`"},{"choiceId":"allow_local_mcp_tool","label":"Always allow this MCP tool","decision":"approvedPolicyAmendment","scope":"localPersistent","rulePreview":"tool `x`"},{"choiceId":"abort","label":"Reject","decision":"abort","scope":"once","acceptsFeedback":true}]|}
;;

let approval_with ~id ~approval_id ~tool_name ~subject ~choices =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":%d,"method":"approval/request","params":{"sessionId":"s-1","approvalId":%S,"turnId":"t-1","taskId":%S,"itemId":%S,"toolCallId":"call_%s","toolName":%S,"rawArgs":"{}","viewCursor":"v:6","sourceRange":{"stream":{"kind":"session","id":"s-1"},"first":{"id":"r-1","sequence":65},"last":{"id":"r-1","sequence":65}},"subject":%s,"currentRequirementId":{"approvalId":%S,"sourceIndex":0},"availableChoices":%s,"protectedWrite":false,"judgeEscalated":false}}|}
    id
    approval_id
    approval_id
    approval_id
    approval_id
    tool_name
    subject
    approval_id
    choices
;;

let tool_subject name = Printf.sprintf {|{"kind":"tool","toolName":%S}|} name

let decide_result_with ~id ~approval_id =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":%d,"result":{"commandId":"c","status":"accepted","approvalId":%S,"terminal":true}}|}
    id
    approval_id
;;

(* One turn whose host raises [approval] under [native]; [check] sees the
   result and every frame MASC wrote. *)
let answer_one ?(native = Runtime_native_tools.Native_read) approval check =
  run_scripted
    ~native
    ~mcp_servers:[ masc_server ]
    (handshake_and_session ~granted:[ "sessionMcp" ]
     @ [ Write approval
       ; Read (* approval ack *)
       ; Read (* approval/decide *)
       ; Write (decide_result_with ~id:4 ~approval_id:"a-1")
       ; Write turn_completed
       ])
    check
;;

let decided_choice ?native ~label approval ~expected ~feedback =
  answer_one ?native approval (fun result requests ->
    (match result with
     | Ok _ -> ()
     | Error error -> failf "%s: %s" label (Serve.error_to_string error));
    let decide = request_with_method "approval/decide" requests in
    check bool (label ^ ": choice") true (params_member "choiceId" decide = `String expected);
    match params_member "feedback" decide, feedback with
    | `String text, true -> check bool (label ^ ": feedback") true (String.trim text <> "")
    | `Null, false -> ()
    | other, true -> failf "%s: expected feedback, got %s" label (Yojson.Safe.to_string other)
    | other, false -> failf "%s: expected no feedback, got %s" label (Yojson.Safe.to_string other))
;;

(* Only a call whose subject is a tool named exactly like one of the
   session's MASC tools is allowed, and only once; every other call is
   rejected with the reason. *)
let test_masc_tools_only_approval_policy () =
  let request ~tool_name ~subject =
    approval_with ~id:1 ~approval_id:"a-1" ~tool_name ~subject ~choices:real_choices
  in
  decided_choice
    ~label:"a mounted MASC tool"
    (request ~tool_name:"mcp__masc__ping" ~subject:(tool_subject "mcp__masc__ping"))
    ~expected:"allow_once"
    ~feedback:false;
  decided_choice
    ~label:"a built-in tool"
    (request
       ~tool_name:"read_file"
       ~subject:{|{"kind":"fileAccess","toolName":"read_file","path":"/etc/hosts","access":"read"}|})
    ~expected:"abort"
    ~feedback:true;
  decided_choice
    ~label:"a MASC tool the session does not serve"
    (request
       ~tool_name:"mcp__masc__not_mounted"
       ~subject:(tool_subject "mcp__masc__not_mounted"))
    ~expected:"abort"
    ~feedback:true;
  decided_choice
    ~label:"another server's tool"
    (request ~tool_name:"mcp__other__x" ~subject:(tool_subject "mcp__other__x"))
    ~expected:"abort"
    ~feedback:true;
  decided_choice
    ~label:"a MASC tool's name on a non-tool subject"
    (request
       ~tool_name:"mcp__masc__ping"
       ~subject:{|{"kind":"network","toolName":"mcp__masc__ping","host":"example.com","port":443}|})
    ~expected:"abort"
    ~feedback:true;
  decided_choice
    ~native:Runtime_native_tools.Native_none
    ~label:"none runs the same session"
    (request ~tool_name:"web_fetch" ~subject:(tool_subject "web_fetch"))
    ~expected:"abort"
    ~feedback:true;
  decided_choice
    ~native:Runtime_native_tools.Native_full
    ~label:"full approves a built-in once"
    (request ~tool_name:"web_fetch" ~subject:(tool_subject "web_fetch"))
    ~expected:"allow_once"
    ~feedback:false
;;

(* A host that offers no way to reject a call it asks about leaves MASC no
   answer to give: the turn fails as a protocol error and nothing is
   decided. *)
let test_no_reject_choice_is_a_protocol_error () =
  answer_one
    (approval_with
       ~id:1
       ~approval_id:"a-1"
       ~tool_name:"read_file"
       ~subject:(tool_subject "read_file")
       ~choices:
         {|[{"choiceId":"allow_once","label":"Allow once","decision":"approved","scope":"once"},{"choiceId":"allow_session","label":"Allow for this session","decision":"approvedForSession","scope":"session"}]|})
    (fun result requests ->
       (match result with
        | Error (Serve.Protocol_error { stage = "approval/request"; _ }) -> ()
        | Error error -> fail (Serve.error_to_string error)
        | Ok _ -> fail "a call with no reject choice was answered");
       check
         bool
         "nothing decided"
         false
         (List.exists
            (fun json -> Yojson.Safe.Util.member "method" json = `String "approval/decide")
            requests))
;;

let approval_resolved ~approval_id ~decision =
  Printf.sprintf
    {|{"jsonrpc":"2.0","method":"approval/resolved","params":{"sessionId":"s-1","viewCursor":"v:8","approvalId":%S,"itemId":%S,"turnId":"t-1","decision":%S,"resolvedBy":"client","stageEvidence":[]}}|}
    approval_id
    approval_id
    decision
;;

let mcp_tool_item ~status ~revision =
  Printf.sprintf
    {|{"jsonrpc":"2.0","method":"%s","params":{"sessionId":"s-1","viewCursor":"v:7","item":{"itemId":"a-1","kind":"toolCall","turnId":"t-1","revision":%d,"status":%S,"tool":"mcp__masc__ping","callId":"call_a-1","args":"{}"}}}|}
    (if revision = 1 then "item/started" else "item/completed")
    revision
    status
;;

(* A promptUnmatched turn shaped like the host's frames: the model calls one
   MASC tool, which MASC allows once, then a built-in, which MASC rejects,
   and the turn still completes with the model's reply. *)
let test_a_masc_tools_only_turn_completes () =
  let decisions = ref [] in
  run_scripted
    ~mcp_servers:[ masc_server ]
    ~on_stream_event:(function
      | Serve.Approval_decided { tool_name; decision; _ } ->
        decisions := (tool_name, decision) :: !decisions
      | _ -> ())
    (handshake_and_session ~granted:[ "sessionMcp" ]
     @ [ Write agent_started
       ; Write
           (approval_with
              ~id:1
              ~approval_id:"a-1"
              ~tool_name:"mcp__masc__ping"
              ~subject:(tool_subject "mcp__masc__ping")
              ~choices:real_choices)
       ; Read (* approval ack *)
       ; Read (* approval/decide *)
       ; Write (decide_result_with ~id:4 ~approval_id:"a-1")
       ; Write (approval_resolved ~approval_id:"a-1" ~decision:"approved")
       ; Write (mcp_tool_item ~status:"inProgress" ~revision:1)
       ; Write (mcp_tool_item ~status:"completed" ~revision:2)
       ; Write
           (approval_with
              ~id:2
              ~approval_id:"a-2"
              ~tool_name:"web_fetch"
              ~subject:{|{"kind":"network","toolName":"web_fetch","host":"example.com","port":443}|}
              ~choices:real_choices)
       ; Read (* approval ack *)
       ; Read (* approval/decide *)
       ; Write (decide_result_with ~id:5 ~approval_id:"a-2")
       ; Write (approval_resolved ~approval_id:"a-2" ~decision:"abort")
       ; Write agent_completed
       ; Write turn_completed
       ])
    (fun result requests ->
       (match result with
        | Ok turn ->
          check string "reply" "MASC_MUSE_OK" turn.text;
          check int "approvals" 2 turn.approvals_decided;
          check int "tool calls" 1 turn.tool_calls
        | Error error -> fail (Serve.error_to_string error));
       check
         bool
         "allowed the MASC tool once, rejected the built-in"
         true
         (List.rev !decisions
          = [ "mcp__masc__ping", Msp.Approved; "web_fetch", Msp.Abort ]);
       let start = request_with_method "session/start" requests in
       check
         bool
         "promptUnmatched"
         true
         (params_member "approvalMode" start = `String "promptUnmatched");
       check
         bool
         "the session's MASC server"
         true
         (Yojson.Safe.Util.(
            params_member "config" start |> member "mcpServers" |> member "masc" |> member "url")
          = `String "http://127.0.0.1:1/mcp");
       let decides =
         List.filter
           (fun json -> Yojson.Safe.Util.member "method" json = `String "approval/decide")
           requests
       in
       check
         (list string)
         "decided choices"
         [ "allow_once"; "abort" ]
         (List.map
            (fun json -> Yojson.Safe.Util.to_string (params_member "choiceId" json))
            decides))
;;

let lines_of path =
  In_channel.with_open_bin path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "")
;;

(* [muse serve] starts with write and shell off for [none] and [read], and
   with its whole surface for [full]. Every spawn turns the launcher's
   background self-update off. *)
let test_serve_flags_and_environment () =
  List.iter
    (fun (native, expected) ->
       let label = Runtime_native_tools.to_string native in
       run_scripted
         ~native
         ~check_dir:(fun dir ->
           check
             (list string)
             (label ^ ": serve flags")
             expected
             (lines_of (Filename.concat dir argv_file));
           check
             (list string)
             (label ^ ": auto update off")
             [ "MUSE_NO_AUTO_UPDATE=1" ]
             (lines_of (Filename.concat dir auto_update_file)))
         (handshake_and_session ~granted:[] @ [ Write turn_completed ])
         (fun result _ ->
            match result with
            | Ok _ -> ()
            | Error error -> failf "%s: %s" label (Serve.error_to_string error)))
    [ Runtime_native_tools.Native_none, [ "--disable-write"; "--disable-shell" ]
    ; Runtime_native_tools.Native_read, [ "--disable-write"; "--disable-shell" ]
    ; Runtime_native_tools.Native_full, []
    ]
;;

(* An operator interrupt a stream callback raises is the owner's stop, not a
   callback failure to log: it leaves [run_turn] as itself. *)
let test_an_operator_interrupt_from_a_callback_leaves_the_turn () =
  match
    run_scripted
      ~on_stream_event:(function
        | Serve.Turn_started _ -> raise Keeper_operator_interrupt.Operator_interrupt
        | _ -> ())
      (handshake_and_session ~granted:[] @ [ Write agent_started; Write turn_completed ])
      (fun _ _ -> fail "the interrupted turn returned")
  with
  | () -> fail "the interrupted turn returned"
  | exception exn when Keeper_operator_interrupt.is_operator_interrupt exn -> ()
;;

let () =
  run
    "runtime_muse_serve"
    [ ( "turn"
      , [ test_case "turn with tool and approval" `Quick test_turn_with_tool_and_approval
        ; test_case "auth required" `Quick test_auth_required
        ; test_case "exit code is typed" `Quick test_exit_code_is_typed
        ; test_case "bridge needs sessionMcp" `Quick test_bridge_needs_session_mcp
        ; test_case "MASC tools only approval policy" `Quick
            test_masc_tools_only_approval_policy
        ; test_case "no reject choice is a protocol error" `Quick
            test_no_reject_choice_is_a_protocol_error
        ; test_case "a MASC tools only turn completes" `Quick
            test_a_masc_tools_only_turn_completes
        ; test_case "serve flags and environment" `Quick test_serve_flags_and_environment
        ; test_case "a blocked approval answer leaves the turn accepted" `Quick
            test_a_blocked_approval_answer_leaves_the_turn_accepted
        ; test_case "resume reads a null model as unnamed" `Quick
            test_resume_reads_a_null_model_as_unnamed
        ; test_case "a started session on another model is refused" `Quick
            test_a_started_session_on_another_model_is_refused
        ; test_case "an operator interrupt from a callback leaves the turn" `Quick
            test_an_operator_interrupt_from_a_callback_leaves_the_turn
        ] )
    ]
;;
