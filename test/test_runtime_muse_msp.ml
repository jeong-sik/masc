open Alcotest

(* The fixtures are MSP golden transcripts copied verbatim from
   github.com/meta-models/muse-code-sdk schema/msp/transcripts at a7c10c5
   (MIT; see fixtures/muse_msp/README.md). Each line is
   {"dir":"client"|"server","raw":"<one wire frame>"}. *)

module Msp = Runtime_muse_msp

type direction =
  | Client
  | Server

let transcript name =
  let path = Printf.sprintf "fixtures/muse_msp/%s.ndjson" name in
  In_channel.with_open_bin path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")
  |> List.map (fun line ->
    match Yojson.Safe.from_string line with
    | `Assoc fields ->
      let dir =
        match List.assoc_opt "dir" fields with
        | Some (`String "client") -> Client
        | Some (`String "server") -> Server
        | _ -> failwith ("transcript line without a direction: " ^ line)
      in
      let raw =
        match List.assoc_opt "raw" fields with
        | Some (`String raw) -> raw
        | _ -> failwith ("transcript line without a frame: " ^ line)
      in
      dir, raw
    | _ -> failwith ("transcript line is not an object: " ^ line))
;;

let ok_or_fail = function
  | Ok value -> value
  | Error error -> fail (Msp.error_to_string error)
;;

let server_frames name =
  transcript name
  |> List.filter_map (function
    | Server, raw -> Some (ok_or_fail (Msp.parse_wire_line raw))
    | Client, _ -> None)
;;

let client_frames name =
  transcript name
  |> List.filter_map (function
    | Client, raw -> Some (Yojson.Safe.from_string raw)
    | Server, _ -> None)
;;

let notifications name =
  server_frames name
  |> List.filter_map (function
    | Msp.Notification { method_; params } ->
      Some (ok_or_fail (Msp.parse_notification ~method_ params))
    | _ -> None)
;;

let json = testable Yojson.Safe.pp (fun a b -> Yojson.Safe.equal (Yojson.Safe.sort a) (Yojson.Safe.sort b))

let client_frame_with_method name method_ =
  match
    List.find_opt
      (function
        | `Assoc fields -> List.assoc_opt "method" fields = Some (`String method_)
        | _ -> false)
      (client_frames name)
  with
  | Some frame -> frame
  | None -> failf "transcript %s has no client %s frame" name method_
;;

let response_result id frames =
  match
    List.find_map
      (function
        | Msp.Response { id = response_id; result } when response_id = id -> Some result
        | _ -> None)
      frames
  with
  | Some result -> result
  | None -> fail "response not found"
;;

(* A whole turn as MASC reads it: the reply the deltas stream, the reply the
   completed item states, and the terminal. The two replies must agree —
   MSP's own delta contract (spec 14653 INV-005). *)
let test_text_run_single_turn () =
  let frames = server_frames "text-run-single-turn" in
  let init = ok_or_fail (Msp.parse_initialize_result (response_result (Msp.Int_id 1) frames)) in
  check string "muse home" "/home/fixture/.muse" init.muse_home;
  let session =
    ok_or_fail
      (Msp.parse_session_result ~stage:"session/start" (response_result (Msp.Int_id 2) frames))
  in
  check string "session id" "0198f0aa-1111-7000-8000-0000000000aa" session.session_id;
  check (option string) "model" (Some "muse-large-2") session.model_id;
  let ack = ok_or_fail (Msp.parse_turn_start_result (response_result (Msp.Int_id 3) frames)) in
  check bool "turn started" true (ack.disposition = Msp.Started);
  let streamed = Buffer.create 64 in
  let completed_reply = ref None in
  let terminal = ref None in
  List.iter
    (function
      | Msp.Item_delta { field = Msp.Delta_text; delta; _ } -> Buffer.add_string streamed delta
      | Msp.Item_completed { item = { kind = Msp.Agent_message; text; _ }; _ } ->
        completed_reply := text
      | Msp.Turn_completed { turn_id; terminal = t; usage; _ } ->
        check string "terminal turn" ack.turn_id turn_id;
        terminal := Some (t, usage)
      | _ -> ())
    (notifications "text-run-single-turn");
  check
    (option string)
    "completed reply equals streamed reply"
    (Some (Buffer.contents streamed))
    !completed_reply;
  match !terminal with
  | Some (Msp.Terminal_completed, Some usage) ->
    check int "input" 48210 usage.input_tokens;
    check int "output" 1211 usage.output_tokens;
    check int "cached" 40100 usage.cached_tokens;
    check int "reasoning" 384 usage.reasoning_tokens
  | _ -> fail "expected a completed terminal carrying usage"
;;

(* The frames MASC writes must be the frames the conformance corpus writes. *)
let test_client_frames_match_corpus () =
  let name = "text-run-single-turn" in
  check json "initialized" (client_frame_with_method name "initialized") Msp.initialized_notification;
  check
    json
    "session/start"
    (client_frame_with_method name "session/start")
    (Msp.session_start_request
       ~id:2
       ~command_id:"0198f0ab-9999-7000-8000-0000000000c1"
       ~workspace_root:"/home/me/src/proj"
       ~model_id:None
       ~approval_mode:None
       ~config:{ mcp_servers = [] });
  check
    json
    "turn/start"
    (client_frame_with_method name "turn/start")
    (Msp.turn_start_request
       ~id:3
       ~session_id:"0198f0aa-1111-7000-8000-0000000000aa"
       ~command_id:"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10"
       ~input:[ Msp.Text "Run the agent test suite and summarize failures" ]
       ~reasoning_effort:None)
;;

(* MASC asks for [sessionMcp] so a session may carry the MCP bridge; the
   corpus shows the same handshake shape with another capability. *)
let test_capability_handshake () =
  let name = "handshake-liststream-granted" in
  check
    json
    "initialize"
    (client_frame_with_method name "initialize")
    (Msp.initialize_request
       ~id:1
       { name = "conformance"; version = "0.0.0" }
       ~requested_capabilities:[ Msp.Session_list_stream ]
       ~user_input_dialogs:true);
  let init =
    ok_or_fail
      (Msp.parse_initialize_result (response_result (Msp.Int_id 1) (server_frames name)))
  in
  check
    bool
    "granted"
    true
    (init.granted_capabilities = [ Msp.Session_list_stream ]);
  check
    string
    "corpus fingerprint"
    Msp.corpus_schema_fingerprint
    init.schema_fingerprint;
  let other_version =
    Yojson.Safe.from_string
      {|{"serverInfo":{"name":"m","version":"9"},"userAgent":"m","museHome":"/h","sessionDurability":"durable","schema":{"version":2,"fingerprint":"sha256:x"},"grantedCapabilities":[]}|}
  in
  (match Msp.parse_initialize_result other_version with
   | Ok _ -> fail "a schema version other than 1 must be refused"
   | Error _ -> ());
  let frame =
    Msp.initialize_request
      ~id:1
      { name = "masc"; version = "0" }
      ~requested_capabilities:[ Msp.Session_mcp ]
      ~user_input_dialogs:false
  in
  check
    json
    "masc capabilities"
    (Yojson.Safe.from_string
       {|{"requestedCapabilities":["sessionMcp"],"userInputDialogs":false}|})
    (match frame with
     | `Assoc fields ->
       (match List.assoc "params" fields with
        | `Assoc params -> List.assoc "capabilities" params
        | _ -> fail "params is not an object")
     | _ -> fail "frame is not an object")
;;

let test_approval_round_trip () =
  let name = "approval-round-trip" in
  let approval =
    match
      List.find_map
        (function
          | Msp.Server_request { method_; params; _ } ->
            (match ok_or_fail (Msp.parse_server_request ~method_ params) with
             | Msp.Approval_request approval -> Some approval
             | _ -> None)
          | _ -> None)
        (server_frames name)
    with
    | Some approval -> approval
    | None -> fail "no approval/request in transcript"
  in
  check string "tool" "write_file" approval.tool_name;
  check bool "subject" true (approval.subject_kind = Msp.Subject_file_access);
  check
    (list string)
    "choices"
    [ "allow_once"; "allow_session"; "abort" ]
    (List.map (fun (c : Msp.approval_choice) -> c.choice_id) approval.choices);
  let decide = client_frame_with_method name "approval/decide" in
  let params = function
    | `Assoc fields -> List.assoc "params" fields
    | _ -> fail "frame is not an object"
  in
  check
    json
    "approval/decide params"
    (params decide)
    (params
       (Msp.approval_decide_request
          ~id:9
          ~command_id:"018f6a2a-3333-7abc-8def-00000000d001"
          approval
          (List.find
             (fun (c : Msp.approval_choice) -> c.choice_id = "allow_session")
             approval.choices)));
  (* The corpus answers a string request id; the codec reads it as one. *)
  check
    bool
    "string response id"
    true
    (List.exists
       (function
         | Msp.Response { id = Msp.String_id "b9"; _ } -> true
         | _ -> false)
       (server_frames name))
;;

let test_provider_failure_turn () =
  let terminals =
    List.filter_map
      (function
        | Msp.Turn_completed { terminal; _ } -> Some terminal
        | _ -> None)
      (notifications "provider-failure-turn")
  in
  match terminals with
  | [ Msp.Terminal_failed { kind = Msp.Model_error; retryable = true; _ }; Msp.Terminal_completed ] ->
    ()
  | _ -> fail "expected a retryable model failure, then a completed turn"
;;

let test_unknown_item_kind_is_kept () =
  let kinds =
    List.filter_map
      (function
        | Msp.Item_completed { item; _ } -> Some item.kind
        | _ -> None)
      (notifications "tolerance-unknown-item-kind")
  in
  check
    bool
    "unknown kind carries its wire name"
    true
    (List.mem (Msp.Unrecognized_item_kind "hologramPreview") kinds)
;;

let parse_error line =
  match Msp.parse_wire_line line with
  | Ok _ -> failf "expected %s to be refused" line
  | Error _ -> ()
;;

let test_wire_refusals () =
  parse_error {|{"jsonrpc":"2.0","id":1,"id":2,"result":{}}|};
  parse_error {|{"jsonrpc":"2.0","id":1.5,"result":{}}|};
  parse_error {|{"jsonrpc":"2.0"}|};
  parse_error "not json";
  parse_error {|{"jsonrpc":"2.0","id":null,"result":{}}|};
  (match
     Msp.parse_wire_line
       {|{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error","data":null}}|}
   with
   | Ok (Msp.Response_error { id = None; code = -32700; data = None; _ }) -> ()
   | _ -> fail "a null-id error response must be read, with null data as absent");
  let failed_without_error =
    `Assoc
      [ "sessionId", `String "s"
      ; "turnId", `String "t"
      ; "terminal", `String "failed"
      ; "viewCursor", `String "v"
      ]
  in
  match Msp.parse_notification ~method_:"turn/completed" failed_without_error with
  | Ok _ -> fail "a failed terminal without an error must be refused"
  | Error _ -> ()
;;

let test_delta_fields () =
  let delta ?field () =
    let fields =
      [ "sessionId", `String "s"; "itemId", `String "i"; "delta", `String "x" ]
      @ (match field with
         | None -> []
         | Some f -> [ "field", `String f ])
    in
    match ok_or_fail (Msp.parse_notification ~method_:"item/delta" (`Assoc fields)) with
    | Msp.Item_delta { field; _ } -> field
    | _ -> fail "expected an item delta"
  in
  check bool "absent is text" true (delta () = Msp.Delta_text);
  check bool "output" true (delta ~field:"output" () = Msp.Delta_output);
  check bool "summary part" true (delta ~field:"summary.2" () = Msp.Delta_summary 2);
  check
    bool
    "unknown path kept"
    true
    (delta ~field:"summary.x" () = Msp.Unrecognized_delta_field "summary.x")
;;

let test_usage_read () =
  check
    bool
    "nothing observed"
    true
    (ok_or_fail (Msp.parse_usage_read_result (`Assoc [])) = None);
  let observed =
    Yojson.Safe.from_string
      {|{"usage":{"observedAtMs":1758800000000,"tier":"power","window":{"usedPercent":112,"resetsAtMs":1758810000000,"windowDurationMins":300},"weekly":{"usedPercent":40,"resetsAtMs":1759300000000}}}|}
  in
  match ok_or_fail (Msp.parse_usage_read_result observed) with
  | Some usage ->
    check int "over-quota percent is verbatim" 112 usage.window.used_percent;
    check int "window length" 300 usage.window.window_duration_mins;
    check int "weekly" 40 usage.weekly.weekly_used_percent
  | None -> fail "expected an observed usage"
;;

let test_session_config_carries_bridge () =
  let frame =
    Msp.session_resume_request
      ~id:4
      ~command_id:"c"
      ~session_id:"s"
      ~config:
        { mcp_servers =
            [ ( "masc"
              , Msp.Streamable_http
                  { url = "http://127.0.0.1:4100/mcp"
                  ; headers = [ "Authorization", "Bearer t" ]
                  ; required = true
                  } )
            ]
        }
  in
  check
    json
    "resume params"
    (Yojson.Safe.from_string
       {|{"commandId":"c","sessionId":"s","excludeItems":true,"config":{"mcpServers":{"masc":{"transport":"streamableHttp","url":"http://127.0.0.1:4100/mcp","headers":{"Authorization":"Bearer t"},"mode":"required"}}}}|})
    (match frame with
     | `Assoc fields -> List.assoc "params" fields
     | _ -> fail "frame is not an object")
;;

let test_reasoning_effort_round_trip () =
  List.iter
    (fun effort ->
      check
        bool
        (Msp.reasoning_effort_to_string effort)
        true
        (Msp.reasoning_effort_of_string (Msp.reasoning_effort_to_string effort) = Some effort))
    Msp.
      [ Effort_none
      ; Effort_minimal
      ; Effort_low
      ; Effort_medium
      ; Effort_high
      ; Effort_xhigh
      ; Effort_max
      ; Effort_ultra
      ];
  check bool "unknown tier" true (Msp.reasoning_effort_of_string "turbo" = None)
;;

let test_session_durability_is_required_and_typed () =
  let initial = response_result (Msp.Int_id 1) (server_frames "text-run-single-turn") in
  let fields = Yojson.Safe.Util.to_assoc initial in
  let with_durability value =
    let fields = List.remove_assoc "sessionDurability" fields in
    `Assoc (match value with None -> fields | Some value -> ("sessionDurability", value) :: fields)
  in
  List.iter
    (fun (wire, expected) ->
       let parsed = ok_or_fail (Msp.parse_initialize_result (with_durability (Some (`String wire)))) in
       check bool wire true (parsed.session_durability = expected))
    [ "durable", Msp.Durable; "ephemeral", Msp.Ephemeral ];
  List.iter
    (fun value ->
       match Msp.parse_initialize_result (with_durability value) with
       | Error _ -> ()
       | Ok _ -> fail "missing, malformed or unknown durability was accepted")
    [ None; Some `Null; Some (`Bool true); Some (`String "unknown") ];
  let extended = `Assoc (("futureField", `Bool true) :: fields) in
  let parsed = ok_or_fail (Msp.parse_initialize_result extended) in
  check bool "unrelated extension preserves known durability" true (parsed.session_durability = Msp.Durable)
;;

let () =
  run
    "runtime_muse_msp"
    [ ( "corpus"
      , [ test_case "text run single turn" `Quick test_text_run_single_turn
        ; test_case "client frames match corpus" `Quick test_client_frames_match_corpus
        ; test_case "capability handshake" `Quick test_capability_handshake
        ; test_case "host session durability is required and typed" `Quick
            test_session_durability_is_required_and_typed
        ; test_case "approval round trip" `Quick test_approval_round_trip
        ; test_case "provider failure turn" `Quick test_provider_failure_turn
        ; test_case "unknown item kind is kept" `Quick test_unknown_item_kind_is_kept
        ] )
    ; ( "codec"
      , [ test_case "wire refusals" `Quick test_wire_refusals
        ; test_case "delta fields" `Quick test_delta_fields
        ; test_case "usage read" `Quick test_usage_read
        ; test_case "session config carries bridge" `Quick test_session_config_carries_bridge
        ; test_case "reasoning effort round trip" `Quick test_reasoning_effort_round_trip
        ] )
    ]
;;
