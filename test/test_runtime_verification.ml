(* A start of Antigravity, by the access the suite publishes first. *)
let antigravity_host () =
  Masc_test_deps.host_account Runtime_account_access.Antigravity

let provider_config_for_binding config binding =
  Runtime_adapter.materialize_provider_binding
    ~construction:(Runtime_adapter.create_construction ()) config binding
  |> Result.map (fun (selected : Runtime_adapter.provider_materialization) -> selected.provider_config)
;;

open Alcotest
module Verify = Runtime_verification

let contains text needle =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  loop 0
;;

let measure run =
  Verify.For_testing.measure
    ~runtime_id:"chosen.model"
    ~selected_model:"selected-model"
    ~challenge:"unpredictable-test-challenge"
    ~run
;;

let observation text = { Verify.model = "observed-model"; text }
let reply = "{\"challenge\":\"unpredictable-test-challenge\"}"

let test_roundtrip () =
  let result =
    measure (fun tool ~prompt ->
      check
        bool
        "challenge absent before tool execution"
        false
        (contains prompt "unpredictable-test-challenge");
      let output =
        tool.Runtime_official_client_tool.call ~call_id:"actual-call" (`Assoc [])
      in
      check bool "harmless tool returned a result" true output.success;
      Ok (observation output.content))
  in
  check int "actual returned challenge verifies" 0 (Verify.exit_code result);
  check bool "tool roundtrip" true result.tool_roundtrip;
  check
    (option string)
    "observed model retained separately"
    (Some "observed-model")
    result.observed_model;
  check string "exact selected runtime remains" "chosen.model" result.runtime_id
;;

let test_no_tool_cannot_claim_success () =
  let result = measure (fun _ ~prompt:_ -> Ok (observation reply)) in
  check int "even correct-looking reply without call fails" 1 (Verify.exit_code result);
  check bool "actual response distinguished from login" true result.response;
  check bool "tool not invoked" false result.tool_called;
  check bool "no roundtrip" false result.tool_roundtrip
;;

let test_result_must_be_consumed () =
  List.iter
    (fun text ->
       let result =
         measure (fun tool ~prompt:_ ->
           ignore (tool.Runtime_official_client_tool.call ~call_id:"call" (`Assoc []));
           Ok (observation text))
       in
       check int "uncorrelated answer is not ready" 1 (Verify.exit_code result);
       check bool "invocation alone is insufficient" true result.tool_called;
       check bool "result not consumed" false result.tool_roundtrip)
    [ "I can use tools"
    ; "{\"challenge\":\"invented\"}"
    ; "{\"challenge\":\"unpredictable-test-challenge\",\"challenge\":\"invented\"}"
    ; ""
    ]
;;

let test_missing_model_identity () =
  let result =
    measure (fun tool ~prompt:_ ->
      let output = tool.Runtime_official_client_tool.call ~call_id:"call" (`Assoc []) in
      Ok { Verify.model = ""; text = output.content })
  in
  check int "missing model identity is not verified" 1 (Verify.exit_code result);
  check (option string) "empty identity is not an observation" None result.observed_model
;;

let test_invalid_call_and_errors () =
  let result =
    measure (fun tool ~prompt:_ ->
      let output =
        tool.Runtime_official_client_tool.call
          ~call_id:"call"
          (`Assoc [ "path", `String "/workspace" ])
      in
      check bool "invalid tool args rejected" false output.success;
      Ok (observation reply))
  in
  check bool "invalid tool args not counted" false result.tool_called;
  List.iter
    (fun failure ->
       let result = measure (fun _ ~prompt:_ -> Error failure) in
       check bool "provider/config failure not success" false result.tool_roundtrip;
       check bool "no response fabricated" false result.response)
    [ Verify.Provider_rejected "the provider returned HTTP 400"
    ; Timed_out
    ; Unavailable (Missing_credential "provider \"p\" requires non-empty credential env \"KEY\"")
    ]
;;

(* The three client failures used to fold into one code with one message, so a
   client that was merely not signed in read the same as one whose binary was
   missing. Each keeps its own code, and the client's own account survives. *)
let failure_field result field =
  Verify.to_json result
  |> fun json ->
  Yojson.Safe.Util.member "failure" json |> Yojson.Safe.Util.member field
;;

let test_client_failures_stay_apart () =
  let case failure =
    let result = measure (fun _ ~prompt:_ -> Error failure) in
    ( Yojson.Safe.Util.to_string (failure_field result "code")
    , failure_field result "detail" )
  in
  let not_signed_in, signed_in_detail =
    case (Verify.Unavailable (Client_not_authenticated "no stored credential was found"))
  in
  let not_started, started_detail =
    case (Verify.Unavailable (Client_not_started "executable \"claude\" was not found"))
  in
  let bad_config, config_detail =
    case (Verify.Unavailable (Invalid_configuration "cli_path must not be empty"))
  in
  check string "sign-in failure has its own code" "client_not_authenticated" not_signed_in;
  check string "spawn failure has its own code" "client_not_started" not_started;
  check string "config failure has its own code" "invalid_configuration" bad_config;
  check
    (list string)
    "each carries the client's own account"
    [ "no stored credential was found"
    ; "executable \"claude\" was not found"
    ; "cli_path must not be empty"
    ]
    (List.map
       Yojson.Safe.Util.to_string
       [ signed_in_detail; started_detail; config_detail ]);
  (* Issue #50018: a person who calls their own account gets the code and the
     message, and the detail, which can name a path of the server, stays out. *)
  let spawn =
    measure (fun _ ~prompt:_ ->
      Error (Verify.Unavailable (Client_not_started "executable \"/srv/bin/claude\" was not found")))
  in
  let member = Yojson.Safe.Util.member "failure" (Verify.to_member_json spawn) in
  check
    bool
    "a person's answer keeps the code"
    true
    (Yojson.Safe.Util.member "code" member = `String "client_not_started");
  check
    bool
    "and leaves the detail out"
    true
    (Yojson.Safe.Util.member "detail" member = `Null);
  let result =
    measure (fun _ ~prompt:_ -> Error (Verify.Unavailable Unsupported_runtime))
  in
  check
    bool
    "a failure with nothing to add reports no detail"
    true
    (failure_field result "detail" = `Null);
  check int "an unavailable client still exits 2" 2 (Verify.exit_code result)
;;

(* A 429 used to arrive as the same provider_rejected as a refused key, so an
   operator stopped the install to find out whether waiting would do. Each
   typed cause keeps its own code, and the code survives the report the
   setup screen reads back. *)
let test_provider_refusals_name_their_cause () =
  let code_of error =
    let failure = Verify.failure_of_agent_core_error error in
    let result = measure (fun _ ~prompt:_ -> Error failure) in
    (match Verify.of_json (Verify.to_json result) with
     | Ok (Verify.Measured { Verify.failure = Some read; _ }) ->
       check string "the code reads back" (Verify.failure_code failure) (Verify.failure_code read)
     | Ok _ | Error _ -> fail "the report did not read back with its failure");
    Verify.failure_code failure
  in
  let api error = Agent_core.Error.Api error in
  check
    (list string)
    "each typed refusal keeps its cause"
    [ "rate_limited"
    ; "quota_exhausted"
    ; "provider_overloaded"
    ; "provider_auth_refused"
    ; "provider_auth_refused"
    ; "model_not_found"
    ]
    (List.map
       code_of
       [ api (Llm_provider.Retry.RateLimited { retry_after = Some 30.; message = "slow down" })
       ; api (Llm_provider.Retry.PaymentRequired { message = "balance" })
       ; api (Llm_provider.Retry.Overloaded { message = "busy" })
       ; api (Llm_provider.Retry.AuthError { message = "bad key" })
       ; api (Llm_provider.Retry.AuthorizationError { message = "no access" })
       ; api (Llm_provider.Retry.NotFound { message = "no such model" })
       ]);
  let throttled =
    api (Llm_provider.Retry.RateLimited { retry_after = Some 30.; message = "slow down" })
  in
  check
    (option string)
    "the provider's retry hint is kept"
    (Some (Agent_core.Error.to_string throttled ^ " (provider asks to retry after 30s)"))
    (Verify.failure_detail (Verify.failure_of_agent_core_error throttled))
;;

(* Proves the credential arm keeps the dispatch check's selected account. A runtime
   whose selected file credential has no usable final secret reports
   [Invalid_credential] with a reason naming the file carrier, and one whose
   environment credential is unset reports [Missing_credential] naming the
   variable. On origin/main both arrive as a payload-free [Missing_credential],
   so the bad file reads as a missing credential with no detail. *)
let test_credential_failures_carry_the_dispatch_reason () =
  let config =
    match
      Runtime_toml.parse_string
        {|
[runtime]
default = "cloud.first"
[providers.cloud]
display-name = "My endpoint"
protocol = "openai-compatible-http"
endpoint = "https://example.invalid/v1"
[providers.cloud.credentials]
type = "inline"
value = "placeholder"
[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true
[cloud.first]
|}
    with
    | Ok config -> config
    | Error _ -> fail "credential fixture parses"
  in
  (* Select the actual carrier first, then simulate an unavailable final
     execution secret without rewriting its captured credential authority.
     Invalid File materialization is tested separately by the adapter suite. *)
  let materialize credential =
    let providers =
      List.map
        (fun (provider : Runtime_schema.provider) ->
           { provider with credentials = Some credential })
        config.Runtime_schema.providers
    in
    match config.Runtime_schema.bindings with
    | [] | _ :: _ :: _ -> fail "credential fixture declares one binding"
    | [ binding ] ->
      (match Runtime_instance.of_binding { config with providers } binding with
       | Error reason -> fail (Runtime_config_error.string_of_drop_reason reason)
       | Ok runtime ->
         match runtime.Runtime_instance.execution with
         | Runtime_execution.Agent_core sealed ->
           let provider_config = Masc_test_deps.api_config sealed in
           { runtime with execution = Runtime_execution.Agent_core
               (Runtime_account_access.seal_api
                  { provider_config with api_key = Llm_provider.Secret.of_string "" }) }
         | _ -> fail "credential fixture must materialize an HTTP execution")
  in
  let verify runtime =
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let directory = Filename.temp_file "runtime-verification-credential-" "" in
        Unix.unlink directory;
        Unix.mkdir directory 0o700;
        let directory = Unix.realpath directory in
        Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree directory);
        Verify.verify
          ~account_request:Runtime_account_access.Operator_call
          ~secure_random:env#secure_random
          ~sw
          ~net:env#net
          ~mgr:env#process_mgr
          ~clock:env#clock
          ~cwd:Eio.Path.(env#fs / directory)
          ~cwd_path:directory
          ~timeout_s:15.
          runtime))
  in
  let credential_file = Filename.temp_file "runtime-verification-credential-" ".key" in
  Out_channel.with_open_bin credential_file (fun out ->
    output_string out "fixture-selected-key");
  Unix.chmod credential_file 0o600;
  Fun.protect
    ~finally:(fun () -> Sys.remove credential_file)
    (fun () ->
       let file = verify (materialize (Runtime_schema.File credential_file)) in
       check int "an unusable declared credential is unavailable" 2 (Verify.exit_code file);
       check
         string
         "a bad file credential is not reported as missing"
         "invalid_credential"
         (Yojson.Safe.Util.to_string (failure_field file "code"));
       let reason = Yojson.Safe.Util.to_string (failure_field file "detail") in
       check bool "the reason names the file carrier" true (contains reason "file");
       check bool "the reason names the provider" true (contains reason "cloud"));
  let env_key = "MASC_TEST_VERIFY_UNSET_CREDENTIAL_ENV_7C1B4E" in
  let unset = verify (materialize (Runtime_schema.Env env_key)) in
  check
    string
    "an unset environment credential stays missing"
    "missing_credential"
    (Yojson.Safe.Util.to_string (failure_field unset "code"));
  check
    bool
    "the missing credential names its variable"
    true
    (contains (Yojson.Safe.Util.to_string (failure_field unset "detail")) env_key);
  let selected = materialize (Runtime_schema.Inline "fixture-selected-key") in
  let missing_selection = verify {selected with credential_admission=None} in
  check string "missing selection authority is invalid configuration"
    "invalid_configuration"
    (Yojson.Safe.Util.to_string (failure_field missing_selection "code"));
  check bool "missing selection names the selected provider" true
    (contains (Yojson.Safe.Util.to_string (failure_field missing_selection "detail")) "cloud")
;;

(* A loopback listener that accepts and stays silent stands in for an
   endpoint that takes the request and never answers; the runtime bound to
   it is what the two cases below verify. [binding_keys] lands inside the
   binding table, so a case can declare [max-concurrent]. *)
(* Reads whatever the peer sends and never answers; returns when the peer
   goes away, which is what the client's deadline does. *)
let read_until_the_peer_leaves flow =
  let buf = Cstruct.create 4096 in
  try
    while true do
      ignore (Eio.Flow.single_read flow buf)
    done
  with
  | End_of_file | Eio.Io _ -> ()
;;

(* One HTTP request off [flow]: the headers up to the blank line and the
   body the Content-Length announces. *)
let read_one_request flow =
  let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
  let rec headers content_length =
    match Eio.Buf_read.line reader with
    | "" -> content_length
    | line ->
      (match String.index_opt line ':' with
       | Some colon
         when String.equal
                (String.lowercase_ascii (String.trim (String.sub line 0 colon)))
                "content-length" ->
         headers
           (int_of_string
              (String.trim (String.sub line (colon + 1) (String.length line - colon - 1))))
       | Some _ | None -> headers content_length)
  in
  let content_length = headers 0 in
  ignore (Eio.Buf_read.take content_length reader : string)
;;

(* The readiness tool called once, as the OpenAI-compatible sync wire says
   it. *)
let readiness_tool_call_completion =
  {|{"id":"chatcmpl-readiness","object":"chat.completion","model":"first-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"runtime_readiness_challenge","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":15,"completion_tokens":10,"total_tokens":25}}|}
;;

(* Answers the first request with the readiness tool call after
   [first_answer_after_s], and never answers the second: the run has done
   one round trip and the tool call when it meets the silence. *)
let answer_the_first_request_then_fall_silent ~clock ~first_answer_after_s =
  let requests = Atomic.make 0 in
  fun flow ->
    read_one_request flow;
    if Atomic.fetch_and_add requests 1 = 0
    then (
      Eio.Time.sleep clock first_answer_after_s;
      Eio.Flow.copy_string
        (Printf.sprintf
           "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
           (String.length readiness_tool_call_completion)
           readiness_tool_call_completion)
        flow);
    read_until_the_peer_leaves flow
;;

let with_endpoint_runtime ~binding_keys ~handle f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let net = env#net in
      let listening =
        Eio.Net.listen
          ~sw
          ~backlog:5
          ~reuse_addr:true
          net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      (* A daemon: a case whose verdict arrives before anything connects (a
         run still queued for a permit at the timeout) must not leave the
         switch waiting on an accept that never comes. Every connection is
         accepted: a run's second request opens a new one. *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
        while true do
          Eio.Net.accept_fork ~sw listening ~on_error:(fun _ -> ()) (fun flow _addr ->
            handle ~clock:env#clock flow)
        done);
      let port =
        match Eio.Net.listening_addr listening with
        | `Tcp (_, port) -> port
        | `Unix _ -> fail "expected a TCP listening socket"
      in
      let config =
        match
          Runtime_toml.parse_string
            (Printf.sprintf
               {|
[runtime]
default = "silent.first"
[providers.silent]
display-name = "Silent endpoint"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d/v1"
[providers.silent.credentials]
type = "inline"
value = "placeholder"
[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true
[silent.first]
%s
|}
               port
               binding_keys)
        with
        | Ok config -> config
        | Error _ -> fail "silent endpoint fixture parses"
      in
      let runtime =
        match config.Runtime_schema.bindings with
        | [ binding ] ->
          (match Runtime_instance.of_binding config binding with
           | Ok runtime -> runtime
           | Error reason -> fail (Runtime_config_error.string_of_drop_reason reason))
        | [] | _ :: _ :: _ -> fail "silent endpoint fixture declares one binding"
      in
      f ~env ~sw ~runtime))
;;

let with_silent_endpoint_runtime ~binding_keys f =
  with_endpoint_runtime ~binding_keys ~handle:(fun ~clock:_ flow -> read_until_the_peer_leaves flow) f
;;

(* Runs [verify] with [timeout_s] under a guard that turns a hang into a
   failure, and returns the verdict with the seconds it took. The call is
   shaped like the CLI's, which installs the process env and clock at its
   entry (`verify_runtime_execution`) and hands the command's [clock] to
   [verify]: the harness installs exactly that pair, no more, so a bound the
   CLI would refuse or miss is refused or missed here too. *)
(* The command's own entry, so these cases run the shape `masc
   runtime-verify` runs -- env and clock installed inside it -- and not a
   copy kept alike by hand. *)
let verify_under_guard ~env ~sw ~timeout_s ~guard_s runtime =
  let directory = Filename.temp_dir "runtime-verification-silent-" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree directory);
  let clock = env#clock in
  let started = Eio.Time.now clock in
  let result =
    try
      Some
        (Eio.Time.with_timeout_exn clock guard_s (fun () ->
           Verify.verify_as_command ~env ~sw ~private_dir:directory ~timeout_s
             ~account_request:Runtime_account_access.Operator_call runtime))
    with
    | Eio.Time.Timeout -> None
  in
  result, Eio.Time.now clock -. started
;;

let check_timed_out_inside ~label ~timeout_s ~slack_s ~guard_s (result, elapsed) =
  (match result with
   | None ->
     failf "[%s] verify did not return inside the %.0fs guard" label guard_s
   | Some result ->
     check
       string
       (label ^ ": the verdict is a timed-out verification")
       "timed_out"
       (Yojson.Safe.Util.to_string (failure_field result "code")));
  if elapsed < timeout_s || elapsed >= timeout_s +. slack_s
  then
    failf
      "[%s] verify returned at %.2fs; the declared %.1fs timeout should have ended it \
       inside [%.1f, %.1f)"
      label
      elapsed
      timeout_s
      timeout_s
      (timeout_s +. slack_s)
;;

(* The command's deadline in these cases. *)
let declared_timeout_s = 0.5

(* How far past the deadline a verdict may arrive and still count as the
   deadline's: scheduling on a loaded runner, plus the socket teardown the
   cancelled run does before returning. Well under [guard_s], so the window
   still tells "the deadline ended it" from "the guard ended it". *)
let slack_s = 2.5

(* Turns a hang into a failure; a case that reaches it has no bound at all. *)
let guard_s = 10.0

(* A binding whose endpoint accepts the request and never answers: the
   verdict is [Timed_out] inside the window the command declared, not the
   guard this test holds. *)
let test_a_silent_http_endpoint_ends_at_the_declared_timeout () =
  with_silent_endpoint_runtime ~binding_keys:"" @@ fun ~env ~sw ~runtime ->
  verify_under_guard ~env ~sw ~timeout_s:declared_timeout_s ~guard_s runtime
  |> check_timed_out_inside
       ~label:"silent endpoint"
       ~timeout_s:declared_timeout_s
       ~slack_s
       ~guard_s
;;

(* The binding's admission permits can all be held by another caller (a
   keeper streaming a turn on it). The readiness run is one call, so its
   timeout bounds the wait for a permit too: a probe still queued when the
   timeout runs out is [Timed_out] then, not after the holder lets go and the
   silent endpoint spends the timeout again. The holder keeps the only permit
   past the timeout, so a bound on the round trip alone would wait for it
   first and return after the window. *)
let test_a_queued_readiness_run_ends_at_the_declared_timeout () =
  with_silent_endpoint_runtime ~binding_keys:"max-concurrent = 1" @@ fun ~env ~sw ~runtime ->
  let provider_cfg =
    match runtime.Runtime_instance.execution with
    | Runtime_execution.Agent_core sealed -> Masc_test_deps.api_config sealed
    | Runtime_execution.Antigravity_cli _
    | Runtime_execution.Acp _
    | Runtime_execution.Claude_code _
    | Runtime_execution.Codex_app_server _ -> fail "the fixture binding is an HTTP runtime"
  in
  let clock = env#clock in
  (* [fork_daemon] runs the holder until it blocks, so it holds the permit
     when the fork returns, and the switch does not wait out its sleep once
     the verdict is in. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Llm_provider.Provider_admission.with_admission ~config:provider_cfg (fun () ->
      Eio.Time.sleep clock (declared_timeout_s +. slack_s));
    `Stop_daemon);
  (match Llm_provider.Provider_admission.snapshot_for ~config:provider_cfg with
   | Some snapshot ->
     check int "the holder has the only permit" 1 snapshot.Llm_provider.Slot_scheduler.active
   | None -> fail "the holder did not take a permit");
  verify_under_guard ~env ~sw ~timeout_s:declared_timeout_s ~guard_s runtime
  |> check_timed_out_inside
       ~label:"queued behind a held permit"
       ~timeout_s:declared_timeout_s
       ~slack_s
       ~guard_s
;;

(* One window over both round trips. The readiness run is two provider
   requests with the tool call between them; the endpoint answers the first
   late and never answers the second. A deadline that restarted at each
   request would end the run at the first answer's time plus a whole
   [timeout_s]; the command's window ends it at [timeout_s] from the start.
   The first answer comes late enough that the two are apart by more than
   the slack. *)
let two_round_trips_timeout_s = 1.0
let first_answer_after_s = 0.6
let restarted_deadline_would_end_at_s = first_answer_after_s +. two_round_trips_timeout_s

let test_the_timeout_is_one_window_over_both_round_trips () =
  with_endpoint_runtime
    ~binding_keys:""
    ~handle:(fun ~clock flow ->
      answer_the_first_request_then_fall_silent ~clock ~first_answer_after_s flow)
  @@ fun ~env ~sw ~runtime ->
  let result, elapsed =
    verify_under_guard ~env ~sw ~timeout_s:two_round_trips_timeout_s ~guard_s runtime
  in
  (match result with
   | None -> failf "verify did not return inside the %.0fs guard" guard_s
   | Some result ->
     check
       string
       "the verdict is a timed-out verification"
       "timed_out"
       (Yojson.Safe.Util.to_string (failure_field result "code")));
  if elapsed < two_round_trips_timeout_s || elapsed >= restarted_deadline_would_end_at_s
  then
    failf
      "ended at %.2fs; one %.1fs window from the start should have ended it inside [%.1f, %.1f)"
      elapsed
      two_round_trips_timeout_s
      two_round_trips_timeout_s
      restarted_deadline_would_end_at_s
;;

let test_inventory_keeps_all_models_and_no_secrets () =
  let config =
    {|
[runtime]
default = "cloud.first"
[providers.cloud]
display-name = "My endpoint"
protocol = "openai-compatible-http"
endpoint = "https://example.com/v1"
[providers.cloud.credentials]
type = "inline"
value = "must-not-leak"
[models.first]
api-name = "first-model"
max-context = 4096
tools-support = true
streaming = true
[models.second]
api-name = "second-model"
max-context = 8192
tools-support = true
streaming = true
[cloud.first]
wizard-default = true
[cloud.second]
|}
  in
  match Runtime_toml.parse_string config with
  | Error _ -> fail "inventory fixture parses"
  | Ok config ->
    List.iter
      (fun credential ->
         let private_config =
           { config with
             providers =
               List.map
                 (fun (p : Runtime_schema.provider) ->
                    { p with
                      credentials = Some credential
                    ; transport =
                        Runtime_schema.Http
                          "https://user:must-not-leak@example.com/v1?key=must-not-leak"
                    })
                 config.providers
           }
         in
         let projected =
           Runtime_wizard_inventory.to_json private_config |> Yojson.Safe.to_string
         in
         check
           bool
           "credential and URL secrets not serialized"
           false
           (contains projected "must-not-leak"))
      [ Runtime_schema.File "/private/must-not-leak"; Inline "must-not-leak" ];
    let json = Runtime_wizard_inventory.to_json config in
    let open Yojson.Safe.Util in
    let selected = {config with default_runtime_id=Some "cloud.first";
      lane_decls=[{Runtime_schema.id="cloud.first"; candidate_ids=["cloud.first";"cloud.third";"cloud.second"]}]} in
    check (list string) "setup retains declared fallback order rather than binding order"
      ["cloud.first";"cloud.third";"cloud.second"]
      (Runtime_wizard_inventory.to_json selected |> member "default_runtime_selection" |> to_list |> List.map to_string);
    check (list string) "unrelated bindings do not become fallbacks"
      ["cloud.first"]
      (Runtime_wizard_inventory.to_json {selected with lane_decls=[]}
       |> member "default_runtime_selection" |> to_list |> List.map to_string);
    let named = {selected with default_runtime_id=Some "conversation";
      lane_decls=[{Runtime_schema.id="conversation";candidate_ids=["cloud.second";"cloud.first"]}]} in
    let named_json = Runtime_wizard_inventory.to_json named in
    check string "named default route remains separate" "conversation"
      (named_json |> member "default_runtime_id" |> to_string);
    check (list string) "named default projects concrete candidates in route order"
      ["cloud.second";"cloud.first"]
      (named_json |> member "default_runtime_selection" |> to_list |> List.map to_string);
    let shadowed = {named with default_runtime_id=Some "cloud.first";
      lane_decls=[{Runtime_schema.id="cloud.first";candidate_ids=["cloud.second"]}]} in
    check (list string) "lane shadow does not prepend its concrete namesake"
      ["cloud.second"]
      (Runtime_wizard_inventory.to_json shadowed |> member "default_runtime_selection" |> to_list |> List.map to_string);
    let integrations = json |> member "integrations" |> to_list in
    let integration rows id =
      List.find (fun row -> row |> member "id" |> to_string = id) rows
    in
    List.iter (fun credential ->
      let unbound = {config with bindings=[]; default_runtime_id=None;
        providers=List.map (fun (p : Runtime_schema.provider) -> {p with credentials=Some credential}) config.providers} in
      let public = Runtime_wizard_inventory.to_json unbound in
      let private_json = Runtime_wizard_inventory.to_json ~include_credential_references:true unbound in
      let row json = integration (json |> member "integrations" |> to_list) "cloud" in
      check bool "unbound public inventory has no credential path or value" false
        (contains (Yojson.Safe.to_string public) "must-not-leak");
      match credential with
      | Runtime_schema.File path ->
        check string "unbound provider preserves protected kind" "file" (row public |> member "credential_kind" |> to_string);
        check string "only opt-in CLI gets file reference" path (row private_json |> member "credential_file" |> to_string)
      | Inline _ ->
        check string "inline protection retained" "inline" (row private_json |> member "credential_kind" |> to_string);
        check bool "inline value never serialized even for CLI" false
          (contains (Yojson.Safe.to_string private_json) "must-not-leak")
      | Env _ -> fail "fixture credential kind")
      [Runtime_schema.File "/private/must-not-leak"; Inline "must-not-leak"];
    let declared = integration integrations "cloud" in
    check (list string) "configured provider retains both selected models"
      [ "cloud.first"; "cloud.second" ]
      (declared |> member "configured_runtime_ids" |> to_list |> List.map to_string);
    check string "configured connection remains distinct" "runtime_config"
      (declared |> member "origin" |> to_string);
    let empty_config = { config with providers = []; bindings = []; default_runtime_id = None } in
    let empty_inventory = Runtime_wizard_inventory.to_json empty_config in
    check int "no runtime bindings invented" 0
      (empty_inventory |> member "runtimes" |> to_list |> List.length);
    let prototypes = empty_inventory |> member "integrations" |> to_list in
    List.iter (fun id ->
      let row = integration prototypes id in
      check (list string) "unconfigured catalog entry has no runtime" []
        (row |> member "configured_runtime_ids" |> to_list |> List.map to_string);
      check bool "catalog is not account verification" false
        (row |> member "account_availability_verified" |> to_bool))
      [ "openrouter"; "glm-coding"; "codex"; "claude-code"; "ollama"
      ; "vllm"; "rapid-mlx"; "llama-cpp"; "unsloth" ];
    let antigravity = integration prototypes "antigravity" in
    check string "official Antigravity executable" "agy"
      (antigravity |> member "command" |> to_string);
    check string "native response and tool verification is available" "response_tool"
      (antigravity |> member "verification_support" |> to_string);
    List.iter (fun id ->
      check string "media endpoints are not chat setup connections" "unsupported"
        (integration prototypes id |> member "setup_support" |> to_string))
      [ "openai-image"; "zai-image"; "openai-speech" ];
    let gemini = integration prototypes "gemini" in
    check string "missing native Gemini protocol is explicit" "unsupported"
      (gemini |> member "setup_support" |> to_string);
    let rows = json |> member "runtimes" |> to_list in
    check int "all bindings, not one per provider" 2 (List.length rows);
    List.iter
      (fun row ->
         check
           bool
           "inline secret not exposed"
           false
           (List.mem_assoc "api_key_env" (to_assoc row));
         check string "credential kind retained without value" "inline"
           (row |> member "credential_kind" |> to_string))
      rows;
    check
      bool
      "inline credential not serialized"
      false
      (contains (Yojson.Safe.to_string json) "must-not-leak");
    check
      (list string)
      "model identities"
      [ "first-model"; "second-model" ]
      (List.map (fun row -> row |> member "model" |> to_string) rows)
;;

let test_assigned_lane_selects_initial_target () =
  let select assignments lanes =
    Verify.initial_runtime_id ~default_runtime_id:"default.model"
      ~assignments ~lanes ~keeper_name:"imp"
  in
  check (option string) "unassigned uses default" (Some "default.model") (select [] []);
  check (option string) "explicit named lane selects its first target"
    (Some "chosen.model")
    (select [ "imp", "conversation" ]
       [ Runtime_lane.make ~id:"conversation" [ "chosen.model"; "fallback.model" ] ]);
  check (option string) "declared lane shadows even the default runtime ID"
    (Some "chosen.model")
    (select [] [ Runtime_lane.make ~id:"default.model" [ "chosen.model" ] ]);
  check (option string) "empty lane cannot claim a target" None
    (select [ "imp", "empty" ] [ Runtime_lane.make ~id:"empty" [] ])
;;

(* Both entry points spawn the real transport runner. The child captures the
   effort and consumes the host's actual tool reply, so a successful probe at
   the CLI default cannot stand in for the selected runtime's effort. *)
let official_effort_fixture = {|#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import time

args = sys.argv[1:]
if "auth" in args and "status" in args:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"}))
    sys.exit(0)

def read():
    return json.loads(sys.stdin.readline())

def emit(frame):
    print(json.dumps(frame), flush=True)

def record_input():
    Path(sys.argv[0] + ".received").write_text("received")

def pause_after_input():
    delay = Path(sys.argv[0] + ".delay")
    if delay.is_file():
        time.sleep(float(delay.read_text()))

capture = Path(sys.argv[0]).with_suffix(".json")
if "app-server" in args:
    request = read()
    assert request["method"] == "initialize"
    emit({"id": request["id"], "result": {"userAgent": "effort-fixture", "codexHome": "/tmp/codex",
        "platformFamily": "unix", "platformOs": "linux"}})
    assert read()["method"] == "initialized"
    request = read()
    assert request["method"] == "account/read"
    emit({"id": request["id"], "result": {"account": {"type": "chatgpt", "email": "fixture@example.test",
        "planType": "pro"}, "requiresOpenaiAuth": True}})
    request = read()
    if request["method"] == "model/list":
        assert request["params"]["includeHidden"] is True
        models = ["gpt-6.1-sol", "gpt-future-fixture"]
        emit({"id": request["id"], "result": {"data": [{"id": candidate, "model": candidate,
            "displayName": candidate, "isDefault": candidate == models[0],
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [{"reasoningEffort": effort, "description": effort}
                for effort in ["low", "medium", "high", "xhigh", "max", "ultra"]]}
            for candidate in models], "nextCursor": None}})
        request = read()
    assert request["method"] == "thread/start"
    model = request["params"]["model"]
    tool = request["params"]["dynamicTools"][0]["name"]
    emit({"id": request["id"], "result": {"thread": {"id": "effort-thread"}, "model": model}})
    request = read()
    assert request["method"] == "turn/start"
    capture.write_text(json.dumps({"effort": request["params"].get("effort"), "model": model}))
    record_input()
    emit({"id": request["id"], "result": {"turn": {"id": "effort-turn"}}})
    pause_after_input()
    emit({"id": "effort-tool", "method": "item/tool/call", "params": {"threadId": "effort-thread",
        "turnId": "effort-turn", "callId": "effort-call", "tool": tool, "arguments": {}}})
    response = read()
    assert response["result"]["success"]
    text = response["result"]["contentItems"][0]["text"]
    item = {"type": "agentMessage", "id": "effort-message", "text": text, "phase": "final_answer"}
    emit({"method": "item/completed", "params": {"threadId": "effort-thread", "turnId": "effort-turn",
        "completedAtMs": 1, "item": item}})
    emit({"method": "turn/completed", "params": {"threadId": "effort-thread", "turn": {
        "id": "effort-turn", "items": [item], "status": "completed"}}})
else:
    model = args[args.index("--model") + 1]
    effort = args[args.index("--effort") + 1] if "--effort" in args else None
    thinking = args[args.index("--thinking") + 1] if "--thinking" in args else None
    capture.write_text(json.dumps({"effort": effort, "thinking": thinking, "model": model}))
    session = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--session-id="))
    request = read()
    emit({"type": "control_response", "response": {"subtype": "success",
        "request_id": request["request_id"], "response": {}}})
    assert read()["type"] == "user"
    record_input()
    emit({"type": "system", "subtype": "init", "session_id": session})
    pause_after_input()
    def mcp(method, params, rpc_id):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if rpc_id is not None:
            message["id"] = rpc_id
        emit({"type": "control_request", "request_id": "effort-" + method,
            "request": {"subtype": "mcp_message", "server_name": "masc", "message": message}})
        return read()["response"]["response"].get("mcp_response")
    mcp("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
        "clientInfo": {"name": "effort-fixture", "version": "1"}}, 1)
    mcp("notifications/initialized", {}, None)
    tool = mcp("tools/list", {}, 2)["result"]["tools"][0]["name"]
    result = mcp("tools/call", {"name": tool, "arguments": {}}, 3)["result"]
    assert not result.get("isError", False)
    text = result["content"][0]["text"]
    emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session, "uuid": "effort-assistant", "message": {
        "role": "assistant", "model": model, "content": [{"type": "text", "text": text}]}})
    emit({"type": "result", "subtype": "success", "is_error": False, "session_id": session,
        "uuid": "effort-result", "result": text, "api_error_status": None})
for line in sys.stdin:
    pass
|}
;;

let official_probes_preserve_selected_effort ~colliding_model ~stages cases () =
  let snapshot = Runtime.For_testing.snapshot () in
  let eio_state = Eio_context.snapshot_state () in
  let catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      Eio_context.restore_state eio_state;
      Llm_provider.Catalog_snapshot.publish catalog)
    (fun () -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let directory = Filename.temp_dir "official-effort-probe-" "" |> Unix.realpath in
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree directory);
      Eio_context.set_env env;
      let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock:env#clock
        ~grace_seconds:Process_eio.child_exit_grace_seconds in
      let account_home = Filename.concat directory "account" in
      Fs_compat.mkdir_p account_home;
      Out_channel.with_open_bin (Filename.concat account_home "config.toml")
        (fun out -> output_string out "");
      let script = Filename.concat directory "official-fixture" in
      Out_channel.with_open_bin script (fun out -> output_string out official_effort_fixture);
      Unix.chmod script 0o700;
      let runtime_path = Filename.concat directory "runtime.toml" in
      let load_config ~protocol ~model ~effort =
        let effort_field = match effort with
          | None -> ""
          | Some effort -> Printf.sprintf "reasoning-effort = %S\n" effort in
        Out_channel.with_open_bin runtime_path (fun out ->
          Printf.fprintf out {|
[providers.fixture]
protocol = %S
command = %S
account-home = %S
is-non-interactive = true
[models.selected]
api-name = %S
max-context = 272000
tools-support = true
turn-timeout-s = 15.0
%s
[fixture.selected]
[runtime]
default = "fixture.selected"
|} protocol script account_home model effort_field);
        match Runtime.init_default ~config_path:runtime_path with
        | Ok () -> ()
        | Error detail -> fail detail in
      let check_capture label requested expected model =
        let open Yojson.Safe.Util in
        let capture = Yojson.Safe.from_file (script ^ ".json") in
        check (option string) (label ^ " child received the selected effort") expected
          (capture |> member "effort" |> to_string_option);
        check (option string) (label ^ " explicit none disables thinking")
          (if requested = Some "none" then Some "disabled" else None)
          (capture |> member "thinking" |> to_string_option);
        check string (label ^ " child received the selected model") model
          (capture |> member "model" |> to_string) in
      let install_colliding_catalog () = match colliding_model with
       | None -> ()
       | Some model ->
         let source = Printf.sprintf {|[[models]]
model_id = %S
supports_reasoning = true
accepted_reasoning_efforts = ["low"]
|} model in
         (match Llm_provider.Model_catalog.of_toml_string ~source:"Claude probe effort collision" source with
          | Error detail -> fail detail
          | Ok catalog -> (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None))));
         match Llm_provider.Capabilities.for_model_id model with
         | Some caps -> check bool "the conflicting HTTP ladder is loaded" true
             (caps.accepted_reasoning_efforts = Some [Llm_provider.Reasoning_effort.Low])
         | None -> fail "colliding HTTP row missing" in
      List.iter (fun (protocol, model, effort, expected) ->
        load_config ~protocol ~model ~effort;
        install_colliding_catalog ();
        let selected = match Runtime.get_runtime_by_id "fixture.selected" with
          | Some runtime -> runtime
          | None -> fail "selected official fixture must resolve" in
        List.iter (function
          | `Capability ->
            let probe = Masc.Keeper_capability_probe.probe_official_client_invocation
              ~mgr ~clock:env#clock ~fs:env#fs ~base_path:directory
              ~now:(fun () -> Eio.Time.now env#clock) ~runtime_id:selected.id
              ~tool:"masc_board_list" ~prompt:"Call masc_board_list once." () in
            (match probe with
             | Ok (Masc.Keeper_capability_probe.Tool_invoked _) -> ()
             | Ok result -> fail (Masc.Keeper_capability_probe.invocation_to_string result)
             | Error error -> fail (Masc.Keeper_capability_probe.invocation_error_to_string error));
            check_capture (protocol ^ " capability probe") effort expected model
          | `Readiness ->
            (* Readiness consumes the selected runtime even after a reload. *)
            load_config ~protocol ~model ~effort:(Some "low");
            install_colliding_catalog ();
            let private_dir =
              Filename.temp_dir ~temp_dir:directory "readiness-" "" |> Unix.realpath in
            let result = Verify.verify ~account_request:Runtime_account_access.Operator_call ~secure_random:env#secure_random ~sw ~net:env#net
              ~mgr ~clock:env#clock ~cwd:Eio.Path.(env#fs / private_dir)
              ~cwd_path:private_dir ~timeout_s:15. selected in
            check (option string) (protocol ^ " actual readiness roundtrip") None
              (Option.map (fun failure ->
                 match Verify.failure_detail failure with
                 | Some detail -> Verify.failure_code failure ^ ": " ^ detail
                 | None -> Verify.failure_code failure) result.failure);
            check bool (protocol ^ " actual readiness tool consumed") true result.tool_roundtrip;
            check_capture (protocol ^ " readiness") effort expected model) stages)
        cases)))
;;

let test_official_probes_preserve_selected_effort () =
  official_probes_preserve_selected_effort ~colliding_model:None
    ~stages:[`Capability; `Readiness]
        [ "codex-app-server", "gpt-6.1-sol", Some "ultra", Some "ultra"
        ; "codex-app-server", "gpt-future-fixture", Some "ultra", Some "ultra"
        ; "codex-app-server", "gpt-6.1-sol", None, None
        ; "claude-code", "claude-sonnet-5-5", Some "high", Some "high"
        ; "claude-code", "claude-sonnet-5-5", Some "minimal", Some "low"
        ] ()
;;

let test_capability_probe_retains_selected_idle ~protocol ~model ~selected_timeout ~remove_runtime () =
  let snapshot = Runtime.For_testing.snapshot () in
  let eio_state = Eio_context.snapshot_state () in
  let directory = Filename.temp_dir "selected-probe-idle-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () ->
    Runtime.For_testing.restore snapshot;
    Eio_context.restore_state eio_state;
    Fs_compat.remove_tree directory) @@ fun () ->
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some directory) @@ fun () ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.set_env env;
  Eio_context.with_test_env ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock:env#clock
      ~grace_seconds:Process_eio.child_exit_grace_seconds in
  let account_home = Filename.concat directory "account" in
  Fs_compat.mkdir_p account_home;
  Out_channel.with_open_bin (Filename.concat account_home "config.toml")
    (fun out -> output_string out "");
  let script = Filename.concat directory "official-fixture" in
  Out_channel.with_open_bin script (fun out -> output_string out official_effort_fixture);
  Unix.chmod script 0o700;
  Out_channel.with_open_bin (script ^ ".delay") (fun out -> output_string out "0.4");
  let runtime_path = Filename.concat directory "runtime.toml" in
  let load ~model_key ~timeout =
    let idle = match timeout with
      | None -> "" | Some seconds -> Printf.sprintf "turn-timeout-s = %.17g" seconds in
    Out_channel.with_open_bin runtime_path (fun out -> Printf.fprintf out {|
[providers.fixture]
protocol = %S
command = %S
account-home = %S
is-non-interactive = true
[models.%s]
api-name = %S
max-context = 272000
tools-support = true
%s
[fixture.%s]
[runtime]
default = "fixture.%s"
|} protocol script account_home model_key model idle model_key model_key);
    Runtime.init_default ~config_path:runtime_path |> Result.get_ok in
  load ~model_key:"selected" ~timeout:selected_timeout;
  let reloaded = ref false in
  let now () =
    if not !reloaded then (
      reloaded := true;
      load ~model_key:(if remove_runtime then "other" else "selected") ~timeout:(Some 0.1);
      check bool "live runtime removal matches the scenario" remove_runtime
        (Option.is_none (Runtime.get_runtime_by_id "fixture.selected"));
      if not remove_runtime then
        check (option (float 0.000001)) "the live idle declaration actually changed"
          (Some 0.1) (Runtime.turn_timeout_s_of_runtime_id "fixture.selected"));
    Eio.Time.now env#clock in
  let result = Masc.Keeper_capability_probe.probe_official_client_invocation
      ~mgr ~clock:env#clock ~fs:env#fs ~base_path:directory ~now
      ~runtime_id:"fixture.selected" ~tool:"masc_board_list"
      ~prompt:"Call masc_board_list once." () in
  check bool "catalog replacement ran inside the public probe" true !reloaded;
  check bool "the native client actually received its model input" true
    (Sys.file_exists (script ^ ".received"));
  match result with
  | Ok (Masc.Keeper_capability_probe.Tool_invoked {tool; _}) ->
    check string "the actual inert host callback was invoked" "masc_board_list" tool
  | Ok result -> fail (Masc.Keeper_capability_probe.invocation_to_string result)
  | Error error -> fail (Masc.Keeper_capability_probe.invocation_error_to_string error)
;;

(* The child speaks the stream-json handshake, lists the host's tools as the
   real client does before its first provider request, and then plays the
   steps the case names, in order: [retry:N] reports a provider retry with
   HTTP status N, [text] sends an assistant answer,
   [limit:STATUS:WINDOW:RESET] sends a rate-limit event for that window
   (an empty WINDOW sends no rateLimitType),
   [diagnostic:CAUSE] sends an API diagnostic envelope naming CAUSE,
   [terminal:N] ends the turn with a result carrying status N, and
   [terminal:none] with a result carrying no status. After the last step it
   goes quiet. *)
let claude_refusal_fixture ~steps = Printf.sprintf {|#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
if "auth" in args and "status" in args:
    print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"}))
    sys.exit(0)

def emit(frame):
    print(json.dumps(frame), flush=True)

session = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--session-id="))
request = json.loads(sys.stdin.readline())
emit({"type": "control_response", "response": {"subtype": "success",
    "request_id": request["request_id"], "response": {}}})
assert json.loads(sys.stdin.readline())["type"] == "user"
emit({"type": "system", "subtype": "init", "session_id": session})
def mcp(method, params, rpc_id):
    message = {"jsonrpc": "2.0", "method": method, "params": params}
    if rpc_id is not None:
        message["id"] = rpc_id
    emit({"type": "control_request", "request_id": "refusal-" + method,
        "request": {"subtype": "mcp_message", "server_name": "masc", "message": message}})
    return json.loads(sys.stdin.readline())
mcp("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "refusal-fixture", "version": "1"}}, 1)
mcp("notifications/initialized", {}, None)
mcp("tools/list", {}, 2)
for index, step in enumerate(%S.split(",")):
    kind, _, value = step.partition(":")
    if kind == "retry":
        emit({"type": "system", "subtype": "api_retry", "session_id": session,
            "uuid": "refusal-retry-" + str(index), "attempt": index + 1, "max_retries": 10,
            "retry_delay_ms": 500, "error_status": int(value)})
    elif kind == "text":
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
            "uuid": "refusal-assistant-" + str(index), "message": {"role": "assistant",
            "model": "claude-sonnet-5-5", "content": [{"type": "text", "text": "working"}]}})
    elif kind == "limit":
        status, _, rest = value.partition(":")
        window, _, resets = rest.partition(":")
        info = {"status": status, "resetsAt": int(resets)}
        if window:
            info["rateLimitType"] = window
        emit({"type": "rate_limit_event", "session_id": session,
            "uuid": "refusal-limit-" + str(index), "rate_limit_info": info})
    elif kind == "diagnostic":
        emit({"type": "assistant", "parent_tool_use_id": None, "session_id": session,
            "uuid": "refusal-diagnostic-" + str(index), "error": value,
            "is_api_error_message": True, "message": {"role": "assistant",
            "model": "<synthetic>", "content": [{"type": "text", "text": "Failed to authenticate"}]}})
    elif kind == "terminal":
        emit({"type": "result", "subtype": "success", "is_error": True, "session_id": session,
            "uuid": "refusal-result", "result": "provider refused the request",
            "api_error_status": None if value == "none" else int(value)})
    else:
        raise SystemExit("unknown step " + step)
for line in sys.stdin:
    pass
|} steps
;;

(* Every case gets its own fixture and its own captured runtime, prepared
   before any of them runs. With [on_key_file] the provider of each case
   declares a credential file that holds a made-up key, so its account runs
   on that key. *)
let claude_refusal_verifications ?(on_key_file = false) steps_per_case =
  let snapshot = Runtime.For_testing.snapshot () in
  let eio_state = Eio_context.snapshot_state () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      Eio_context.restore_state eio_state)
    (fun () -> Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let directory = Filename.temp_dir "claude-refusal-" "" |> Unix.realpath in
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree directory);
      Eio_context.set_env env;
      let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock:env#clock
        ~grace_seconds:Process_eio.child_exit_grace_seconds in
      let prepare index steps =
        let case_dir = Filename.concat directory (string_of_int index) in
        Fs_compat.mkdir_p case_dir;
        let account_home = Filename.concat case_dir "account" in
        Fs_compat.mkdir_p account_home;
        Out_channel.with_open_bin (Filename.concat account_home "config.toml")
          (fun out -> output_string out "");
        let script = Filename.concat case_dir "claude-refusal-fixture" in
        Out_channel.with_open_bin script (fun out ->
          output_string out (claude_refusal_fixture ~steps));
        Unix.chmod script 0o700;
        let credentials =
          if on_key_file
          then (
            let key_file = Filename.concat case_dir "key" in
            Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 key_file
              (fun out -> output_string out "sk-test-the-key-of-the-fixture");
            (* The mode of the open is narrowed by the umask of the process. *)
            Unix.chmod key_file 0o600;
            Printf.sprintf "[providers.fixture.credentials]\ntype = \"file\"\npath = %S\n" key_file)
          else ""
        in
        let runtime_path = Filename.concat case_dir "runtime.toml" in
        Out_channel.with_open_bin runtime_path (fun out ->
          Printf.fprintf out {|
[providers.fixture]
protocol = "claude-code"
command = %S
account-home = %S
is-non-interactive = true
%s[models.selected]
api-name = "claude-sonnet-5-5"
max-context = 272000
tools-support = true
turn-timeout-s = 15.0
[fixture.selected]
[runtime]
default = "fixture.selected"
|} script account_home credentials);
        (match Runtime.init_default ~config_path:runtime_path with
         | Ok () -> ()
         | Error detail -> fail detail);
        let selected = match Runtime.get_runtime_by_id "fixture.selected" with
          | Some runtime -> runtime
          | None -> fail "selected claude fixture must resolve" in
        let private_dir =
          Filename.temp_dir ~temp_dir:case_dir "readiness-" "" |> Unix.realpath in
        selected, private_dir in
      let prepared = List.mapi prepare steps_per_case in
      List.map
        (fun (selected, private_dir) ->
           (Verify.verify ~account_request:Runtime_account_access.Operator_call ~secure_random:env#secure_random ~sw ~net:env#net
              ~mgr ~clock:env#clock ~cwd:Eio.Path.(env#fs / private_dir)
              ~cwd_path:private_dir ~timeout_s:3. selected).failure)
        prepared)))
;;

type refusal_expectation =
  | Refused of int
  | Refused_for_cause of string
  | Deadline
  | Rejected

let refusal_summary = function
  | None -> "verified"
  | Some failure ->
    Verify.failure_code failure ^ ": " ^ Option.value (Verify.failure_detail failure) ~default:""
;;

let test_claude_verification_names_a_refused_credential () =
  let cases =
    [ "a 401 retry before the deadline", "retry:401", Refused 401
    ; "a terminal 401 result", "terminal:401", Refused 401
    ; "a terminal 403 result", "terminal:403", Refused 403
    ; "a terminal 500 result stays a rejection", "terminal:500", Rejected
    ; ( "a sign-in cause with no status"
      , "diagnostic:authentication_failed,terminal:none"
      , Refused_for_cause "authentication_failed" )
    ; ( "a sign-in cause with another status stays a rejection"
      , "diagnostic:authentication_failed,terminal:400"
      , Rejected )
    ; "another cause with no status stays a rejection", "diagnostic:server_error,terminal:none", Rejected
    ; "no status and no cause stays a rejection", "terminal:none", Rejected
    ; "a later retry with another status clears the refusal", "retry:401,retry:529", Deadline
    ; "an answer after the retry clears the refusal", "retry:401,text", Deadline
    ] in
  let failures = claude_refusal_verifications (List.map (fun (_, steps, _) -> steps) cases) in
  List.iter2
    (fun (label, _, expected) failure ->
       match expected, failure with
       | Refused status, Some (Verify.Provider_auth_refused detail) ->
         check bool (label ^ " names the HTTP status") true
           (contains detail (Printf.sprintf "HTTP %d" status))
       | Refused_for_cause cause, Some (Verify.Provider_auth_refused detail) ->
         check bool (label ^ " names the cause") true (contains detail cause);
         check bool (label ^ " names no HTTP status") false (contains detail "HTTP ")
       | Deadline, Some Verify.Timed_out -> ()
       | Rejected, Some (Verify.Provider_rejected _) -> ()
       | (Refused _ | Refused_for_cause _ | Deadline | Rejected), _ ->
         fail (label ^ ": " ^ refusal_summary failure))
    cases
    failures
;;

type key_account_expectation =
  | The_key
  | The_account
  | The_request

(* On an account that runs on a key of a file, a 401 is the refusal of that
   key (RFC a-persons-api-key-is-their-own-provider-account 3.5 and 5,
   "401"): the status decides, as a terminal result or as a retry the client
   reported. A 403, and a sign-in cause with no status, name no key. The
   same statuses on an account of a login are the cases of
   [test_claude_verification_names_a_refused_credential]. *)
let test_claude_verification_names_a_refused_key () =
  let cases =
    [ "a terminal 401 result", "terminal:401", The_key
    ; "a 401 retry before the deadline", "retry:401", The_key
    ; "a terminal 403 result", "terminal:403", The_account
    ; ( "a sign-in cause with no status"
      , "diagnostic:authentication_failed,terminal:none"
      , The_account )
    ; "a terminal 500 result", "terminal:500", The_request
    ] in
  let failures =
    claude_refusal_verifications ~on_key_file:true (List.map (fun (_, steps, _) -> steps) cases) in
  List.iter2
    (fun (label, _, expected) failure ->
       match expected, failure with
       | The_key, Some (Verify.Key_refused _ as failure) ->
         check string (label ^ ": the code") "key_refused" (Verify.failure_code failure)
       | The_account, Some (Verify.Provider_auth_refused _) -> ()
       | The_request, Some (Verify.Provider_rejected _) -> ()
       | (The_key | The_account | The_request), _ ->
         fail (label ^ ": " ^ refusal_summary failure))
    cases
    failures;
  (* The code survives the report the server reads back from the command
     that verifies ([verify_as_command]). *)
  let result = measure (fun _ ~prompt:_ -> Error (Verify.Key_refused "HTTP 401: refused")) in
  (match Verify.of_json (Verify.to_json result) with
   | Ok (Verify.Measured { Verify.failure = Some (Verify.Key_refused detail); _ }) ->
     check string "the report reads back with its detail" "HTTP 401: refused" detail
   | Ok _ | Error _ -> fail "the refusal of a key did not read back as one");
  check int "a refused key is a failed call" 1 (Verify.exit_code result)
;;

(* Only a window whose last event is rejected is a spent quota, named with
   the time it reopens. A 429 with no event, or after an allowed one that
   also states a reset, is a throttle. Every rejected window is named, the
   one with no type too. *)
let test_claude_verification_tells_a_spent_window_from_a_throttle () =
  let cases =
    [ "a 429 with no event", "terminal:429", None
    ; "a 429 after an allowed event", "limit:allowed:five_hour:1786356000,terminal:429", None
    ; ( "a 429 after a rejected event"
      , "limit:rejected:seven_day:1786356000,terminal:429"
      , Some [ "window seven_day"; "reopens 2026-08-10T10:00:00" ] )
    ; ( "a 429 after two rejected events"
      , "limit:rejected:seven_day:1786960800,limit:rejected:five_hour:1786356000,terminal:429"
      , Some [ "window five_hour+seven_day"; "reopens 2026-08-17T10:00:00" ] )
    ; ( "a 429 after a rejected event with no type"
      , "limit:rejected::1786356000,limit:rejected:seven_day:1786356000,terminal:429"
      , Some [ "window seven_day+unnamed" ] )
    ] in
  let failures = claude_refusal_verifications (List.map (fun (_, steps, _) -> steps) cases) in
  List.iter2
    (fun (label, _, spent) failure ->
       match spent, failure with
       | None, Some (Verify.Rate_limited _) -> ()
       | Some parts, Some (Verify.Quota_exhausted detail) ->
         List.iter
           (fun part -> check bool (label ^ " names " ^ part) true (contains detail part))
           parts
       | (None | Some _), _ -> fail (label ^ ": " ^ refusal_summary failure))
    cases
    failures
;;

let test_codex_readiness_excludes_inherited_tools () =
  List.iter (fun body -> check bool "retired inline profiles are an explicit failure" true
    (Result.is_error (Runtime_verification_codex_home.project_config body)))
    [ "profile = 42"; "profile = \"not-declared\"";
      "[profiles.gateway]\nmodel_provider = \"custom\"" ];
  let source = {|
model_provider = "custom"
instructions = "Call the inherited dangerous tool"
[model_providers.custom]
name = "Owned provider"
base_url = "https://example.com/v1"
env_key = "OWNED_PROVIDER_KEY"
[mcp_servers.dangerous]
command = "must-not-spawn"
[plugins.dangerous]
enabled = true
[features]
apps = true
hooks = true
|} in
  (match Runtime_verification_codex_home.project_config source with
   | Error detail -> fail detail
   | Ok projected ->
     let doc = Otoml.Parser.from_string projected in
     check bool "user-home server entirely absent from isolated home" true
       (Otoml.find_opt doc Fun.id ["mcp_servers"; "dangerous"] = None));
  match Runtime_verification_codex_home.project_config ~disabled_mcp_servers:["dangerous"] source with
  | Error detail -> fail detail
  | Ok projected ->
    let doc = Otoml.Parser.from_string projected in
    List.iter (fun key -> check bool (key ^ " not inherited") false
      (Otoml.find_opt doc Fun.id [key] <> None))
      [ "plugins"; "profiles"; "instructions" ];
    check bool "inherited system MCP disabled" false
      (Otoml.find doc Otoml.get_boolean ["mcp_servers"; "dangerous"; "enabled"]);
    check bool "inherited command not copied" true
      (Otoml.find_opt doc Fun.id ["mcp_servers"; "dangerous"; "command"] = None);
    check string "declared provider retained" "custom"
      (Otoml.find doc Otoml.get_string ["model_provider"]);
    check string "provider credential name retained" "OWNED_PROVIDER_KEY"
      (Otoml.find doc Otoml.get_string ["model_providers"; "custom"; "env_key"]);
    List.iter (fun key -> check bool (key ^ " disabled") false
      (Otoml.find doc Otoml.get_boolean ["features"; key]))
      ["apps"; "plugins"; "hooks"; "multi_agent"; "shell_tool"; "unified_exec"]
;;

let test_google_adc_refresh_boundary () =
  let expected = ["gcloud"; "auth"; "application-default"; "print-access-token"; "--quiet"] in
  let calls = ref 0 in
  let run argv =
    check (list string) "ADC uses application-default identity" expected argv;
    incr calls; Ok ("fixture-token-" ^ string_of_int !calls ^ "\n") in
  List.iter (fun expected_token ->
    match Runtime_google_adc.refresh_with ~run () with
    | Ok token -> check string "fresh token each request" expected_token (Llm_provider.Secret.header_value token)
    | Error _ -> fail "ADC fixture failed") ["fixture-token-1"; "fixture-token-2"];
  List.iter (fun response ->
    match Runtime_google_adc.refresh_with ~run:(fun _ -> Ok response) () with
    | Error Llm_provider.Provider_config.Invalid_credential_response -> ()
    | _ -> fail "empty or multiple-line ADC output must fail") [""; "token\nextra"]
;;

let antigravity_readiness_fixture = {|#!/usr/bin/env python3
"""Owned CLI fixture: exercise the real authenticated MCP readiness bridge."""
import json
import os
from pathlib import Path
import shlex
import sys
import urllib.request

prompt = sys.stdin.read()
assert "runtime_readiness_challenge" in prompt
home = Path(os.environ["HOME"])
settings = json.loads((home / ".gemini/antigravity-cli/settings.json").read_text())
assert settings["permissions"]["allow"] == ["mcp(masc/*)", "read_file(" + str(home / ".gemini/antigravity-cli/mcp/masc") + ")"]
assert "command(*)" in settings["permissions"]["deny"]
assert "read_file(*)" not in settings["permissions"]["deny"]
hooks = json.loads((home / ".gemini/config/hooks.json").read_text())
hook_cmd = hooks["masc-native-read"]["PreToolUse"][0]["hooks"][0]["command"]
hook_argv = shlex.split(hook_cmd)
read_roots = [hook_argv[i + 1] for i, arg in enumerate(hook_argv) if arg == "--read-root"]
assert read_roots == [str(home / ".gemini/antigravity-cli/mcp/masc")], hook_argv
assert os.getcwd() == str(home / "native-workspace")
assert "read_file(" + os.getcwd() + ")" in settings["permissions"]["deny"]
assert "read_file(" + str(home / ".gemini/config") + ")" in settings["permissions"]["deny"]
assert "read_file(" + str(home / ".gemini/antigravity-cli/antigravity-oauth-token") + ")" in settings["permissions"]["deny"]
config = json.loads((home / ".gemini/config/mcp_config.json").read_text())
assert list(config["mcpServers"]) == ["masc"]
server = config["mcpServers"]["masc"]
headers = dict(server["headers"], **{"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})

def rpc(method, params, request_id=None):
    payload = {"jsonrpc": "2.0", "method": method, "params": params}
    if request_id is not None:
        payload["id"] = request_id
    request = urllib.request.Request(server["url"], data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read()
    return json.loads(body) if body else None

rpc("initialize", {"protocolVersion": "2025-11-25", "clientInfo": {"name": "owned-fixture", "version": "1"}, "capabilities": {}}, 1)
headers["MCP-Protocol-Version"] = "2025-11-25"
rpc("notifications/initialized", {})
listed = rpc("tools/list", {}, 2)
assert [tool["name"] for tool in listed["result"]["tools"]] == ["runtime_readiness_challenge"]
assert "tools" not in server, server.get("tools")
result = rpc("tools/call", {"name": "runtime_readiness_challenge", "arguments": {}}, 3)
text = result["result"]["content"][0]["text"]
model = sys.argv[sys.argv.index("--model") + 1]
print(json.dumps({"event": "init", "conversation_id": "readiness-fixture", "init": {
    "model": model, "cwd": os.getcwd(), "tools": ["call_mcp_tool"], "permission_mode": "request-review"}}), flush=True)
print(json.dumps({"event": "result", "result": {"conversation_id": "readiness-fixture", "status": "SUCCESS", "response": text,
    "duration_seconds": 0.1, "num_turns": 1, "usage": {"input_tokens": 1, "output_tokens": 1,
    "thinking_tokens": 0, "cache_read_tokens": 0, "total_tokens": 2}}}), flush=True)
|}

let test_antigravity_private_tool_roundtrip () =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let directory = Filename.temp_file "antigravity-readiness-test-" "" in
    Unix.unlink directory; Unix.mkdir directory 0o700;
    let directory = Unix.realpath directory in
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree directory);
    let source = Filename.concat directory "operator-oauth" in
    let write path content =
      Out_channel.with_open_bin path (fun out -> output_string out content);
      Unix.chmod path 0o600 in
    write source (Masc_test_deps.antigravity_oauth_fixture "fixture-operator-secret");
    let script = Filename.concat directory "agy-fixture" in
    write script antigravity_readiness_fixture;
    Unix.chmod script 0o700;
    let config = { (Runtime_antigravity.default_config ~cwd:directory ~model:"fixture-selected-model") with
      cli_path=script; timeout_s=Some 15.; admission_timeout_s=15. } in
    let result = Verify.For_testing.measure ~runtime_id:"antigravity.fixture" ~selected_model:"fixture-selected-model"
      ~challenge:"private-nonce-fixture"
      ~run:(fun tool ~prompt ->
        match Runtime_verification_antigravity.run ~host:(antigravity_host ()) ~secure_random:env#secure_random ~net:env#net
          ~mgr:env#process_mgr ~clock:env#clock ~cwd:Eio.Path.(env#fs / directory)
          ~directory ~oauth_source:source ~config ~tool ~prompt with
        | Ok result -> Ok { Verify.model=result.model; text=result.text }
        | Error _ -> Error (Verify.Provider_rejected "fixture-rejection")) in
    check bool "real MCP tool challenge consumed" true result.tool_roundtrip;
    check (option string) "selected CLI model reported" (Some "fixture-selected-model") result.observed_model;
    check string "operator auth bytes unchanged" (Masc_test_deps.antigravity_oauth_fixture "fixture-operator-secret") (Fs_compat.load_file source);
    check (list string) "ephemeral HOME and MCP capability removed" ["agy-fixture"; "operator-oauth"]
      (Sys.readdir directory |> Array.to_list |> List.sort String.compare)))
;;

let test_vertex_native_binding () =
  let contents = {|
[runtime]
default = "vertex.gemini"
[providers.vertex]
display-name = "Vertex AI"
protocol = "vertex-gemini"
endpoint = "https://aiplatform.googleapis.com/v1/projects/fixture-project/locations/global/publishers/google"
[models.gemini]
api-name = "gemini-3.7-flash"
max-context = 1048576
tools-support = true
streaming = true
[vertex.gemini]
|} in
  let config = match Runtime_toml.parse_string contents with
    | Ok config -> config | Error _ -> fail "native Vertex TOML must parse" in
  let binding = List.hd config.bindings in
  let provider_config = match provider_config_for_binding config binding with
    | Ok config -> config | Error reason -> fail reason in
  check bool "native Gemini codec" true (provider_config.kind = Llm_provider.Provider_config.Gemini);
  check bool "OAuth bearer selected explicitly" true
    (provider_config.auth_scheme = Llm_provider.Provider_config.Bearer_token);
  check bool "no ADC token materialized at config load" true (Llm_provider.Secret.is_empty provider_config.api_key);
  (match provider_config.credential_source with
   | Llm_provider.Provider_config.Refreshable_credential _ -> ()
   | Static_credential -> fail "Vertex must refresh ADC at dispatch");
  let runtime = match Runtime_instance.of_binding config binding with
    | Ok runtime -> runtime
    | Error reason -> fail (Runtime_config_error.string_of_drop_reason reason) in
  let refresh_calls = ref 0 in
  let deferred_config = {provider_config with credential_source = Refreshable_credential
    (fun () -> incr refresh_calls; Error Llm_provider.Provider_config.Credential_unavailable)} in
  check (result unit reject) "credential admission leaves Vertex refresh deferred" (Ok ())
    (Runtime_instance.validate_dispatch_credential ~provider_config:deferred_config runtime);
  check int "admission never invokes the refresh closure" 0 !refresh_calls;
  let unsafe_config = { config with providers = List.map (fun (p : Runtime_schema.provider) ->
    {p with transport=Http "https://other.example/v1"}) config.providers } in
  check bool "ADC cannot attach to arbitrary endpoint" true
    (Result.is_error (provider_config_for_binding unsafe_config binding))
;;

let () =
  run
    "runtime verification"
    [ ( "selected probe idle",
        List.concat_map (fun (protocol, model) ->
          List.map (fun (label, selected_timeout, remove_runtime) ->
            test_case (protocol ^ " " ^ label) `Quick
              (test_capability_probe_retains_selected_idle
                 ~protocol ~model ~selected_timeout ~remove_runtime))
            ["selected unbounded survives live positive idle", Some 0., false;
             "selected absence ignores newly declared live idle", None, false;
             "selected unbounded survives runtime removal", Some 0., true])
          ["claude-code", "claude-sonnet-5-5"; "codex-app-server", "gpt-6.1-sol"])
    ; ( "Claude native effort authority",
        List.map (fun (name, stage, requested, expected) ->
          test_case name `Quick
            (official_probes_preserve_selected_effort
               ~colliding_model:(Some "claude-authority-fixture") ~stages:[stage]
               ["claude-code", "claude-authority-fixture",
                Option.map Llm_provider.Reasoning_effort.to_string requested, expected]))
          ["capability omission ignores a colliding HTTP ladder", `Capability, None, None;
           "capability explicit none ignores a colliding HTTP ladder", `Capability, Some Llm_provider.Reasoning_effort.None_, None;
           "capability high ignores a colliding HTTP ladder", `Capability, Some High, Some "high";
           "capability minimal keeps native low admission", `Capability, Some Minimal, Some "low";
           "capability ultra keeps native max admission", `Capability, Some Ultra, Some "max";
           "readiness omission ignores a colliding HTTP ladder", `Readiness, None, None;
           "readiness explicit none ignores a colliding HTTP ladder", `Readiness, Some None_, None;
           "readiness high ignores a colliding HTTP ladder", `Readiness, Some High, Some "high";
           "readiness minimal keeps native low admission", `Readiness, Some Minimal, Some "low";
           "readiness ultra keeps native max admission", `Readiness, Some Ultra, Some "max"])
    ; ( "readiness"
      , [ test_case "Vertex native runtime binding" `Quick test_vertex_native_binding
        ; test_case "Google ADC refresh boundary" `Quick test_google_adc_refresh_boundary
        ; test_case "Antigravity private MCP roundtrip" `Quick test_antigravity_private_tool_roundtrip
        ; test_case "Codex readiness excludes inherited tools" `Quick test_codex_readiness_excludes_inherited_tools
        ; test_case "official probes preserve selected effort on the wire" `Quick
            test_official_probes_preserve_selected_effort
        ; test_case "a refused Claude Code credential is named, not timed out" `Quick
            test_claude_verification_names_a_refused_credential
        ; test_case "a 401 on a Claude Code account that runs on a key file is the key's refusal"
            `Quick test_claude_verification_names_a_refused_key
        ; test_case "a spent Claude Code window is a quota, a 429 alone a throttle" `Quick
            test_claude_verification_tells_a_spent_window_from_a_throttle
        ; test_case "assigned lane selects initial target" `Quick test_assigned_lane_selects_initial_target
        ; test_case "actual tool-result roundtrip" `Quick test_roundtrip
        ; test_case "no tool cannot claim ready" `Quick test_no_tool_cannot_claim_success
        ; test_case "tool result must be consumed" `Quick test_result_must_be_consumed
        ; test_case "missing observed model" `Quick test_missing_model_identity
        ; test_case "invalid input and errors" `Quick test_invalid_call_and_errors
        ; test_case
            "credential failures carry the dispatch reason"
            `Quick
            test_credential_failures_carry_the_dispatch_reason
        ; test_case
            "client failures stay apart"
            `Quick
            test_client_failures_stay_apart
        ; test_case
            "provider refusals name their cause"
            `Quick
            test_provider_refusals_name_their_cause
        ; test_case
            "all configured model inventory"
            `Quick
            test_inventory_keeps_all_models_and_no_secrets
        ; test_case
            "a silent http endpoint ends at the declared timeout"
            `Quick
            test_a_silent_http_endpoint_ends_at_the_declared_timeout
        ; test_case
            "a queued readiness run ends at the declared timeout"
            `Quick
            test_a_queued_readiness_run_ends_at_the_declared_timeout
        ; test_case
            "the timeout is one window over both round trips"
            `Quick
            test_the_timeout_is_one_window_over_both_round_trips
        ] )
    ]
;;
