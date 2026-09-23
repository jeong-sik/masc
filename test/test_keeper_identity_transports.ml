(* An identity tool call reaches a server outside masc from inside a keeper
   turn, where the attempt watchdog does not watch a tool in flight. The
   transport's deadline is therefore the only liveness the call has. These
   cases pin that the production transports are bounded, by which declared
   setting, and what the model is told when the deadline ends a call. *)

open Alcotest
open Masc

let keeper_name = "identity-transports-fixture"
let access_token_env = "ATLASSIAN_ACCESS_TOKEN"

exception Fixture_done

(* One directory per call, made by the runtime, so two calls cannot
   collide; removed once the call is over. *)
let with_temp_base f =
  let base_path = Filename.temp_dir "masc-identity-transports-" "" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> f ~base_path)
;;

(* A declaration for the stub-transport cases. The loader admits only https
   endpoints, so the wire cases below do not go through a declaration; the
   stubs never look at the address. No expiry is stored for the token, so no
   renewal is attempted and the MCP session is the whole call. *)
let provider () =
  let contents =
    Printf.sprintf
      {|
id = "atlassian"
label = "Atlassian"
mcp_url = "https://mcp.example.test/v1/mcp"
access_token_env = %S
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600
|}
      access_token_env
  in
  match Keeper_oauth_provider.load ~file_name:"atlassian" ~contents with
  | Ok provider -> provider
  | Error err ->
    failf "fixture declaration did not load: %s" (Keeper_oauth_provider.error_to_string err)
;;

let project_token ~base_path =
  match
    Keeper_secret_projection.set_env_entry
      ~base_path
      ~keeper_name
      ~scope:Keeper_secret_projection.Keeper_secret
      ~name:access_token_env
      ~value:"the-keepers-token"
  with
  | Ok () -> ()
  | Error message -> failf "could not project a token: %s" message
;;

(* Listens and never writes. The pool opens a probe connection before the
   request connection, so this accepts the probe and the request itself
   waits in the kernel backlog: from the client's side the server took the
   connection and never answered, which is the shape a hung MCP server has.
   The handler holds until the test's switch is failed. *)
let start_server_that_never_answers ~sw ~net =
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:1
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> invalid_arg "expected a TCP listening socket"
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Net.accept_fork
      ~sw
      socket
      ~on_error:(fun exn -> failf "fixture listener: %s" (Printexc.to_string exn))
      (fun _flow _addr -> Eio.Fiber.await_cancel ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

(* The shared HTTP client takes its connection pool from the process
   context, so the fixture installs one the way the server does at boot. *)
let with_eio test =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    Eio_context.set_env env;
    Eio_context.with_test_env
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~sw
      (fun () ->
        test ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock;
        Eio.Switch.fail sw Fixture_done)
  with
  | Fixture_done -> ()
;;

(* A call that the deadline under test should end, raced against a watchdog
   set past that deadline: a transport that lost its deadline then fails the
   case instead of holding the suite until the job's own timeout. The
   watchdog sleeps on the monotonic clock; the elapsed time is read from the
   clock the deadline itself runs on, so the two cannot disagree about how
   long the call took. *)
let bounded ~clock ~mono_clock ~deadline_s ~slack_s call =
  let started = Eio.Time.now clock in
  match
    Eio.Fiber.first
      (fun () -> `Returned (call ()))
      (fun () ->
        Eio.Time.Mono.sleep mono_clock (deadline_s +. slack_s);
        `Unbounded)
  with
  | `Unbounded ->
    failf "the call was still waiting %.1fs past its %.1fs deadline" slack_s deadline_s
  | `Returned answer -> answer, Eio.Time.now clock -. started
;;

let check_ended_at ~deadline_s ~slack_s elapsed =
  check
    bool
    (Printf.sprintf "ended at the %.1fs deadline (took %.2fs)" deadline_s elapsed)
    true
    (elapsed >= deadline_s && elapsed < deadline_s +. slack_s)
;;

let transport_deadline_s = 0.3
let transport_slack_s = 3.0

(* The transport alone: a session opened through {!Mcp_client.http_post}
   against a server that never answers ends at the deadline it was built
   with, as a transport error the caller can classify. *)
let test_the_mcp_transport_ends_at_its_deadline () =
  with_eio (fun ~sw ~net ~clock ~mono_clock ->
    let url = start_server_that_never_answers ~sw ~net in
    let post = Mcp_client.http_post ~clock ~deadline_s:transport_deadline_s in
    let answer, elapsed =
      bounded ~clock ~mono_clock ~deadline_s:transport_deadline_s ~slack_s:transport_slack_s (fun () ->
        Mcp_client.connect ~post ~url ~access_token:"the-keepers-token" ())
    in
    match answer with
    | Error (Mcp_client.Transport _) ->
      check_ended_at ~deadline_s:transport_deadline_s ~slack_s:transport_slack_s elapsed
    | Error other -> failf "not a transport error: %s" (Mcp_client.error_to_string other)
    | Ok _ -> fail "a server that never answers opened a session")
;;

(* [turn.provider_call_deadline_sec] has a declared range whose lower bound
   is the shortest deadline a declared threshold can produce; a value below
   it is refused where it is read. Paid once: it is the proof that the keeper's threshold reaches
   the wire through {!Keeper_identity_tools.http_transports}, the transport
   every live identity call is built from. *)
let shortest_declared_threshold_s =
  Env_config_keeper.KeeperKeepalive.provider_call_deadline_min_sec
let threshold_slack_s = 5.0

(* The process environment outranks the boot override, so the threshold is
   declared there; an inherited operator value is replaced for the case and
   put back after it, not skipped under. *)
let with_declared_provider_call_deadline seconds f =
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Masc_test_deps.with_process_env
    Env_config_keeper.KeeperKeepalive.provider_call_deadline_env_key
    (Some (Printf.sprintf "%.0f" seconds))
    (fun () ->
      Keeper_runtime_resolved.reset_for_tests ();
      Fun.protect
        ~finally:(fun () ->
          Config_boot_overrides.reset_for_tests ();
          Keeper_runtime_resolved.reset_for_tests ())
        f)
;;

let test_the_keeper_threshold_reaches_the_wire () =
  with_declared_provider_call_deadline shortest_declared_threshold_s (fun () ->
    check
      (float 0.0)
      "the resolver saw the declared threshold"
      shortest_declared_threshold_s
      (Keeper_runtime_resolved.provider_call_deadline_sec ());
    with_eio (fun ~sw ~net ~clock ~mono_clock ->
      let url = start_server_that_never_answers ~sw ~net in
      let transports = Keeper_identity_tools.http_transports ~clock in
      let answer, elapsed =
        bounded
          ~clock
          ~mono_clock
          ~deadline_s:shortest_declared_threshold_s
          ~slack_s:threshold_slack_s
          (fun () ->
            Mcp_client.connect
              ~post:transports.Keeper_identity_tools.mcp_post
              ~url
              ~access_token:"the-keepers-token"
              ())
      in
      match answer with
      | Error (Mcp_client.Transport _) ->
        check_ended_at
          ~deadline_s:shortest_declared_threshold_s
          ~slack_s:threshold_slack_s
          elapsed
      | Error other -> failf "not a transport error: %s" (Mcp_client.error_to_string other)
      | Ok _ -> fail "a server that never answers opened a session"))
;;

(* ── what the deadline's error means to the keeper ─────────────────────
   Nothing below reaches a network: the transport answers as a live one
   would once its deadline has passed. *)

let deadline_error = Printf.sprintf "timeout after %.1fs" shortest_declared_threshold_s

let json_answer body =
  Ok { Masc_http_client.status = 200; headers = [ "content-type", "application/json" ]; body }
;;

(* The JSON-RPC method the client asked for, read from the request body. *)
let rpc_method body =
  Yojson.Safe.Util.(to_string_option (member "method" (Yojson.Safe.from_string body)))
;;

let initialize_answer =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":%S,"capabilities":{}}}|}
    Mcp_transport_protocol.default_protocol_version
;;

(* The deadline passes on the first request: the session never came up. *)
let transport_that_never_opens ~url:_ ~headers:_ ~body:_ = Error deadline_error

(* The session comes up and the deadline passes on tools/call: the call
   went to the transport, and nothing proves more than that. *)
let transport_that_times_out_the_call ~url:_ ~headers:_ ~body =
  match rpc_method body with
  | Some "initialize" -> json_answer initialize_answer
  | Some "tools/call" -> Error deadline_error
  | Some _ | None -> json_answer "{}"
;;

let never_token_post ~url:_ ~headers:_ ~body:_ =
  fail "renewal reached the token endpoint when it should not have"
;;

let never_discover ~mcp_url:_ = fail "renewal reached discovery when it should not have"

let run_with mcp_post =
  with_temp_base
  @@ fun ~base_path ->
  project_token ~base_path;
  Keeper_identity_tools.run_call
    ~transports:
      { Keeper_identity_tools.mcp_post; token_post = never_token_post; discover = never_discover }
    ~config:(Workspace.default_config base_path)
    ~keeper_name
    ~provider:(provider ())
    ~remote_name:"createJiraIssue"
    ~arguments:(`Assoc [])
    ()
;;

let effect_disposition =
  testable
    (fun fmt disposition ->
      Format.pp_print_string fmt (Tool_result.failure_effect_disposition_to_string disposition))
    ( = )
;;

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0
;;

let recoverable ~read_only answer =
  match Keeper_identity_tools.tool_result_of_call ~read_only answer with
  | Ok output -> failf "the call did not fail: %s" output.Agent_core.Types.content
  | Error err -> err.Agent_core.Types.recoverable
;;

let test_a_deadline_before_the_session_opened_is_a_safe_retry () =
  match run_with transport_that_never_opens with
  | Error
      (Keeper_identity_tools.Mcp
         { phase = Keeper_identity_tools.Session_open; error = Mcp_client.Transport _ } as
       call_error) as answer ->
    check
      effect_disposition
      "nothing was sent"
      Tool_result.Proven_pre_effect
      (Keeper_identity_tools.effect_disposition_of_call_error call_error);
    check bool "a write may be sent again" true (recoverable ~read_only:(Some false) answer)
  | Error (Keeper_identity_tools.Mcp { error; _ }) ->
    failf "not a transport fault before send: %s" (Mcp_client.error_to_string error)
  | Error (Keeper_identity_tools.Precondition message)
  | Error (Keeper_identity_tools.Transient_precondition message) ->
    failf "the call never reached the transport: %s" message
  | Ok _ -> fail "a session that never opened completed the call"
;;

let test_a_deadline_on_the_call_itself_is_not_a_blind_retry () =
  match run_with transport_that_times_out_the_call with
  | Error
      (Keeper_identity_tools.Mcp
         { phase = Keeper_identity_tools.Tool_call; error = Mcp_client.Transport _ } as
       call_error) as answer ->
    check
      effect_disposition
      "the outcome is unknown"
      Tool_result.Effect_outcome_unknown
      (Keeper_identity_tools.effect_disposition_of_call_error call_error);
    check
      bool
      "a write is not offered for a second send"
      false
      (recoverable ~read_only:(Some false) answer);
    check
      bool
      "a tool the provider did not call read-only is treated as a write"
      false
      (recoverable ~read_only:None answer);
    check
      bool
      "a read-only tool may be called again"
      true
      (recoverable ~read_only:(Some true) answer);
    (match Keeper_identity_tools.tool_result_of_call ~read_only:(Some false) answer with
     | Error err ->
       check
         bool
         "the model is told the request may have reached the service"
         true
         (contains ~needle:"may have reached the service" err.Agent_core.Types.message);
       check
         bool
         "the model is told to read the service's state first"
         true
         (contains ~needle:"read the service's state" err.Agent_core.Types.message)
     | Ok _ -> fail "the call did not fail")
  | Error (Keeper_identity_tools.Mcp { phase; error }) ->
    failf
      "not a transport fault on the tool call: %s (%s)"
      (Mcp_client.error_to_string error)
      (match phase with
       | Keeper_identity_tools.Session_open -> "opening the session"
       | Keeper_identity_tools.Tool_call -> "the tool call")
  | Error (Keeper_identity_tools.Precondition message)
  | Error (Keeper_identity_tools.Transient_precondition message) ->
    failf "the call never reached the transport: %s" message
  | Ok _ -> fail "a call the transport timed out completed"
;;

let () =
  run
    "keeper_identity_transports"
    [ ( "bounded by construction"
      , [ test_case
            "the MCP transport ends at its deadline"
            `Quick
            test_the_mcp_transport_ends_at_its_deadline
        ; test_case
            "the keeper threshold reaches the wire"
            `Slow
            test_the_keeper_threshold_reaches_the_wire
        ] )
    ; ( "what the deadline means"
      , [ test_case
            "a deadline before the session opened is a safe retry"
            `Quick
            test_a_deadline_before_the_session_opened_is_a_safe_retry
        ; test_case
            "a deadline on the call itself is not a blind retry"
            `Quick
            test_a_deadline_on_the_call_itself_is_not_a_blind_retry
        ] )
    ]
;;
