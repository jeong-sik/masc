(** The durable Gate in front of attached outside services.

    On 2026-08-27 one keeper wrote three tickets and two comments
    into a company Jira with no approval anywhere: neither approval device
    covered the identity-tool path. These tests pin the three claims of the
    fix, each against the real files under a temp base path:

    1. routing — only the provider's own written "this tool only reads" runs
       unasked; a declared write and silence both defer durably;
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
  match
    Agent_core.Types.tool_schema_of_input_schema ~name
      ~description:("does " ^ remote_name)
      ~input_schema:
        (`Assoc
           [ ("type", `String "object");
             ("properties", `Assoc [ ("key", `Assoc [ ("type", `String "string") ]) ])
           ])
      ()
  with
  | Ok schema ->
      { Identity_tools.schema; read_only; provider = provider (); remote_name }
  | Error detail -> Alcotest.failf "fixture schema rejected: %s" detail

(* A transport that records what it was asked and answers whatever the test
   set. Nothing here reaches a network. *)
let recording_transport () =
  let sent = ref [] in
  let post ~url ~headers ~body =
    sent := (url, headers, body) :: !sent;
    let answer =
      if
        String.length body > 0
        && Str.string_match (Str.regexp ".*initialize") body 0
      then
        Printf.sprintf
          {|{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":%S,"capabilities":{}}}|}
          Mcp_transport_protocol.default_protocol_version
      else
        {|{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"PK-1"}]}}|}
    in
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
  | Error error -> Alcotest.fail (Queue.install_error_to_string error)

let project_token ~base_path =
  match
    Projection.set_env_entry ~base_path ~keeper_name
      ~scope:Projection.Keeper_secret ~name:"ATLASSIAN_ACCESS_TOKEN"
      ~value:"the-keepers-token"
  with
  | Ok () -> ()
  | Error message -> Alcotest.failf "could not project a token: %s" message

let execute ?post ~base_path tool_fixture arguments =
  let config = Masc.Workspace.default_config base_path in
  let tool = Gate.agent_tool ?post ~config ~meta:(meta ()) tool_fixture in
  Agent_core.Base.Tool.execute tool arguments

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
        (Queue.storage_error_to_string error)

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i =
    i + n <= h && (String.sub haystack i n = needle || scan (i + 1))
  in
  n = 0 || scan 0

(* ── routing: the provider's word, and only that word ─────────────────── *)

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

let test_the_providers_read_only_word_runs () =
  let base_path = temp_base () in
  project_token ~base_path;
  let post, sent = recording_transport () in
  match
    execute ~post ~base_path
      (offered ~read_only:true "getJiraIssue")
      (`Assoc [ ("key", `String "PK-1") ])
  with
  | Error err ->
      Alcotest.failf "a declared read was not run: %s" err.Agent_core.Types.message
  | Ok output ->
      check str "the provider's answer comes back" "PK-1"
        output.Agent_core.Types.content;
      check Alcotest.bool "the call went out" true (!sent <> []);
      let count, _ = pending_dump ~base_path in
      check Alcotest.int "and nothing was enqueued" 0 count

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
    Gate.gate_input ~provider_id:"atlassian"
      ~remote_name:"addCommentToJiraIssue" ~arguments
  in
  match Gate.replay_of_gate_input input with
  | Error message -> Alcotest.failf "its own encoding did not decode: %s" message
  | Ok call ->
      check str "provider" "atlassian" call.Gate.provider_id;
      check str "remote tool" "addCommentToJiraIssue" call.Gate.remote_name;
      check Alcotest.bool "arguments verbatim" true (call.Gate.arguments = arguments);
      check Alcotest.bool "and the stored input verbatim" true
        (call.Gate.input = input)

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
        [ Alcotest.test_case "silence defers durably" `Quick
            test_silence_defers_durably;
          Alcotest.test_case "a declared write defers durably" `Quick
            test_a_declared_write_defers_durably;
          Alcotest.test_case "the provider's read-only word runs" `Quick
            test_the_providers_read_only_word_runs;
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
          Alcotest.test_case "the decoder is strict" `Quick
            test_the_decoder_is_strict;
        ] );
    ]
