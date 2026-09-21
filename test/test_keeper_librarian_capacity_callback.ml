open Masc
module Runtime = Keeper_librarian_runtime
module Fixture = Exact_output_fixture
module Runs = Exact_lane_run_registry

let overflow =
  {|{"id":"capacity","model":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"model_context_window_exceeded"}],"usage":{"prompt_tokens":1,"completion_tokens":0,"total_tokens":1}}|}

let test_callback ?(cli_errors = []) ~base_path ~registry ~keeper_id ~first_overflow ~status ~expected () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = env#net and clock = env#clock in
  Eio_context.with_test_env ~net ~clock ~mono_clock:env#mono_clock ~sw @@ fun () ->
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
  let start_server status =
  let posts = ref 0 in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | _ -> Alcotest.fail "missing loopback port" in
  let handler _ _ body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all));
    incr posts;
    let body = match status with
      | `OK -> overflow
      | `Request_entity_too_large -> {|{"error":{"message":"fixture body limit","type":"invalid_request_error"}}|}
      | `Too_many_requests -> {|{"error":{"message":"fixture quota","type":"rate_limit_error"}}|}
      | _ -> {|{"error":{"message":"fixture authorization","type":"authentication_error"}}|} in
    Cohttp_eio.Server.respond_string ~status ~body () in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port, posts in
  let first = if first_overflow then Some (start_server `Request_entity_too_large) else None in
  let base_url, posts = start_server status in
  let terminal : Fixture.target_fixture = {id = "capacity-terminal"; base_url} in
  let targets = match first with
    | None -> [terminal]
    | Some (base_url, _) -> [{Fixture.id = "capacity-first"; base_url}; terminal] in
  let resolver = Fixture.resolver_snapshot ~source:"capacity-callback-fixture" targets in
  (match Runtime_exact_output_registry.publish
      ~lanes:[{Runtime_schema.id = "librarian_exact";
        slot_ids = List.map (fun (target : Fixture.target_fixture) -> target.id) targets;
        cli_slot_ids = List.map fst cli_errors}] resolver with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Runtime_exact_output_registry.publication_error_to_string error));
  let input : Keeper_librarian.input =
    {turn_ref = Ids.Turn_ref.make ~trace_id:keeper_id ~absolute_turn:1;
     goal_context = Keeper_librarian.No_task; keeper_instructions = "Preserve evidence.";
     current = None; working_context = Keeper_librarian_context.empty;
     messages = [Agent_core.Types.user_msg "Pending conversation evidence."];
     tool_observations = []; counterpart_observations = []} in
  let cli_calls = ref [] in
  let cli_runner ~runtime_id ~system_prompt:_ ~output_schema:_ ~prompt:_ =
    cli_calls := !cli_calls @ [runtime_id];
    Error (List.assoc runtime_id cli_errors) in
  let refused = ref 0 and committed = ref false in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Runtime.run_best_effort ~trigger:Runtime.Durable_range
    ~input_projection:Runtime.Already_selected_range ~cli_runner
    ~on_capacity_refused:(fun () -> incr refused)
    ~on_memory_committed:(fun () -> committed := true)
    ~base_path ~keepers_dir ~keeper_id ~expected_revision:None input;
  Alcotest.(check int) "only final capacity failure requests narrowing" expected !refused;
  Alcotest.(check (list string)) "CLI candidates ran in order"
    (List.map fst cli_errors) !cli_calls;
  Alcotest.(check int) "terminal provider really received the request" 1 !posts;
  Option.iter (fun (_, count) -> Alcotest.(check int)
    "body-refused first provider really ran" 1 !count) first;
  Alcotest.(check bool) "refused request never commits Memory" false !committed;
  let runs = Runs.list_runs registry |> List.filter
    (fun (run : Runs.run) -> String.equal run.actor keeper_id) in
  match runs with
  | [run] -> Alcotest.(check string) "terminal failure remains observable" "failed"
      (Runs.status_label run.status)
  | _ -> Alcotest.fail "expected one recorded Librarian run"

let () =
  let base_path = Filename.temp_dir "librarian-capacity-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let registry = Runs.create ~path:(Filename.concat base_path Runs.storage_filename) () in
  (match Runs.install_global registry with
   | Ok () -> () | Error Runs.Already_installed -> Alcotest.fail "registry already installed");
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  Prompt_registry.set_markdown_dir (Filename.concat root "config/prompts");
  Prompt_defaults.init ();
  let case name first_overflow status expected =
    Alcotest.test_case name `Quick
      (test_callback ~base_path ~registry ~keeper_id:name ~first_overflow ~status ~expected) in
  let codex_error data = Fusion_official_client.Codex_failure
    (Runtime_codex_app_server.Rpc_error
      { method_ = "turn/start"; code = Some (-32602);
        message = "Input exceeds the maximum length of 1048576 characters.";
        data }) in
  let capacity = codex_error (Some (`Assoc [
    "input_error_code", `String "input_too_large";
    "actual_chars", `Int 23; "max_chars", `Int 17])) in
  let generic = codex_error None in
  let quota = Fusion_official_client.Setup_failure (Fusion_types.Provider_error "quota") in
  let cli_case name cli_errors expected = Alcotest.test_case name `Quick (fun () ->
    Fixture.with_official_client_runtimes @@ fun () ->
    test_callback ~cli_errors ~base_path ~registry ~keeper_id:name
      ~first_overflow:false ~status:`Too_many_requests ~expected ()) in
  Alcotest.run "Librarian capacity callbacks"
    ["actual HTTP outcomes", [
      case "capacity-final" false `OK 1;
      case "quota-final" false `Too_many_requests 0;
      case "capacity-then-quota" true `Too_many_requests 0;
      case "capacity-then-auth" true `Unauthorized 0];
    "HTTP to CLI outcomes", [
      cli_case "quota-then-cli-capacity" [Fixture.cli_primary_runtime, capacity] 1;
      cli_case "quota-then-cli-generic-rpc" [Fixture.cli_primary_runtime, generic] 0;
      cli_case "cli-capacity-then-quota"
        [Fixture.cli_primary_runtime, capacity; Fixture.cli_secondary_runtime, quota] 0;
      cli_case "cli-quota-then-capacity"
        [Fixture.cli_primary_runtime, quota; Fixture.cli_secondary_runtime, capacity] 1]]
