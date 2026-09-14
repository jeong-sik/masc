(* An identity tool call reaches a server outside masc from inside a keeper
   turn, where the attempt watchdog does not watch a tool in flight. The
   transport's deadline is therefore the only liveness the call has. These
   cases pin that the production transports are bounded, and by which
   declared setting: the same server that accepts a connection and never
   answers used to hold the turn until its wall-clock ceiling. *)

open Alcotest
open Masc

let keeper_name = "identity-transports-fixture"
let access_token_env = "ATLASSIAN_ACCESS_TOKEN"

let temp_base () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-identity-transports-%d-%.0f" (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Unix.mkdir path 0o700;
  path
;;

(* A declaration whose MCP endpoint is the fixture server. No expiry is
   stored for the token, so no renewal is attempted and the OAuth hops are
   never reached; the MCP session is the whole call. *)
let provider ~mcp_url =
  let contents =
    Printf.sprintf
      {|
id = "atlassian"
label = "Atlassian"
mcp_url = %S
access_token_env = %S
expires_at_env = "ATLASSIAN_ACCESS_TOKEN_EXPIRES_AT"
refresh_token_file = "/home/keeper/.atlassian/refresh_token"
renew_before_sec = 600
|}
      mcp_url
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

(* Accepts the connection and never writes: an MCP server that hangs after
   taking the request. The handler holds the flow until the test's switch is
   failed. *)
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
      ~on_error:(fun _ -> ())
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
        test ~sw ~net:env#net ~clock:env#clock;
        Eio.Switch.fail sw Exit)
  with
  | Exit -> ()
;;

let transport_deadline_s = 0.3
let transport_slack_s = 3.0

(* The transport alone: a session opened through {!Mcp_client.http_post}
   against a server that never answers ends at the deadline it was built
   with, as a transport error the caller can classify. *)
let test_the_mcp_transport_ends_at_its_deadline () =
  with_eio (fun ~sw ~net ~clock ->
    let url = start_server_that_never_answers ~sw ~net in
    let post = Mcp_client.http_post ~clock ~deadline_s:(Some transport_deadline_s) in
    let started = Eio.Time.now clock in
    match Mcp_client.connect ~post ~url ~access_token:"the-keepers-token" () with
    | Error (Mcp_client.Transport _) ->
      let elapsed = Eio.Time.now clock -. started in
      check
        bool
        "the session ended at the transport's deadline"
        true
        (elapsed >= transport_deadline_s && elapsed < transport_deadline_s +. transport_slack_s)
    | Error other -> failf "not a transport error: %s" (Mcp_client.error_to_string other)
    | Ok _ -> fail "a server that never answers opened a session")
;;

(* [turn.provider_call_deadline_sec] is clamped to [30, 3600] where it is
   read, so thirty seconds is the shortest deadline a declared threshold can
   produce. Paid once: it is the proof that the keeper's threshold reaches
   the MCP session through {!Keeper_identity_tools.http_transports}, and that
   the call the model sees ends as a transport fault before anything was
   sent. *)
let shortest_declared_threshold_s = 30.0
let threshold_slack_s = 5.0

let with_declared_provider_call_deadline seconds f =
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Config_boot_overrides.set
    "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC"
    (Printf.sprintf "%.0f" seconds);
  Keeper_runtime_resolved.reset_for_tests ();
  Fun.protect
    ~finally:(fun () ->
      Config_boot_overrides.reset_for_tests ();
      Keeper_runtime_resolved.reset_for_tests ())
    f
;;

let test_the_keeper_threshold_bounds_a_tool_call () =
  with_declared_provider_call_deadline shortest_declared_threshold_s (fun () ->
    check
      (option (float 0.0))
      "the resolver saw the declared threshold"
      (Some shortest_declared_threshold_s)
      (Keeper_runtime_resolved.provider_call_deadline_sec ());
    with_eio (fun ~sw ~net ~clock ->
      let mcp_url = start_server_that_never_answers ~sw ~net in
      let base_path = temp_base () in
      project_token ~base_path;
      let started = Eio.Time.now clock in
      match
        Keeper_identity_tools.run_call
          ~transports:(Keeper_identity_tools.http_transports ~clock)
          ~base_path
          ~keeper_name
          ~provider:(provider ~mcp_url)
          ~remote_name:"getJiraIssue"
          ~arguments:(`Assoc [])
          ()
      with
      | Error
          (Keeper_identity_tools.Mcp
             { phase = Keeper_identity_tools.Before_send; error = Mcp_client.Transport _ }) ->
        let elapsed = Eio.Time.now clock -. started in
        check
          bool
          "the call ended at the declared threshold"
          true
          (elapsed >= shortest_declared_threshold_s
           && elapsed < shortest_declared_threshold_s +. threshold_slack_s)
      | Error (Keeper_identity_tools.Mcp { error; _ }) ->
        failf "not a transport fault before send: %s" (Mcp_client.error_to_string error)
      | Error (Keeper_identity_tools.Precondition message)
      | Error (Keeper_identity_tools.Transient_precondition message) ->
        failf "the call never reached the wire: %s" message
      | Ok _ -> fail "a server that never answers completed the call"))
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
            "the keeper threshold bounds a tool call"
            `Slow
            test_the_keeper_threshold_bounds_a_tool_call
        ] )
    ]
;;
