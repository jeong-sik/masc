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
  | Close_input  (** Close stdin, so the client's next write fails. *)
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
      | Write_times (count, frame) ->
        line
          (Printf.sprintf
             "i=0; while [ $i -lt %d ]; do printf '%%s\\n' %s; i=$((i+1)); done"
             count
             (shell_quote frame))
      | Stderr text -> line (Printf.sprintf "printf '%%s\\n' %s >&2" (shell_quote text))
      | Close_input -> line "exec 0<&-"
      | Exit_with code -> line (Printf.sprintf "exit %d" code))
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
           "read posture selects denyUnmatched"
           true
           (params_member "approvalMode" start = `String "denyUnmatched");
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
      [ ( "masc_keeper"
        , Msp.Streamable_http
            { url = "http://127.0.0.1:1/mcp"; headers = []; required = true } )
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

(* The server frames a real host (muse serve 1.4.0) wrote when its own policy
   closed a [denyUnmatched] approval before MASC's decision landed:
   [approval/request], [approval/resolved], and the -32051
   [approvalAlreadyResolved] answer to MASC's [approval/decide], whose id is
   the fourth request a started session writes. *)
let resolved_by_policy_frames () =
  let path = "fixtures/muse_msp/approval-resolved-by-policy.ndjson" in
  In_channel.with_open_bin path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")
  |> List.filter_map (fun line ->
    match Yojson.Safe.from_string line with
    | `Assoc fields ->
      (match List.assoc_opt "dir" fields, List.assoc_opt "raw" fields with
       | Some (`String "server"), Some (`String raw) -> Some raw
       | Some (`String "client"), Some (`String _) -> None
       | _ -> failf "capture line without a direction and frame: %s" line)
    | _ -> failf "capture line is not an object: %s" line)
;;

let captured_approval_request () =
  match resolved_by_policy_frames () with
  | [ request; _resolved; _already_resolved ] -> request
  | frames -> failf "expected three server frames in the capture, got %d" (List.length frames)
;;

let approval_steps ~decide_answer =
  match resolved_by_policy_frames () with
  | [ request; resolved; _already_resolved ] ->
    handshake_and_session ~granted:[]
    @ [ Write agent_started
      ; Write request
      ; Write resolved
      ; Read (* approval ack *)
      ; Read (* approval/decide *)
      ; Write decide_answer
      ; Write agent_completed
      ; Write turn_completed
      ]
  | frames -> failf "expected three server frames in the capture, got %d" (List.length frames)
;;

(* A refusal of the fourth request with [data] as given. *)
let decide_refusal ~code data =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":4,"error":{"code":%d,"message":"refused","data":%s}}|}
    code
    data
;;

(* The host's policy closed the approval first. Its -32051 answer names the
   winning resolution; the turn goes on to [turn/completed], and MASC's
   decision, which did not land, is neither reported nor counted. *)
let test_an_approval_the_host_already_resolved_leaves_the_turn_running () =
  let already_resolved =
    match resolved_by_policy_frames () with
    | [ _; _; answer ] -> answer
    | frames -> failf "expected three server frames in the capture, got %d" (List.length frames)
  in
  let decided = ref [] in
  let resolved = ref [] in
  run_scripted
    ~on_stream_event:(function
      | Serve.Approval_decided { decision; _ } -> decided := decision :: !decided
      | Serve.Approval_resolved_by_host { tool_name; resolution; masc_decision; subject = _ } ->
        resolved := (tool_name, masc_decision, resolution) :: !resolved
      | _ -> ())
    (approval_steps ~decide_answer:already_resolved)
    (fun result requests ->
       match result with
       | Error error -> fail (Serve.error_to_string error)
       | Ok turn ->
         check string "reply" "MASC_MUSE_OK" turn.text;
         check int "no decision of MASC's landed" 0 turn.approvals_decided;
         check int "no decision is reported as MASC's" 0 (List.length !decided);
         (match !resolved with
          | [ ( "mcp__masc__ping"
              , Msp.Abort
              , Some { Msp.decision = Msp.Denied; resolved_by = Msp.Resolved_by_policy } )
            ] -> ()
          | _ -> fail "the host's own resolution, beside MASC's abort, was not reported once");
         let (_ : Yojson.Safe.t) = request_with_method "approval/decide" requests in
         ())
;;

(* Any other refusal of [approval/decide] still fails the turn, carrying
   the kind it named. *)
let test_another_refusal_of_a_decision_fails_the_turn () =
  let choice_invalid =
    decide_refusal
      ~code:(-32052)
      {|{"kind":"approvalChoiceInvalid","retryable":false,"choiceId":"abort"}|}
  in
  run_scripted
    (approval_steps ~decide_answer:choice_invalid)
    (fun result _ ->
       match result with
       | Error
           (Serve.Rpc_error
             { method_ = "approval/decide"
             ; code = -32052
             ; message = "refused"
             ; data = Serve.Error_data (Msp.Rpc_error_kind Msp.Rpc_approval_choice_invalid)
             }) -> ()
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "a refused decision left the turn running")
;;

(* A refusal whose [data] does not decode keeps its code and message, with
   the failed read beside them. *)
let test_a_refusal_with_unreadable_data_keeps_its_code () =
  run_scripted
    (approval_steps ~decide_answer:(decide_refusal ~code:(-32052) {|{"retryable":false}|}))
    (fun result _ ->
       match result with
       | Error
           (Serve.Rpc_error
             { method_ = "approval/decide"
             ; code = -32052
             ; message = "refused"
             ; data = Serve.Unreadable_error_data _
             }) -> ()
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "a refused decision left the turn running")
;;

(* [approvalAlreadyResolved] with a malformed resolution still says the
   approval is closed: the turn goes on, and the resolution is reported as
   unknown. *)
let test_an_unreadable_resolution_still_leaves_the_turn_running () =
  let resolved = ref [] in
  run_scripted
    ~on_stream_event:(function
      | Serve.Approval_resolved_by_host { resolution; _ } -> resolved := resolution :: !resolved
      | _ -> ())
    (approval_steps
       ~decide_answer:
         (decide_refusal
            ~code:(-32051)
            {|{"kind":"approvalAlreadyResolved","resolution":{"decision":"denied"}}|}))
    (fun result _ ->
       match result with
       | Error error -> fail (Serve.error_to_string error)
       | Ok turn ->
         check string "reply" "MASC_MUSE_OK" turn.text;
         check bool "the resolution is reported as unknown" true (!resolved = [ None ]))
;;

(* [turn/completed] before the host answered MASC's decision: the turn
   stands, and the decision is reported as unanswered rather than dropped
   or counted. *)
let test_a_decision_the_turn_outran_is_reported_unanswered () =
  let unanswered = ref [] in
  run_scripted
    ~on_stream_event:(function
      | Serve.Approval_unanswered { tool_name; decision; subject = _ } ->
        unanswered := (tool_name, decision) :: !unanswered
      | _ -> ())
    (handshake_and_session ~granted:[]
     @ [ Write agent_started
       ; Write (captured_approval_request ())
       ; Read (* approval ack *)
       ; Read (* approval/decide *)
       ; Write agent_completed
       ; Write turn_completed
       ])
    (fun result _ ->
       match result with
       | Error error -> fail (Serve.error_to_string error)
       | Ok turn ->
         check int "an unanswered decision is not counted" 0 turn.approvals_decided;
         check bool "the unanswered decision is reported once" true
           (!unanswered = [ "mcp__masc__ping", Msp.Abort ]))
;;

(* The host stops reading before MASC answers an approval request. The
   answer is not best effort: the turn fails as a write failure naming the
   tool, instead of waiting on a host that holds it. *)
let test_a_failed_approval_answer_write_fails_the_turn () =
  run_scripted
    (handshake_and_session ~granted:[]
     @ [ Write agent_started; Close_input; Write (captured_approval_request ()) ])
    (fun result _ ->
       match result with
       | Error (Serve.Approval_answer_write_failed { tool_name = "mcp__masc__ping"; detail = _ }) ->
         ()
       | Error error -> fail (Serve.error_to_string error)
       | Ok _ -> fail "a turn whose approval answer was never written completed")
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
        ; test_case "native none is config error" `Quick test_native_none_is_config_error
        ; test_case "a blocked approval answer leaves the turn accepted" `Quick
            test_a_blocked_approval_answer_leaves_the_turn_accepted
        ; test_case "resume reads a null model as unnamed" `Quick
            test_resume_reads_a_null_model_as_unnamed
        ; test_case "a started session on another model is refused" `Quick
            test_a_started_session_on_another_model_is_refused
        ; test_case "an operator interrupt from a callback leaves the turn" `Quick
            test_an_operator_interrupt_from_a_callback_leaves_the_turn
        ; test_case "an approval the host already resolved leaves the turn running" `Quick
            test_an_approval_the_host_already_resolved_leaves_the_turn_running
        ; test_case "another refusal of a decision fails the turn" `Quick
            test_another_refusal_of_a_decision_fails_the_turn
        ; test_case "a refusal with unreadable data keeps its code" `Quick
            test_a_refusal_with_unreadable_data_keeps_its_code
        ; test_case "an unreadable resolution still leaves the turn running" `Quick
            test_an_unreadable_resolution_still_leaves_the_turn_running
        ; test_case "a decision the turn outran is reported unanswered" `Quick
            test_a_decision_the_turn_outran_is_reported_unanswered
        ; test_case "a failed approval answer write fails the turn" `Quick
            test_a_failed_approval_answer_write_fails_the_turn
        ] )
    ]
;;
