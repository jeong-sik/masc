(** The durable Gate in front of attached outside services.

    On 2026-08-27 one keeper wrote three tickets and two comments
    into a company Jira with no approval anywhere: neither approval device
    covered the identity-tool path. These tests pin the three claims of the
    fix, each against the real files under a temp base path:

    1. routing — provider annotations do not bypass the external Gate;
    2. the lane — opening the workspace Gate ([Always_allow]) does not open
       writes to somebody else's service, and opening the external lane is
       its own explicit gesture;
    3. the inversion — the approved input decodes back to exactly one call,
       strictly, so host replay spends approvals without the model
       re-emitting a byte-identical payload. *)

module Gate = Masc.Keeper_identity_gate
module Identity_tools = Masc.Keeper_identity_tools
module Mode = Masc.Keeper_gate_mode
module Queue = Masc.Keeper_approval_queue
module Projection = Masc.Keeper_secret_projection
module Provider = Keeper_oauth_provider

let check = Alcotest.check
let str = Alcotest.string

(* The Keeper name here is deliberately not a word: an ordinary one
   eventually picks a live Keeper's, which is what
   test/fixtures/concrete-keeper-identities.txt exists to stop. *)
let keeper_name = "identity-gate-fixture"

let declaration =
  {|
id = "atlassian"
label = "Atlassian"
mcp_url = "https://mcp.atlassian.com/v1/mcp/authv2"
access_token_env = "ATLASSIAN_ACCESS_TOKEN"
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600

[authorize_params]
audience = "api.atlassian.com"
|}

let provider () =
  match Provider.load ~file_name:"atlassian" ~contents:declaration with
  | Ok provider -> provider
  | Error err ->
      Alcotest.failf "declaration rejected: %s" (Provider.error_to_string err)

let temp_base () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-identity-gate-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir path 0o700;
  path

let meta () =
  match
    Masc_test_deps.meta_of_json_fixture (`Assoc [ ("name", `String keeper_name) ])
  with
  | Ok meta -> meta
  | Error detail -> Alcotest.failf "meta fixture rejected: %s" detail

let offered ?read_only remote_name =
  let name = "atlassian_" ^ remote_name in
  let remote_input_schema =
    `Assoc
      [ ("type", `String "object");
        ("properties", `Assoc [ ("key", `Assoc [ ("type", `String "string") ]) ]) ]
  in
  match
    Agent_core.Types.tool_schema_of_input_schema ~name
      ~description:("does " ^ remote_name)
      ~input_schema:remote_input_schema
      ()
  with
  | Ok schema ->
      { Identity_tools.schema; remote_input_schema; read_only; provider = provider (); remote_name }
  | Error detail -> Alcotest.failf "fixture schema rejected: %s" detail

(* A transport that records what it was asked and answers whatever the test
   set. Nothing here reaches a network. *)
let recording_transport ?(modern = false) ?(get_read_only_hint = true) () =
  let sent = ref [] in
  let post ~url ~headers ~body =
    sent := (url, headers, body) :: !sent;
    let request = Yojson.Safe.from_string body in
    let method_ = Yojson.Safe.Util.member "method" request in
    let id = Yojson.Safe.Util.member "id" request in
    let result = match method_ with
      | `String "server/discover" when modern -> `Assoc
          [ "supportedVersions", `List [ `String "2026-07-28" ]
          ; "capabilities", `Assoc [ "tools", `Assoc [] ]
          ; "ttlMs", `Int 0; "cacheScope", `String "private" ]
      | `String "initialize" -> `Assoc
          [ "protocolVersion", `String Mcp_transport_protocol.default_protocol_version
          ; "capabilities", `Assoc [] ]
      | `String "tools/list" ->
        let tool name hint = `Assoc
          [ "name", `String name
          ; "inputSchema", (offered ~read_only:hint name).Identity_tools.remote_input_schema
          ; "annotations", `Assoc [ "readOnlyHint", `Bool hint ] ] in
        `Assoc [ "tools", `List [ tool "getJiraIssue" get_read_only_hint; tool "editJiraIssue" false ] ]
      | `String "tools/call" -> `Assoc
          [ "content", `List [ `Assoc [ "type", `String "text"; "text", `String "PK-1" ] ] ]
      | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> `Null
    in
    let result = match modern, result with
      | true, `Assoc fields -> `Assoc (("resultType", `String "complete") :: fields)
      | false, _ | true, _ -> result in
    let answer =
      if method_ = `String "server/discover" && not modern then
        Yojson.Safe.to_string (`Assoc [ "jsonrpc", `String "2.0"; "id", id
          ; "error", `Assoc [ "code", `Int (-32601); "message", `String "not found" ] ])
      else Yojson.Safe.to_string (`Assoc [ "jsonrpc", `String "2.0"; "id", id; "result", result ]) in
    Ok
      {
        Masc_http_client.status = 200;
        headers = [ ("content-type", "application/json") ];
        body = answer;
      }
  in
  (post, sent)

let unreachable_transport () =
  let post ~url:_ ~headers:_ ~body:_ =
    Alcotest.fail "the transport was reached before the Gate answered"
  in
  post

(* The durable queue is installed per workspace at server bootstrap; a
   deferral submits into it, so the tests that defer install it first. *)
let install_queue ~base_path =
  match Queue.install_persistence ~base_path with
  | Ok _ -> ()
  | Error error -> Alcotest.fail (Masc.Keeper_approval_queue_result.install_error_to_string error)

let allow_external ~base_path =
  let config = Masc.Workspace.default_config base_path in
  match Mode.set_external config ~actor:"identity-gate-test" Mode.Always_allow with
  | Ok _ -> ()
  | Error message -> Alcotest.failf "could not open the external lane: %s" message

let project_token ~base_path =
  match
    Projection.set_env_entry ~base_path ~keeper_name
      ~scope:Projection.Keeper_secret ~name:"ATLASSIAN_ACCESS_TOKEN"
      ~value:"the-keepers-token"
  with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not project a token: %s" message

(* The renewal hops are not what these cases pin; reaching one is a defect
   the case reports rather than a fixture that answers. *)
let never_token_post ~url:_ ~headers:_ ~body:_ =
  Alcotest.fail "the token endpoint was reached when it should not have been"

let never_discover ~mcp_url:_ =
  Alcotest.fail "renewal reached the network when it should not have"

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i =
    i + n <= h && (String.sub haystack i n = needle || scan (i + 1))
  in
  n = 0 || scan 0

let transports_of_post post =
  { Identity_tools.mcp_post = post; token_post = never_token_post; discover = never_discover }

let execute ?post ~base_path tool_fixture arguments =
  let config = Masc.Workspace.default_config base_path in
  let tool =
    Gate.agent_tool ?transports:(Option.map transports_of_post post) ~config
      ~meta:(meta ()) tool_fixture
  in
  Agent_core.Base.Tool.execute tool arguments

(* An explicitly allowed external call still needs a bounded transport. *)
let test_without_a_clock_the_call_is_refused_not_unbounded () =
  let base_path = temp_base () in
  allow_external ~base_path;
  let config = Masc.Workspace.default_config base_path in
  let tool = Gate.agent_tool ~config ~meta:(meta ()) (offered ~read_only:true "getJiraIssue") in
  match Agent_core.Base.Tool.execute tool (`Assoc [ ("key", `String "PK-1") ]) with
  | Ok output ->
      Alcotest.failf "a call with no clock ran: %s" output.Agent_core.Types.content
  | Error err ->
      check Alcotest.bool "the model is not told to retry" false
        err.Agent_core.Types.recoverable;
      check Alcotest.bool "and is told why" true
        (contains ~needle:"no clock" err.Agent_core.Types.message)

let member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let deferred_decision_of_content content =
  match Yojson.Safe.from_string content with
  | json -> (
      match (member "operation" json, member "gate" json) with
      | Some (`String operation), Some gate -> (
          match member "decision" gate with
          | Some (`String decision) -> (operation, decision)
          | _ -> Alcotest.fail "the deferred payload names no decision")
      | _ -> Alcotest.fail "the deferred payload names no operation")
  | exception Yojson.Json_error message ->
      Alcotest.failf "the tool's answer is not the deferred payload: %s" message

let pending_dump ~base_path =
  match Queue.list_pending_dashboard_json_for_workspace ~base_path with
  | Ok items -> (List.length items, Yojson.Safe.to_string (`List items))
  | Error error ->
      Alcotest.failf "the pending queue did not read: %s"
        (Masc.Keeper_approval_queue_result.storage_error_to_string error)

(* ── routing: the external Gate owns attached calls ─────────────────── *)

let test_silence_defers_durably () =
  (* No token is projected and the transport faults the test on contact:
     the deferral proves the Gate is asked before the credential is read
     and before anything reaches the wire — ordering, not just outcome. *)
  let base_path = temp_base () in
  install_queue ~base_path;
  match
    execute ~post:(unreachable_transport ()) ~base_path
      (offered "addCommentToJiraIssue")
      (`Assoc [ ("key", `String "PK-1") ])
  with
  | Error err ->
      Alcotest.failf "a deferral is an answer, not a failure: %s"
        err.Agent_core.Types.message
  | Ok output ->
      let operation, decision =
        deferred_decision_of_content output.Agent_core.Types.content
      in
      check str "one closed operation identity" "identity_call" operation;
      check str "and the call was deferred, not run" "deferred" decision;
      let count, dump = pending_dump ~base_path in
      check Alcotest.int "one durable pending entry" 1 count;
      check Alcotest.bool "the entry carries the remote tool name" true
        (contains ~needle:"addCommentToJiraIssue" dump);
      check Alcotest.bool "and the provider" true
        (contains ~needle:"atlassian" dump)

let test_a_declared_write_defers_durably () =
  let base_path = temp_base () in
  install_queue ~base_path;
  match
    execute ~post:(unreachable_transport ()) ~base_path
      (offered ~read_only:false "editJiraIssue")
      (`Assoc [ ("key", `String "PK-1") ])
  with
  | Error err ->
      Alcotest.failf "a deferral is an answer, not a failure: %s"
        err.Agent_core.Types.message
  | Ok output ->
      let _, decision =
        deferred_decision_of_content output.Agent_core.Types.content
      in
      check str "deferred" "deferred" decision

let test_the_providers_read_only_word_does_not_bypass_gate () =
  let base_path = temp_base () in
  install_queue ~base_path;
  project_token ~base_path;
  let post, sent = recording_transport () in
  match
    execute ~post ~base_path
      (offered ~read_only:true "getJiraIssue")
      (`Assoc [ ("key", `String "PK-1") ])
  with
  | Error err ->
      Alcotest.failf "a deferral is an answer: %s" err.Agent_core.Types.message
  | Ok output ->
      let _, decision = deferred_decision_of_content output.Agent_core.Types.content in
      check str "the provider hint cannot bypass approval" "deferred" decision;
      check Alcotest.bool "the call did not go out" true (!sent = []);
      let count, _ = pending_dump ~base_path in
      check Alcotest.int "the call is enqueued" 1 count

let test_changed_modern_catalog_does_not_send_the_tool_call () =
  let base_path = temp_base () in
  allow_external ~base_path;
  project_token ~base_path;
  let offered_tool = offered ~read_only:true "getJiraIssue" in
  let calls = ref 0 in
  let discoveries = ref 0 in
  let listings = ref 0 in
  let post ~url:_ ~headers:_ ~body =
    let json = Yojson.Safe.from_string body in
    let method_ = match member "method" json with Some (`String value) -> value | _ -> "" in
    let answer =
      match method_ with
      | "server/discover" ->
        incr discoveries;
        {|{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}}|}
      | "tools/list" ->
        incr listings;
        Yojson.Safe.to_string
          (`Assoc [ "jsonrpc", `String "2.0"; "id", `Int 2;
                    "result", `Assoc [ "resultType", `String "complete";
                      "tools", `List [ `Assoc [ "name", `String "getJiraIssue";
                        "inputSchema", offered_tool.Identity_tools.remote_input_schema;
                        "annotations", `Assoc [ "readOnlyHint", `Bool false ] ] ];
                      "ttlMs", `Int 0; "cacheScope", `String "private" ] ])
      | _ -> incr calls; "{}"
    in
    Ok { Masc_http_client.status = 200; headers = [ "content-type", "application/json" ]; body = answer }
  in
  (match execute ~post ~base_path offered_tool (`Assoc [ "key", `String "PK-1" ]) with
   | Error error ->
     check Alcotest.bool "the catalog change is the reason" true
       (contains ~needle:"tool schema changed since approval" error.Agent_core.Types.message)
   | Ok _ -> Alcotest.fail "a changed read-only hint was accepted");
  check Alcotest.int "modern discovery was reached" 1 !discoveries;
  check Alcotest.int "the live catalog was read" 1 !listings;
  check Alcotest.int "no tool request was sent" 0 !calls

(* Real queue, grant, Gate and client wiring, with only the remote HTTP
   answers stubbed. This intentionally exercises the direct identity replay
   entrypoint; the host's settlement and restart path is a separate boundary. *)
let approved_identity_call ~base_path fixture arguments =
  let config = Masc.Workspace.default_config base_path in
  let keeper = meta () in
  (match Masc.Keeper_meta_store.replace_snapshot config keeper with
   | Ok () -> () | Error error -> Alcotest.fail error);
  install_queue ~base_path;
  project_token ~base_path;
  (match execute ~post:(unreachable_transport ()) ~base_path fixture arguments with
   | Ok output ->
     let _, decision = deferred_decision_of_content output.Agent_core.Types.content in
     check str "the identity call was deferred" "deferred" decision
   | Error error -> Alcotest.fail error.Agent_core.Types.message);
  let pending = match Queue.list_pending_entries_for_workspace ~base_path with
    | Ok [ pending ] -> pending
    | Ok _ -> Alcotest.fail "expected exactly one pending identity approval"
    | Error error -> Alcotest.fail (Masc.Keeper_approval_queue_result.storage_error_to_string error) in
  let input = pending.Keeper_approval_queue_rules_types.input in
  let id = pending.id in
  (match Queue.resolve_with_policy ~base_path ~id
           ~decision:Keeper_approval_queue_rules_types.Decision.Approve
           ~source:Keeper_approval_queue_rules_types.Human_operator () with
   | Ok _ -> () | Error error -> Alcotest.fail (Queue.resolve_error_to_string error));
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id = id; decision = Keeper_event_queue.Hitl_approved;
      channel = pending.continuation_channel } in
  let grant = match Masc.Keeper_gate.cycle_grant_of_resolution resolution with
    | Some grant -> grant | None -> Alcotest.fail "approval produced no grant" in
  let call = match Gate.replay_of_gate_input input with
    | Ok call -> call | Error error -> Alcotest.fail error in
  config, keeper, id, grant, call

let tool_calls sent =
  !sent |> List.filter_map (fun (_, _, body) ->
    let json = Yojson.Safe.from_string body in
    match member "method" json with
    | Some (`String "tools/call") -> Some json
    | Some (`String _) | Some _ | None -> None)

let method_count sent method_ =
  !sent |> List.fold_left (fun count (_, _, body) ->
    if member "method" (Yojson.Safe.from_string body) = Some (`String method_)
    then count + 1 else count) 0

let test_approved_replay_checks_catalog_and_sends_once ~modern () =
  let base_path = temp_base () in
  let arguments = `Assoc [ "key", `String "PK-1" ] in
  let config, keeper, id, grant, call =
    approved_identity_call ~base_path (offered ~read_only:true "getJiraIssue") arguments in
  let post, sent = recording_transport ~modern () in
  let replay () = Gate.replay_call_with_outcome ~transports:(transports_of_post post)
    ~config ~meta:keeper ~gate_grant:grant call in
  let result = replay () in
  (match result.Masc.Keeper_tool_execution.disposition with
   | Tool_result.Completed () -> ()
   | Tool_result.Deferred () | Tool_result.Failed _ ->
     Alcotest.failf "approved replay failed: %s" result.raw_output);
  (match tool_calls sent with
   | [ request ] ->
     check Alcotest.bool "approved arguments are sent verbatim" true
       (Yojson.Safe.Util.(request |> member "params" |> member "arguments") = arguments);
     check Alcotest.bool "approved remote tool is selected" true
       (Yojson.Safe.Util.(request |> member "params" |> member "name") = `String "getJiraIssue")
   | _ -> Alcotest.fail "expected exactly one approved tool call");
  let tool_post = !sent |> List.find_opt (fun (_, _, body) ->
    member "method" (Yojson.Safe.from_string body) = Some (`String "tools/call")) in
  (match tool_post with
   | Some (url, headers, _) ->
     check str "approved provider endpoint" "https://mcp.atlassian.com/v1/mcp/authv2" url;
     check (Alcotest.option str) "Keeper's credential is used" (Some "Bearer the-keepers-token")
       (List.assoc_opt "Authorization" headers);
     if modern then
       check (Alcotest.option str) "modern call carries the negotiated version" (Some "2026-07-28")
         (List.assoc_opt "MCP-Protocol-Version" headers)
   | None -> Alcotest.fail "no tool post was captured");
  check Alcotest.int "discovery was attempted once" 1 (method_count sent "server/discover");
  check Alcotest.int "only legacy negotiates initialize" (if modern then 0 else 1)
    (method_count sent "initialize");
  check Alcotest.int "catalog was checked before the call" 1 (method_count sent "tools/list");
  (match Queue.approved_resolution_state ~base_path ~id with
   | Ok Masc.Keeper_approval_queue_result.Resolution_consumed -> ()
   | Ok Masc.Keeper_approval_queue_result.Resolution_unconsumed ->
     Alcotest.fail "the one-shot grant was not consumed"
   | Error error -> Alcotest.fail (Masc.Keeper_approval_queue_result.grant_error_to_string error));
  let repeated = replay () in
  (match repeated.Masc.Keeper_tool_execution.disposition with
   | Tool_result.Deferred () -> ()
   | Tool_result.Completed () | Tool_result.Failed _ ->
     Alcotest.failf "a spent grant should require a new approval: %s" repeated.raw_output);
  check Alcotest.int "the same grant cannot send a second tool call" 1 (List.length (tool_calls sent))

let test_approved_replay_rejects_changed_catalog () =
  let base_path = temp_base () in
  let config, keeper, id, grant, call =
    approved_identity_call ~base_path (offered ~read_only:true "getJiraIssue") (`Assoc []) in
  let post, sent = recording_transport ~modern:true ~get_read_only_hint:false () in
  let result = Gate.replay_call_with_outcome ~transports:(transports_of_post post)
    ~config ~meta:keeper ~gate_grant:grant call in
  (match result.Masc.Keeper_tool_execution.disposition with
   | Tool_result.Failed _ -> ()
   | Tool_result.Completed () | Tool_result.Deferred () ->
     Alcotest.fail "changed catalog was accepted");
  check Alcotest.bool "catalog mismatch was a pre-effect failure" true
    (result.failure_effect_disposition = Tool_result.Proven_pre_effect);
  check Alcotest.bool "live schema mismatch caused the rejection" true
    (contains ~needle:"tool schema changed since approval" result.raw_output);
  check Alcotest.int "the live catalog was queried once" 1 (method_count sent "tools/list");
  check Alcotest.int "modern discovery was used" 1 (method_count sent "server/discover");
  check Alcotest.int "modern replay did not fall back to initialize" 0 (method_count sent "initialize");
  (match Queue.approved_resolution_state ~base_path ~id with
   | Ok Masc.Keeper_approval_queue_result.Resolution_consumed -> ()
   | Ok Masc.Keeper_approval_queue_result.Resolution_unconsumed ->
     Alcotest.fail "the live catalog check did not follow grant consumption"
   | Error error -> Alcotest.fail (Masc.Keeper_approval_queue_result.grant_error_to_string error));
  check Alcotest.int "changed catalog cannot reach tools/call" 0 (List.length (tool_calls sent))

let test_approved_replay_rejects_changed_provider_before_grant () =
  let base_path = temp_base () in
  let changed_declaration = Str.global_replace
    (Str.regexp_string "https://mcp.atlassian.com/v1/mcp/authv2")
    "https://different.example/mcp" declaration in
  let changed_provider = match Provider.load ~file_name:"atlassian" ~contents:changed_declaration with
    | Ok provider -> provider | Error error -> Alcotest.fail (Provider.error_to_string error) in
  let fixture = { (offered ~read_only:true "getJiraIssue") with provider = changed_provider } in
  let config, keeper, id, grant, call = approved_identity_call ~base_path fixture (`Assoc []) in
  let post, sent = recording_transport () in
  let result = Gate.replay_call_with_outcome ~transports:(transports_of_post post)
    ~config ~meta:keeper ~gate_grant:grant call in
  (match result.Masc.Keeper_tool_execution.disposition with
   | Tool_result.Failed _ -> ()
   | Tool_result.Completed () | Tool_result.Deferred () -> Alcotest.fail "changed provider was accepted");
  check Alcotest.bool "provider change was a pre-effect failure" true
    (result.failure_effect_disposition = Tool_result.Proven_pre_effect);
  check Alcotest.bool "provider declaration mismatch caused the rejection" true
    (contains ~needle:"the provider declaration changed" result.raw_output);
  check Alcotest.bool "no network call occurred" true (!sent = []);
  (match Queue.approved_resolution_state ~base_path ~id with
   | Ok Masc.Keeper_approval_queue_result.Resolution_unconsumed -> ()
   | Ok Masc.Keeper_approval_queue_result.Resolution_consumed ->
     Alcotest.fail "provider validation consumed the grant"
   | Error error -> Alcotest.fail (Masc.Keeper_approval_queue_result.grant_error_to_string error))

(* ── the lane: two switches, two questions ────────────────────────────── *)

let test_workspace_always_allow_does_not_open_outside_writes () =
  (* The incident-shaped case. On 2026-08-27, 374 of the day's 379 Gate
     decisions rode workspace [Always_allow]; a lane that inherited that
     switch would have let the Jira writes through with only an audit row. *)
  let base_path = temp_base () in
  install_queue ~base_path;
  let config = Masc.Workspace.default_config base_path in
  (match Mode.set config ~actor:"identity-gate-test" Mode.Always_allow with
  | Ok _ -> ()
  | Error message -> Alcotest.failf "could not open the workspace lane: %s" message);
  match
    execute ~post:(unreachable_transport ()) ~base_path
      (offered ~read_only:false "editJiraIssue")
      (`Assoc [ ("key", `String "PK-1") ])
  with
  | Error err ->
      Alcotest.failf "a deferral is an answer, not a failure: %s"
        err.Agent_core.Types.message
  | Ok output ->
      let _, decision =
        deferred_decision_of_content output.Agent_core.Types.content
      in
      check str "the workspace switch does not reach this lane" "deferred"
        decision

let test_opening_the_external_lane_is_its_own_gesture () =
  let base_path = temp_base () in
  let config = Masc.Workspace.default_config base_path in
  project_token ~base_path;
  (match Mode.set_external config ~actor:"identity-gate-test" Mode.Always_allow with
  | Ok _ -> ()
  | Error message -> Alcotest.failf "could not open the external lane: %s" message);
  let post, _ = recording_transport () in
  match
    execute ~post ~base_path
      (offered ~read_only:false "editJiraIssue")
      (`Assoc [ ("key", `String "PK-1") ])
  with
  | Error err ->
      Alcotest.failf "an explicitly opened lane still deferred: %s"
        err.Agent_core.Types.message
  | Ok output ->
      check str "the call ran" "PK-1" output.Agent_core.Types.content

let test_the_external_lane_defaults_to_manual () =
  check str "the lane's declared default is Manual" "manual"
    (Mode.to_string Mode.default_external);
  let base_path = temp_base () in
  (match Mode.read_external ~base_path with
  | Ok mode -> check str "absent state selects Manual" "manual" (Mode.to_string mode)
  | Error message -> Alcotest.failf "the absent lane did not read: %s" message);
  match Mode.read ~base_path with
  | Ok mode ->
      check str "while the workspace lane keeps its own default" "auto_judge"
        (Mode.to_string mode)
  | Error message -> Alcotest.failf "the workspace lane did not read: %s" message

(* ── the inversion: approved input to exactly one call ────────────────── *)

let test_the_gate_input_inverts () =
  let arguments = `Assoc [ ("key", `String "PK-1"); ("body", `String "hello") ] in
  let input =
    Gate.gate_input ~provider:(provider ())
      ~remote_name:"addCommentToJiraIssue" ~arguments
      ~input_schema:(`Assoc [ "type", `String "object" ])
      ~read_only:(Some false)
  in
  match Gate.replay_of_gate_input input with
  | Error message -> Alcotest.failf "its own encoding did not decode: %s" message
  | Ok call ->
      check str "provider" "atlassian" call.Gate.provider_id;
      check str "remote tool" "addCommentToJiraIssue" call.Gate.remote_name;
      check Alcotest.bool "arguments verbatim" true (call.Gate.arguments = arguments);
      check Alcotest.bool "approved schema preserved" true
        (call.Gate.input_schema = Some (`Assoc [ "type", `String "object" ]));
      check (Alcotest.option Alcotest.bool) "approved hint preserved" (Some false) call.Gate.read_only;
      check Alcotest.bool "and the stored input verbatim" true
        (call.Gate.input = input);
      check Alcotest.bool "current declaration accepted" true
        (Result.is_ok (Gate.validate_replay_provider ~provider:(provider ()) call));
      check Alcotest.bool "approval does not copy the provider endpoint" false
        (contains ~needle:"mcp.atlassian.com" (Yojson.Safe.to_string input))

let test_replay_requires_same_provider_authority () =
  let original = provider () in
  let input = Gate.gate_input ~provider:original ~remote_name:"getJiraIssue"
    ~arguments:(`Assoc []) ~input_schema:(`Assoc [ "type", `String "object" ])
    ~read_only:(Some true) in
  let call = match Gate.replay_of_gate_input input with
    | Ok call -> call | Error error -> Alcotest.fail error in
  let changed old_text new_text =
    let contents = Str.global_replace (Str.regexp_string old_text) new_text declaration in
    match Provider.load ~file_name:"atlassian" ~contents with
    | Ok provider -> provider
    | Error error -> Alcotest.fail (Provider.error_to_string error) in
  List.iter
    (fun (label, provider) ->
       check Alcotest.bool label true
         (Result.is_error (Gate.validate_replay_provider ~provider call)))
    [ "changed endpoint", changed "https://mcp.atlassian.com/v1/mcp/authv2" "https://different.example/mcp"
    ; "changed token location", changed "ATLASSIAN_ACCESS_TOKEN\"" "OTHER_ACCESS_TOKEN\""
    ; "changed client group", changed "label = \"Atlassian\"" "client_group = \"another\"\nlabel = \"Atlassian\""
    ; "changed credential source", changed "label = \"Atlassian\""
        "credential_source = \"github_cli\"\ncredential_source_host = \"github.com\"\nlabel = \"Atlassian\""
    ; "changed refresh token location", changed "/home/keeper/.atlassian/refresh_token" "/home/keeper/.other/refresh_token"
    ];
  let remove key = match input with
    | `Assoc fields -> `Assoc (List.remove_assoc key fields)
    | _ -> assert false in
  List.iter (fun key ->
    let old = match Gate.replay_of_gate_input (remove key) with
      | Ok call -> call | Error error -> Alcotest.fail error in
    check Alcotest.bool ("old approval missing " ^ key ^ " requires a new approval") true
      (Result.is_error (Gate.validate_replay_provider ~provider:original old)))
    [ "provider_authority_sha256"; "input_schema" ];
  (match input with
   | `Assoc fields ->
     let bad = `Assoc (("provider_authority_sha256", `String "short") ::
                       List.remove_assoc "provider_authority_sha256" fields) in
     check Alcotest.bool "malformed fingerprint rejected" true
       (Result.is_error (Gate.replay_of_gate_input bad))
   | _ -> assert false)

let test_the_decoder_is_strict () =
  List.iter
    (fun input ->
      match Gate.replay_of_gate_input input with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "an invalid approval decoded into a call")
    [ (* missing fields *)
      `Assoc [ ("provider_id", `String "atlassian") ];
      (* a repeated field *)
      `Assoc
        [ ("provider_id", `String "atlassian");
          ("remote_name", `String "a");
          ("remote_name", `String "b");
          ("arguments", `Assoc [])
        ];
      (* an unknown field *)
      `Assoc
        [ ("provider_id", `String "atlassian");
          ("remote_name", `String "a");
          ("arguments", `Assoc []);
          ("widened", `Bool true)
        ];
      (* a blank identity *)
      `Assoc
        [ ("provider_id", `String "  ");
          ("remote_name", `String "a");
          ("arguments", `Assoc [])
        ];
      (* not an object *)
      `String "not an approval"
    ]

let () =
  Alcotest.run "keeper_identity_gate"
    [ ( "routing",
        [ Alcotest.test_case "without a clock the call is refused, not unbounded"
            `Quick test_without_a_clock_the_call_is_refused_not_unbounded;
          Alcotest.test_case "silence defers durably" `Quick
            test_silence_defers_durably;
          Alcotest.test_case "a declared write defers durably" `Quick
            test_a_declared_write_defers_durably;
          Alcotest.test_case "a provider read-only hint cannot bypass the Gate" `Quick
            test_the_providers_read_only_word_does_not_bypass_gate;
          Alcotest.test_case "changed modern catalog stops the call" `Quick
            test_changed_modern_catalog_does_not_send_the_tool_call;
          Alcotest.test_case "approved legacy replay sends exact call once" `Quick
            (test_approved_replay_checks_catalog_and_sends_once ~modern:false);
          Alcotest.test_case "approved modern replay sends exact call once" `Quick
            (test_approved_replay_checks_catalog_and_sends_once ~modern:true);
          Alcotest.test_case "approved replay checks the live catalog" `Quick
            test_approved_replay_rejects_changed_catalog;
          Alcotest.test_case "approved replay checks the provider before grant" `Quick
            test_approved_replay_rejects_changed_provider_before_grant;
        ] );
      ( "the external lane",
        [ Alcotest.test_case
            "workspace always-allow does not open outside writes" `Quick
            test_workspace_always_allow_does_not_open_outside_writes;
          Alcotest.test_case "opening the external lane is its own gesture"
            `Quick test_opening_the_external_lane_is_its_own_gesture;
          Alcotest.test_case "the external lane defaults to manual" `Quick
            test_the_external_lane_defaults_to_manual;
        ] );
      ( "the inversion",
        [ Alcotest.test_case "the gate input inverts" `Quick
            test_the_gate_input_inverts;
          Alcotest.test_case "replay requires the same provider authority" `Quick
            test_replay_requires_same_provider_authority;
          Alcotest.test_case "the decoder is strict" `Quick
            test_the_decoder_is_strict;
        ] );
    ]
