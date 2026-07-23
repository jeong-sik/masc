open Masc

module EO = Agent_sdk.Exact_output

type server_behavior =
  | Reply of string
  | Abort_after_request
  | Delay_then_reply of float * string

type test_server =
  { base_url : string
  ; posts : int Atomic.t
  ; requests : string list Atomic.t
  ; first_request_arrived : unit Eio.Promise.t
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
    Atomic.incr posts;
    ignore (Eio.Promise.try_resolve resolve_first_request_arrived ());
    Option.iter (fun hook -> hook ()) on_request_before_reply;
    match behavior with
    | Reply response -> Cohttp_eio.Server.respond_string ~status:`OK ~body:response ()
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
  }
;;

let target_fixture_toml ?connect_timeout_s index fixture =
  let provider_id = Printf.sprintf "masc-exact-fixture-provider-%d" index in
  let model_id = Printf.sprintf "masc-exact-fixture-model-%d" index in
  let timeout =
    Option.fold
      ~none:""
      ~some:(fun value -> Printf.sprintf "connect_timeout_s = %.6g\n" value)
      connect_timeout_s
  in
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     kind = \"openai_compat\"\n\
     base_url = %S\n\
     request_path = \"/v1/chat/completions\"\n\
     api_key_env = \"\"\n\n\
     [[models]]\n\
     id_prefix = %S\n\
     provider_name = %S\n\
     max_context_tokens = 8192\n\
     max_output_tokens = 1024\n\
     supports_response_format_json = true\n\
     supports_structured_output = true\n\n\
     [[targets]]\n\
     id = %S\n\
     provider_ref = %S\n\
     model_id = %S\n\
     %s"
    provider_id
    fixture.base_url
    model_id
    provider_id
    fixture.id
    provider_id
    model_id
    timeout
;;

let resolver_snapshot ?(connect_timeouts = []) ~source fixtures =
  let timeout_for id = List.assoc_opt id connect_timeouts in
  let overlay : EO.catalog_overlay =
    { source
    ; contents =
        fixtures
        |> List.mapi (fun index fixture ->
          target_fixture_toml ?connect_timeout_s:(timeout_for fixture.id) index fixture)
        |> String.concat "\n"
    }
  in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  match EO.load_resolver_snapshot ~io ~overlay () with
  | Ok snapshot -> snapshot
  | Error _ -> Alcotest.fail "exact-output resolver fixture did not load"
;;

let catalog_generation_fingerprint snapshot =
  snapshot
  |> EO.resolver_catalog_generation
  |> EO.catalog_generation_fingerprint
;;

let publish_registry ~lane_id ~slot_ids resolver_snapshot =
  let lane : Runtime_schema.exact_output_lane_decl = { id = lane_id; slot_ids } in
  match Runtime_exact_output_registry.publish ~lanes:[ lane ] resolver_snapshot with
  | Ok registry -> registry
  | Error error ->
    Alcotest.failf
      "exact-output registry fixture did not publish: %s"
      (Runtime_exact_output_registry.error_to_string error)
;;

let runtime_exact_output_lanes () =
  let runtime_path =
    Filename.concat (Masc_test_deps.find_project_root ()) "config/runtime.toml"
  in
  match Runtime_toml.parse_file runtime_path with
  | Ok (config : Runtime_schema.config) -> config.exact_output_lane_decls
  | Error errors ->
    Alcotest.failf
      "exact-output runtime fixture did not parse: %d error(s)"
      (List.length errors)
;;

let publish_runtime_lane ?connect_timeout_s ~source ~base_url () =
  let lanes = runtime_exact_output_lanes () in
  let slot_ids =
    match
      List.find_opt
        (fun (lane : Runtime_schema.exact_output_lane_decl) ->
           String.equal lane.id "compaction_exact")
        lanes
    with
    | Some { slot_ids = _ :: _ as slot_ids; _ } -> slot_ids
    | Some { slot_ids = []; _ } ->
      Alcotest.fail "compaction_exact fixture lane is empty"
    | None -> Alcotest.fail "compaction_exact fixture lane is missing"
  in
  let fixtures = List.map (fun id -> { id; base_url }) slot_ids in
  let connect_timeouts =
    Option.fold
      ~none:[]
      ~some:(fun timeout -> List.map (fun id -> id, timeout) slot_ids)
      connect_timeout_s
  in
  let resolver_snapshot = resolver_snapshot ~connect_timeouts ~source fixtures in
  (match Runtime_exact_output_registry.publish ~lanes resolver_snapshot with
   | Ok _ -> ()
   | Error error ->
     Alcotest.failf
       "exact-output runtime fixture did not publish: %s"
       (Runtime_exact_output_registry.error_to_string error));
  slot_ids
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
let await_first_request server = Eio.Promise.await server.first_request_arrived
