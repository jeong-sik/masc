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
let recording_transport ?(modern = false) ?(get_read_only_hint = true)
    ?(call_text = "PK-1") ?call_content ?structured_content ?(call_is_error = false) () =
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
          ([ "content", Option.value call_content
               ~default:(`List [ `Assoc [ "type", `String "text"; "text", `String call_text ] ])
          ; "isError", `Bool call_is_error ]
          @ match structured_content with None -> [] | Some value -> ["structuredContent", value])
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

let transports_of_post send =
  let post : Mcp_client.post = { deadline_s = 60.; send = (fun ~deadline:_ -> send) } in
  { Identity_tools.mcp_post = post; token_post = never_token_post; discover = never_discover }

let invocation () =
  Agent_core.Tool_contract.Invocation.create ~tool_use_id:"identity-call-fixture" ~turn:1
    ~completion:Agent_core.Tool_contract.Continue_after_success
    ~schedule:{ planned_index = 0; batch_index = 0; batch_size = 1;
                execution_mode = Agent_core.Tool_contract.Serial }

let execute ?post ?(invocation = invocation ()) ?(accepts_image_input = false) ?(inline_ceiling_bytes = Common.max_tool_result_wire_bytes)
    ~base_path tool_fixture arguments =
  let config = Masc.Workspace.default_config base_path in
  let tool =
    Gate.agent_tool ?transports:(Option.map transports_of_post post) ~accepts_image_input ~config
      ~meta:(meta ()) ~inline_ceiling_bytes:(fun () -> inline_ceiling_bytes) tool_fixture
  in
  Agent_core.Base.Tool.execute ~invocation tool arguments

(* An explicitly allowed external call still needs a bounded transport. *)
let test_without_a_clock_the_call_is_refused_not_unbounded () =
  let base_path = temp_base () in
  allow_external ~base_path;
  let config = Masc.Workspace.default_config base_path in
  let tool =
    Gate.agent_tool ~config ~meta:(meta ())
      ~inline_ceiling_bytes:(fun () -> Common.max_tool_result_wire_bytes)
      (offered ~read_only:true "getJiraIssue")
  in
  match Agent_core.Base.Tool.execute ~invocation:(invocation ()) tool (`Assoc [ ("key", `String "PK-1") ]) with
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

(* ── the answer: what the model receives from an allowed call ──────── *)

(* On 2026-11-04 one Confluence page came back at 52,480 characters. A
   Claude Code Keeper got it whole, the CLI spilled it to a file under its own
   configuration directory, and the Keeper's Read refused that path as outside
   its sandbox. *)
let oversized_answer () =
  String.concat "\n"
    (List.init 2_000 (fun line -> Printf.sprintf "%04d 페이지 본문 한 줄" line))

let retry_warning = "The service may have applied an effect; check its state before retrying."

let stored_body ~base_path marker =
  match Tool_output.decode_from_agent_core marker with
  | Tool_output.Not_marker | Tool_output.Invalid_marker _ ->
      Alcotest.failf "the model received %d bytes inline, not a reference"
        (String.length marker)
  | Tool_output.Decoded reference -> (
      match
        Tool_blob_store.fetch (Tool_blob_store.create ~base_path)
          ~sha256:reference.Tool_output.sha256
      with
      | Ok (Some bytes) -> bytes
      | Ok None -> Alcotest.fail "the reference names no stored body"
      | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error))

let allowed_call ?(before_call = fun ~base_path:_ -> ()) ~call_text ~call_is_error () =
  let base_path = temp_base () in
  allow_external ~base_path;
  project_token ~base_path;
  before_call ~base_path;
  let post, _sent = recording_transport ~call_text ~call_is_error () in
  ( base_path,
    execute ~post ~base_path
      (offered ~read_only:true "getJiraIssue")
      (`Assoc [ ("key", `String "PK-1") ]) )

let test_a_large_answer_reaches_the_model_as_a_reference () =
  let answer = oversized_answer () in
  check Alcotest.bool "the fixture is over the ceiling" true
    (String.length answer > Common.max_tool_result_wire_bytes);
  match allowed_call ~call_text:answer ~call_is_error:false () with
  | base_path, Ok output ->
      check str "the stored body is the service's answer" answer
        (stored_body ~base_path output.Agent_core.Types.content)
  | _, Error error ->
      Alcotest.failf "an allowed read failed: %s" error.Agent_core.Types.message

(* The exact marker keeps the warning inline in its preview, and the stored
   result includes the same warning with the complete service reply. *)
let test_a_large_failure_keeps_the_warning_inline () =
  let answer = oversized_answer () in
  match allowed_call ~call_text:answer ~call_is_error:true () with
  | _, Ok output ->
      Alcotest.failf "a reported failure became a success: %s"
        output.Agent_core.Types.content
  | base_path, Error error ->
      let message = error.Agent_core.Types.message in
      check Alcotest.bool "the message is within the ceiling" true
        (String.length message <= Common.max_tool_result_wire_bytes);
      check Alcotest.bool "the retry warning is inline" true
        (contains ~needle:retry_warning message);
      check Alcotest.bool "the model is not told to retry" false
        error.Agent_core.Types.recoverable;
      let marker =
        match String.index_opt message '\n' with
        | Some cut -> String.sub message 0 cut
        | None -> message
      in
      check str "the stored body includes the complete retry warning" (answer ^ "\n" ^ retry_warning)
        (stored_body ~base_path marker)

let block_the_blob_store ~base_path =
  let root = Tool_blob_store.root_dir (Tool_blob_store.create ~base_path) in
  Fs_compat.mkdir_p (Filename.dirname root);
  Out_channel.with_open_bin root (fun channel ->
    Out_channel.output_string channel "a file where the store's directory goes")

(* A received answer is not independent proof of an external effect. A
   local storage failure must not make the call safe to repeat. *)
let test_an_unstorable_answer_preserves_unknown_effect () =
  let answer = oversized_answer () in
  match allowed_call ~before_call:block_the_blob_store ~call_text:answer ~call_is_error:false () with
  | _, Ok output ->
      Alcotest.failf "an unstored answer reached the model as %d bytes"
        (String.length output.Agent_core.Types.content)
  | _, Error error ->
      check Alcotest.bool "storage failure leaves effect unknown" true
        (error.Agent_core.Types.error_class = Some Agent_core.Types.Unknown);
      check Alcotest.bool "the model is not told to retry" false
        error.Agent_core.Types.recoverable

let test_a_small_answer_stays_inline () =
  match allowed_call ~call_text:"PK-1" ~call_is_error:false () with
  | _, Ok output -> check str "the answer is inline" "PK-1" output.Agent_core.Types.content
  | _, Error error ->
      Alcotest.failf "an allowed read failed: %s" error.Agent_core.Types.message

(* ── the observers: the dashboard series hears of every attached call ──── *)

(* [Gate.agent_tool] answers Agent Core in Agent Core's types, so its calls
   never pass through [Tool_dispatch.guarded_dispatch] or the Keeper exec
   handler, the two places that fire the dispatch observers. The dashboard
   series is written by one of those observers: until the tool fired them
   itself, an attached tool's refused calls were its only rows there. *)
let observed_calls run =
  let seen = ref [] in
  Tool_dispatch.clear_hooks ();
  Fun.protect ~finally:Tool_dispatch.clear_hooks (fun () ->
      Tool_dispatch.register_dispatch_observer (fun outcome result ->
          match (outcome, result) with
          | Dispatch_outcome.Handled, Some handled -> seen := handled :: !seen
          | (Dispatch_outcome.Handled, None) | (Dispatch_outcome.No_handler, _) -> ());
      let answer = run () in
      (answer, List.rev !seen))

let the_one_observed_call = function
  | [ call ] -> call
  | calls -> Alcotest.failf "expected one observed call, saw %d" (List.length calls)

let failure_of observed =
  match observed with
  | Tool_result.Failed failure -> failure
  | (Tool_result.Completed _ | Tool_result.Deferred _) as other ->
      Alcotest.failf "expected a failed call, saw %s"
        (Tool_result.string_of_disposition other)

let test_a_completed_call_reaches_the_observers () =
  let (_, answer), observed =
    observed_calls (fun () -> allowed_call ~call_text:"PK-1" ~call_is_error:false ())
  in
  (match answer with
   | Ok output ->
       check str "the model still gets the answer" "PK-1" output.Agent_core.Types.content
   | Error error ->
       Alcotest.failf "an allowed read failed: %s" error.Agent_core.Types.message);
  let call = the_one_observed_call observed in
  check str "under the name the model calls it by" "atlassian_getJiraIssue"
    (Tool_result.tool_name call);
  check str "as completed" "completed" (Tool_result.string_of_disposition call);
  check Alcotest.bool "with a measured duration" true (Tool_result.duration_ms call >= 0.0)

(* A service that reports an error may have applied an effect first. The
   observers get that and the class; the service's own words stay in the
   tool-call row, because they are as long as the service makes them. *)
let test_a_reported_error_reaches_the_observers_without_the_services_words () =
  let words = "the-services-own-error-words" in
  let (_, answer), observed =
    observed_calls (fun () -> allowed_call ~call_text:words ~call_is_error:true ())
  in
  (match answer with
   | Ok output ->
       Alcotest.failf "a reported failure became a success: %s"
         output.Agent_core.Types.content
   | Error error ->
       check Alcotest.bool "the model still reads the words" true
         (contains ~needle:words error.Agent_core.Types.message));
  let call = the_one_observed_call observed in
  check str "as failed" "failed" (Tool_result.string_of_disposition call);
  let failure = failure_of call in
  check str "as a runtime failure"
    (Tool_result.tool_failure_class_to_string Tool_result.Runtime_failure)
    (Tool_result.tool_failure_class_to_string failure.Tool_result.class_);
  check str "whose effect is unknown"
    (Tool_result.failure_effect_disposition_to_string
       Tool_result.Effect_outcome_unknown)
    (Tool_result.failure_effect_disposition_to_string
       failure.Tool_result.effect_disposition);
  check Alcotest.bool "without the words" false
    (contains ~needle:words failure.Tool_result.message)

(* The tool-call row and observers preserve the same unknown effect when
   an answer arrived but its durable copy could not be kept. *)
let test_an_answer_that_cannot_be_kept_reaches_the_observers_as_unknown () =
  let (_, answer), observed =
    observed_calls (fun () ->
        allowed_call ~before_call:block_the_blob_store
          ~call_text:(oversized_answer ()) ~call_is_error:false ())
  in
  (match answer with
   | Ok output ->
       Alcotest.failf "an unstored answer reached the model as %d bytes"
         (String.length output.Agent_core.Types.content)
   | Error _ -> ());
  let call = the_one_observed_call observed in
  check str "as failed, like the row" "failed" (Tool_result.string_of_disposition call);
  let failure = failure_of call in
  check str "effect unknown"
    (Tool_result.failure_effect_disposition_to_string Tool_result.Effect_outcome_unknown)
    (Tool_result.failure_effect_disposition_to_string
       failure.Tool_result.effect_disposition)

(* No clock means nothing was sent, and the observers are told so. *)
let test_a_call_that_was_never_sent_reaches_the_observers_as_pre_effect () =
  let base_path = temp_base () in
  allow_external ~base_path;
  let config = Masc.Workspace.default_config base_path in
  let tool =
    Gate.agent_tool ~config ~meta:(meta ())
      ~inline_ceiling_bytes:(fun () -> Common.max_tool_result_wire_bytes)
      (offered ~read_only:true "getJiraIssue")
  in
  let answer, observed =
    observed_calls (fun () ->
        Agent_core.Base.Tool.execute ~invocation:(invocation ()) tool (`Assoc [ ("key", `String "PK-1") ]))
  in
  (match answer with
   | Ok output ->
       Alcotest.failf "a call with no clock ran: %s" output.Agent_core.Types.content
   | Error _ -> ());
  let failure = failure_of (the_one_observed_call observed) in
  check str "the effect never began"
    (Tool_result.failure_effect_disposition_to_string Tool_result.Proven_pre_effect)
    (Tool_result.failure_effect_disposition_to_string
       failure.Tool_result.effect_disposition)

let test_a_deferral_reaches_the_observers_as_deferred () =
  let base_path = temp_base () in
  install_queue ~base_path;
  let answer, observed =
    observed_calls (fun () ->
        execute ~post:(unreachable_transport ()) ~base_path
          (offered "addCommentToJiraIssue")
          (`Assoc [ ("key", `String "PK-1") ]))
  in
  (match answer with
   | Ok _ -> ()
   | Error error ->
       Alcotest.failf "a deferral is an answer, not a failure: %s"
         error.Agent_core.Types.message);
  let call = the_one_observed_call observed in
  check str "under the name the model calls it by" "atlassian_addCommentToJiraIssue"
    (Tool_result.tool_name call);
  check str "as deferred" "deferred" (Tool_result.string_of_disposition call)

(* A Gate that cannot record its decision runs nothing; that is a dependency
   being down, not a fault in the call. A workspace whose approval queue was
   never installed is such a Gate: a deferral has nowhere to be written. *)
let test_an_unavailable_gate_reaches_the_observers_as_a_dependency_failure () =
  let base_path = temp_base () in
  let answer, observed =
    observed_calls (fun () ->
        execute ~post:(unreachable_transport ()) ~base_path
          (offered ~read_only:true "getJiraIssue")
          (`Assoc [ ("key", `String "PK-1") ]))
  in
  (match answer with
   | Ok output ->
       Alcotest.failf "a call ran with no Gate decision: %s"
         output.Agent_core.Types.content
   | Error _ -> ());
  let failure = failure_of (the_one_observed_call observed) in
  check str "as a dependency failure"
    (Tool_result.tool_failure_class_to_string Tool_result.Dependency_unavailable)
    (Tool_result.tool_failure_class_to_string failure.Tool_result.class_);
  check str "before any effect"
    (Tool_result.failure_effect_disposition_to_string Tool_result.Proven_pre_effect)
    (Tool_result.failure_effect_disposition_to_string
       failure.Tool_result.effect_disposition)

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

let mcp_media_content ~text =
  `List
    [ `Assoc ["type", `String "text"; "text", `String text]
    ; `Assoc ["type", `String "text"; "text", `String "user-only-secret";
        "annotations", `Assoc ["audience", `List [`String "user"]]]
    ; `Assoc ["type", `String "image"; "mimeType", `String "image/png";
        "data", `String "cHJpdmF0ZSBpbWFnZQ==";
        "annotations", `Assoc ["audience", `List [`String "user"]]]
    ; `Assoc ["type", `String "image"; "mimeType", `String "image/png";
        "data", `String "aW1hZ2UgYnl0ZXM="]
    ; `Assoc ["type", `String "audio"; "mimeType", `String "audio/wav; rate=16000";
        "data", `String "YXVkaW8gYnl0ZXM="]
    ; `Assoc ["type", `String "resource"; "resource", `Assoc
        ["uri", `String "fixture:report"; "mimeType", `String "application/pdf";
         "blob", `String "JVBERi0="]]
    ]

let output_ok = function
  | Ok output -> output
  | Error error -> Alcotest.fail error.Agent_core.Types.message

let fetch_reference ~base_path (reference : Tool_output.artifact_ref) =
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256 with
  | Ok (Some bytes) -> bytes
  | Ok None -> Alcotest.fail "retained artifact is absent"
  | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error)

let public_artifact_body ~base_path (reference : Tool_output.artifact_ref) =
  let body = fetch_reference ~base_path reference in
  if reference.mime = Tool_output.artifact_manifest_mime then
    match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string body) with
    | Tool_output.Decoded_artifact_manifest {content; _} -> content
    | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ ->
      Alcotest.fail "public result is not a canonical manifest"
  else body

let visible_body ~base_path text =
  match Tool_output.decode_from_agent_core text with
  | Tool_output.Not_marker -> text
  | Tool_output.Invalid_marker {detail} -> Alcotest.fail detail
  | Tool_output.Decoded reference -> public_artifact_body ~base_path reference

let raw_reference references =
  match List.filter (fun (reference : Tool_output.artifact_ref) ->
      reference.mime = "application/vnd.masc.mcp-result+json") references with
  | [reference] -> reference
  | _ -> Alcotest.fail "expected one retained raw MCP result"

let assert_media ~native_image blocks =
  let blocks = Option.value blocks ~default:[] in
  check Alcotest.bool "native image follows the frozen runtime capability" native_image
    (List.mem (Llm_provider.Types.Image {media_type="image/png";
       source=Llm_provider.Types.Base64 "aW1hZ2UgYnl0ZXM="}) blocks);
  check Alcotest.bool "PDF is a byte artifact, not unsupported native input" false
    (List.mem (Llm_provider.Types.Document {media_type="application/pdf";
       source=Llm_provider.Types.Base64 "JVBERi0="}) blocks);
  check Alcotest.bool "user-only text is absent from model blocks" false
    (List.exists (function Llm_provider.Types.Text text -> contains ~needle:"user-only-secret" text
      | _ -> false) blocks)

let save_fixture_history ~base_path messages =
  let path = Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) Common.keepers_runtime_dirname)
    (keeper_name ^ "/mcp-history.json") in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path (Yojson.Safe.to_string
    (`List (List.map Agent_core.History.message_to_json messages)))

let rec remove_fixture_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> remove_fixture_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path

let check_history_owns_public_media ~base_path ~raw ~public_ref =
  let manifest = fetch_reference ~base_path public_ref |> Yojson.Safe.from_string in
  let children = match Tool_output.artifact_manifest_of_json manifest with
    | Tool_output.Decoded_artifact_manifest {artifact_refs; _} -> artifact_refs
    | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ ->
      Alcotest.fail "history must own a canonical public manifest" in
  check Alcotest.int "public manifest owns exactly the three published byte references" 3
    (List.length children);
  check Alcotest.bool "private raw receipt is not a public child" false
    (List.exists (fun (reference : Tool_output.artifact_ref) -> reference.sha256 = raw.Tool_output.sha256) children);
  (* Retire every execution/approval/chat owner in this isolated fixture.
     Only the actual serialized history remains as a public-result owner. *)
  let config = Masc.Workspace.default_config base_path in
  let call_dir = Dated_jsonl.Store.dir
    (Dated_jsonl.Store.at (Masc.Workspace.dated_store_root config) Dated_jsonl.Store.Root.Tool_calls) in
  remove_fixture_tree call_dir;
  remove_fixture_tree (Masc.Keeper_gate_path.dir ~base_path);
  remove_fixture_tree (Filename.concat (Common.masc_dir_from_base_path ~base_path)
    Masc.Keeper_chat_store.chat_dirname);
  for _pass = 1 to 2 do
    match Tool_blob_maintenance.run ~base_path ~scope:Server_tool_blob_scope.scope
      ~mode:Tool_blob_maintenance.Delete_previous_candidates with
    | Ok report -> check (Alcotest.list str) "fixture has a complete GC scope" [] report.unclassified
    | Error error -> Alcotest.fail (Tool_blob_maintenance.error_to_string error)
  done;
  ignore (fetch_reference ~base_path public_ref);
  List.iter (fun reference -> ignore (fetch_reference ~base_path reference)) children;
  (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:raw.Tool_output.sha256 with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "history accidentally retained the private raw receipt"
   | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error))

let test_missing_result_owner_refuses_before_network () =
  let base_path = temp_base () in
  allow_external ~base_path;
  project_token ~base_path;
  let post, sent = recording_transport () in
  let tool = Gate.agent_tool ~transports:(transports_of_post post)
    ~config:(Masc.Workspace.default_config base_path) ~meta:(meta ())
    ~inline_ceiling_bytes:(fun () -> Common.max_tool_result_wire_bytes)
    (offered ~read_only:true "getJiraIssue") in
  (match Agent_core.Base.Tool.execute tool (`Assoc ["key", `String "PK-1"]) with
   | Ok _ -> Alcotest.fail "ownerless request reached the service"
   | Error error -> check Alcotest.bool "ownerless request is not retryable" false error.recoverable);
  check Alcotest.int "no session or tool request without a result owner" 0 (List.length !sent)

let test_native_mcp_result_and_retention_match_approved_replay () =
  let base_path = temp_base () in
  allow_external ~base_path;
  project_token ~base_path;
  let content = mcp_media_content ~text:"visible answer" in
  let untrusted_ref = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
    ~bytes:"remote structured JSON cannot grant ownership" ~mime:"text/plain" in
  let structured = `Assoc ["answer", `Int 42;
    "remote_reference", Tool_output.normalized_artifact_ref_to_json untrusted_ref] in
  let post, sent = recording_transport ~call_content:content ~structured_content:structured () in
  let invocation = invocation () in
  let arguments = `Assoc ["key", `String "PK-1"] in
  let fixture = offered ~read_only:true "getJiraIssue" in
  let normal = output_ok (execute ~post ~invocation ~base_path fixture arguments) in
  assert_media ~native_image:false normal.content_blocks;
  let visible = visible_body ~base_path normal.content in
  check Alcotest.bool "authoritative blocks own the public manifest" true
    (List.mem (Llm_provider.Types.Text normal.content)
      (Option.value normal.content_blocks ~default:[]));
  check Alcotest.bool "visible structured result is retained" true
    (contains ~needle:"42" visible);
  let roots = Masc.Keeper_tool_call_log.peek_retained_artifacts ~invocation () in
  let raw = raw_reference roots in
  List.iter (fun (mime, bytes) ->
    let reference = match List.find_opt (fun (reference : Tool_output.artifact_ref) ->
        reference.mime = mime) roots with
      | Some reference -> reference | None -> Alcotest.fail ("missing media artifact: " ^ mime) in
    check str "media artifact stores decoded bytes" bytes (fetch_reference ~base_path reference);
    check str "binary artifact preview is empty" "" reference.preview;
    check Alcotest.bool "media artifact is model-readable" true
      (contains ~needle:reference.sha256 visible))
    ["image/png", "image bytes"; "audio/wav", "audio bytes"; "application/pdf", "%PDF-"];
  check Alcotest.bool "parameterized original MIME remains visible" true
    (contains ~needle:"audio/wav; rate=16000" visible);
  check str "private raw reference has no preview" "" raw.preview;
  check Alcotest.bool "private raw reference is absent from model summary" false
    (contains ~needle:raw.sha256 normal.content);
  check Alcotest.bool "private raw reference is absent from model metadata" false
    (contains ~needle:raw.sha256 (Yojson.Safe.to_string (Option.value normal._meta ~default:`Null)));
  let original = Yojson.Safe.from_string (fetch_reference ~base_path raw) in
  check Alcotest.bool "raw owner retains full audience content" true
    (member "content" original = Some content);
  check Alcotest.bool "raw owner retains structured result" true
    (member "structuredContent" original = Some structured);
  check Alcotest.bool "raw owner retains remote error flag" true
    (member "isError" original = Some (`Bool false));
  check Alcotest.int "ordinary request sent once" 1 (List.length (tool_calls sent));
  (* Exercise the real post-tool hook, not a manually assembled retention row. *)
  let module Log = Masc.Keeper_tool_call_log in
  Fun.protect ~finally:(fun () -> Log.reset_for_testing ();
      Masc.Keeper_execution_join.For_testing.clear ()) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Log.init ~base_path ();
    let hooks = Masc.Keeper_hooks_agent_core.make_hooks
      ~config:(Masc.Workspace.default_config base_path) ~meta_ref:(ref (meta ()))
      ~turn_ctx_cell:(Log.create_turn_ctx_cell ()) ~trace_id:"identity-retention" ~keeper_turn_id:1 () in
    ignore ((Option.get hooks.Agent_core.Hooks.post_tool_use)
      (Agent_core.Hooks.PostToolUse { invocation; tool_name=fixture.schema.name; input=arguments;
        output=Ok normal; result_bytes=String.length normal.content; duration_ms=1. }));
    let rows = match Log.read_recent ~keeper_name () with
      | Ok rows -> rows | Error (Log.Index_unavailable detail) -> Alcotest.fail detail in
    let refs = List.concat_map Tool_output.normalized_artifact_refs_in_json rows in
    check Alcotest.bool "durable tool-call row retains the raw artifact" true
      (List.exists (fun (reference : Tool_output.artifact_ref) -> reference.sha256 = raw.sha256) refs);
    let status = Option.get (Masc.Keeper_runtime_trust_timeline.latest_tool_call_json ~keeper_name) in
    let status_refs = Tool_output.normalized_artifact_refs_in_json status in
    check Alcotest.bool "status does not expose the private audit handle" false
      (contains ~needle:raw.sha256 (Yojson.Safe.to_string status));
    check Alcotest.int "status keeps visible media and manifest references" 4 (List.length status_refs);
    check Alcotest.int "carrier is cleared only after log commit" 0
      (List.length (Log.peek_retained_artifacts ~invocation ())));
  let public_ref = match Tool_output.decode_from_agent_core normal.content with
    | Tool_output.Decoded reference -> reference
    | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> Alcotest.fail "missing public manifest" in
  let history_blocks = Option.map (List.map (function
    | Llm_provider.Types.Text text -> Agent_core.Types.Text text
    | _ -> Alcotest.fail "text-only runtime received native media")) normal.content_blocks in
  save_fixture_history ~base_path
    [Agent_core.Types.make_message ~role:Tool [Agent_core.Types.ToolResult
      {tool_use_id="identity-call-fixture"; content=normal.content; content_blocks=history_blocks;
       outcome=Tool_succeeded; json=None}]];
  check_history_owns_public_media ~base_path ~raw ~public_ref;
  (match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:untrusted_ref.sha256 with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "remote structured content acquired manifest ownership"
   | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error));
  let replay_base = temp_base () in
  let config, keeper, _, grant, call = approved_identity_call ~base_path:replay_base fixture arguments in
  let replay_post, replay_sent = recording_transport ~call_content:content ~structured_content:structured () in
  let replayed = Gate.replay_call_with_outcome ~transports:(transports_of_post replay_post)
    ~config ~meta:keeper ~gate_grant:grant call in
  (match replayed.Masc.Keeper_tool_execution.disposition with
   | Tool_result.Completed () -> ()
   | Tool_result.Deferred () | Tool_result.Failed _ -> Alcotest.fail replayed.raw_output);
  check str "normal and approved replay use identical model text" normal.content replayed.raw_output;
  check Alcotest.bool "normal and replay preserve identical native blocks" true
    (normal.content_blocks = replayed.content_blocks);
  check str "normal and replay retain the same raw content address" raw.sha256
    (raw_reference replayed.retained_artifacts).sha256;
  check Alcotest.int "approved request sent once" 1 (List.length (tool_calls replay_sent))

let test_large_mcp_text_keeps_native_media_and_filters_private_text () =
  let base_path = temp_base () in
  allow_external ~base_path;
  project_token ~base_path;
  let content = mcp_media_content ~text:(oversized_answer ()) in
  let post, sent = recording_transport ~call_content:content () in
  let invocation = invocation () in
  let output = output_ok (execute ~post ~invocation ~accepts_image_input:true ~base_path
      (offered ~read_only:true "getJiraIssue") (`Assoc ["key", `String "PK-1"])) in
  assert_media ~native_image:true output.content_blocks;
  let allowed = visible_body ~base_path output.content in
  check Alcotest.bool "visible text remains readable" true (contains ~needle:(oversized_answer ()) allowed);
  check Alcotest.bool "private text never enters model-readable text blob" false
    (contains ~needle:"user-only-secret" allowed);
  (match output.content_blocks with
   | Some (Llm_provider.Types.Text marker :: _) ->
     check str "authoritative blocks include the text artifact" output.content marker
   | Some [] | None | Some _ -> Alcotest.fail "media result lost its text artifact");
  check Alcotest.int "raw, audio, PDF and allowed text have owners" 4
    (List.length (Masc.Keeper_tool_call_log.peek_retained_artifacts ~invocation ()));
  check Alcotest.int "externalization never repeats the request" 1 (List.length (tool_calls sent))

let test_unsupported_image_format_is_a_byte_reference () =
  let base_path = temp_base () in
  allow_external ~base_path; project_token ~base_path;
  let content = `List [`Assoc ["type", `String "image"; "mimeType", `String "image/svg+xml";
      "data", `String "PHN2Zy8+"]] in
  let post, sent = recording_transport ~call_content:content () in
  let invocation = invocation () in
  let output = output_ok (execute ~post ~invocation ~accepts_image_input:true ~base_path
      (offered ~read_only:true "getJiraIssue") (`Assoc ["key", `String "PK-1"])) in
  let blocks = Option.value output.content_blocks ~default:[] in
  check Alcotest.bool "unsupported image format is not passed natively" true
    (List.for_all (function Llm_provider.Types.Text _ -> true | _ -> false) blocks);
  let roots = Masc.Keeper_tool_call_log.peek_retained_artifacts ~invocation () in
  let reference = match List.find_opt (fun (reference : Tool_output.artifact_ref) ->
      reference.mime = "image/svg+xml") roots with
    | Some reference -> reference | None -> Alcotest.fail "unsupported image bytes were lost" in
  check str "SVG remains readable by its original content address" "<svg/>"
    (fetch_reference ~base_path reference);
  check Alcotest.bool "SVG reference reaches the model" true
    (contains ~needle:reference.sha256 (visible_body ~base_path output.content));
  check Alcotest.int "format projection sends only once" 1 (List.length (tool_calls sent))

let test_generic_mcp_resources_keep_bytes_and_public_ownership () =
  let base_path = temp_base () in
  allow_external ~base_path; project_token ~base_path;
  let content = `List
    [ `Assoc ["type", `String "resource"; "resource", `Assoc
        ["uri", `String "fixture:archive"; "mimeType", `String "application/zip";
         "blob", `String "YmluYXJ5IGJ5dGVz"]]
    ; `Assoc ["type", `String "resource"; "resource", `Assoc
        ["uri", `String "fixture:empty"; "blob", `String ""]]
    ] in
  let post, sent = recording_transport ~call_content:content () in
  let invocation = invocation () in
  let output = output_ok (execute ~post ~invocation ~base_path
    (offered ~read_only:true "getJiraIssue") (`Assoc ["key", `String "PK-1"])) in
  let public_ref = match Tool_output.decode_from_agent_core output.content with
    | Tool_output.Decoded reference -> reference
    | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> Alcotest.fail "generic resources lost their manifest" in
  let visible, children = match fetch_reference ~base_path public_ref
    |> Yojson.Safe.from_string |> Tool_output.artifact_manifest_of_json with
    | Tool_output.Decoded_artifact_manifest {content; artifact_refs; _} -> content, artifact_refs
    | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ ->
      Alcotest.fail "generic resource manifest is invalid" in
  check Alcotest.int "both generic resources are public children" 2 (List.length children);
  List.iter (fun (mime, bytes) ->
    let reference = List.find (fun (reference : Tool_output.artifact_ref) -> reference.mime = mime) children in
    check str "generic resource bytes survive exactly" bytes (fetch_reference ~base_path reference);
    check str "binary preview is empty" "" reference.preview)
    ["application/zip", "binary bytes"; "application/octet-stream", ""];
  check Alcotest.bool "resource URI remains visible" true (contains ~needle:"fixture:archive" visible);
  check Alcotest.bool "missing MIME remains explicit" true
    (contains ~needle:"fixture:empty (MIME unspecified)" visible);
  check Alcotest.bool "generic public manifest is in authoritative blocks" true
    (List.mem (Llm_provider.Types.Text output.content) (Option.value output.content_blocks ~default:[]));
  let raw = raw_reference (Masc.Keeper_tool_call_log.peek_retained_artifacts ~invocation ()) in
  check Alcotest.bool "generic manifest does not publish its raw receipt" false
    (List.exists (fun (reference : Tool_output.artifact_ref) -> reference.sha256 = raw.sha256) children);
  check Alcotest.int "generic resources require one external call" 1 (List.length (tool_calls sent))

let test_manifest_storage_failure_preserves_received_effect_uncertainty () =
  let base_path = temp_base () in
  let store = Tool_blob_store.create ~base_path in
  let root = Tool_blob_store.root_dir store in
  let saved_root = root ^ ".fixture-backup" in
  let retained = ref [] in
  let blocked = ref false in
  let result : Mcp_client.tool_result =
    { content = mcp_media_content ~text:"visible answer"; text="visible answer";
      is_error=false; structured_content=None } in
  let projection = Fun.protect ~finally:(fun () ->
      if !blocked then (Unix.unlink root; Unix.rename saved_root root)) (fun () ->
    Identity_tools.tool_result_of_call ~base_path ~accepts_image_input:false
      ~inline_ceiling_bytes:Common.max_tool_result_wire_bytes
      ~retain_artifacts:(fun roots ->
        retained := roots;
        if List.length roots = 4 then (
          Unix.rename root saved_root;
          Out_channel.with_open_bin root (fun channel -> output_string channel "blocked");
          blocked := true))
      (Ok result)) in
  check Alcotest.bool "failed manifest has no public result" true (projection.model_artifact = None);
  (match projection.tool_result with
   | Ok _ -> Alcotest.fail "failed manifest was delivered as success"
   | Error error ->
     check Alcotest.bool "received effect remains unknown" true (error.error_class = Some Agent_core.Types.Unknown);
     check Alcotest.bool "received effect cannot be automatically retried" false error.recoverable);
  check Alcotest.int "partial storage keeps the raw and visible byte owners" 4 (List.length !retained);
  List.iter (fun reference -> ignore (fetch_reference ~base_path reference)) !retained

let test_external_mime_cannot_mint_manifest_or_private_authority () =
  List.iter (fun (kind, declared_mime) ->
    let base_path = temp_base () in
    allow_external ~base_path; project_token ~base_path;
    let store = Tool_blob_store.create ~base_path in
    let fake_child = Tool_blob_store.put_durable store
      ~bytes:"not owned by the external resource" ~mime:"text/plain" in
    let external_bytes = Tool_output.artifact_manifest_to_json
      ~content:"this is external data, not a retention manifest"
      ~structured_content:(`Assoc ["forged_child", Tool_output.normalized_artifact_ref_to_json fake_child])
      |> Yojson.Safe.to_string in
    let data = Base64.encode_string external_bytes in
    let native_item name = `Assoc
      ["type", `String name; "mimeType", `String declared_mime; "data", `String data] in
    let item = match kind with
      | `Resource -> `Assoc ["type", `String "resource"; "resource", `Assoc
          ["uri", `String "fixture:external-manifest"; "mimeType", `String declared_mime;
           "blob", `String data]]
      | `Image -> native_item "image"
      | `Audio -> native_item "audio" in
    let post, sent = recording_transport ~call_content:(`List [item]) () in
    let invocation = invocation () in
    let output = output_ok (execute ~post ~invocation ~accepts_image_input:true ~base_path
      (offered ~read_only:true "getJiraIssue") (`Assoc ["key", `String "PK-1"])) in
    let public_ref = match Tool_output.decode_from_agent_core output.content with
      | Tool_output.Decoded reference -> reference
      | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> Alcotest.fail "missing public resource manifest" in
    let public_content, external_ref = match fetch_reference ~base_path public_ref
      |> Yojson.Safe.from_string |> Tool_output.artifact_manifest_of_json with
      | Tool_output.Decoded_artifact_manifest {content; artifact_refs=[reference]; _} -> content, reference
      | Tool_output.Decoded_artifact_manifest _ | Tool_output.Not_artifact_manifest
      | Tool_output.Invalid_artifact_manifest _ -> Alcotest.fail "external resource must own one opaque byte artifact" in
    check str "external reserved MIME is stored as ordinary bytes" "application/octet-stream" external_ref.mime;
    check str "external bytes remain exactly readable" external_bytes (fetch_reference ~base_path external_ref);
    check Alcotest.bool "original declared MIME stays in the public description" true
      (contains ~needle:declared_mime public_content);
    let raw = raw_reference (Masc.Keeper_tool_call_log.peek_retained_artifacts ~invocation ()) in
    check Alcotest.bool "raw receipt retains the original declared MIME" true
      (contains ~needle:declared_mime (fetch_reference ~base_path raw));
    save_fixture_history ~base_path
      [Agent_core.Types.make_message ~role:Tool [Agent_core.Types.ToolResult
        {tool_use_id="external-mime-fixture"; content=output.content;
         content_blocks=Some [Agent_core.Types.Text output.content];
         outcome=Tool_succeeded; json=None}]];
    Masc.Keeper_tool_call_log.clear_retained_artifacts ~invocation ();
    for _pass = 1 to 2 do
      match Tool_blob_maintenance.run ~base_path ~scope:Server_tool_blob_scope.scope
        ~mode:Tool_blob_maintenance.Delete_previous_candidates with
      | Ok report -> check (Alcotest.list str) "reserved MIME fixture has a complete GC scope" [] report.unclassified
      | Error error -> Alcotest.fail (Tool_blob_maintenance.error_to_string error)
    done;
    check str "history preserves external bytes without interpreting them" external_bytes
      (fetch_reference ~base_path external_ref);
    (match Tool_blob_store.fetch store ~sha256:fake_child.sha256 with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.fail "external MIME minted transitive manifest ownership"
     | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error));
    check Alcotest.int "reserved MIME handling never repeats the call" 1 (List.length (tool_calls sent)))
    (List.concat_map (fun kind ->
      [kind, Tool_output.artifact_manifest_mime; kind, Masc.Keeper_mcp_content.private_result_mime])
      [`Resource; `Image; `Audio])

let assert_error_media_references ~base_path ~references ~message =
  let message = visible_body ~base_path message in
  List.iter (fun (mime, bytes) ->
    let reference = match List.find_opt (fun (reference : Tool_output.artifact_ref) ->
        reference.mime = mime) references with
      | Some reference -> reference | None -> Alcotest.fail ("error result lost media: " ^ mime) in
    check str "error media bytes remain readable" bytes (fetch_reference ~base_path reference);
    check Alcotest.bool "error carries each visible media reference" true
      (contains ~needle:reference.sha256 message))
    ["image/png", "image bytes"; "audio/wav", "audio bytes"; "application/pdf", "%PDF-"];
  check Alcotest.bool "error never exposes raw envelope reference" false
    (contains ~needle:(raw_reference references).sha256 message);
  let private_sha = (Agent_core.History.stored_of_raw "private image").sha256 in
  check Alcotest.bool "error does not reference a user-only media body" false
    (List.exists (fun (reference : Tool_output.artifact_ref) -> reference.sha256 = private_sha) references);
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:private_sha with
  | Ok None -> ()
  | Ok (Some _) -> Alcotest.fail "user-only media was separately published"
  | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error)

let test_received_mcp_failures_keep_unknown_effect_and_never_retry () =
  List.iter (fun (content, is_error, block_store) ->
    let base_path = temp_base () in
    allow_external ~base_path; project_token ~base_path;
    if block_store then block_the_blob_store ~base_path;
    let post, sent = recording_transport ~call_content:content ~call_is_error:is_error () in
    let invocation = invocation () in
    let result, observed = observed_calls (fun () -> execute ~post ~invocation ~accepts_image_input:true ~base_path
      (offered ~read_only:true "getJiraIssue") (`Assoc ["key", `String "PK-1"])) in
    (match result with
     | Ok _ -> Alcotest.fail "unusable received result became success"
     | Error error ->
       check Alcotest.bool "received failure is nonrecoverable" false error.recoverable;
       check Alcotest.bool "received failure has unknown error class" true
         (error.error_class = Some Agent_core.Types.Unknown);
       check Alcotest.bool "failed result does not expose private text" false
         (contains ~needle:"user-only-secret" error.message));
    let failed = failure_of (the_one_observed_call observed) in
    check Alcotest.bool "received failure cannot prove an effect phase" true
      (failed.effect_disposition = Tool_result.Effect_outcome_unknown);
    check Alcotest.int "one external request even after local failure" 1 (List.length (tool_calls sent));
    let retained = Masc.Keeper_tool_call_log.peek_retained_artifacts ~invocation () in
    check Alcotest.int "raw reply and visible error media retain their owners"
      (if block_store then 0 else if is_error then 5 else 1) (List.length retained);
    if is_error then (match result with
      | Error error -> assert_error_media_references ~base_path ~references:retained ~message:error.message
      | Ok _ -> Alcotest.fail "remote error became success");
    let replay_base = temp_base () in
    let config, keeper, _, grant, call = approved_identity_call ~base_path:replay_base
      (offered ~read_only:true "getJiraIssue") (`Assoc ["key", `String "PK-1"]) in
    if block_store then block_the_blob_store ~base_path:replay_base;
    let replay_post, replay_sent = recording_transport ~call_content:content ~call_is_error:is_error () in
    let replayed = Gate.replay_call_with_outcome ~transports:(transports_of_post replay_post)
      ~config ~meta:keeper ~gate_grant:grant call in
    (match replayed.Masc.Keeper_tool_execution.disposition with
     | Tool_result.Failed class_ -> check Alcotest.bool "replay runtime failure" true
         (class_ = Tool_result.Runtime_failure)
     | Tool_result.Completed () | Tool_result.Deferred () ->
       Alcotest.fail "replay lost the received-result failure");
    check Alcotest.bool "replay also retains unknown external effect" true
      (replayed.failure_effect_disposition = Tool_result.Effect_outcome_unknown);
    check Alcotest.bool "replay error never exposes user-only data" false
      (contains ~needle:"user-only-secret" replayed.raw_output);
    check Alcotest.int "replay sends once after projection/storage/error response" 1
      (List.length (tool_calls replay_sent));
    check Alcotest.int "replay failure retains raw and visible media roots"
      (if block_store then 0 else if is_error then 5 else 1) (List.length replayed.retained_artifacts);
    if is_error then assert_error_media_references ~base_path:replay_base
      ~references:replayed.retained_artifacts ~message:replayed.raw_output)
    [ `List [`Assoc ["type", `String "unknown"; "text", `String "user-only-secret"]], false, false
    ; mcp_media_content ~text:"visible failure", true, false
    ; mcp_media_content ~text:"visible answer", false, true
    ]

let test_host_replay_retains_mcp_artifacts_across_settlement_and_repair () =
  let module Replay = Masc.Keeper_gate_replay in
  let module Result = Masc.Keeper_approval_queue_result in
  List.iter (fun (is_error, fault) ->
    let base_path = temp_base () in
    let config, keeper, approval_id, grant, _ = approved_identity_call ~base_path
      (offered ~read_only:true "getJiraIssue") (`Assoc ["key", `String "PK-1"]) in
    let content = mcp_media_content ~text:"visible host replay" in
    let structured = `Assoc ["answer", `Int 42] in
    let post, sent = recording_transport ~call_content:content
      ~structured_content:structured ~call_is_error:is_error () in
    let replay () = Replay.replay_approved_effect_with_receipt ~config ~meta:keeper
      ~publication_recovery:{ provider = Masc.Keeper_publication_recovery_availability.non_runtime_provider;
        keeper_name }
      ~turn_sandbox_factory:None ~identity_transports:(transports_of_post post)
      ~grant ~approval_id () in
    let first = match fault with
      | `None -> replay ()
      | `Evidence -> Replay.For_testing.with_replay_evidence_persister
          (fun ~base_path:_ _ -> Error "fixture evidence storage unavailable") replay
      | `Journal ->
        let path = Queue.For_testing.replay_results_store_path ~base_path in
        let backup = path ^ ".fixture-backup" in
        let existed = Sys.file_exists path in
        if existed then Unix.rename path backup;
        Unix.mkdir path 0o700;
        Fun.protect ~finally:(fun () ->
          Unix.rmdir path;
          if existed then Unix.rename backup path) replay in
    (match fault, first.Replay.outcome with
     | (`None | `Evidence), (Replay.Applied _ | Replay.Indeterminate _) -> ()
     | `Journal, Replay.Repair_required { stage = Replay.Replay_journal; _ } -> ()
     | _ -> Alcotest.failf "unexpected replay settlement: %s"
         (Replay.outcome_to_string first.outcome));
    check Alcotest.int "the external effect ran exactly once before repair" 1
      (List.length (tool_calls sent));
    let settled = replay () in
    (match is_error, settled.outcome with
     | false, Replay.Applied _ | true, Replay.Indeterminate _ -> ()
     | _ -> Alcotest.failf "repaired effect changed its outcome: %s"
         (Replay.outcome_to_string settled.outcome));
    check Alcotest.int "repair never repeats the external effect" 1
      (List.length (tool_calls sent));
    let read_evidence () =
      match Queue.approved_resolution_delivery ~base_path ~id:approval_id with
      | Ok { state = Result.Resolution_consumed; replay_outcome = Some outcome; _ } ->
        (match is_error, outcome with
         | false, Result.Replay_applied evidence
         | true, Result.Replay_indeterminate evidence -> evidence
         | _ -> Alcotest.fail "durable replay has the wrong effect disposition")
      | Ok _ -> Alcotest.fail "actual replay did not settle its consumed approval"
      | Error error -> Alcotest.fail (Result.grant_error_to_string error) in
    let evidence = read_evidence () in
    check Alcotest.int "raw receipt, public manifest and media have a durable owner" 5
      (List.length evidence.retained_artifacts);
    let raw = raw_reference evidence.retained_artifacts in
    let raw_json = Yojson.Safe.from_string (fetch_reference ~base_path raw) in
    check Alcotest.bool "replay raw receipt preserves the full received content" true
      (member "content" raw_json = Some content);
    check Alcotest.bool "replay raw receipt preserves structured content" true
      (member "structuredContent" raw_json = Some structured);
    check Alcotest.bool "replay raw receipt preserves the remote error flag" true
      (member "isError" raw_json = Some (`Bool is_error));
    check str "Gate owns the producer manifest directly" Tool_output.artifact_manifest_mime
      evidence.artifact_ref.mime;
    let delivered = public_artifact_body ~base_path evidence.artifact_ref in
    assert_error_media_references ~base_path ~references:evidence.retained_artifacts
      ~message:delivered;
    check Alcotest.bool "model result omits audience-restricted text" false
      (contains ~needle:"user-only-secret" delivered);
    let model = Replay.append_model_evidence ~approval_id ~user_message:"continue"
      settled.outcome in
    check Alcotest.bool "model replay instruction omits the private raw root" false
      (contains ~needle:raw.sha256 model.text);
    let sidecar = Yojson.Safe.from_file
      (Queue.For_testing.replay_results_store_path ~base_path) in
    check Alcotest.bool "private roots are in the actual Gate sidecar" true
      (List.exists (fun (reference : Tool_output.artifact_ref) -> reference.sha256 = raw.sha256)
         (Tool_output.normalized_artifact_refs_in_json sidecar));
    let live = match Tool_blob_maintenance.live_references ~base_path
      ~scope:Server_tool_blob_scope.scope with
      | Ok live -> live
      | Error error -> Alcotest.fail (Tool_blob_maintenance.error_to_string error) in
    let live_digests = Tool_blob_maintenance.fold_live_sha256 live ~init:[]
      ~f:(fun digests digest -> digest :: digests) in
    List.iter (fun (reference : Tool_output.artifact_ref) ->
      check Alcotest.bool "the production GC scan retains every replay artifact" true
        (List.mem reference.sha256 live_digests))
      (evidence.artifact_ref :: evidence.retained_artifacts);
    Queue.For_testing.reset_runtime_state ();
    install_queue ~base_path;
    let reloaded = read_evidence () in
    check Alcotest.bool "private replay roots survive a registry restart" true
      (reloaded = evidence);
    ignore (replay ());
    check Alcotest.int "restart reads the durable result without resending" 1
      (List.length (tool_calls sent));
    let canonical = match model.replay_evidence with
      | [public_evidence] ->
        (match Replay.approval_input public_evidence with
         | Ok (_, message) -> message
         | Error error -> Alcotest.fail (Masc.Keeper_approval_input_admission.error_to_string error))
      | [] | _ :: _ :: _ -> Alcotest.fail "host replay has no singular public evidence" in
    save_fixture_history ~base_path [canonical];
    Queue.For_testing.reset_runtime_state ();
    check_history_owns_public_media ~base_path ~raw ~public_ref:evidence.artifact_ref)
    [false, `None; true, `None; false, `Evidence; true, `Evidence;
     false, `Journal; true, `Journal]

let () =
  Alcotest.run "keeper_identity_gate"
    [ ( "native MCP results",
        [ Alcotest.test_case "missing result owner refuses before network" `Quick
            test_missing_result_owner_refuses_before_network;
          Alcotest.test_case "normal and approved replay preserve media bytes and durable roots" `Quick
            test_native_mcp_result_and_retention_match_approved_replay;
          Alcotest.test_case "externalized text keeps media and filters private content" `Quick
            test_large_mcp_text_keeps_native_media_and_filters_private_text;
          Alcotest.test_case "unsupported image formats retain readable bytes" `Quick
            test_unsupported_image_format_is_a_byte_reference;
          Alcotest.test_case "generic resources retain bytes and public manifest ownership" `Quick
            test_generic_mcp_resources_keep_bytes_and_public_ownership;
          Alcotest.test_case "failed manifest keeps the received effect unknown" `Quick
            test_manifest_storage_failure_preserves_received_effect_uncertainty;
          Alcotest.test_case "external MIME cannot mint retention or private authority" `Quick
            test_external_mime_cannot_mint_manifest_or_private_authority;
          Alcotest.test_case "received errors retain unknown effects without retry" `Quick
            test_received_mcp_failures_keep_unknown_effect_and_never_retry;
          Alcotest.test_case "host replay retains artifacts through settlement repair and restart" `Quick
            test_host_replay_retains_mcp_artifacts_across_settlement_and_repair;
        ] );
      ( "routing",
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
      ( "the answer",
        [ Alcotest.test_case "a large answer reaches the model as a reference"
            `Quick test_a_large_answer_reaches_the_model_as_a_reference;
          Alcotest.test_case "a large failure keeps the warning inline"
            `Quick test_a_large_failure_keeps_the_warning_inline;
          Alcotest.test_case "an unstorable answer preserves unknown effect"
            `Quick test_an_unstorable_answer_preserves_unknown_effect;
          Alcotest.test_case "a small answer stays inline" `Quick
            test_a_small_answer_stays_inline;
        ] );
      ( "the observers",
        [ Alcotest.test_case "a completed call reaches the observers" `Quick
            test_a_completed_call_reaches_the_observers;
          Alcotest.test_case
            "a reported error reaches the observers without the service's words"
            `Quick
            test_a_reported_error_reaches_the_observers_without_the_services_words;
          Alcotest.test_case "an answer that cannot be kept has unknown effect" `Quick
            test_an_answer_that_cannot_be_kept_reaches_the_observers_as_unknown;
          Alcotest.test_case "a call that was never sent is pre-effect" `Quick
            test_a_call_that_was_never_sent_reaches_the_observers_as_pre_effect;
          Alcotest.test_case "a deferral reaches the observers as deferred" `Quick
            test_a_deferral_reaches_the_observers_as_deferred;
          Alcotest.test_case "an unavailable Gate is a dependency failure" `Quick
            test_an_unavailable_gate_reaches_the_observers_as_a_dependency_failure;
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
