open Masc

module EO = Agent_core.Exact_output

(* Every wait a case makes on the fixture is bounded by this budget. A
   loopback POST from a forked worker (connect, accept, read) takes well
   under a second on an idle machine. The nightly runner has 4 CPUs and runs
   several suites at once, where 50ms sleeps are known to miss, so the budget
   is generous. It is still 20x shorter than the 600s per-suite deadline, so
   a wait that never ends fails the case by name instead of holding the suite
   until the runner kills it (#33200). *)
let fixture_wait_seconds = 30.0

(* Default [connect_timeout_s] for every fixture target. The exact-output
   HTTP client puts no deadline on the request-to-response-headers phase
   unless the target sets one, so a worker whose POST never gets its headers
   answered would wait forever. This bounds the worker's side of the socket;
   [fixture_wait_seconds] bounds the test's side. *)
let fixture_post_connect_timeout_seconds = 30.0

type server_behavior =
  | Reply of string
  | Replies of string list
  | Abort_after_request
  | Delay_then_reply of float * string

type test_server =
  { base_url : string
  ; posts : int Atomic.t
  ; requests : string list Atomic.t
  ; first_request_arrived : unit Eio.Promise.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  }

type target_fixture =
  { id : string
  ; base_url : string
  }

let add_request requests body =
  let rec loop () =
    let current = Atomic.get requests in
    if not (Atomic.compare_and_set requests current (body :: current)) then loop ()
  in
  loop ()
;;

let start_server ?on_request_before_reply ~sw ~net ~clock behavior =
  let posts = Atomic.make 0 in
  let requests = Atomic.make [] in
  let first_request_arrived, resolve_first_request_arrived = Eio.Promise.create () in
  let handler _conn _request body =
    let request_body = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    add_request requests request_body;
    let request_index = Atomic.fetch_and_add posts 1 in
    ignore (Eio.Promise.try_resolve resolve_first_request_arrived ());
    Option.iter (fun hook -> hook ()) on_request_before_reply;
    match behavior with
    | Reply response -> Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
    | Replies responses ->
      let response =
        match List.nth_opt responses request_index with
        | Some response -> response
        | None -> Alcotest.failf "no fixture reply for request %d" request_index
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
    | Abort_after_request -> raise Exit
    | Delay_then_reply (delay_s, response) ->
      Eio.Time.sleep clock delay_s;
      Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | _ -> Alcotest.fail "loopback listener did not expose a TCP port"
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  { base_url = Printf.sprintf "http://127.0.0.1:%d" port
  ; posts
  ; requests
  ; first_request_arrived
  ; clock
  }
;;

let target_fixture_toml
      ~connect_timeout_s
      ?max_request_body_bytes
      ~supports_response_format_json
      ~supports_structured_output
      ~api_key_env
      index
      fixture
  =
  let provider_id = Printf.sprintf "masc-exact-fixture-provider-%d" index in
  let model_id = Printf.sprintf "masc-exact-fixture-model-%d" index in
  let timeout = Printf.sprintf "connect_timeout_s = %.6g\n" connect_timeout_s in
  let request_body_limit =
    Option.fold
      ~none:""
      ~some:(fun value -> Printf.sprintf "max_request_body_bytes = %d\n" value)
      max_request_body_bytes
  in
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     kind = \"openai_compat\"\n\
     base_url = %S\n\
     request_path = \"/v1/chat/completions\"\n\
     api_key_env = %S\n\n\
     [[models]]\n\
     id_prefix = %S\n\
     provider_name = %S\n\
     max_context_tokens = 8192\n\
     max_output_tokens = 1024\n\
     supports_response_format_json = %b\n\
     supports_structured_output = %b\n\n\
     [[targets]]\n\
     id = %S\n\
     provider_ref = %S\n\
     model_id = %S\n\
     %s\
     %s"
    provider_id
    fixture.base_url
    api_key_env
    model_id
    provider_id
    supports_response_format_json
    supports_structured_output
    fixture.id
    provider_id
    model_id
    timeout
    request_body_limit
;;

let resolver_snapshot
      ?(connect_timeouts = [])
      ?(request_body_limits = [])
      ?(api_key_env = "")
      ?(api_key_envs = [])
      ?(supports_response_format_json = true)
      ?(supports_structured_output = true)
      ~source
      fixtures
  =
  let timeout_for id =
    List.assoc_opt id connect_timeouts
    |> Option.value ~default:fixture_post_connect_timeout_seconds
  in
  let request_body_limit_for id = List.assoc_opt id request_body_limits in
  let api_key_env_for id =
    List.assoc_opt id api_key_envs |> Option.value ~default:api_key_env
  in
  let overlay : EO.catalog_document =
    { source
    ; contents =
        fixtures
        |> List.mapi (fun index fixture ->
            target_fixture_toml
              ~connect_timeout_s:(timeout_for fixture.id)
              ?max_request_body_bytes:(request_body_limit_for fixture.id)
              ~supports_response_format_json
              ~supports_structured_output
              ~api_key_env:(api_key_env_for fixture.id)
            index
            fixture)
        |> String.concat "\n"
    }
  in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  match
    EO.load_resolver_snapshot
      ~io
      ~catalog:(EO.Embedded_with_overlay overlay)
      ()
  with
  | Ok snapshot -> snapshot
  | Error _ -> Alcotest.fail "exact-output resolver fixture did not load"
;;

let catalog_generation_fingerprint snapshot =
  snapshot
  |> EO.resolver_catalog_generation
  |> EO.catalog_generation_fingerprint
;;

(* Official-client runtime table for cli lane-slot tests: enough for
   [Fusion_official_client.is_official_client] to admit the two claude ids
   without executing a client (command is /usr/bin/true). Same shape as the
   fusion panel fixture. *)
let official_client_runtime_fixture =
  {|
[runtime]
default = "stub-http.stub-model"

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[providers.claude_code]
display-name = "Claude Code Max Subscription"
protocol = "claude-code"
command = "/usr/bin/true"
is-non-interactive = true

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 1000000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-sonnet-5"]

[models."claude-haiku-4-5"]
api-name = "claude-haiku-4-5"
max-context = 200000
tools-support = true
streaming = true
turn-timeout-s = 0

[claude_code."claude-haiku-4-5"]
|}
;;

let cli_primary_runtime = "claude_code.claude-sonnet-5"
let cli_secondary_runtime = "claude_code.claude-haiku-4-5"

let with_official_client_runtimes f =
  let path = Filename.temp_file "cli-lane-runtime" ".toml" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       let channel = open_out path in
       Fun.protect
         ~finally:(fun () -> close_out channel)
         (fun () -> output_string channel official_client_runtime_fixture);
       match Runtime.init_default ~config_path:path with
       | Error detail ->
         Alcotest.failf "official-client runtime fixture must initialize: %s" detail
       | Ok () -> f ())
;;

let publish_registry ?(cli_slot_ids = []) ~lane_id ~slot_ids resolver_snapshot =
  let lane : Runtime_schema.exact_output_lane_decl = { id = lane_id; slot_ids; cli_slot_ids } in
  match Runtime_exact_output_registry.publish ~lanes:[ lane ] resolver_snapshot with
  | Ok registry -> registry
  | Error error ->
    Alcotest.failf
      "exact-output registry fixture did not publish: %s"
      (Runtime_exact_output_registry.publication_error_to_string error)
;;

let openai_response output =
  let encoded_content =
    output
    |> Yojson.Safe.to_string
    |> fun json -> Yojson.Safe.to_string (`String json)
  in
  Printf.sprintf
    {|{"id":"masc-conformance","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":%s},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    encoded_content
;;

let post_count server = Atomic.get server.posts
let request_bodies server = Atomic.get server.requests |> List.rev

(* Waits for [promise] at most [fixture_wait_seconds]. Past that the case
   fails with [failure] instead of holding the suite until the runner
   deadline (#33200). *)
let await_within_fixture_budget ~clock ~failure promise =
  match
    Eio.Time.with_timeout clock fixture_wait_seconds (fun () ->
      Ok (Eio.Promise.await promise))
  with
  | Ok value -> value
  | Error `Timeout -> Alcotest.failf "%s within %gs" failure fixture_wait_seconds
;;

let await_first_request server =
  await_within_fixture_budget
    ~clock:server.clock
    ~failure:(Printf.sprintf "fixture server %s received no request" server.base_url)
    server.first_request_arrived
;;
