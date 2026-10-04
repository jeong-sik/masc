open Alcotest
open Masc
module S = Mcp_protocol.Sampling
module Store = Lane_addon_store
let require = function Ok value -> value | Error detail -> fail detail
let member = Yojson.Safe.Util.member
let text key json = member key json |> Yojson.Safe.Util.to_string
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1sAAAAASUVORK5CYII="
let params : S.create_message_params = {
  messages=[{S.role=S.User;content=S.Text {type_="text";text="Compare this image"}};
    {S.role=S.User;content=S.Image {type_="image";data=image;mime_type="image/png"}}];
  model_preferences=Some {hints=Some [{name=Some "unconfigured-package-hint"}];
    cost_priority=None;speed_priority=None;intelligence_priority=None};
  system_prompt=Some "Return only the measured comparison";include_context=Some S.None_;
  temperature=Some 0.25;max_tokens=37;stop_sequences=None;metadata=None;
  tools=None;tool_choice=None;_meta=None}

let test_image_only_completion_is_sampling_content () =
  let module L = Llm_provider.Types in
  let response content : L.api_response =
    {id="image-response";model="image-model";stop_reason=L.EndTurn;
     content;usage=None;telemetry=None} in
  let block = L.Image {media_type="image/png";data=image;source_type=L.Base64} in
  let project = Server_lane_addon_sampling.For_testing.response_content in
  let actual = require (project (response [block])) in
  check bool "single image is preserved as MCP image content" true
    (match actual with S.Image value -> value.data = image && value.mime_type = "image/png"
     | S.Text _ -> false);
  check bool "projected image survives protocol encoding and decoding" true
    (S.sampling_content_of_yojson (S.sampling_content_to_yojson actual) = Ok actual);
  check bool "multiple image outputs are not silently reduced" true
    (Result.is_error (project (response [block;block])));
  let url_image = L.Image {media_type="image/png";data="https://example.invalid/image.png";
    source_type=L.Url} in
  check bool "mixed image sources are not silently reduced" true
    (Result.is_error (project (response [block;url_image])));
  check bool "URL-only image cannot become MCP base64 content" true
    (Result.is_error (project (response [url_image])));
  check bool "empty completion remains an error" true
    (Result.is_error (project (response [])))

let test_captured_binding_survives_same_id_reload () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock @@ fun () ->
  let root = Filename.temp_dir "sampling-snapshot-" "" in
  let original = Runtime.For_testing.snapshot () in
  Eio.Switch.on_release sw (fun () -> Runtime.For_testing.restore original; Fs_compat.remove_tree root);
  let requests = ref [] in
  let callback _connection request body =
    let json = Eio.Buf_read.(of_flow ~max_size:65536 body |> take_all) |> Yojson.Safe.from_string in
    requests := (Cohttp.Request.resource request, json) :: !requests;
    Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"id":"snapshot-response","model":"snapshot-model","choices":[{"index":0,"message":{"role":"assistant","content":"captured binding answer"},"finish_reason":"stop"}]}|} () in
  let socket = Eio.Net.listen env#net ~sw ~backlog:4 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
  let port = match Eio.Net.listening_addr socket with `Tcp (_,port) -> port | _ -> fail "TCP listener missing" in
  Eio.Fiber.fork_daemon ~sw (fun () -> Cohttp_eio.Server.run socket
    (Cohttp_eio.Server.make ~callback ()) ~on_error:raise);
  let path = Filename.concat root "runtime.toml" in
  let load endpoint temperature =
    write path (Printf.sprintf {|[providers.snapshot]
protocol="openai-compatible-http"
endpoint="http://127.0.0.1:%d/%s"
[models.sample]
api-name="snapshot-model"
max-context=4096
temperature=%g
[ snapshot.sample ]
[runtime]
default="snapshot.sample"
|} port endpoint temperature);
    require (Runtime.init_default ~config_path:path) in
  load "before" 0.25;
  let captured = match Runtime.get_runtime_by_id "snapshot.sample" with Some value -> value | None -> fail "runtime missing" in
  load "after" 0.75;
  let text_params = {params with messages=[{S.role=S.User;content=S.Text {type_="text";text="test snapshot"}}]} in
  ignore (require (Server_lane_addon_sampling.For_testing.attempt_captured ~sw ~net:env#net captured text_params));
  match !requests with
  | [path, body] ->
    check string "dispatch uses the captured endpoint" "/before/chat/completions" path;
    check (float 0.) "dispatch uses the captured fixed temperature" 0.25
      Yojson.Safe.Util.(body |> member "temperature" |> to_float)
  | _ -> fail "expected one captured binding request"

let test_actual_http_route_and_durable_sampling ?(primary_reply=`Bad_request) ?(primary_images=true) ?initial_pressure ?fixed_temperature ?turn_timeout_s ?(omit_temperature=false) () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock @@ fun () ->
  Time_compat.set_clock env#clock;
  let root = Filename.temp_dir "server-lane-sampling-" "" |> Unix.realpath in
  let old_runtime = Runtime.For_testing.snapshot () in
  let old_startup = Runtime_startup_state.get () in
  let old_catalog = Llm_provider.Model_catalog.global () in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore old_runtime;
    Runtime_startup_state.set old_startup;
    (match old_catalog with None -> Llm_provider.Model_catalog.clear_global ()
      | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree root);
  let config = Workspace.default_config root in
  let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let requests = ref [] and expected_retained_requests = ref 1 in
  Runtime_quota_window.reset_for_testing ();
  Eio.Switch.on_release sw Runtime_quota_window.reset_for_testing;
  let retained_requests () =
    let directory = Filename.concat (Store.root store) "evidence" in
    if not (Sys.file_exists directory) then [] else
      Sys.readdir directory |> Array.to_list |> List.filter_map (fun file ->
        let bytes = In_channel.with_open_bin (Filename.concat directory file) In_channel.input_all in
        let json = Yojson.Safe.from_string bytes in
        if member "kind" json=`String "model_request" then Some json else None) in
  let callback _connection request body =
    let body = Eio.Buf_read.(of_flow ~max_size:1048576 body |> take_all) |> Yojson.Safe.from_string in
    let captures = retained_requests () in
    check int "request is durable before the provider receives HTTP" !expected_retained_requests (List.length captures);
    check string "retained request belongs to the exact worker" "installed-analysis-worker"
      (text "instance_id" (List.hd captures));
    check string "retained request uses the operator binding route" "analysis"
      (text "route" (List.hd captures));
    requests := (Cohttp.Request.resource request,body) :: !requests;
    if String.starts_with ~prefix:"/primary/" (Cohttp.Request.resource request) then
      (match primary_reply with
      | `Thinking -> Cohttp_eio.Server.respond_string ~status:`OK
          ~body:{|{"id":"thinking-only","model":"actual-primary-model","choices":[{"index":0,"message":{"role":"assistant","content":"","reasoning_content":"Provider reasoning without an answer."},"finish_reason":"length"}],"usage":{"prompt_tokens":9,"completion_tokens":37,"total_tokens":46}}|} ()
      | `Missing_model | `Blank_model ->
          let model = match primary_reply with `Blank_model -> ["model",`String "  "] | _ -> [] in
          let body = `Assoc (model @ ["id",`String "identityless";"choices",`List [`Assoc [
            "index",`Int 0;"message",`Assoc ["role",`String "assistant";"content",`String "Unusable claimed answer"];
            "finish_reason",`String "stop"]]]) |> Yojson.Safe.to_string in
          Cohttp_eio.Server.respond_string ~status:`OK ~body ()
      | `Rate_limit -> Cohttp_eio.Server.respond_string ~status:(Cohttp.Code.status_of_code 429)
          ~headers:(Cohttp.Header.of_list ["retry-after","30"])
          ~body:{|{"error":{"message":"synthetic throttling"}}|} ()
      | `Quota -> Cohttp_eio.Server.respond_string ~status:(Cohttp.Code.status_of_code 402)
          ~body:{|{"error":{"message":"synthetic quota exhaustion"}}|} ()
      | `Bad_request -> Cohttp_eio.Server.respond_string ~status:`Bad_request
          ~body:{|{"error":{"message":"synthetic primary unavailable"}}|} ())
    else Cohttp_eio.Server.respond_string ~status:`OK
      ~body:{|{"id":"actual-response","model":"actual-secondary-model","choices":[{"index":0,"message":{"role":"assistant","content":"The image comparison is retained."},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":6,"total_tokens":15}}|} () in
  let socket = Eio.Net.listen env#net ~sw ~backlog:4 ~reuse_addr:true
    (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_,port) -> port | `Unix _ -> fail "expected loopback TCP listener" in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () -> Cohttp_eio.Server.run socket server ~on_error:raise);
  let catalog_path = Filename.concat root "models.toml" in
  write catalog_path (String.concat "\n" (List.map (fun provider -> Printf.sprintf
    "[[models]]\nid_prefix=\"sampling-fixture\"\nprovider_name=%S\nbase=\"openai_chat\"\nmax_context_tokens=200000\nmax_output_tokens=128\nchat_output_budget_field=\"max_tokens\"\nsupports_tools=false\nsupports_multimodal_inputs=true\nsupports_image_input=%b\nsupports_system_prompt=true\nsupports_reasoning=false\nsupports_native_streaming=false\nignored_sampling_parameters=[]\n" provider (primary_images || provider <> "primary"))
    ["primary";"secondary"]));
  let catalog = require (Llm_provider.Model_catalog.load_file catalog_path) in
  Llm_provider.Model_catalog.set_global catalog;
  let runtime_path = Filename.concat root "runtime.toml" in
  write runtime_path (Printf.sprintf {|[runtime]
default="primary.sample"
[runtime.lanes.analysis]
candidates=["primary.sample","secondary.sample"]
[providers.primary]
protocol="openai-compatible-http"
endpoint="http://127.0.0.1:%d/primary"
[providers.secondary]
protocol="openai-compatible-http"
endpoint="http://127.0.0.1:%d/secondary"
[models.sample]
api-name="sampling-fixture"
%s%smax-context=200000
tools-support=false
streaming=false
[primary.sample]
is-default=true
[secondary.sample]
|} port port (match fixed_temperature with
    | Some value -> Printf.sprintf "temperature=%g\n" value | None -> "")
    (match turn_timeout_s with
     | Some seconds -> Printf.sprintf "turn-timeout-s=%g\n" seconds | None -> ""));
  require (Runtime.init_default ~config_path:runtime_path);
  check (option (float 0.)) "declared liveness window is admitted unchanged" turn_timeout_s
    (Runtime_inference.resolve_turn_timeout_s ~runtime_id:"primary.sample");
  let runtime id = match Runtime.get_runtime_by_id id with Some value -> value | None -> fail "fixture runtime missing" in
  let primary = runtime "primary.sample" and secondary = runtime "secondary.sample" in
  (match initial_pressure with
   | None -> Runtime_candidate_backpressure.note_rate_limit ~candidate:secondary.candidate_backpressure ~retry_after:None
   | Some `Rate_limit -> Runtime_candidate_backpressure.note_rate_limit ~candidate:primary.candidate_backpressure ~retry_after:None
   | Some `Quota -> Runtime_quota_window.note_observed_exhausted ~scope:(Runtime_instance.quota_scope_of_runtime primary)
   | Some `Failed -> Runtime_candidate_backpressure.note_failed_attempt ~candidate:primary.candidate_backpressure
       ~failure:Server_error ~recorded_by:(Runtime_candidate_backpressure.keeper_recorder ~keeper_name:"other-keeper"));
  let manifest = Filename.concat root "lane.toml" in
  write manifest {|id="sampling-proof"
revision="1"
title="Installed analysis worker"
contributions=["derive"]
image="not-executed"
command=["not-executed"]
[interface]
model_access="host_sampling"
[resources]
cpus=0.5
memory_bytes=134217728
pids=16
max_reply_bytes=4194304
|};
  let package = Lane_addon_manifest.load ~path:manifest
    |> Result.map_error Lane_addon_manifest.error_to_string |> require in
  let create ?(store=store) route = Server_lane_addon_sampling.create_handler
    ~config ~net:env#net ~sw ~store ~instance_id:"installed-analysis-worker" ~package
    ~binding:(`Assoc ["model_route",`String route]) in
  let broker = require (create "analysis") in
  let handler = require (Lane_addon_sampling.for_worker broker ~package
    ~instance_id:"installed-analysis-worker") in
  let handler params =
    let answer = ref None in
    let scoped = Lane_addon_sampling.with_observation broker
      ~binding:(`Assoc ["model_route",`String "analysis"]) ~sources:(`List [])
      ~on_error:Fun.id (fun () ->
        Result.map (fun value -> answer := Some value; {Lane_addon_types.rows=[];coverage=[]})
          (handler params)) in
    Result.bind scoped (fun _ -> match !answer with
      | Some value -> Ok value | None -> Error "observation did not sample") in
  let request_params = if omit_temperature then {params with temperature=None} else params in
  let answer = require (handler request_params) in
  check string "route fallback returns the actual responding model, not its configured alias"
    "actual-secondary-model" answer.model;
  check string "only visible assistant text becomes an answer" "The image comparison is retained."
    (match answer.content with S.Text {text;_} -> text | S.Image _ -> fail "unexpected image answer");
  check (option string) "provider stop reason maps to MCP vocabulary" (Some "endTurn") answer.stop_reason;
  let sent_requests = List.rev !requests in
  let expected_paths = match initial_pressure with
    | None when primary_images -> ["/primary/chat/completions";"/secondary/chat/completions"]
    | None -> ["/secondary/chat/completions"]
    | Some _ -> ["/secondary/chat/completions"] in
  check (list string) "shared backpressure orders only the declared route"
    expected_paths (List.map fst sent_requests);
  check bool "successful response clears candidate backpressure" true
    (Runtime_candidate_backpressure.candidate_backpressure ~now:(Time_compat.now ())
      ~candidate:secondary.candidate_backpressure = None);
  List.iter (fun (_,body) ->
    check int "requested provider output limit is serialized" 37 Yojson.Safe.Util.(member "max_tokens" body |> to_int);
    check (float 0.) "operator temperature wins; undeclared models use the request"
      (match fixed_temperature with Some value -> value | None -> 0.25)
      Yojson.Safe.Util.(member "temperature" body |> to_float);
    let messages = member "messages" body |> Yojson.Safe.Util.to_list in
    check string "system prompt reaches HTTP" "Return only the measured comparison"
      (text "content" (List.hd messages));
    check string "text message reaches HTTP" "Compare this image" (text "content" (List.nth messages 1));
    let image_content = member "content" (List.nth messages 2) |> Yojson.Safe.Util.to_list |> List.hd in
    check string "image bytes and MIME reach HTTP" ("data:image/png;base64," ^ image)
      (member "image_url" image_content |> text "url")) sent_requests;
  let metadata = match answer._meta with Some metadata -> metadata | None -> fail "missing sampling references" in
  let refs = member "masc.lane_sampling" metadata in
  let read key = member key refs |> Lane_addon_types.evidence_of_json |> require
    |> Store.read_blob store |> require |> Yojson.Safe.from_string in
  check string "actual response is retained as a terminal outcome" "answered" (text "status" (read "outcome"));
  check string "terminal evidence preserves the actual responding model" "actual-secondary-model"
    (read "outcome" |> member "response" |> text "model");
  check string "outcome preserves the original request reference"
    (member "request" refs |> text "uri") (read "outcome" |> member "request" |> text "uri");
  check (list string) "package response exposes only sampling references" ["masc.lane_sampling"]
    (Yojson.Safe.Util.to_assoc metadata |> List.map fst);
  let retained_metadata = read "outcome" |> member "response" |> member "_meta" in
  check string "provider stop reason survives in private retained metadata" "end_turn"
    (member "masc.lane_provider" retained_metadata |> text "stop_reason");
  let host = member "masc.lane_host" retained_metadata in
  check string "selected concrete runtime is retained" "secondary.sample" (text "runtime_id" host);
  let failed = member "failed_attempts" host |> Yojson.Safe.Util.to_list in
  check int "only actually attempted failures are retained" (if Option.is_none initial_pressure then 1 else 0)
    (List.length failed);
  if Option.is_none initial_pressure then
    check string "failed attempt identifies the primary configured runtime" "primary.sample"
      (List.hd failed |> text "runtime_id");
  if primary_reply=`Thinking then
    check string "thinking-only failure preserves its exact provider stop reason" "max_tokens"
      (member "failed_attempts" host |> Yojson.Safe.Util.to_list |> List.hd |> text "provider_stop_reason");
  let expected_http_count = ref (List.length expected_paths) in
  (match primary_reply with
   | `Rate_limit | `Quota ->
       expected_retained_requests := 2;
       ignore (require (handler request_params));
       incr expected_http_count;
       check (list string) "observed refusal demotes the provider on the next request"
         (expected_paths @ ["/secondary/chat/completions"])
         (List.rev !requests |> List.map fst)
   | `Bad_request | `Thinking | `Missing_model | `Blank_model -> ());
  check bool "unknown route is rejected before HTTP" true (Result.is_error (create "unconfigured"));
  check bool "missing binding route cannot use the host default" true
    (Result.is_error (Server_lane_addon_sampling.create_handler ~config ~net:env#net ~sw ~store
      ~instance_id:"installed-analysis-worker" ~package ~binding:(`Assoc [])));
  let foreign = Store.create ~root:(Filename.concat root "foreign-store") in
  check bool "another workspace store cannot borrow the host factory" true
    (Result.is_error (create ~store:foreign "analysis"));
  let result = handler {params with stop_sequences=Some ["stop here"]} in
  check bool "unsupported stop controls do not silently disappear" true (Result.is_error result);
  let tool_result = handler {params with tools=Some [{S.name="unexpected-tool";
    description=None;input_schema=`Assoc ["type",`String "object"]}]} in
  check bool "unsupported sampling tools are refused before HTTP" true (Result.is_error tool_result);
  check int "refused control performs no additional HTTP" !expected_http_count
    (List.length !requests)

let test_invalid_sampling_route_is_stable_until_runtime_update () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock @@ fun () ->
  let root = Filename.temp_dir "sampling-preflight-" "" |> Unix.realpath in
  let old_runtime = Runtime.For_testing.snapshot () in
  let old_startup = Runtime_startup_state.get () in
  let old_catalog = Llm_provider.Model_catalog.global () in
  Lane_addon_runtime.For_testing.reset ();
  Eio.Switch.on_release sw (fun () ->
    Lane_addon_runtime.For_testing.reset ();
    Runtime.For_testing.restore old_runtime; Runtime_startup_state.set old_startup;
    (match old_catalog with None -> Llm_provider.Model_catalog.clear_global ()
      | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree root);
  let config = Workspace.default_config root in
  let masc = Workspace.masc_dir config in
  if not (Sys.file_exists masc) then Unix.mkdir masc 0o700;
  let config_root = Filename.concat masc "config" in Unix.mkdir config_root 0o700;
  let directory = Filename.concat config_root "lane-addons" in Unix.mkdir directory 0o700;
  let store = Store.create ~root:(Filename.concat masc "lane-addons") in
  let catalog_path = Filename.concat root "models.toml" in
  write catalog_path {|[[models]]
id_prefix="sampling-fixture"
provider_name="primary"
base="openai_chat"
max_context_tokens=200000
max_output_tokens=128
chat_output_budget_field="max_tokens"
supports_tools=false
supports_system_prompt=true
supports_native_streaming=false
ignored_sampling_parameters=[]
|};
  Llm_provider.Model_catalog.set_global (require (Llm_provider.Model_catalog.load_file catalog_path));
  let runtime_path = Filename.concat root "runtime.toml" in
  let runtime_bytes = {|[runtime]
default="primary.sample"
[providers.primary]
protocol="openai-compatible-http"
endpoint="http://127.0.0.1:1"
[models.sample]
api-name="sampling-fixture"
max-context=200000
tools-support=false
streaming=false
[primary.sample]
is-default=true
|} in
  write runtime_path runtime_bytes; require (Runtime.init_default ~config_path:runtime_path);
  let manifest = Filename.concat root "lane.toml" in
  write manifest {|id="sampling-preflight"
revision="1"
title="Sampling preflight"
image="not-executed"
command=["not-executed"]
contributions=["derive"]
[interface]
model_access="host_sampling"
[resources]
cpus=0.5
memory_bytes=134217728
pids=16
max_reply_bytes=4194304
|};
  let declaration = Filename.concat directory "observer.toml" in
  let declare route = write declaration (Printf.sprintf
    "id=\"observer\"\nrun_id=\"preflight-world\"\nmanifest_path=%S\n[binding]\nsources=[]\n%s" manifest route) in
  let calls = ref [] and starts = ref [] and invocations = ref 0 in
  let factory ~sw ~store ~instance_id ~package ~binding =
    calls := (instance_id, sw) :: !calls;
    Result.bind (Server_lane_addon_sampling.create_handler ~config ~net:env#net ~sw
        ~store ~instance_id ~package ~binding) (fun _broker ->
      Lane_addon_sampling.create ~store ~instance_id ~package ~route:"fixture"
        ~invoke:(fun ~route:_ ~request:_ _params ->
          incr invocations; Error "fixture forbids provider invocation") ()) in
  let backend : Lane_addon_runtime.For_testing.backend = {
    start=(fun ~sw ~instance_id ~package ~binding ~on_created ->
      let _handler = require (factory ~sw ~store ~instance_id ~package ~binding) in
      starts := instance_id :: !starts;
      let connection : Lane_addon_runtime.For_testing.connection = {
        container_id=Store.digest instance_id; action_schema=(fun () -> None);
        act=(fun ~arguments:_ -> Error "read-only fixture");
        observe=(fun ~binding:_ ~sources:_ -> Ok {Lane_addon_types.rows=[];coverage=[]});
        stop=(fun () -> Ok ())} in
      on_created connection; Ok connection);
    acquire=(fun ~access:_ ~store:_ ~package:_ ~resolve_lane_output:_ ~binding:_ -> Ok (`List []));
    image_ready=(fun ~package:_ -> Ok ());
    recover_stop=(fun ~instance_id:_ ~container_id:_ ~max_reply_bytes:_ -> Ok ())} in
  Lane_addon_runtime.For_testing.with_backend backend (fun () ->
    let reconcile () = require (Lane_addon_runtime.reconcile_configuration ~config ~directory) in
    let inspect () = Lane_addon_runtime.dispatch ~config ~operation:Lane_addon_runtime.Inspect (`Assoc [])
      |> Result.map_error Lane_addon_runtime.error_to_string |> require in
    let stable_refusal label =
      List.iter (fun _ ->
        check int (label ^ " remains one configuration issue") 1
          (member "issues" (reconcile ()) |> Yojson.Safe.Util.to_list |> List.length);
        check int (label ^ " publishes no instance") 0
          (member "instances" (inspect ()) |> Yojson.Safe.Util.to_list |> List.length);
        check int (label ^ " persists no binding") 0 (require (Store.bindings store) |> List.length)) [1;2;3];
      check int (label ^ " starts no worker") 0 (List.length !starts);
      check int (label ^ " invokes no provider") 0 !invocations in
    declare "model_route=\"primary.sample\"\n"; stable_refusal "absent host factory";
    Lane_addon_runtime.register_sampling_factory factory;
    declare ""; stable_refusal "missing route";
    declare "model_route=\"later\"\n"; stable_refusal "unknown route";
    let unchanged_declaration = In_channel.with_open_bin declaration In_channel.input_all in
    write runtime_path (runtime_bytes ^ "\n[runtime.lanes.later]\ncandidates=[\"primary.sample\"]\n");
    require (Runtime.init_default ~config_path:runtime_path);
    ignore (reconcile ());
    let rec await predicate = if not (predicate ()) then (Eio.Time.sleep env#clock 0.001; await predicate) in
    await (fun () -> List.length !starts = 1);
    let id = List.hd !starts in
    let construction_switches = List.filter_map (fun (owner, switch) ->
      if owner = id then Some switch else None) !calls in
    check int "exact attached identity constructed twice" 2 (List.length construction_switches);
    check bool "preflight uses root switch and worker callback uses another switch" true
      (List.exists (fun switch -> switch == sw) construction_switches
       && List.exists (fun switch -> switch != sw) construction_switches);
    check string "runtime update recovers without editing installation TOML" unchanged_declaration
      (In_channel.with_open_bin declaration In_channel.input_all);
    check int "preflight and worker construction invoke no model" 0 !invocations;
    ignore (Lane_addon_runtime.dispatch ~config ~operation:Lane_addon_runtime.Detach
      (`Assoc ["instance_id", `String id]) |> Result.map_error Lane_addon_runtime.error_to_string |> require);
    await (fun () -> member "instances" (inspect ()) |> Yojson.Safe.Util.to_list
      |> List.for_all (fun item -> text "kind" (member "phase" item) = "detached")))

let () = run "Server Lane sampling HTTP composition" ["host boundary",[
  test_case "sampling route preflight stays stable and recovers after runtime update" `Quick
    test_invalid_sampling_route_is_stable_until_runtime_update;
  test_case "captured binding survives same-ID reload" `Quick
    test_captured_binding_survives_same_id_reload;
  test_case "image-only completion preserves MCP content" `Quick
    test_image_only_completion_is_sampling_content;
  test_case "installed route, serialized request, fallback and durable outcome" `Quick
    (fun () -> test_actual_http_route_and_durable_sampling ());
  test_case "image-incapable primary is skipped before HTTP dispatch" `Quick
    (test_actual_http_route_and_durable_sampling ~primary_images:false);
  test_case "missing model identity walks the secondary" `Quick
    (test_actual_http_route_and_durable_sampling ~primary_reply:`Missing_model);
  test_case "blank model identity walks the secondary" `Quick
    (test_actual_http_route_and_durable_sampling ~primary_reply:`Blank_model);
  test_case "existing rate limit demotes the primary" `Quick
    (test_actual_http_route_and_durable_sampling ~initial_pressure:`Rate_limit);
  test_case "existing quota exhaustion demotes the primary" `Quick
    (test_actual_http_route_and_durable_sampling ~initial_pressure:`Quota);
  test_case "another Keeper's failed attempt demotes the primary" `Quick
    (test_actual_http_route_and_durable_sampling ~initial_pressure:`Failed);
  test_case "sampling records a rate limit for its next request" `Quick
    (test_actual_http_route_and_durable_sampling ~primary_reply:`Rate_limit);
  test_case "sampling records hard quota for its next request" `Quick
    (test_actual_http_route_and_durable_sampling ~primary_reply:`Quota);
  test_case "declared zero liveness reaches providers and retains the answer" `Quick
    (test_actual_http_route_and_durable_sampling ~turn_timeout_s:0.);
  test_case "declared positive liveness reaches providers and retains the answer" `Quick
    (test_actual_http_route_and_durable_sampling ~turn_timeout_s:30.);
  test_case "thinking-only maxTokens falls back and fixed model temperature wins" `Quick
    (test_actual_http_route_and_durable_sampling ~primary_reply:`Thinking ~fixed_temperature:0.75);
  test_case "fixed model temperature survives an omitted request value" `Quick
    (test_actual_http_route_and_durable_sampling ~fixed_temperature:0.75 ~omit_temperature:true)]]
