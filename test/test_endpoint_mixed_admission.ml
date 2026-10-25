open Alcotest
open Masc
module LP = Llm_provider
module EO = Agent_core.Exact_output

type allowance = Declared | Undeclared
type reply = Answer | Rate_limited

type peer = {
  url : string;
  first_seen : unit Eio.Promise.t;
  release_first : unit Eio.Promise.u;
  mutable primary_posts : int;
  mutable other_posts : int;
  mutable primary_active : int;
  mutable primary_peak : int;
  mutable next_reply : reply;
}

let answer = {|{"resolved_answer":"controlled endpoint answer","decision":{"kind":"answer","answer":"yes"}}|}

let response_body ~model ~stream =
  let content = `String answer in
  let choice fields = `Assoc ["index", `Int 0; "delta", `Assoc fields;
                              "finish_reason", `Null] in
  if stream then
    let chunk fields = "data: " ^ Yojson.Safe.to_string (`Assoc fields) ^ "\n\n" in
    chunk ["id", `String "fixture"; "choices", `List [choice ["role", `String "assistant"; "content", content]]]
    ^ chunk ["id", `String "fixture"; "choices", `List [`Assoc ["index", `Int 0; "delta", `Assoc []; "finish_reason", `String "stop"]]]
    ^ "data: [DONE]\n\n"
  else
    Yojson.Safe.to_string (`Assoc ["id", `String "fixture"; "model", `String model;
      "choices", `List [`Assoc ["index", `Int 0;
        "message", `Assoc ["role", `String "assistant"; "content", content];
        "finish_reason", `String "stop"]]])

let start_peer ~sw ~net ~prefix ~primary_key ~hold_first =
  let socket = Eio.Net.listen net ~sw ~backlog:8
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | `Unix _ -> fail "expected TCP peer" in
  let first_seen, notify_first = Eio.Promise.create () in
  let release, release_first = Eio.Promise.create () in
  let peer = {url=Printf.sprintf "http://127.0.0.1:%d/%s/v1" port prefix;
    first_seen; release_first; primary_posts=0; other_posts=0;
    primary_active=0; primary_peak=0; next_reply=Answer} in
  let callback _ request body =
    let json = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)
        |> Yojson.Safe.from_string in
    let authorization = Cohttp.Header.get (Cohttp.Request.headers request) "authorization" in
    let primary = authorization = Some ("Bearer " ^ primary_key) in
    check bool "actual HTTP request carries its declared account" true
      (Option.is_some authorization);
    if primary then (
      peer.primary_posts <- peer.primary_posts + 1;
      peer.primary_active <- peer.primary_active + 1;
      peer.primary_peak <- max peer.primary_peak peer.primary_active)
    else peer.other_posts <- peer.other_posts + 1;
    let first = primary && peer.primary_posts = 1 in
    let reply = peer.next_reply in
    peer.next_reply <- Answer;
    Fun.protect
      ~finally:(fun () -> if primary then peer.primary_active <- peer.primary_active - 1)
      (fun () ->
        if first then (
          Eio.Promise.resolve notify_first ();
          if hold_first then Eio.Promise.await release);
        match reply with
        | Rate_limited -> Cohttp_eio.Server.respond_string ~status:`Too_many_requests
            ~body:{|{"error":{"message":"controlled peer concurrency refusal","type":"rate_limit_error"}}|} ()
        | Answer ->
          let stream = match Yojson.Safe.Util.member "stream" json with
            | `Bool value -> value | `Null -> false
            | _ -> fail "stream must be a protocol boolean" in
          let headers = Cohttp.Header.of_list ["content-type",
              if stream then "text/event-stream" else "application/json"] in
          Cohttp_eio.Server.respond_string ~status:`OK ~headers
            ~body:(response_body ~model:(Yojson.Safe.Util.member "model" json |> Yojson.Safe.Util.to_string) ~stream) ())
  in
  let server = Cohttp_eio.Server.make ~callback () in
  let serve () = Cohttp_eio.Server.run socket server ~on_error:raise in
  peer, serve

let get_ok label = function Ok value -> value | Error _ -> fail label

let runtime_toml allowance endpoint =
  let declaration = match allowance with
    | Declared -> "max-concurrent = 1\n"
    | Undeclared -> "" in
  Printf.sprintf {|[runtime]
default = "openai.chat"
[providers.openai]
display-name = "Controlled endpoint fixture"
protocol = "openai-compatible-http"
endpoint = "%s"
[providers.openai.credentials]
type = "env"
key = "OPENAI_API_KEY"
[models.chat]
api-name = "gpt-4o"
max-context = 128000
tools-support = false
streaming = false
turn-timeout-s = 0
[openai.chat]
%s|} endpoint declaration

let fork ~sw f =
  let result, resolve = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve (f ()));
  result

type 'a cancelled_result = Returned of 'a | Cancelled
exception Cancel_waiter

let fork_cancellable ~sw f =
  let context, notify_context = Eio.Promise.create () in
  let result = fork ~sw (fun () ->
    match Eio.Cancel.sub (fun ctx ->
      Eio.Promise.resolve notify_context ctx;
      f ()) with
    | value -> Returned value
    | exception Eio.Cancel.Cancelled _ -> Cancelled) in
  context, result

let messages = [LP.Types.user_msg "Return the controlled endpoint answer."]

let ordinary ~sw ~net config =
  (LP.Complete.complete ~sw ~net ~config ~messages ()).LP.Completion_outcome.result

let exact_flow config =
  let declaration : EO.declared_target =
    {target_ref="openai.chat"; binding=config;
     credential=EO.Credential_resolved config.LP.Provider_config.api_key;
     (* The public exact API requires an explicit transport deadline. It is
        not used as the synchronization/assertion boundary in this fixture. *)
     body_timeout_s=Some 120.0} in
  let snapshot = EO.load_resolver_snapshot
      ~catalog:(EO.Embedded_with_targets [declaration]) ()
      |> get_ok "exact snapshot must use the original runtime binding" in
  let admitted_target = EO.admit_target_ref snapshot "openai.chat"
      |> get_ok "exact runtime target must be admitted" in
  let candidate = EO.make_flow_candidate ~id:"controlled" ~admitted_target
      |> get_ok "exact flow candidate must be constructed" in
  let schema = `Assoc ["type", `String "object";
      "properties", `Assoc ["resolved_answer", `Assoc ["type", `String "string"]];
      "required", `List [`String "resolved_answer"]] in
  let requirement = EO.make_output_requirement ~schema ~minimum_guarantee:EO.Json_syntax in
  let ready = EO.snapshot_flow ~first:candidate ~rest:[] ~messages requirement
      |> get_ok "exact flow must preserve the target admission declaration" in
  EO.start_flow ~admission_class:LP.Admission_class.Standard ready
    |> get_ok "exact flow must start"

type no_rejection = |

let execute_exact ?(on_receipt=(fun _ -> ())) ~net ~clock flow =
  let validate success : (EO.flow_success, no_rejection) EO.semantic_verdict =
    EO.Accept success in
  EO.execute_flow_once ~net ~clock
    ~before_measurement_dispatch:(fun _ -> Ok ())
    ~on_measurement_terminal:(fun _ -> Ok ())
    ~before_dispatch:(fun (candidate:EO.flow_attempt_receipt) -> on_receipt candidate.receipt; Ok ())
    ~before_advance:(fun ~failed:_ ~next:_ -> Ok ())
    ~validate flow

let judge ~work ~sw ~net () =
  Fusion_judge.run ~base_dir:work ~sw ~net
    ~judge_system_prompt:"Return the requested synthesis."
    ~judge_model:"openai.chat" ~question:"controlled endpoint concurrency"
    ~panel:[] ~web_tools:false ()

let assert_released config =
  match LP.Provider_admission.snapshot_for ~config with
  | Some snapshot ->
    check int "all endpoint permits returned" 0 snapshot.active;
    check int "all endpoint waiters settled" 0 snapshot.queue_length
  | None -> fail "declared endpoint lost its admission scheduler"

(* Wait for the actual queue state, not elapsed time or a fixed yield count.
   An extra primary POST before release is an admission failure, even if its
   response has already completed when the controller next runs. *)
let await_queue peer config expected =
  let rec loop () =
    check int "held endpoint has only its first primary HTTP request" 1 peer.primary_posts;
    match LP.Provider_admission.snapshot_for ~config with
    | Some snapshot when snapshot.queue_length = expected ->
      check int "first request still owns the permit" 1 snapshot.active
    | Some _ -> Eio.Fiber.yield (); loop ()
    | None -> fail "declared endpoint must own a scheduler"
  in loop ()

let await_undeclared config promise =
  let rec loop () =
    check bool "undeclared endpoint creates no admission scheduler" true
      (Option.is_none (LP.Provider_admission.snapshot_for ~config));
    match Eio.Promise.peek promise with
    | Some value -> value
    | None -> Eio.Fiber.yield (); loop ()
  in loop ()

let with_fixture allowance f =
  let work = Filename.temp_file "endpoint-mixed-admission-" "" in
  Sys.remove work; Unix.mkdir work 0o700;
  let key = match allowance with Declared -> "fixture-declared" | Undeclared -> "fixture-undeclared" in
  let prefix = match allowance with Declared -> "declared" | Undeclared -> "undeclared" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree work) (fun () ->
    Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some work) (fun () ->
      Masc_test_deps.with_process_env "OPENAI_API_KEY" (Some key) (fun () ->
        Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
          Eio_context.set_env env;
          Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock (fun () ->
            let a, serve_a = start_peer ~sw ~net:env#net ~prefix ~primary_key:key ~hold_first:true in
            let b, serve_b = start_peer ~sw ~net:env#net ~prefix ~primary_key:key ~hold_first:false in
            let run () =
              let path = Filename.concat work "runtime.toml" in
              Fs_compat.save_file_atomic path (runtime_toml allowance a.url)
                |> get_ok "controlled runtime fixture must persist";
              Runtime.init_default ~config_path:path |> get_ok "controlled runtime must initialize";
              let configs = Runtime_agent_core_runner.resolve_runtime_providers_for_turn
                  ~runtime_id:"openai.chat" () |> get_ok "HTTP runtime must resolve" in
              let config = match configs with
                | [config] -> config | _ -> fail "fixture must resolve one original binding" in
              check (option int) "actual runtime carries the allowance declaration"
                (match allowance with Declared -> Some 1 | Undeclared -> None)
                config.max_concurrent_requests;
              Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
              Prompt_defaults.init ();
              f ~work ~sw ~net:env#net ~clock:env#clock ~a ~b config
            in
            Eio.Fiber.first (fun () -> Eio.Fiber.both serve_a serve_b) run))))))

let test_mixed_declared () = with_fixture Declared (fun ~work ~sw ~net ~clock ~a ~b config ->
  let first = fork ~sw (fun () -> ordinary ~sw ~net config |> get_ok "first ordinary completion") in
  Eio.Promise.await a.first_seen;
  let exact_config = {config with LP.Provider_config.model_id="gpt-4o-mini"} in
  let flow = exact_flow exact_config in
  let exact = fork ~sw (fun () -> execute_exact ~net ~clock flow |> get_ok "queued exact completion") in
  let fusion = fork ~sw (fun () -> judge ~work ~sw ~net () |> get_ok "queued actual Fusion judge") in
  let cancel_context, cancelled = fork_cancellable ~sw (fun () ->
    execute_exact ~net ~clock (exact_flow exact_config)) in
  await_queue a config 3;
  Eio.Cancel.cancel (Eio.Promise.await cancel_context) Cancel_waiter;
  (match Eio.Promise.await cancelled with
   | Cancelled -> () | Returned _ -> fail "queued exact request ignored cancellation");
  await_queue a config 2;
  ordinary ~sw ~net {config with base_url=b.url}
    |> get_ok "another endpoint progresses while A is saturated" |> ignore;
  ordinary ~sw ~net {config with api_key=LP.Secret.of_string "fixture-alternate-account"}
    |> get_ok "another credential progresses while A is saturated" |> ignore;
  check int "independent endpoint received its actual HTTP request" 1 b.primary_posts;
  check int "independent account received its actual HTTP request" 1 a.other_posts;
  check int "queued exact and Fusion have sent no primary HTTP yet" 1 a.primary_posts;
  Eio.Promise.resolve a.release_first ();
  ignore (Eio.Promise.await first);
  ignore (Eio.Promise.await exact);
  let synthesis, _usage = Eio.Promise.await fusion in
  check string "actual Fusion parser receives its answer" "controlled endpoint answer" synthesis.resolved_answer;
  check int "ordinary/exact/Fusion share one actual in-flight request" 1 a.primary_peak;
  check int "cancelled waiter never sends an HTTP request" 3 a.primary_posts;
  assert_released config;
  a.next_reply <- Rate_limited;
  (match ordinary ~sw ~net config with
   | Ok _ -> fail "ordinary 429 must fail"
   | Error error ->
     (match error with
      | LP.Http_client.HttpError {code; _} -> check int "ordinary typed HTTP status" 429 code
      | NetworkError _ | TimeoutError _ | AcceptRejected _
      | ProviderTerminal _ | ProviderFailure _ -> fail "ordinary 429 lost its HTTP status"));
  assert_released config;
  ordinary ~sw ~net config |> get_ok "ordinary succeeds after 429" |> ignore;
  a.next_reply <- Rate_limited;
  let receipt = ref None in
  let refused = execute_exact ~net ~clock ~on_receipt:(fun value -> receipt := Some value)
      (exact_flow exact_config) in
  check bool "exact HTTP429 is a failed execution" true (Result.is_error refused);
  (match !receipt with
   | Some receipt -> check (option int) "exact receipt retains actual HTTP status"
       (Some 429) (EO.receipt_http_status receipt)
   | None -> fail "exact HTTP429 lost its generation receipt");
  assert_released config;
  execute_exact ~net ~clock (exact_flow exact_config) |> get_ok "exact succeeds after 429" |> ignore;
  a.next_reply <- Rate_limited;
  (match judge ~work ~sw ~net () with
   | Ok _ -> fail "actual Fusion 429 must fail"
   | Error (failure, _) ->
     (match failure with
      | Fusion_types.Provider_error _ -> ()
      | Timeout | Empty_response _ | Empty_result | Build_error _ | Parse_error _
      | Panels_unavailable _ | Unknown_route _ | Route_unavailable _ | Internal_error _ ->
        fail "actual Fusion 429 must remain a provider failure"));
  assert_released config;
  judge ~work ~sw ~net () |> get_ok "Fusion succeeds after 429" |> ignore;
  assert_released config)

let test_mixed_undeclared () = with_fixture Undeclared (fun ~work ~sw ~net ~clock ~a ~b config ->
  let first = fork ~sw (fun () -> ordinary ~sw ~net config |> get_ok "held undeclared ordinary call") in
  Eio.Promise.await a.first_seen;
  let exact = fork ~sw (fun () -> execute_exact ~net ~clock (exact_flow config)
    |> get_ok "undeclared exact call progresses") in
  let fusion = fork ~sw (fun () -> judge ~work ~sw ~net ()
    |> get_ok "undeclared actual Fusion call progresses") in
  ignore (await_undeclared config exact);
  ignore (await_undeclared config fusion);
  ordinary ~sw ~net {config with base_url=b.url}
    |> get_ok "independent undeclared endpoint progresses" |> ignore;
  check bool "None does not invent a process allowance" true (a.primary_peak >= 2);
  check int "all undeclared producer routes reached actual HTTP" 3 a.primary_posts;
  Eio.Promise.resolve a.release_first ();
  ignore (Eio.Promise.await first);
  check bool "None still owns no scheduler after completion" true
    (Option.is_none (LP.Provider_admission.snapshot_for ~config)))

let () = run "actual mixed endpoint admission"
  ["shared HTTP boundary", [test_case "ordinary/exact/Fusion isolate endpoints and return permits" `Quick test_mixed_declared;
                            test_case "undeclared endpoints preserve direct dispatch" `Quick test_mixed_undeclared]]
