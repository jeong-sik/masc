(** #27898: same wire/model text, different explicit provider authority. *)
open Llm_provider

let catalog_text_for_endpoint endpoint = Printf.sprintf {|
[[providers]]
id = "label-a"
kind = "openai_compat"
base_url = "https://a.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "openai_chat"
[[providers]]
id = "label-b"
aliases = ["label-b-alias"]
default_model = "overlap"
kind = "openai_compat"
base_url = "https://b.invalid"
request_path = "/v1/chat/completions"
auth = "none"
capabilities_base = "openai_chat"
[[providers]]
id = "ollama"
kind = "ollama"
base_url = "%s"
request_path = "/api/chat"
auth = "none"
discovery_timeout_s = 4.0
capabilities_base = "ollama"
[[providers]]
id = "ollama-keyed"
kind = "ollama"
base_url = "%s"
request_path = "/api/chat"
auth = "api-key"
discovery_timeout_s = 4.0
capabilities_base = "ollama"
[[models]]
model_id = "overlap"
base = "openai_chat"
max_context_tokens = 1000000
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
[[models]]
model_id = "overlap"
provider_name = "label-a"
base = "openai_chat"
max_context_tokens = 8192
supports_tools = true
supports_tool_choice = false
supports_required_tool_choice = false
supports_named_tool_choice = false
[[models]]
model_id = "overlap"
provider_name = "label-b"
base = "openai_chat"
max_context_tokens = 32768
supports_tools = true
supports_tool_choice = true
supports_required_tool_choice = true
|} endpoint endpoint

let catalog endpoint = match Model_catalog.of_toml_string ~source:"label binding fixture"
  (catalog_text_for_endpoint endpoint) with
  | Ok catalog -> catalog | Error detail -> Alcotest.fail detail
let with_catalog ?(endpoint="http://127.0.0.1:11434") f =
  let previous = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () -> Llm_provider.Catalog_snapshot.publish previous)
    (fun () -> (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some ((catalog endpoint))) ~providers:(None))); f ())

let resolve_binding ?model provider =
  match Agent_core.Provider_runtime_binding.find provider with
  | None -> Error `Unknown_provider
  | Some binding ->
    Agent_core.Provider_runtime_binding.to_provider_config ?model binding
    |> Result.map_error (fun _ -> `Missing_default)

let config provider = match resolve_binding ~model:"overlap" provider with
  | Ok config -> config
  | Error _ -> Alcotest.fail "registered model binding was refused"
let caps config = match Provider_config.capabilities_for_config_model config with
  | Some caps -> caps | None -> Alcotest.fail "provider model capabilities disappeared"

let identity () = with_catalog (fun () ->
  List.iter (fun provider ->
    let config = config provider in
    Alcotest.(check (option string)) "explicit provider survives label resolution" (Some provider)
      config.Provider_config.provider_id;
    Alcotest.(check string) "resolved endpoint remains owned by provider"
      (if provider="label-a" then "https://a.invalid" else "https://b.invalid") config.base_url)
    ["label-a";"label-b"])
let context () = with_catalog (fun () ->
  List.iter (fun (provider,expected) ->
    let config = config provider in
    Alcotest.(check (option int)) "context excludes unrelated bare model declaration" (Some expected)
      (Provider_config.context_window config);
    Alcotest.(check (option int)) "provider binding without max_context leaves override unset" None
      config.max_context) ["label-a",8192;"label-b",32768])
let policy () = with_catalog (fun () ->
  let first = config "label-a" and second = config "label-b" in
  Alcotest.(check bool) "A rejects forcing despite the bare row allowing it" false
    (caps first).supports_required_tool_choice;
  Alcotest.(check bool) "B retains its separate forcing declaration" true
    (caps second).supports_required_tool_choice;
  let rotated = {first with Provider_config.base_url=second.base_url} in
  Alcotest.(check (option string)) "endpoint override preserves selected provider"
    (Some "label-a") rotated.provider_id;
  Alcotest.(check bool) "endpoint override cannot borrow B's policy" false
    (caps rotated).supports_required_tool_choice;
  Alcotest.(check bool) "A rejects required choice before dispatch" true
    (Result.is_error (Complete_common.validate_all {first with tool_choice=Some Types.Any}));
  Alcotest.(check bool) "B admits required choice" true
    (Result.is_ok (Complete_common.validate_all {second with tool_choice=Some Types.Any}));
  let tools = [`Assoc ["name",`String "lookup";"description",`String "Lookup";
    "input_schema",`Assoc ["type",`String "object";"properties",`Assoc []]]] in
  match Complete_common.serialize_http_request ~stream:false
      ~config:{second with tool_choice=Some Types.Any}
      ~messages:[Types.make_message ~role:Types.User [Types.Text "Look up the receipt"]] ~tools with
  | Error _ -> Alcotest.fail "admitted provider B failed final serialization"
  | Ok request ->
    Alcotest.(check string) "B forcing reaches final Chat body" "required"
      Yojson.Safe.Util.(Yojson.Safe.from_string request.Complete_common.body |> member "tool_choice" |> to_string))

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect ~finally:(fun () -> match previous with
    | None -> Unix.unsetenv key | Some previous -> Unix.putenv key previous)
    (fun () ->
      (match value with None -> Unix.unsetenv key | Some value -> Unix.putenv key value);
      f ())

let with_mock_server_on ~sw ~net handler f =
  let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> Alcotest.fail "expected a TCP listener" in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () -> Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
  f ~endpoint

let with_mock_server handler f =
  Eio_main.run @@ fun env ->
  try
    Eio.Switch.run @@ fun sw ->
    with_mock_server_on ~sw ~net:env#net handler (fun ~endpoint ->
      f ~sw ~net:env#net ~clock:env#clock ~endpoint;
      Eio.Switch.fail sw Exit)
  with
  | Unix.Unix_error ((Unix.EPERM | Unix.EADDRINUSE), "bind", _) -> Alcotest.skip ()
  | Exit -> ()

let no_default () = with_catalog (fun () ->
  Alcotest.(check bool) "provider without catalog default cannot reach execution" true
    (Result.is_error (resolve_binding "label-a")))
let declared_default () = with_catalog (fun () ->
  with_env "LABEL_B_DEFAULT_MODEL" (Some "ambient-model") (fun () ->
    let config = match resolve_binding "label-b" with
      | Ok config -> config | Error _ -> Alcotest.fail "declared default was refused" in
    Alcotest.(check string) "catalog default wins independently of derived environment key" "overlap" config.model_id;
    Alcotest.(check (option string)) "auto retains canonical provider" (Some "label-b") config.provider_id;
    Alcotest.(check (option int)) "auto retains exact model context" (Some 32768)
      (Provider_config.context_window config)))
let alias_default () = with_catalog (fun () ->
  let config = match resolve_binding "label-b-alias" with
    | Ok config -> config | Error _ -> Alcotest.fail "alias default was refused" in
  Alcotest.(check string) "alias resolves declared default" "overlap" config.model_id;
  Alcotest.(check (option string)) "alias carries canonical binding identity" (Some "label-b") config.provider_id)
let supported_is_not_default () = with_catalog (fun () ->
  let previous = Llm_provider.Catalog_snapshot.current () in
  Fun.protect ~finally:(fun () -> Llm_provider.Catalog_snapshot.publish previous)
    (fun () ->
      let entry : Provider_catalog.entry =
        {id="label-a";aliases=[];kind=Provider_config.OpenAI_compat;
         base_url="https://a.invalid";request_path="/v1/chat/completions";
         auth=Provider_catalog.No_auth;default_model=None;discovery_timeout_s=None;max_context=None;
         capabilities=Some {Capabilities.default_capabilities with supported_models=Some ["supported-not-default"]};
         credential_scope=None} in
      let overlay = match Provider_catalog.of_entries [entry] with
        | Ok catalog -> catalog | Error detail -> Alcotest.fail detail in
      (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Llm_provider.Catalog_snapshot.models (Llm_provider.Catalog_snapshot.current ())) ~providers:(Some (overlay))));
      Alcotest.(check bool) "supported-model metadata cannot invent an execution default" true
        (Result.is_error (resolve_binding "label-a"))))

let expect_timeout clock request =
  match Eio.Time.with_timeout clock 5. (fun () -> Ok (request ())) with
  | Ok (Error (Http_client.TimeoutError _)) ->
    Alcotest.(check (float 0.001)) "timeout fires at the declared four seconds"
      1004.0 (Eio.Time.now clock)
  | Ok (Error _) -> Alcotest.fail "the request failed before its declared deadline"
  | Ok (Ok _) -> Alcotest.fail "the request succeeded without observing its deadline"
  | Error `Timeout -> Alcotest.fail "the request escaped its declared deadline"

let expect_stalled_dns_timeout clock request =
  Eio_main.run @@ fun _ ->
  Eio.Switch.run @@ fun sw ->
  let pending, _ = Eio.Promise.create () in
  let module Stalled_dns = struct
    type t = unit
    type tag = [`Generic | `Unix]
    let unsupported _ = invalid_arg "stalled DNS fixture supports only getaddrinfo"
    let listen = unsupported
    let connect = unsupported
    let datagram_socket = unsupported
    let getaddrinfo () ~service:_ _ =
      Eio_mock.Clock.advance clock;
      Eio.Promise.await pending
    let getnameinfo = unsupported
  end in
  let net : [`Generic | `Unix] Eio.Net.ty Eio.Resource.t =
    Eio.Resource.T ((), Eio.Resource.handler
      (Eio.Resource.bindings (Eio.Net.Pi.network (module Stalled_dns)))) in
  expect_timeout clock (fun () -> request ~sw ~net)

let get_sync_deadline_covers_dns_resolution () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  expect_stalled_dns_timeout clock (fun ~sw ~net ->
    Http_client.get_sync ~sw ~net ~clock ~timeout_s:4.0
      ~url:"http://stalled-dns.invalid/api/tags" ~headers:[] ())

let delete_sync_deadline_covers_dns_resolution () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  expect_stalled_dns_timeout clock (fun ~sw ~net ->
    Http_client.delete_sync ~sw ~net ~clock ~timeout_s:4.0
      ~url:"http://stalled-dns.invalid/api/tags" ~headers:[] ())

let post_sync_deadline_covers_dns_resolution () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  expect_stalled_dns_timeout clock (fun ~sw ~net ->
    Http_client.post_sync ~sw ~net ~clock ~timeout_s:4.0
      ~url:"http://stalled-dns.invalid/api/tags" ~headers:[] ~body:"{}" ())

let get_sync_deadline_covers_stalled_body () =
  Eio_main.run @@ fun env ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  try
    Eio.Switch.run @@ fun sw ->
    let socket = Eio.Net.listen env#net ~sw ~backlog:128 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "expected a TCP listener" in
    Eio.Fiber.fork ~sw (fun () ->
      let flow, _ = Eio.Net.accept ~sw socket in
      let reader = Eio.Buf_read.of_flow ~max_size:65536 flow in
      let rec drain_headers () =
        match Eio.Buf_read.line reader with
        | "" -> ()
        | _ -> drain_headers ()
      in
      drain_headers ();
      Eio.Flow.copy_string
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n" flow;
      Eio_mock.Clock.advance clock;
      let pending, _ = Eio.Promise.create () in
      Eio.Promise.await pending);
    let endpoint = Printf.sprintf "http://127.0.0.1:%d/api/tags" port in
    expect_timeout clock (fun () ->
      Http_client.get_sync ~sw ~net:env#net ~clock ~timeout_s:4.0
        ~url:endpoint ~headers:[] ());
    Eio.Switch.fail sw Exit
  with
  | Unix.Unix_error ((Unix.EPERM | Unix.EADDRINUSE), "bind", _) -> Alcotest.skip ()
  | Exit -> ()

let global_registry_probe_uses_declared_deadline () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      Eio_mock.Clock.advance clock;
      let pending, _ = Eio.Promise.create () in
      Eio.Promise.await pending
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock:_ ~endpoint ->
    let declared = Discovery.endpoint
      ~discovery_timeout_s:4.0
      ~protocol:Discovery.Ollama_native
      ~capabilities:Capabilities.ollama_capabilities endpoint in
    (match Eio.Time.with_timeout clock 5. (fun () ->
       Ok (Provider_registry.refresh_llama_endpoints
         ~sw ~net ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
         ~endpoints:[declared] ())) with
     | Ok (Error (Provider_registry.No_healthy_endpoints [ status ])) ->
       Alcotest.(check bool) "declared timeout produces an unhealthy endpoint"
         false status.healthy
     | Ok (Error Provider_registry.No_endpoints_declared) ->
       Alcotest.fail "the declared endpoint disappeared"
     | Ok (Error (Provider_registry.No_healthy_endpoints _)) ->
       Alcotest.fail "registry returned an unexpected endpoint count"
     | Ok (Ok _) -> Alcotest.fail "an unanswered registry probe became healthy"
     | Error `Timeout -> Alcotest.fail "the registry probe escaped its declared deadline");
    Alcotest.(check (float 0.001)) "registry probe expires at its declared four seconds"
      1004.0 (Eio.Time.now clock);
    Alcotest.(check int) "the bounded registry attempt reached the endpoint"
      1 !tag_requests)

let global_cache_probe_preserves_declared_deadline () =
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 1000.;
  let tag_requests = ref 0 in
  let handler _conn req body =
    ignore (Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) : string);
    match Uri.path (Cohttp.Request.uri req) with
    | "/api/tags" ->
      incr tag_requests;
      if !tag_requests = 1 then
        Cohttp_eio.Server.respond_string ~status:`OK
          ~body:{|{"models":[{"name":"global-model"}]}|} ()
      else
        (Eio_mock.Clock.advance clock;
         let pending, _ = Eio.Promise.create () in
         Eio.Promise.await pending)
    | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()
  in
  with_mock_server handler (fun ~sw ~net ~clock:_ ~endpoint ->
    Discovery_cache.set_env ~sw ~net
      ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t);
    let declared = Discovery.endpoint
      ~discovery_timeout_s:4.0
      ~protocol:Discovery.Ollama_native
      ~capabilities:Capabilities.ollama_capabilities endpoint in
    (match Provider_registry.refresh_llama_endpoints
       ~sw ~net ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
       ~endpoints:[declared] () with
     | Ok [ status ] ->
       Alcotest.(check bool) "initial registry activation succeeds" true status.healthy
     | Ok _ -> Alcotest.fail "registry returned an unexpected activation count"
     | Error Provider_registry.No_endpoints_declared ->
       Alcotest.fail "the declared endpoint disappeared"
     | Error (Provider_registry.No_healthy_endpoints _) ->
       Alcotest.fail "the immediate activation probe failed");
    (match Eio.Time.with_timeout clock 5. (fun () ->
       Ok (Discovery_cache.get_cached_or_refresh ())) with
     | Ok [ status ] ->
       Alcotest.(check bool) "global cache observes the declared timeout"
         false status.healthy
     | Ok _ -> Alcotest.fail "global cache returned an unexpected endpoint count"
     | Error `Timeout -> Alcotest.fail "the global cache escaped its declared deadline");
    Alcotest.(check (float 0.001)) "global cache expires at its declared four seconds"
      1004.0 (Eio.Time.now clock);
    Alcotest.(check int) "activation and bounded refresh both reached the endpoint"
      2 !tag_requests)

let () = Alcotest.run "runtime model label binding"
  ["provider authority",["identity",`Quick,identity;"context",`Quick,context;"policy and wire",`Quick,policy];
   "catalog defaults",["missing default",`Quick,no_default;"declared default",`Quick,declared_default;
     "canonical alias",`Quick,alias_default;"supported is not default",`Quick,supported_is_not_default];
   "http deadlines",["DNS deadline",`Quick,get_sync_deadline_covers_dns_resolution;
     "DELETE DNS deadline",`Quick,delete_sync_deadline_covers_dns_resolution;
     "POST DNS deadline",`Quick,post_sync_deadline_covers_dns_resolution;
     "stalled body deadline",`Quick,get_sync_deadline_covers_stalled_body];
   "discovery deadlines",["global registry declared deadline",`Quick,global_registry_probe_uses_declared_deadline;
     "global cache declared deadline",`Quick,global_cache_probe_preserves_declared_deadline]]
