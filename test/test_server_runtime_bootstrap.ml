module Types = Masc_domain

open Masc

module Runtime_under_test = Server_routes_http_runtime

(* The payload reports what should run and what does; which keepers are
   missing is the difference between the two lists. *)
let keepers_not_running json =
  let open Yojson.Safe.Util in
  let names key = json |> member key |> to_list |> List.map to_string in
  let executable = names "executable_keeper_names" in
  names "autoboot_enabled_keeper_names"
  |> List.filter (fun name -> not (List.mem name executable))
  |> List.sort_uniq String.compare

let test_request_authority () =
  match Server_request_authority.of_host_port ~host:"localhost" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> Alcotest.fail "test authority must be valid"
;;

module Server_routes_http_runtime = struct
  include Runtime_under_test

  let make_health_json ?listener ?section_timings_ref request =
    Runtime_under_test.make_health_json
      ?listener
      ?section_timings_ref
      ~request_authority:(test_request_authority ())
      request
  ;;

  let make_health_response_json ?listener request =
    Runtime_under_test.make_health_response_json
      ?listener
      ~request_authority:(test_request_authority ())
      request
  ;;

  module For_testing = struct
    include Runtime_under_test.For_testing

    let refresh_full_health_snapshot_now ?listener request =
      Runtime_under_test.For_testing.refresh_full_health_snapshot_now
        ?listener
        ~request_authority:(test_request_authority ())
        request
    ;;
  end
end

let () = Mirage_crypto_rng_unix.use_default ()

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f

let with_explicit_test_config_root config_root f =
  with_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" (Some "1") @@ fun () ->
  with_env "MASC_CONFIG_DIR" (Some config_root) f

let with_config_input name value f =
  let saved_env = Sys.getenv_opt name in
  let saved_override = Config_boot_overrides.get_opt name in
  (match value with
   | Some v ->
       Unix.putenv name v;
       Config_boot_overrides.set name v
   | None ->
       Unix.putenv name "";
       Config_boot_overrides.clear name);
  Fun.protect
    ~finally:(fun () ->
      (match saved_env with
       | Some prior -> Unix.putenv name prior
       | None -> Unix.putenv name "");
      match saved_override with
      | Some prior -> Config_boot_overrides.set name prior
      | None -> Config_boot_overrides.clear name)
    f

let with_clean_base_path_env f =
  with_config_input "MASC_BASE_PATH" None @@ fun () ->
  with_config_input "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_config_input "MASC_BASE_PATH_RESOLUTION_SOURCE" None f

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let repo_runtime_toml = "# repo runtime seed\n"
let local_runtime_toml = "# local runtime seed\n"
let repo_model_catalog_overlay_toml =
  "[[models]]\nid_prefix = \"repo-runtime\"\nprovider_name = \"repo-provider\"\n"

let test_grpc_tool_arguments_fail_closed_before_dispatch () =
  let dispatch_calls = ref 0 in
  let dispatch _arguments =
    incr dispatch_calls;
    Ok "{}"
  in
  [ "malformed", "{"; "non-object", "[]" ]
  |> List.iter (fun (label, arguments_json) ->
    match
          Masc_test_deps.Server_grpc_tool_dispatch.dispatch ~dispatch arguments_json
    with
    | Error error ->
      Alcotest.(check string)
        (label ^ " typed error")
        "Invalid params: expected object"
        (Masc_test_deps.Server_grpc_tool_dispatch.error_message error);
      Alcotest.(check int)
        (label ^ " invalid-params code")
        (Masc.Mcp_error_code.to_wire_code Masc.Mcp_error_code.Invalid_params)
        (Masc_test_deps.Server_grpc_tool_dispatch.error_code error
         |> Masc.Mcp_error_code.to_wire_code)
    | Ok _ -> Alcotest.failf "%s arguments reached the dispatcher" label);
  Alcotest.(check int) "rejected dispatcher calls" 0 !dispatch_calls;
  (match
     Masc_test_deps.Server_grpc_tool_dispatch.dispatch ~dispatch ""
   with
   | Ok "{}" -> ()
   | Ok result -> Alcotest.failf "unexpected omitted-arguments result: %s" result
   | Error error ->
     Alcotest.fail
       (Masc_test_deps.Server_grpc_tool_dispatch.error_message error));
  Alcotest.(check int) "omitted arguments dispatch once" 1 !dispatch_calls
;;

let canonical_path path =
  try Unix.realpath path with Unix.Unix_error _ -> path

let project_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

let read_all ic =
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_channel buf ic 1024
     done
   with End_of_file -> ());
  Buffer.contents buf

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir)
    (fun () -> with_clean_base_path_env (fun () -> f dir))

let with_cwd path f =
  let saved = Sys.getcwd () in
  Unix.chdir path;
  Fun.protect ~finally:(fun () -> Unix.chdir saved) f

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let test_keeper_msg_startup_recovery_settles_disk_only_running_request () =
  with_temp_dir "keeper-msg-startup-recovery" (fun base_path ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let request_id = "startup_recovery_running_0" in
    let active_path =
      match
        Keeper_msg_async.For_testing.active_record_path ~base_path ~request_id
      with
      | Some path -> path
      | None -> Alcotest.fail "startup recovery request id was rejected"
    in
    mkdir_p (Filename.dirname active_path);
    `Assoc
      [ "schema_version", `Int Keeper_msg_async.For_testing.record_schema_version
      ; "request_id", `String request_id
      ; "keeper_name", `String "startup-recovery-keeper"
      ; "base_path", `String (Fs_compat.realpath base_path)
      ; "submitted_by", `String "startup-recovery-caller"
      ; "status", `String "running"
      ; "submitted_at", `Float 1.0
      ; "request_context", `Null
      ]
    |> Yojson.Safe.to_string
    |> Fs_compat.save_file active_path;
    let report =
      Server_bootstrap_maintenance.recover_keeper_msg_requests_on_startup
        ~base_path
    in
    Alcotest.(check int) "startup recovered one request" 1 report.lost;
    match
      Keeper_msg_async.poll
        ~base_path
        ~caller:"startup-recovery-caller"
        request_id
    with
    | Keeper_msg_async.Found { status = Keeper_msg_async.Lost _; _ } -> ()
    | Keeper_msg_async.Found entry ->
      Alcotest.failf
        "startup recovery retained status=%s"
        (Keeper_msg_async.status_to_string entry.status)
    | Keeper_msg_async.Absent
    | Keeper_msg_async.Unreadable _
    | Keeper_msg_async.Rejected _ ->
      Alcotest.fail "startup recovery lost the durable request row")
;;

(* The example keeper must satisfy the fail-closed profile contract
   (#24144/#24226): a TOML without inline instructions requires a non-empty
   keeper.instructions, and a keeper whose profile fails to load is
   excluded from autoboot/bootable targets entirely — which silently removed
   "example" from every blocked-target expectation below (#28485 layer 2). *)
let write_example_keeper config =
  write_file
    (Filename.concat config "keepers/example.toml")
    "[keeper]\nautoboot_enabled = true\ninstructions = \"example instructions\"\n"

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  write_file
    (Filename.concat config "agent-core-models-overlay.toml")
    repo_model_catalog_overlay_toml;
  write_file (Filename.concat root "agent-core-models.toml") "legacy full catalog must be ignored";
  write_file (Filename.concat config "runtime.toml") repo_runtime_toml;
  write_file (Filename.concat config "prompts/keeper.md") "prompt";
  write_example_keeper config;
  config

let make_base_path_config_root root =
  let config =
    Filename.concat (Filename.concat root Common.masc_dirname) "config"
  in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  write_file
    (Filename.concat config "agent-core-models-overlay.toml")
    repo_model_catalog_overlay_toml;
  write_file (Filename.concat config "runtime.toml") repo_runtime_toml;
  write_file (Filename.concat config "prompts/keeper.md") "prompt";
  write_example_keeper config;
  config

let test_model_catalog_configuration_installs_explicit_env_override () =
  let env = function
    | "AGENT_CORE_MODEL_CATALOG" -> Some "/explicit/agent-core-models.toml"
    | _ -> None
  in
  let load_calls = ref [] in
  let set_calls = ref 0 in
  let result =
    Server_runtime_bootstrap.configure_agent_core_model_catalog_env
      ~env
      ~load_catalog:(fun path ->
        load_calls := path :: !load_calls;
        Ok Llm_provider.Model_catalog.empty)
      ~set_catalog:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_calls)
      ()
  in
  Alcotest.(check (option string))
    "explicit override path"
    (Some "/explicit/agent-core-models.toml")
    result;
  Alcotest.(check (list string))
    "load explicit catalog"
    [ "/explicit/agent-core-models.toml" ]
    (List.rev !load_calls);
  Alcotest.(check int) "set catalog override" 1 !set_calls

let test_model_catalog_configuration_ignores_legacy_discovery_inputs () =
  let catalog_calls = ref 0 in
  let load_calls = ref 0 in
  let set_calls = ref 0 in
  let env = function
    | "MASC_MODEL_CATALOG" -> Some "/legacy/masc-models.toml"
    | _ -> None
  in
  let result =
    Server_runtime_bootstrap.configure_agent_core_model_catalog_env
      ~env
      ~agent_core_catalog:(fun () ->
        incr catalog_calls;
        Some Llm_provider.Model_catalog.empty)
      ~load_catalog:(fun (_ : string) ->
        incr load_calls;
        Ok Llm_provider.Model_catalog.empty)
      ~set_catalog:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_calls)
      ()
  in
  Alcotest.(check bool) "ambient catalog selected" true (Option.is_none result);
  Alcotest.(check int) "ambient catalog queried" 1 !catalog_calls;
  Alcotest.(check int) "legacy catalog not loaded" 0 !load_calls;
  Alcotest.(check int) "legacy catalog not installed" 0 !set_calls

let test_model_catalog_overlay_installs_config_root_overlay () =
  with_temp_dir "model-catalog-overlay-install" (fun dir ->
    let config_root = Filename.concat dir "config-root" in
    let overlay = Filename.concat config_root "agent-core-models-overlay.toml" in
    mkdir_p config_root;
    write_file overlay "[[models]]\nid_prefix = \"deployment-delta\"\n";
    let load_calls = ref [] in
    let set_overlay_calls = ref 0 in
    let result =
      Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
        ~config_root
        ~load_catalog:(fun path ->
          load_calls := path :: !load_calls;
          Ok Llm_provider.Model_catalog.empty)
        ~set_overlay:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_overlay_calls)
        ()
    in
    (match result with
     | None -> Alcotest.fail "expected config-root overlay resolution"
     | Some path ->
       Alcotest.(check string) "path" (canonical_path overlay) (canonical_path path));
    Alcotest.(check (list string)) "load overlay" [ overlay ] (List.rev !load_calls);
    Alcotest.(check int) "set overlay" 1 !set_overlay_calls)

let test_model_catalog_overlay_absent_is_noop () =
  with_temp_dir "model-catalog-overlay-absent" (fun dir ->
    let config_root = Filename.concat dir "config-root" in
    mkdir_p config_root;
    let load_calls = ref [] in
    let set_overlay_calls = ref 0 in
    let result =
      Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
        ~config_root
        ~load_catalog:(fun path ->
          load_calls := path :: !load_calls;
          Ok Llm_provider.Model_catalog.empty)
        ~set_overlay:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_overlay_calls)
        ()
    in
    Alcotest.(check bool) "no overlay resolved" true (Option.is_none result);
    Alcotest.(check (list string)) "no load" [] !load_calls;
    Alcotest.(check int) "no install" 0 !set_overlay_calls)

let test_model_catalog_overlay_invalid_fails_loud () =
  with_temp_dir "model-catalog-overlay-invalid" (fun dir ->
    let config_root = Filename.concat dir "config-root" in
    let overlay = Filename.concat config_root "agent-core-models-overlay.toml" in
    mkdir_p config_root;
    write_file overlay "not toml";
    let set_overlay_calls = ref 0 in
    match
      Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
        ~config_root
        ~load_catalog:(fun (_ : string) -> Error "parse failed")
        ~set_overlay:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_overlay_calls)
        ()
    with
    | (_ : string option) ->
      Alcotest.fail "expected Config_error for invalid overlay"
    | exception Env_config_core.Config_error message ->
      Alcotest.(check bool)
        "error names overlay path"
        true
        (String_util.contains_substring message "agent-core-models-overlay.toml");
      Alcotest.(check int) "no install" 0 !set_overlay_calls)

let test_explicit_model_catalog_replacement_precedes_overlay () =
  with_temp_dir "model-catalog-explicit-precedence" (fun config_root ->
    let overlay_path = Filename.concat config_root "agent-core-models-overlay.toml" in
    write_file overlay_path "overlay fixture";
    let parse source toml =
      match Llm_provider.Model_catalog.of_toml_string ~source toml with
      | Ok catalog -> catalog
      | Error detail -> Alcotest.failf "%s catalog fixture invalid: %s" source detail
    in
    let explicit =
      parse
        "explicit"
        "[[models]]\nid_prefix = \"explicit-model\"\nbase = \"openai_chat\"\n"
    in
    let overlay =
      parse
        "overlay"
        "[[models]]\nid_prefix = \"overlay-model\"\nbase = \"openai_chat\"\n"
    in
    let previous = Llm_provider.Model_catalog.global () in
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some catalog -> Llm_provider.Model_catalog.set_global catalog
        | None -> Llm_provider.Model_catalog.clear_global ())
      (fun () ->
        Llm_provider.Model_catalog.clear_global ();
        ignore
          (Server_runtime_bootstrap.configure_agent_core_model_catalog_env
             ~env:(function
               | "AGENT_CORE_MODEL_CATALOG" -> Some "/explicit/catalog.toml"
               | _ -> None)
             ~load_catalog:(fun _ -> Ok explicit)
             ());
        ignore
          (Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
             ~config_root
             ~load_catalog:(fun _ -> Ok overlay)
             ());
        match Llm_provider.Model_catalog.global () with
        | None -> Alcotest.fail "expected explicit global catalog"
        | Some effective ->
          Alcotest.(check bool)
            "explicit row remains"
            true
            (Option.is_some
               (Llm_provider.Model_catalog.lookup effective "explicit-model"));
          Alcotest.(check bool)
            "overlay row does not override explicit full replacement"
            true
            (Option.is_none
               (Llm_provider.Model_catalog.lookup effective "overlay-model"))))

let test_model_catalog_configuration_delegates_to_agent_core_ambient () =
  let env _ = None in
  let result =
    Server_runtime_bootstrap.configure_agent_core_model_catalog_env
      ~env
      ~agent_core_catalog:(fun () -> Some Llm_provider.Model_catalog.empty)
      ()
  in
  Alcotest.(check bool) "no explicit path resolution" true (Option.is_none result)

(* Instructions live in [keeper.instructions]; the TOML is the whole setup. *)
let write_keeper_instructions keepers_dir name body =
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (Printf.sprintf "[keeper]\ninstructions = %S\n" body)

let write_config_root_keeper_toml ?(autoboot_enabled = true) config_root name =
  let keepers_dir = Filename.concat config_root "keepers" in
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    (Printf.sprintf
       "[keeper]\ninstructions = \"instructions-%s\"\nautoboot_enabled = %b\nsandbox_profile = \"local\"\n"
       name
       autoboot_enabled)

let fixture_runtime_id () =
  match Runtime.get_default_runtime () with
  | Some runtime -> Runtime.id_of_binding runtime.binding
  | None -> "test.runtime"

let write_basepath_keeper_toml base_path name =
  let keepers_dir =
    Filename.concat (Filename.concat (Filename.concat base_path Common.masc_dirname) "config")
      "keepers"
  in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
{|[keeper]
instructions = "example"
proactive_enabled = false
autoboot_enabled = true
|}
let find_free_port_from start =
  let rec loop attempts port =
    if attempts <= 0 then
      Alcotest.skip ()
    else
      let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      let next_port = if port >= 65535 then 9200 else port + 1 in
      Fun.protect
        ~finally:(fun () -> Unix.close socket)
        (fun () ->
          match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) with
          | () -> port
          | exception Unix.Unix_error
                        ((Unix.EADDRINUSE | Unix.EADDRNOTAVAIL | Unix.EPERM | Unix.EACCES), "bind", _) ->
              loop (attempts - 1) next_port
          | exception Unix.Unix_error (err, fn, arg) ->
              Alcotest.failf "find_free_port bind failed: %s (%s %s)"
                (Unix.error_message err) fn arg)
  in
  loop 2048 start

let find_free_port () =
  find_free_port_from (9200 + (Unix.getpid () mod 1000))

let openai_text_response ?(id = "chatcmpl-1") text =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}|}
    id text

let start_mock_openai_server ~port ~response =
  let program = "python3" in
  let script =
    {|
import http.server
import sys

response = sys.argv[2].encode()

class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    do_GET = reply
    do_POST = reply

    def log_message(self, _format, *_args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
|}
  in
  let pid =
    Unix.create_process_env
      program
      [| program; "-c"; script; string_of_int port; response |]
      (Unix.environment ())
      Unix.stdin
      Unix.stdout
      Unix.stderr
  in
  Unix.sleepf 0.1;
  pid

let merge_env_overrides overrides =
  let override_keys = List.map fst overrides in
  let is_override_key entry =
    match String.index_opt entry '=' with
    | None -> false
    | Some idx ->
      let key = String.sub entry 0 idx in
      List.mem key override_keys
  in
  let base =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (is_override_key entry))
  in
  let injected = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
  Array.of_list (base @ injected)

let main_eio_test_admin_token = "main-eio-test-admin-token"
let main_eio_auth_header = "Authorization: Bearer " ^ main_eio_test_admin_token

let main_eio_env_overrides overrides =
  merge_env_overrides
    (("MASC_ADMIN_TOKEN", main_eio_test_admin_token)
     :: ("MASC_INTERNAL_MCP_TOKEN", "")
     :: overrides)

let curl_health_status ~port =
  let url = Printf.sprintf "http://127.0.0.1:%d/health" port in
  let args =
    [|
      "curl";
      "-sS";
      "--http1.1";
      "--max-time";
      "1";
      "-o";
      "/dev/null";
      "-w";
      "%{http_code}";
      url;
    |]
  in
  let ic = Unix.open_process_args_in "curl" args in
  let output = read_all ic |> String.trim in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> int_of_string_opt output
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None

let curl_health_json ~port =
  let url = Printf.sprintf "http://127.0.0.1:%d/health" port in
  let args = [| "curl"; "-sS"; "--http1.1"; "--max-time"; "2"; url |] in
  let ic = Unix.open_process_args_in "curl" args in
  let output = read_all ic |> String.trim in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> (
      try Some (Yojson.Safe.from_string output) with _ -> None)
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None

let http_status_from_headers path =
  let lines = String.split_on_char '\n' (read_file path) in
  let rec loop = function
    | [] -> None
    | line :: rest ->
        let line = String.trim line in
        if String.starts_with ~prefix:"HTTP/" line then
          match String.split_on_char ' ' line with
          | _version :: code :: _ -> int_of_string_opt code
          | _ -> loop rest
        else
          loop rest
  in
  loop lines

let require_http_status_from_headers path =
  match http_status_from_headers path with
  | Some status -> status
  | None -> Alcotest.failf "missing HTTP status\nheaders:\n%s" (read_file path)

let header_value path key =
  let key = String.lowercase_ascii key ^ ":" in
  let lines = String.split_on_char '\n' (read_file path) in
  let rec loop = function
    | [] -> None
    | line :: rest ->
        let normalized = String.lowercase_ascii line in
        if String.starts_with ~prefix:key normalized then
          let value =
            match String.split_on_char ':' line with
            | _name :: rest -> String.concat ":" rest |> String.trim
            | [] -> ""
          in
          Some (String.trim (String.map (fun c -> if Char.equal c '\r' then ' ' else c) value))
        else
          loop rest
  in
  loop lines

let require_header_value path key =
  match header_value path key with
  | Some value -> value
  | None ->
      Alcotest.failf "missing %s\nheaders:\n%s" key (read_file path)

let parse_json_response_file path =
  let text = read_file path in
  let trimmed = String.trim text in
  if trimmed <> "" && (trimmed.[0] = '{' || trimmed.[0] = '[') then
    Yojson.Safe.from_string trimmed
  else
    let lines = String.split_on_char '\n' text in
    let rec loop = function
      | [] -> Alcotest.failf "no JSON payload found in %s" path
      | line :: rest ->
          let line = String.trim line in
          if String.starts_with ~prefix:"data: " line then
            Yojson.Safe.from_string (String.sub line 6 (String.length line - 6))
          else
            loop rest
    in
    loop lines

let curl_request_capture ?(headers = []) ~output_dir ~name ~method_ ~url ?payload () =
  let headers_path = Filename.concat output_dir (name ^ ".headers") in
  let body_path = Filename.concat output_dir (name ^ ".body") in
  let base_args =
    [
      "curl";
      "-sS";
      "--http1.1";
      "--max-time";
      "5";
      "-D";
      headers_path;
      "-o";
      body_path;
      "-X";
      method_;
      url;
      "-H";
      "Accept: application/json, text/event-stream";
    ]
  in
  let header_args =
    headers |> List.concat_map (fun header -> [ "-H"; header ])
  in
  let payload_args =
    match payload with
    | Some body -> [ "-d"; body ]
    | None -> []
  in
  let args = Array.of_list (base_args @ header_args @ payload_args) in
  let ic = Unix.open_process_args_in "curl" args in
  let _ = read_all ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> (headers_path, body_path)
  | Unix.WEXITED code ->
      Alcotest.failf "curl %s failed with exit %d" name code
  | Unix.WSIGNALED signal ->
      Alcotest.failf "curl %s signaled %d" name signal
  | Unix.WSTOPPED signal ->
      Alcotest.failf "curl %s stopped %d" name signal

let process_alive pid =
  match Unix.waitpid [Unix.WNOHANG] pid with
  | 0, _ -> true
  | _ -> false
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false

let wait_for_health ~pid ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match curl_health_status ~port with
    | Some 200 -> true
    | _ ->
      if not (process_alive pid) then
        false
      else if Unix.gettimeofday () >= deadline then
        false
      else begin
        Unix.sleepf 0.1;
        loop ()
      end
  in
  loop ()

let wait_for_process_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if not (process_alive pid) then
      true
    else if Unix.gettimeofday () >= deadline then
      false
    else begin
      Unix.sleepf 0.1;
      loop ()
    end
  in
  loop ()

let wait_for_startup_phase ~pid ~port ~timeout_s expected_phase =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match curl_health_json ~port with
    | Some json -> (
        let phase =
          match Yojson.Safe.Util.member "startup" json with
          | `Assoc _ as startup ->
              Yojson.Safe.Util.(startup |> member "phase" |> to_string_option)
          | _ -> None
        in
        match phase with
        | Some phase when String.equal phase expected_phase -> true
        | _ ->
            if not (process_alive pid) then
              false
            else if Unix.gettimeofday () >= deadline then
              false
            else begin
              Unix.sleepf 0.2;
              loop ()
            end)
    | None ->
        if not (process_alive pid) then
          false
        else if Unix.gettimeofday () >= deadline then
          false
        else begin
          Unix.sleepf 0.2;
          loop ()
        end
  in
  loop ()

let write_invalid_local_only_runtime base_path =
  let config_root = Filename.concat base_path ".masc/config" in
  mkdir_p config_root;
  write_file
    (Filename.concat config_root "runtime.toml")
    {|[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen]
api-name = "qwen3.6:35b-a3b-mlx-bf16"
max-context = 32768
tools-support = false

[runtime.invalid_local_lane]
members = ["missing_provider.qwen"]

[runtime.invalid_local_lane]
tiers = ["invalid_local_lane"]

[routes.keeper_turn]
target = "runtime.invalid_local_lane"
|}

let split_custom_model_spec spec =
  let after_scheme =
    match String.index_opt spec ':' with
    | Some idx -> String.sub spec (idx + 1) (String.length spec - idx - 1)
    | None -> spec
  in
  match String.index_opt after_scheme '@' with
  | Some idx ->
      ( String.sub after_scheme 0 idx,
        String.sub after_scheme (idx + 1) (String.length after_scheme - idx - 1) )
  | None -> after_scheme, "http://127.0.0.1:9/v1"

let write_partially_invalid_runtime ~base_path ~valid_model =
  let config_root = Filename.concat base_path ".masc/config" in
  mkdir_p config_root;
  let model_id, endpoint = split_custom_model_spec valid_model in
  write_file
    (Filename.concat config_root "runtime.toml")
    (Printf.sprintf
       {|[providers.custom]
protocol = "openai-compatible-http"
endpoint = %S

[models.stable]
api-name = %S
max-context = 128000
tools-support = true

[custom.stable]

[runtime.primary_profile]
members = ["custom.stable"]

[runtime.primary_profile]
tiers = ["primary_profile"]

[runtime.broken_profile]
members = ["missing_provider.fake"]

[runtime.broken_profile]
tiers = ["broken_profile"]

[routes.keeper_turn]
target = "runtime.primary_profile"
|}
       endpoint model_id)

let write_partially_invalid_default_runtime ~base_path ~valid_model =
  let config_root = Filename.concat base_path ".masc/config" in
  mkdir_p config_root;
  let model_id, endpoint = split_custom_model_spec valid_model in
  write_file
    (Filename.concat config_root "runtime.toml")
    (Printf.sprintf
       {|[providers.custom]
protocol = "openai-compatible-http"
endpoint = %S

[models.stable]
api-name = %S
max-context = 128000
tools-support = true

[custom.stable]

[runtime.primary_profile]
members = ["missing_provider.fake"]

[runtime.primary_profile]
tiers = ["primary_profile"]

[runtime.secondary_profile]
members = ["custom.stable"]

[runtime.secondary_profile]
tiers = ["secondary_profile"]

[routes.keeper_turn]
target = "runtime.primary_profile"
|}
       endpoint model_id)

let stop_process pid =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  ignore
    (let rec wait () =
       try Unix.waitpid [] pid
       with
       | Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
       | Unix.Unix_error (Unix.ECHILD, _, _) -> (0, Unix.WEXITED 0)
     in
     wait ())

let json_assoc = function
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "expected JSON object"

let json_string_field name json =
  match List.assoc_opt name (json_assoc json) with
  | Some (`String value) -> value
  | Some _ -> Alcotest.failf "field %s is not a string" name
  | None -> Alcotest.failf "missing field %s" name

let json_bool_field name json =
  match List.assoc_opt name (json_assoc json) with
  | Some (`Bool value) -> value
  | Some _ -> Alcotest.failf "field %s is not a bool" name
  | None -> Alcotest.failf "missing field %s" name

let test_bootstrap_base_path_config_root_copies_shared_seed_but_not_keepers () =
  with_temp_dir "startup-config-bootstrap" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      mkdir_p base_path;
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
      let config_root = Filename.concat base_path ".masc/config" in
      Alcotest.(check bool) "config root created" true (Sys.is_directory config_root);
      Alcotest.(check string) "runtime copied" repo_runtime_toml
        (read_file (Filename.concat config_root "runtime.toml"));
      Alcotest.(check string)
        "model catalog overlay copied"
        repo_model_catalog_overlay_toml
        (read_file (Filename.concat config_root "agent-core-models-overlay.toml"));
      Alcotest.(check bool)
        "legacy full model catalog not copied"
        false
        (Sys.file_exists (Filename.concat config_root "agent-core-models.toml"));
      Alcotest.(check bool) "prompt copied" true
        (Sys.file_exists
           (Filename.concat config_root "prompts/keeper.md"));
      Alcotest.(check bool) "keepers dir created" true
        (Sys.file_exists (Filename.concat config_root "keepers"));
      Alcotest.(check bool) "repo keeper TOML not copied" false
        (Sys.file_exists (Filename.concat config_root "keepers/example.toml")))

let test_bootstrap_base_path_config_root_backfills_missing_prompts_and_overlay () =
  with_temp_dir "startup-config-preserve" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      let config_root = Filename.concat base_path ".masc/config" in
      mkdir_p config_root;
      write_file (Filename.concat config_root "runtime.toml") local_runtime_toml;
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
      Alcotest.(check string) "existing runtime preserved" local_runtime_toml
        (read_file (Filename.concat config_root "runtime.toml"));
      Alcotest.(check bool) "keepers dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "keepers"));
      Alcotest.(check bool) "prompts dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "prompts"));
      Alcotest.(check bool) "versioned keeper not resurrected" false
        (Sys.file_exists (Filename.concat config_root "keepers/example.toml"));
      Alcotest.(check bool) "versioned prompt backfilled" true
        (Sys.file_exists
           (Filename.concat config_root "prompts/keeper.md"));
      Alcotest.(check string) "backfilled prompt content" "prompt"
        (read_file (Filename.concat config_root "prompts/keeper.md"));
      Alcotest.(check string)
        "model catalog overlay backfilled"
        repo_model_catalog_overlay_toml
        (read_file (Filename.concat config_root "agent-core-models-overlay.toml"));
      Alcotest.(check bool)
        "legacy full model catalog not backfilled"
        false
        (Sys.file_exists (Filename.concat config_root "agent-core-models.toml"));
      ())

let test_bootstrap_base_path_config_root_skips_explicit_config_override () =
  with_temp_dir "startup-config-explicit" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      mkdir_p base_path;
      let explicit = Filename.concat dir "override-config" in
      mkdir_p explicit;
      with_env "MASC_CONFIG_DIR" (Some explicit) @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
      Alcotest.(check bool) "base-path config not bootstrapped" false
        (Sys.file_exists (Filename.concat base_path ".masc/config")))

let test_startup_config_resolution_defaults_to_bootstrapped_root () =
  with_temp_dir "startup-config-activate" (fun dir ->
      let base_path = Filename.concat dir "base" in
      let config_root = Filename.concat base_path ".masc/config" in
      mkdir_p (Filename.concat config_root "prompts");
      mkdir_p (Filename.concat config_root "keepers");
      write_file (Filename.concat config_root "runtime.toml") "";
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      let resolution =
        Server_runtime_bootstrap.startup_config_resolution ~base_path
      in
      let expected = config_root in
      Alcotest.(check string) "returns base-path config root" expected
        resolution.Config_dir_resolver.config_root.path;
      Alcotest.(check (option string)) "env remains effectively unset" None
        ((Host_config.from_env ()).config_dir))

let test_startup_config_resolution_preserves_explicit_override () =
  with_temp_dir "startup-config-activate-explicit" (fun dir ->
      let base_path = Filename.concat dir "base" in
      let explicit = Filename.concat dir "custom-config" in
      mkdir_p (Filename.concat base_path ".masc/config");
      mkdir_p explicit;
      with_env "MASC_CONFIG_DIR" (Some explicit) @@ fun () ->
      let resolution =
        Server_runtime_bootstrap.startup_config_resolution ~base_path
      in
      Alcotest.(check string) "explicit override preserved" explicit
        resolution.Config_dir_resolver.config_root.path;
      Alcotest.(check (option string)) "env override unchanged" (Some explicit)
        (Sys.getenv_opt "MASC_CONFIG_DIR"))

let test_bootstrap_base_path_config_root_collapses_masc_input () =
  with_temp_dir "startup-config-collapse" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      mkdir_p (Filename.concat base_path Common.masc_dirname);
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root
        ~base_path:(Filename.concat base_path Common.masc_dirname);
      Alcotest.(check bool) "config root created under parent .masc" true
        (Sys.file_exists (Filename.concat base_path ".masc/config/runtime.toml"));
      Alcotest.(check bool) "nested .masc/.masc config not created" false
        (Sys.file_exists
           (Filename.concat base_path ".masc/.masc/config/runtime.toml")))
let test_config_bootstrap_mode_parses_env () =
  let check expected value =
    with_env "MASC_CONFIG_BOOTSTRAP" value @@ fun () ->
    Alcotest.(check string) (Printf.sprintf "mode for %s" (Option.value ~default:"<unset>" value))
      expected
      (match Server_runtime_bootstrap.config_bootstrap_mode () with
       | `Auto -> "auto" | `Empty -> "empty" | `Skip -> "skip")
  in
  check "auto" None;
  check "auto" (Some "");
  check "auto" (Some "auto");
  check "empty" (Some "empty");
  check "empty" (Some "EMPTY");
  check "skip" (Some "skip");
  check "skip" (Some "SKIP")

let test_bootstrap_empty_mode_creates_scaffold_without_files () =
  with_temp_dir "startup-empty-mode" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      mkdir_p base_path;
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_CONFIG_BOOTSTRAP" (Some "empty") @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
      let config_root = Filename.concat base_path ".masc/config" in
      Alcotest.(check bool) "config root created" true (Sys.is_directory config_root);
      Alcotest.(check bool) "keepers dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "keepers"));
      Alcotest.(check bool) "prompts dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "prompts"));
      Alcotest.(check bool) "runtime not copied" false
        (Sys.file_exists (Filename.concat config_root "runtime.toml"));
      Alcotest.(check bool) "keeper not copied" false
        (Sys.file_exists (Filename.concat config_root "keepers/example.toml")))

let test_bootstrap_skip_mode_creates_nothing () =
  with_temp_dir "startup-skip-mode" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      mkdir_p base_path;
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_CONFIG_BOOTSTRAP" (Some "skip") @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
      let config_root = Filename.concat base_path ".masc/config" in
      Alcotest.(check bool) "config root not created" false
        (Sys.file_exists config_root))

let test_constructor_is_pure () =
  with_temp_dir "startup-pure" (fun dir ->
      let agents_dir = Workspace.agents_dir (Workspace.default_config dir) in
      Fs_compat.mkdir_p agents_dir;
      write_file (Filename.concat agents_dir "alice.json") "{}";
      let state = Mcp_server.For_testing.create_state ~base_path:dir in
      Alcotest.(check int) "constructor does not restore persisted sessions" 0
        (List.length (Session.connected_agents state.Mcp_server.session_registry)))

let test_restore_persisted_sessions_uses_flat_agents_dir () =
  with_temp_dir "startup-scope" (fun dir ->
      let state = Mcp_server.For_testing.create_state ~base_path:dir in
      let agents = Workspace.agents_dir (Mcp_server.workspace_config state) in
      Fs_compat.mkdir_p agents;
      write_file (Filename.concat agents "test-agent.json") "{}";
      Server_runtime_bootstrap.restore_persisted_sessions state;
      let restored =
        Session.connected_agents state.Mcp_server.session_registry |> List.sort String.compare
      in
      Alcotest.(check (list string))
        "restore uses flat agents dir"
        [ "test-agent" ] restored)

let test_keeper_paths_use_cluster_root () =
  with_temp_dir "startup-cluster" (fun dir ->
      with_env "MASC_CLUSTER_NAME" (Some "cluster-alpha") (fun () ->
          let config = Workspace.default_config dir in
          let keeper_dir = Keeper_fs.keeper_dir config in
          let expected_root =
            Filename.concat
              (Filename.concat (Filename.concat dir Common.masc_dirname) "clusters")
              "cluster-alpha"
          in
          Alcotest.(check bool) "keeper dir under cluster root" true
            (String.starts_with ~prefix:expected_root keeper_dir)))

let test_tool_usage_log_uses_cluster_root () =
  with_temp_dir "startup-tool-usage-cluster" (fun dir ->
      with_env "MASC_CLUSTER_NAME" (Some "cluster-alpha") (fun () ->
          Tool_usage_log.init ~base_path:dir ~cluster_name:"cluster-alpha" ();
          Tool_usage_log.log_call
            ~on_io_failure:(fun ~site:_ _ -> ())
            ~tool_name:"keeper_tasks_list"
            ~disposition:(Tool_result.Completed ())
            ~caller:(Some "oracle");
          let expected_dir =
            Filename.concat
              (Filename.concat
                 (Filename.concat (Filename.concat dir Common.masc_dirname) "clusters")
                 "cluster-alpha")
              "tool_usage"
          in
          let legacy_dir =
            Filename.concat (Filename.concat dir Common.masc_dirname) "tool_usage"
          in
          Alcotest.(check bool) "cluster tool_usage dir exists" true
            (Sys.file_exists expected_dir && Sys.is_directory expected_dir);
          Alcotest.(check bool) "legacy tool_usage dir absent" false
            (Sys.file_exists legacy_dir);
          match Tool_usage_log.read_recent ~n:10 () with
          | [ row ] ->
            Alcotest.(check string)
              "tool_usage row preserves disposition"
              "completed"
              Yojson.Safe.Util.(row |> member "disposition" |> to_string);
            Alcotest.(check bool)
              "tool_usage row has no legacy success bool"
              true
              Yojson.Safe.Util.(row |> member "success" = `Null)
          | rows ->
            Alcotest.failf
              "expected one tool_usage row from cluster store, got %d"
              (List.length rows)))

let test_keeper_tool_call_log_uses_cluster_root () =
  with_temp_dir "startup-tool-call-cluster" (fun dir ->
      with_env "MASC_CLUSTER_NAME" (Some "cluster-alpha") (fun () ->
          Keeper_tool_call_log.reset_for_testing ();
          Fun.protect
            ~finally:Keeper_tool_call_log.reset_for_testing
            (fun () ->
              Keeper_tool_call_log.init ~base_path:dir
                ~cluster_name:"cluster-alpha" ();
              Keeper_tool_call_log.log_call
                ~keeper_name:"oracle" ~tool_name:"keeper_tasks_list"
                ~input:(`Assoc []) ~output_text:"ok"
                ~success:true ~duration_ms:1.0 ();
              let expected_dir =
                Filename.concat
                  (Filename.concat
                     (Filename.concat (Filename.concat dir Common.masc_dirname) "clusters")
                     "cluster-alpha")
                  "tool_calls"
              in
              let legacy_dir =
                Filename.concat (Filename.concat dir Common.masc_dirname) "tool_calls"
              in
              Alcotest.(check bool) "cluster tool_calls dir exists" true
                (Sys.file_exists expected_dir && Sys.is_directory expected_dir);
              Alcotest.(check bool) "legacy tool_calls dir absent" false
                (Sys.file_exists legacy_dir);
              Alcotest.(check int) "tool_call row readable from cluster store"
                1
                (List.length (Keeper_tool_call_log.read_recent ~n:10 ())))))

let test_workspace_init_bootstraps_keeper_runtime_dirs () =
  with_temp_dir "startup-keeper-dirs" (fun dir ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:None);
      let root_dir = Workspace.masc_root_dir config in
      let keeper_dir = Filename.concat root_dir "keepers" in
      let traces_dir = Filename.concat root_dir "traces" in
      Alcotest.(check bool) "keeper dir exists" true
        (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir);
      Alcotest.(check bool) "traces dir exists" true
        (Sys.file_exists traces_dir && Sys.is_directory traces_dir))

let test_otel_exporter_setup_failure_is_soft () =
  Otel_spans.shutdown ~enabled:true ();
  let setup_called = ref false in
  let raised =
    try
      Otel_spans.setup_exporter_with ~enabled:true
        ~endpoint:"http://127.0.0.1:4318"
        ~setup:(fun () ->
          setup_called := true;
          failwith "synthetic otel exporter failure")
        ();
      false
    with _ -> true
  in
  Alcotest.(check bool) "setup invoked" true !setup_called;
  Alcotest.(check bool) "failure does not escape" false raised;
  Alcotest.(check bool) "exporter inactive after failure" false
    (Otel_spans.is_exporter_active ());
  Otel_spans.shutdown ~enabled:true ()

let test_otel_exporter_setup_does_not_block_maintenance_wiring () =
  Eio.Switch.run @@ fun sw ->
  let started, resolve_started = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let returned = ref false in
  Server_bootstrap_maintenance.Otel_for_testing.start_exporter_background
    ~sw
    (fun () ->
      Eio.Promise.resolve resolve_started ();
      Eio.Promise.await release);
  returned := true;
  Eio.Promise.await started;
  Alcotest.(check bool)
    "maintenance wiring returns while exporter setup is blocked"
    true
    !returned;
  Eio.Promise.resolve resolve_release ()

let make_keeper_meta_json ?(name = "alpha")
    ?(trace_id = "trace-alpha-live")
    ?(updated_at = "2026-03-29T10:36:57Z") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("trace_id", `String trace_id);
          ("updated_at", `String updated_at);
        ])
  with
  | Ok meta -> Keeper_meta_json.meta_to_json meta |> Yojson.Safe.pretty_to_string
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

let make_keeper_meta ?(paused = false) ?(name = "alpha")
    ?(trace_id = "trace-alpha-live")
    ?(updated_at = "2026-03-29T10:36:57Z") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("trace_id", `String trace_id);
          ("updated_at", `String updated_at);
        ])
  with
  | Ok meta ->
      { meta with paused }
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

let make_task ?(title = "Task") ?(description = "") ~id ~status () : Types.task =
  {
    id;
    title;
    description;
    task_status = status;
    priority = 3;
    files = [];
    created_at = "2026-06-26T00:00:00Z";
    created_by = Some "test";
    predecessor_task_id = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    execution_links = Masc_domain.no_execution_links;
    do_not_reclaim_reason = None;
    skills = [];
  }

let terminal_fixture_epoch = 0.0

let write_keeper_meta_exn config meta =
  match Keeper_meta_store.replace_snapshot config meta with
  | Ok () -> ()
  | Error err -> Alcotest.fail ("keeper meta write failed: " ^ err)

let with_owner_inventory config f =
  Eio.Switch.run @@ fun sw ->
  (match
     Keeper_owner_registry.install_from_store
       ~sw
       ~operation_runner:None
           ~on_turn_slot_released:None
       config
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
  f ()

let with_running_keeper_metas ?(owner_inventory = true) config metas f =
  let base_path = config.Workspace.base_path in
  List.iter
    (fun (meta : Keeper_meta_contract.keeper_meta) ->
      Keeper_registry.For_testing.unregister ~base_path meta.name;
      ignore (Keeper_registry.For_testing.register ~base_path meta.name meta))
    metas;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (meta : Keeper_meta_contract.keeper_meta) ->
          Keeper_registry.For_testing.unregister ~base_path meta.name)
        metas)
    (fun () -> if owner_inventory then with_owner_inventory config f else f ())

let dispatch_keeper_event config (meta : Keeper_meta_contract.keeper_meta) event =
  match
    Keeper_registry.dispatch_event
      ~base_path:config.Workspace.base_path
      meta.name
      event
  with
  | Ok _ -> ()
  | Error err ->
      Alcotest.fail
        ("keeper phase transition failed: "
        ^ Keeper_state_machine.transition_error_to_string err)

let mark_keeper_failing config (meta : Keeper_meta_contract.keeper_meta) =
  dispatch_keeper_event config meta
    (Keeper_state_machine.Turn_failed { consecutive = 1 })

let mark_keeper_stopped config (meta : Keeper_meta_contract.keeper_meta) =
  dispatch_keeper_event config meta Keeper_state_machine.Stop_requested;
  dispatch_keeper_event config meta Keeper_state_machine.Drain_complete


let terminate_keeper_fiber config (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_registry.dispatch_event
      ~base_path:config.Workspace.base_path
      meta.name
      (Keeper_state_machine.Fiber_terminated
         {
           outcome = "stale_turn_timeout(idle_turn(2268s))";
           provider_id = None;
           http_status = None;
         })
  with
  | Ok _ -> ()
  | Error err ->
    Alcotest.fail
      ("keeper fiber termination failed: "
       ^ Keeper_state_machine.transition_error_to_string err)

let mark_keeper_dead_with_registry_cause config
    (meta : Keeper_meta_contract.keeper_meta) =
  let base_path = config.Workspace.base_path in
  Keeper_registry.For_testing.record_restart ~base_path meta.name;
  Keeper_registry.For_testing.record_restart ~base_path meta.name;
  Keeper_registry.set_failure_reason ~base_path meta.name
    (Some
       (Keeper_registry.Provider_runtime_error
          {
            code = "provider_http_500";
            detail =
              Printf.sprintf
                "provider cancelled with sk-testsecret at %s/private/provider.json"
                base_path;
            provider_id = Some "runpod";
            http_status = Some 500;
            runtime_id = Some "runtime-a";
            agent_core_timeout = None;
            reason = None;
          }));
  Keeper_registry.set_last_error_entry ~base_path ~name:meta.name
    (Printf.sprintf
       "synthetic cancelled by parent sk-testsecret at %s/private/state.json"
       base_path);
  Keeper_registry.record_crash ~base_path meta.name 1780000000.0
    (Printf.sprintf
       "synthetic crash record Bearer github_pat_secret at %s/crash.log"
       base_path)

let test_health_json_surfaces_durable_paused_keepers () =
  with_temp_dir "health-durable-paused-keepers" (fun dir ->
      let config_root = make_base_path_config_root dir in
      List.iter
        (write_config_root_keeper_toml config_root)
        [ "durable-paused" ];
      with_explicit_test_config_root config_root @@ fun () ->
      let previous_state = Server_auth.For_testing.snapshot_server_state () in
      Config_dir_resolver.reset ();
      Fun.protect
        ~finally:(fun () ->
          Server_auth.For_testing.restore_server_state @@ previous_state;
          Config_dir_resolver.reset ())
        (fun () ->
          let state = Mcp_server.For_testing.create_state ~base_path:dir in
          Server_auth.For_testing.restore_server_state @@ Some state;
          let config = (Mcp_server.workspace_config state) in
          write_keeper_meta_exn config
            (make_keeper_meta ~name:"durable-paused" ~trace_id:"trace-paused"
               ~paused:true ());
          write_keeper_meta_exn config
            (make_keeper_meta ~name:"durable-active" ~trace_id:"trace-active"
               ~paused:false ());
          let ledger_stimulus : Keeper_event_queue.stimulus =
            { post_id = "health-post-1"
            ; urgency = Immediate
            ; arrived_at = 1234.5
            ; payload =
                Keeper_event_queue.Board_signal
                  { kind = Keeper_event_queue.Post_created
                  ; author = ""
                  ; title = ""
                  ; content = ""
                  ; hearth = None
                  ; updated_at = None
                  }
            }
          in
          Keeper_reaction_ledger.record_event_queue_stimulus
            ~base_path:dir
            ~keeper_name:"durable-active"
            ledger_stimulus;
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let paused = json |> member "paused_keepers" in
          let fd_observation = json |> member "fd_observation" in
          let fd_accountant = json |> member "fd_accountant" in
          let disk_observation = json |> member "disk_observation" in
          let runtime_truth = json |> member "runtime_truth" in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          let publication_recovery =
            json |> member "publication_recovery_activation"
          in
          let reaction_ledger = json |> member "keeper_reaction_ledger" in
          let durable_names =
            paused |> member "durable_names" |> to_list |> List.map to_string
          in
	          let names = paused |> member "names" |> to_list |> List.map to_string in
          Alcotest.(check int) "durable paused count" 1
            (paused |> member "durable_count" |> to_int);
          Alcotest.(check string)
            "pure test state exposes unavailable recovery activation"
            "unavailable"
            (publication_recovery |> member "status" |> to_string);
          Alcotest.(check string)
            "pure test state names its missing runtime"
            "non_runtime_state"
            (publication_recovery |> member "reason" |> to_string);
	          Alcotest.(check int) "registry paused count" 0
	            (paused |> member "registry_paused_count" |> to_int);
	          Alcotest.(check string) "registry paused semantics"
	            "registered keepers whose persisted meta has paused=true; this is not FSM phase=Running"
	            (paused |> member "registry_paused_semantics" |> to_string);
	          Alcotest.(check (list string)) "durable paused names"
	            [ "durable-paused" ] durable_names;
          Alcotest.(check int) "durable paused autoboot count" 1
            (paused |> member "autoboot_enabled_count" |> to_int);
          Alcotest.(check (list string)) "durable paused autoboot names"
            [ "durable-paused" ]
            (paused |> member "autoboot_enabled_names" |> to_list
             |> List.map to_string);
          let paused_details = paused |> member "details" |> to_list in
          let durable_paused_detail =
            paused_details
            |> List.find (fun detail ->
                 detail |> member "name" |> to_string = "durable-paused")
          in
          Alcotest.(check string) "pause kind" "unclassified_paused"
            (durable_paused_detail |> member "pause_kind" |> to_string);
          Alcotest.(check bool) "pause missing root cause" true
            (durable_paused_detail |> member "missing_pause_root_cause" |> to_bool);
          Alcotest.(check bool) "pause detail keeps autoboot" true
            (durable_paused_detail |> member "autoboot_enabled" |> to_bool);
          Alcotest.(check bool) "union includes durable paused keeper" true
            (List.exists (( = ) "durable-paused") names);
          Alcotest.(check bool) "union excludes active durable keeper" false
            (List.exists (( = ) "durable-active") names);
          Alcotest.(check int) "durable read errors" 0
            (paused |> member "read_error_count" |> to_int);
          Alcotest.(check string) "FD surface is observation-only"
            "observation_only"
            (fd_observation |> member "mode" |> to_string);
          ignore (fd_observation |> member "active_keepers" |> to_int);
          ignore (fd_observation |> member "nofile_probe_supported" |> to_bool);
          Alcotest.(check bool) "FD surface has no admission decision" true
            (fd_observation |> member "admission_decision" = `Null);
          Alcotest.(check string) "disk surface is observation-only"
            "observation_only"
            (disk_observation |> member "mode" |> to_string);
          Alcotest.(check bool) "disk surface has no admission decision" true
            (disk_observation |> member "admission" = `Null);
          ignore (fd_accountant |> member "fd_open" |> to_int_option);
          ignore (fd_accountant |> member "fd_limit" |> to_int_option);
          Alcotest.(check string) "runtime truth schema"
            "masc.runtime_truth.v1"
            (runtime_truth |> member "schema" |> to_string);
          Alcotest.(check string) "runtime truth source"
            "running_process"
            (runtime_truth |> member "source" |> to_string);
          Alcotest.(check string) "runtime truth effective base path"
            (canonical_path dir)
            (runtime_truth |> member "effective_base_path" |> to_string |> canonical_path);
          Alcotest.(check string) "runtime truth effective masc root"
            (Filename.concat dir ".masc" |> canonical_path)
            (runtime_truth |> member "effective_masc_root" |> to_string |> canonical_path);
          ignore (runtime_truth |> member "process_cwd" |> to_string);
          ignore (runtime_truth |> member "executable_path" |> to_string);
          ignore (runtime_truth |> member "executable_dir" |> to_string);
          ignore (runtime_truth |> member "keeper_fibers" |> to_int);
          ignore (runtime_truth |> member "fd_open" |> to_int_option);
          ignore (runtime_truth |> member "fd_limit" |> to_int_option);
          let fd_accountant_per_kind =
            fd_accountant |> member "per_kind" |> to_list
          in
          Alcotest.(check int) "health exposes all FD accountant kinds"
            (List.length Fd_accountant.all_kinds)
            (List.length fd_accountant_per_kind);
          List.iter
            (fun kind ->
              let kind_name = Fd_accountant.kind_to_string kind in
              let row =
                fd_accountant_per_kind
                |> List.find (fun row ->
                  String.equal (row |> member "kind" |> to_string) kind_name)
              in
              ignore (row |> member "active_operations" |> to_int))
            Fd_accountant.all_kinds;
          Alcotest.(check int) "health exposes typed FD error series"
            (List.length Fd_accountant.all_kinds
             * List.length Fd_accountant.all_resource_errors)
            (fd_accountant |> member "resource_errors" |> to_list |> List.length);
          Alcotest.(check int) "health exposes bootable keeper count" 1
            (fleet_safety |> member "bootable_keeper_count" |> to_int);
          Alcotest.(check int) "health exposes autoboot keeper count" 1
            (fleet_safety |> member "autoboot_enabled_keeper_count" |> to_int);
          Alcotest.(check int) "health exposes paused autoboot keeper count" 1
            (fleet_safety |> member "paused_autoboot_enabled_keeper_count" |> to_int);
          Alcotest.(check int) "health exposes target reaction capacity" 1
            (fleet_safety |> member "target_reaction_capacity_count" |> to_int);
          Alcotest.(check string) "health marks fleet blocked" "blocked"
            (fleet_safety |> member "status" |> to_string);
          Alcotest.(check string) "health marks fleet blocker"
            "no_executable_keeper_fibers"
            (fleet_safety |> member "blocker" |> to_string);
          Alcotest.(check bool) "health marks no executable fibers" true
            (fleet_safety |> member "no_executable_keeper_fibers" |> to_bool);
          Alcotest.(check bool) "health marks capacity below target" true
            (fleet_safety |> member "reaction_capacity_below_target" |> to_bool);
          Alcotest.(check int) "health exposes capacity shortfall" 1
            (fleet_safety |> member "reaction_capacity_shortfall_count" |> to_int);
          Alcotest.(check bool) "health fleet asks for operator action" true
            (fleet_safety |> member "operator_action_required" |> to_bool);
          Alcotest.(check string) "health reaction ledger degraded"
            "degraded"
            (reaction_ledger |> member "status" |> to_string);
          Alcotest.(check int) "health reaction ledger pending stimuli" 1
            (reaction_ledger |> member "pending_stimulus_count" |> to_int);
          Alcotest.(check bool) "health reaction ledger names pending reason" true
            (reaction_ledger |> member "status_reasons" |> to_list
             |> List.map to_string
             |> List.exists (String.equal "reaction_ledger_pending_stimulus"));
          Alcotest.(check bool)
            "top-level health preserves reaction ledger reason"
            true
            (json |> member "operator_action_reasons" |> to_list
             |> List.map to_string
             |> List.exists
                  (String.equal
                     "keeper_reaction_ledger:reaction_ledger_pending_stimulus"));
          Alcotest.(check bool) "health reaction ledger asks for operator action"
            true
            (reaction_ledger |> member "operator_action_required" |> to_bool)))

let test_health_json_observes_owner_turn () =
  with_temp_dir "health-keeper-owner-work" (fun dir ->
    let config_root = make_config_root dir in
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let keeper_name = "example" in
        let config = Mcp_server.workspace_config state in
        write_keeper_meta_exn
          config
          (make_keeper_meta ~name:keeper_name ~trace_id:"trace-owner-health" ());
        Eio.Switch.run (fun sw ->
          (match
             Keeper_owner_registry.install_from_store
               ~sw
               ~operation_runner:None
           ~on_turn_slot_released:None
               config
           with
           | Ok _ -> ()
           | Error error ->
             Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
          let started, set_started = Eio.Promise.create () in
          let release, set_release = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
            match
              Keeper_owner_registry.run_maintenance_if_idle
                ~base_path:dir
                ~keeper_name
                (fun () ->
                   Eio.Promise.resolve set_started ();
                   Eio.Promise.await release)
            with
            | Ok (`Ran ()) -> ()
            | Ok (`Busy _) -> Alcotest.fail "free Owner must admit"
            | Error error ->
              Alcotest.fail (Keeper_owner_registry.command_error_to_string error));
          Eio.Promise.await started;
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let owner = json |> member "keeper_owner" in
          Alcotest.(check string) "in-flight Owner is not health degradation"
            "ok"
            (owner |> member "status" |> to_string);
          Alcotest.(check int) "Owner exposes one in-flight Keeper"
            1
            (owner |> member "in_flight_keeper_count" |> to_int);
          Alcotest.(check bool)
            "in-flight work does not require an operator"
            false
            (owner |> member "operator_action_required" |> to_bool);
          let runtime_resolution =
            `Assoc
              (Server_routes_http_runtime.keeper_fleet_runtime_resolution_fields ())
          in
          let runtime_owner =
            runtime_resolution |> member "keeper_owner"
          in
          Alcotest.(check bool)
            "runtime resolution exposes Owner"
            true
            (runtime_owner |> member "schema" |> to_string = "masc.keeper_owner.v1");
          let light_runtime_resolution =
            `Assoc
              (Server_routes_http_runtime.keeper_fleet_runtime_resolution_light_fields ())
          in
          let light_runtime_owner =
            light_runtime_resolution |> member "keeper_owner"
          in
          Alcotest.(check bool)
            "light runtime resolution exposes Owner"
            true
            (light_runtime_owner |> member "schema" |> to_string = "masc.keeper_owner.v1");
          Eio.Promise.resolve set_release ())))

let test_health_json_surfaces_board_event_collection_failure () =
  with_temp_dir "health-board-event-collection-failure" (fun dir ->
    let config_root = make_config_root dir in
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Keeper_heartbeat_loop_board_events.For_testing.reset ();
    Fun.protect
      ~finally:(fun () ->
        Keeper_heartbeat_loop_board_events.For_testing.reset ();
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let keeper_name = "example" in
        Keeper_heartbeat_loop_board_events.For_testing.record_collection_failure
          ~base_path:dir
          ~keeper_name
          ~message:"board event store unavailable";
        let request = Httpun.Request.create `GET "/health" in
        let json = Server_routes_http_runtime.make_health_json request in
        let open Yojson.Safe.Util in
        let collection = json |> member "keeper_board_event_collection" in
        Alcotest.(check string) "board collection health degraded"
          "degraded"
          (collection |> member "status" |> to_string);
        Alcotest.(check int) "board collection failure count"
          1
          (collection |> member "failure_count" |> to_int);
        Alcotest.(check bool) "board collection failure reason surfaced"
          true
          (collection |> member "status_reasons" |> to_list
           |> List.map to_string
           |> List.exists (String.equal "board_event_collection_failure"));
        Alcotest.(check bool)
          "top-level health preserves board collection failure reason"
          true
          (json |> member "operator_action_reasons" |> to_list
           |> List.map to_string
           |> List.exists
                (String.equal
                   "keeper_board_event_collection:board_event_collection_failure"));
        let runtime_resolution =
          `Assoc
            (Server_routes_http_runtime.keeper_fleet_runtime_resolution_fields ())
        in
        let runtime_collection =
          runtime_resolution |> member "keeper_board_event_collection"
        in
        Alcotest.(check int)
          "runtime resolution exposes board collection failure count"
          1
          (runtime_collection |> member "failure_count" |> to_int);
        let light_runtime_resolution =
          `Assoc
            (Server_routes_http_runtime.keeper_fleet_runtime_resolution_light_fields ())
        in
        let light_runtime_collection =
          light_runtime_resolution |> member "keeper_board_event_collection"
        in
        Alcotest.(check int)
          "light runtime resolution exposes board collection failure count"
          1
          (light_runtime_collection |> member "failure_count" |> to_int)))

let test_keeper_identity_drift_health_json_surfaces_config_meta_split () =
  with_temp_dir "keeper-identity-drift" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    write_config_root_keeper_toml config_root "mad-improver";
    write_file
      (Filename.concat (Filename.concat config_root "keepers") "operator.toml")
      "[keeper]\ninstructions = \"test keeper\"\nautoboot_enabled = false\n";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        write_keeper_meta_exn config
          (make_keeper_meta ~name:"omicron-improver" ~trace_id:"trace-omicron-improver" ());
        write_keeper_meta_exn config
          (make_keeper_meta ~name:"operator" ~trace_id:"trace-operator" ());
        let json =
          Server_routes_http_runtime_fleet_scan.keeper_identity_drift_health_json
            config
        in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "drift schema" "masc.keeper_identity_drift.v1"
          (json |> member "schema" |> to_string);
        Alcotest.(check string) "drift status" "blocked"
          (json |> member "status" |> to_string);
        Alcotest.(check bool) "drift blocks on stale meta" true
          (json |> member "blocking" |> to_bool);
        Alcotest.(check string) "drift terminal reason"
          "runtime_meta_without_keeper_toml"
          (json |> member "terminal_reason" |> to_string);
        Alcotest.(check bool) "drift asks operator action" true
          (json |> member "operator_action_required" |> to_bool);
        Alcotest.(check (list string)) "configured names include disabled keepers"
          [ "mad-improver"; "operator" ]
          (json |> member "configured_keeper_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list string)) "materializable configured names"
          [ "mad-improver" ]
          (json |> member "materializable_configured_keeper_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list string)) "persisted meta includes disabled keeper"
          [ "omicron-improver"; "operator" ]
          (json |> member "persisted_meta_names" |> to_list |> List.map to_string);
        Alcotest.(check (list string)) "configured without meta"
          [ "mad-improver" ]
          (json |> member "configured_without_meta_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list string)) "meta without config"
          [ "omicron-improver" ]
          (json |> member "meta_without_config_names" |> to_list
           |> List.map to_string);
        Alcotest.(check string) "drift next action"
          "add_matching_keeper_toml_or_retire_stale_meta"
          (json |> member "next_action" |> to_string);
        let request = Httpun.Request.create `GET "/health" in
        let health = Server_routes_http_runtime.make_health_json request in
        Alcotest.(check string) "health exposes drift status" "blocked"
          (health |> member "keeper_identity_drift" |> member "status"
           |> to_string)))

let test_keeper_identity_drift_treats_explicit_autoboot_base_as_materializable
    () =
  with_temp_dir "keeper-identity-drift-base-autoboot" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    write_file
      (Filename.concat (Filename.concat config_root "keepers") "base.toml")
      "[keeper]\nautoboot_enabled = true\n";
    write_keeper_instructions
      (Filename.concat config_root "keepers")
      "base"
      "default keeper\n";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        write_keeper_meta_exn config
          (make_keeper_meta ~name:"base" ~trace_id:"trace-base" ());
        let json =
          Server_routes_http_runtime_fleet_scan.keeper_identity_drift_health_json
            config
        in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "drift status" "ok"
          (json |> member "status" |> to_string);
        Alcotest.(check bool) "base meta does not block drift" false
          (json |> member "blocking" |> to_bool);
        Alcotest.(check (list string)) "materializable configured names"
          [ "base" ]
          (json |> member "materializable_configured_keeper_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list string)) "meta without config"
          []
          (json |> member "meta_without_config_names" |> to_list
           |> List.map to_string)))

let test_health_json_reports_unclassified_timeout_pause_without_mutation () =
  with_temp_dir "health-timeout-paused-without-policy" (fun dir ->
    let config_root = make_config_root dir in
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = (Mcp_server.workspace_config state) in
        let timeout_paused =
          make_keeper_meta
            ~name:"timeout-without-policy"
            ~trace_id:"trace-timeout-without-policy"
            ~paused:true
            ()
        in
        write_keeper_meta_exn config timeout_paused;
        let request = Httpun.Request.create `GET "/health" in
        let json = Server_routes_http_runtime.make_health_json request in
        let open Yojson.Safe.Util in
        let paused_details =
          json |> member "paused_keepers" |> member "details" |> to_list
        in
        let detail =
          paused_details
          |> List.find (fun row ->
               row |> member "name" |> to_string = "timeout-without-policy")
        in
        Alcotest.(check string) "pause kind" "unclassified_paused"
          (detail |> member "pause_kind" |> to_string)))

let test_health_json_reports_dormant_task_owner_as_advisory () =
  with_temp_dir "health-active-task-owner-without-fiber" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    write_file
      (Filename.concat (Filename.concat config_root "keepers") "omega.toml")
      "[keeper]\nautoboot_enabled = false\n";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        let executor =
          make_keeper_meta ~name:"omega" ~trace_id:"trace-omega" ()
        in
        write_keeper_meta_exn config executor;
        let task =
          make_task
            ~id:"task-active-owner"
            ~title:"Active keeper task"
            ~status:
              (Types.InProgress
                 {
                   assignee = executor.Keeper_meta_contract.name;
                   started_at = "2026-06-26T00:00:01Z";
                 })
            ()
        in
        Workspace.write_backlog config
          { Types.tasks = [ task ]; last_updated = "2026-06-26T00:00:02Z"; version = 2 };
        let request = Httpun.Request.create `GET "/health" in
        let json = Server_routes_http_runtime.make_health_json request in
        let open Yojson.Safe.Util in
        let fleet_safety = json |> member "keeper_fleet_safety" in
        Alcotest.(check int) "health keeps autoboot target empty" 0
          (fleet_safety |> member "target_reaction_capacity_count" |> to_int);
        Alcotest.(check bool) "health does not report target no-executable" false
          (fleet_safety |> member "no_executable_keeper_fibers" |> to_bool);
        Alcotest.(check string) "health keeps dormant task owner advisory"
          "ok"
          (fleet_safety |> member "status" |> to_string);
        Alcotest.(check (option string)) "health keeps blocker empty" None
          (fleet_safety |> member "blocker" |> to_string_option);
        Alcotest.(check bool) "health excludes non-target dormant owner" false
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber"
           |> to_bool);
        Alcotest.(check int) "health exposes no non-target owner rows" 0
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_count"
           |> to_int);
        Alcotest.(check (list string)) "health exposes no dormant owner names"
          []
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_names"
           |> to_list
           |> List.map to_string);
        let dormant_tasks =
          fleet_safety
          |> member "active_task_owner_without_executable_fiber_tasks"
          |> to_list
        in
        Alcotest.(check int) "health exposes no dormant owner task row" 0
          (List.length dormant_tasks);
        Alcotest.(check string) "health documents active owner scan semantics"
          Server_routes_http_runtime_fleet_scan.active_task_owner_fiber_scan_semantics
          (fleet_safety |> member "active_task_owner_fiber_scan_semantics" |> to_string);
        Alcotest.(check int) "health has no scan errors" 0
          (fleet_safety |> member "active_task_owner_scan_error_count" |> to_int);
        Alcotest.(check bool) "health does not ask fleet operator action" false
          (fleet_safety |> member "operator_action_required" |> to_bool)))

let test_health_json_keeps_awaiting_verification_in_system_llm_lane () =
  with_temp_dir "health-awaiting-verification-system-llm" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        let task =
          make_task
            ~id:"task-awaiting-system-llm-verdict"
            ~title:"Task awaiting system LLM completion verdict"
            ~status:
              (Types.AwaitingVerification
                 {
                   assignee = "producer-agent";
                   started_at = "2026-06-26T00:00:00Z";
                   submitted_at = "2026-06-26T00:00:01Z";
                   verification_id = "verification-system-llm-001";
                 })
            ()
        in
        Workspace.write_backlog config
          { Types.tasks = [ task ]; last_updated = "2026-06-26T00:00:02Z"; version = 2 };
        let phase_counts :
            Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
          { running = 0; failing = 0; recovering = 0 }
        in
        let phase_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
          {
            counts = phase_counts;
            running_names = [];
            recovering_names = [];
            configuration_blocked_names = [];
            phase_values = [];
            phase_details = [];
          }
        in
        let execution_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_execution_snapshot =
          { owners = []; executable_names = [] }
        in
        let fleet_safety =
          Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
            ~bootable_names:[]
            ~autoboot_scan:
              Server_routes_http_runtime_fleet_scan.empty_autoboot_keeper_scan
            ~phase_snapshot
            ~execution_snapshot
            ~phase_counts
            ~paused_keepers_json:(`Assoc [ ("count", `Int 0) ])
            ()
        in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "pending verdict does not degrade Keeper fleet"
          "ok"
          (fleet_safety |> member "status" |> to_string);
        Alcotest.(check (option string)) "pending verdict is not a Keeper blocker"
          None
          (fleet_safety |> member "blocker" |> to_string_option);
        Alcotest.(check bool) "pending verdict is absent from Keeper blocker flag"
          false
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber"
           |> to_bool);
        Alcotest.(check int) "pending verdict has no Keeper blocker rows" 0
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_count"
           |> to_int);
        Alcotest.(check bool) "system LLM pending flag" true
          (fleet_safety |> member "completion_authority_pending" |> to_bool);
        Alcotest.(check int) "one completion authority pending row" 1
          (fleet_safety
           |> member "completion_authority_pending_task_count"
           |> to_int);
        let pending_tasks =
          fleet_safety |> member "completion_authority_pending_tasks" |> to_list
        in
        Alcotest.(check int) "one exact pending task row" 1
          (List.length pending_tasks);
        let pending_task = List.hd pending_tasks in
        Alcotest.(check string) "pending row preserves producer"
          "producer-agent"
          (pending_task |> member "producer_agent_name" |> to_string);
        Alcotest.(check string) "pending row preserves task id"
          "task-awaiting-system-llm-verdict"
          (pending_task |> member "task_id" |> to_string);
        Alcotest.(check string) "pending row preserves submission time"
          "2026-06-26T00:00:01Z"
          (pending_task |> member "submitted_at" |> to_string);
        let pending_task_fields =
          match pending_task with
          | `Assoc fields -> fields
          | _ -> Alcotest.fail "pending task row must be a JSON object"
        in
        Alcotest.(check bool) "pending row does not duplicate status"
          false
          (List.mem_assoc "task_status" pending_task_fields);
        Alcotest.(check string) "pending row preserves verification id"
          "verification-system-llm-001"
          (pending_task |> member "verification_id" |> to_string);
        Alcotest.(check string) "pending row identifies system LLM authority"
          "system_llm_completion_authority"
          (pending_task |> member "owner_kind" |> to_string);
        Alcotest.(check bool) "pending row cannot block Keeper fleet" false
          (pending_task |> member "fleet_blocking" |> to_bool);
        Alcotest.(check bool) "pending verdict does not ask Keeper operator action"
          false
          (fleet_safety |> member "operator_action_required" |> to_bool)))
let test_health_json_reports_non_keeper_active_task_owner_as_advisory () =
  with_temp_dir "health-non-keeper-active-task-owner" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        let assignee = "codex-mcp-client" in
        (match
           Auth.save_raw_token_credential
             config.Workspace_utils_backend_setup.base_path
             ~agent_name:assignee ~role:Masc_domain.Worker
             ~raw_token:"codex-mcp-client-token"
         with
        | Ok _ -> ()
        | Error err ->
            Alcotest.failf "failed to seed external client credential: %s"
              (Masc_domain.masc_error_to_string err));
        let task =
          make_task
            ~id:"task-external-owner"
            ~title:"External client-owned task"
            ~status:
              (Types.InProgress
                 { assignee; started_at = "2026-06-26T00:00:01Z" })
            ()
        in
        Workspace.write_backlog config
          { Types.tasks = [ task ]; last_updated = "2026-06-26T00:00:02Z"; version = 2 };
        let request = Httpun.Request.create `GET "/health" in
        let json = Server_routes_http_runtime.make_health_json request in
        let open Yojson.Safe.Util in
        let fleet_safety = json |> member "keeper_fleet_safety" in
        Alcotest.(check string) "health ignores external client task owner"
          "ok"
          (fleet_safety |> member "status" |> to_string);
        Alcotest.(check (option string)) "health has no blocker" None
          (fleet_safety |> member "blocker" |> to_string_option);
        Alcotest.(check bool) "external client owner is not a keeper blocker" false
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber"
           |> to_bool);
        Alcotest.(check int) "health exposes no blocking owner rows" 0
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_count"
           |> to_int);
        Alcotest.(check int) "health exposes one advisory owner row" 1
          (fleet_safety |> member "non_keeper_active_task_owner_count" |> to_int);
        let owners =
          fleet_safety |> member "non_keeper_active_task_owners" |> to_list
        in
        Alcotest.(check int) "one advisory owner row" 1 (List.length owners);
        let owner = List.hd owners in
        Alcotest.(check string) "advisory row agent" assignee
          (owner |> member "agent_name" |> to_string);
        Alcotest.(check string) "advisory row task id" "task-external-owner"
          (owner |> member "task_id" |> to_string);
        Alcotest.(check string) "advisory row owner kind" "non_keeper_client"
          (owner |> member "owner_kind" |> to_string);
        Alcotest.(check bool) "advisory row does not block fleet" false
          (owner |> member "fleet_blocking" |> to_bool);
        Alcotest.(check (list string)) "health has no blocked keeper names"
          []
          (keepers_not_running fleet_safety);
        Alcotest.(check bool) "health does not ask operator action" false
          (fleet_safety |> member "operator_action_required" |> to_bool)))

let test_health_json_preserves_active_task_owner_meta_read_error () =
  with_temp_dir "health-active-task-owner-meta-read-error" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    write_config_root_keeper_toml config_root "broken";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        write_file (Keeper_types_profile.keeper_meta_path config "broken")
          "{ invalid keeper meta";
        let assignee = "keeper-broken-agent" in
        let task =
          make_task
            ~id:"task-active-owner-corrupt-meta"
            ~title:"Active keeper task with unreadable keeper meta"
            ~status:
              (Types.InProgress
                 { assignee; started_at = "2026-06-26T00:00:01Z" })
            ()
        in
        Workspace.write_backlog config
          { Types.tasks = [ task ]; last_updated = "2026-06-26T00:00:02Z"; version = 2 };
        let phase_counts :
            Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
          { running = 0; failing = 0; recovering = 0 }
        in
        let phase_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
          {
            counts = phase_counts;
            running_names = [];
            recovering_names = [];
            configuration_blocked_names = [];
            phase_values = [];
            phase_details = [];
          }
        in
        let execution_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_execution_snapshot =
          { owners = []; executable_names = [] }
        in
        let fleet_safety =
          Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
            ~bootable_names:[]
            ~autoboot_scan:
              Server_routes_http_runtime_fleet_scan.empty_autoboot_keeper_scan
            ~phase_snapshot
            ~execution_snapshot
            ~phase_counts
            ~paused_keepers_json:(`Assoc [ ("count", `Int 0) ])
            ()
        in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "health leaves incomplete owner scan non-degraded"
          "ok"
          (fleet_safety |> member "status" |> to_string);
        Alcotest.(check bool) "health does not reinterpret read error as owner gap"
          false
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber"
           |> to_bool);
        Alcotest.(check int) "health has no active owner task rows" 0
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_count"
           |> to_int);
        Alcotest.(check int) "health preserves active owner scan error" 1
          (fleet_safety |> member "active_task_owner_scan_error_count" |> to_int);
        Alcotest.(check (list string)) "health records broken keeper scan error"
          [ "broken" ]
          (fleet_safety |> member "active_task_owner_scan_errors" |> to_list
           |> List.map (fun row -> row |> member "source" |> to_string));
        Alcotest.(check bool) "health does not ask action for incomplete scan"
          false
          (fleet_safety |> member "operator_action_required" |> to_bool)))

let test_health_json_degrades_recovery_backed_owner_scan () =
  with_temp_dir "health-recovery-backed-owner-scan" (fun dir ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () -> Server_auth.For_testing.restore_server_state @@ previous_state)
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        Workspace.write_backlog config
          {
            Types.tasks = [];
            last_updated = "2026-08-03T00:00:00Z";
            version = 1;
          };
        write_file (Workspace.backlog_path config) "{ invalid backlog";
        let phase_counts :
            Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
          { running = 0; failing = 0; recovering = 0 }
        in
        let execution_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_execution_snapshot =
          { owners = []; executable_names = [] }
        in
        let fleet_safety =
          Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
            ~bootable_names:[]
            ~autoboot_scan:
              Server_routes_http_runtime_fleet_scan.empty_autoboot_keeper_scan
            ~execution_snapshot
            ~phase_counts
            ~paused_keepers_json:(`Assoc [ ("count", `Int 0) ])
            ()
        in
        let open Yojson.Safe.Util in
        Alcotest.(check string)
          "recovery-backed observation degrades fleet health"
          "degraded"
          (fleet_safety |> member "status" |> to_string);
        Alcotest.(check int)
          "recovery-backed observation records one scan error"
          1
          (fleet_safety |> member "active_task_owner_scan_error_count" |> to_int);
        let errors =
          fleet_safety |> member "active_task_owner_scan_errors" |> to_list
        in
        Alcotest.(check (list string))
          "recovery provenance identifies backlog"
          [ "backlog" ]
          (List.map (fun row -> row |> member "source" |> to_string) errors);
        Alcotest.(check bool)
          "recovery provenance names the snapshot"
          true
          (errors
           |> List.hd
           |> member "error"
           |> to_string
           |> fun error -> String_util.contains_substring error "observing recovery snapshot")))

let test_health_json_reuses_canonical_owner_execution_snapshot () =
  with_temp_dir "health-canonical-owner-execution-snapshot" (fun dir ->
    let config_root = make_base_path_config_root dir in
    write_config_root_keeper_toml
      ~autoboot_enabled:false
      config_root
      "canonical-meta-disabled";
    with_explicit_test_config_root config_root @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        let cached_missing =
          make_keeper_meta
            ~name:"canonical-meta-missing"
            ~trace_id:"trace-canonical-meta-missing"
            ()
        in
        let cached_disabled =
          make_keeper_meta
            ~name:"canonical-meta-disabled"
            ~trace_id:"trace-canonical-meta-disabled"
            ()
        in
        let paused =
          make_keeper_meta
            ~paused:true
            ~name:"canonical-meta-paused"
            ~trace_id:"trace-canonical-meta-paused"
            ()
        in
        let cached_owners = [ cached_missing; cached_disabled; paused ] in
        List.iter
          (fun (meta : Keeper_meta_contract.keeper_meta) ->
            Keeper_registry.For_testing.unregister
              ~base_path:config.Workspace.base_path
              meta.name;
            ignore
              (Keeper_registry.register_offline
                 ~base_path:config.Workspace.base_path
                 meta.name
                 meta);
            Keeper_event_queue_persistence.persist
              ~base_path:config.Workspace.base_path
              ~keeper_name:meta.name
              Keeper_event_queue.empty)
          cached_owners;
        Fun.protect
          ~finally:(fun () ->
            List.iter
              (fun (meta : Keeper_meta_contract.keeper_meta) ->
                Keeper_registry.For_testing.unregister
                  ~base_path:config.Workspace.base_path
                  meta.name)
              cached_owners)
          (fun () ->
            write_keeper_meta_exn
              config
              { cached_disabled with autoboot_enabled = false };
            write_keeper_meta_exn config paused;
            with_owner_inventory config (fun () ->
            let missing_meta_path =
              Keeper_types_profile.keeper_meta_path config cached_missing.name
            in
            if Sys.file_exists missing_meta_path then Sys.remove missing_meta_path;
            let request = Httpun.Request.create `GET "/health" in
            let json = Server_routes_http_runtime.make_health_json request in
            let open Yojson.Safe.Util in
            let fleet_safety = json |> member "keeper_fleet_safety" in
            Alcotest.(check int)
              "offline cached registry owners are not running"
              0
              (fleet_safety |> member "running_keeper_fiber_count" |> to_int);
            Alcotest.(check int)
              "durable missing/disabled owners are not executable"
              0
              (fleet_safety |> member "executable_keeper_fiber_count" |> to_int);
            Alcotest.(check (list string))
              "canonical execution snapshot exposes no executable names"
              []
              (fleet_safety
               |> member "executable_keeper_names"
               |> to_list
               |> List.map to_string);
            let queue_owners =
              json
              |> member "keeper_event_queue"
              |> member "keepers"
              |> to_list
            in
            let owner name =
              List.find
                (fun row ->
                  String.equal
                    (row |> member "keeper_name" |> to_string)
                    name)
                queue_owners
            in
            Alcotest.(check string)
              "missing durable meta stays owner-local unknown"
              "unclassified"
              (owner cached_missing.name
               |> member "owner_lifecycle"
               |> to_string);
            Alcotest.(check string)
              "durable disabled meta overrides cached enabled registry meta"
              "retained_disabled"
              (owner cached_disabled.name
               |> member "owner_lifecycle"
               |> to_string);
            Alcotest.(check string)
              "paused durable owner remains a distinct retained variant"
              "paused_dead"
              (owner paused.name |> member "owner_lifecycle" |> to_string)))))
;;

let test_health_json_capacity_uses_execution_snapshot () =
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () -> Server_auth.For_testing.restore_server_state @@ previous_state)
    (fun () ->
      Server_auth.For_testing.restore_server_state @@ None;
      let running_names = [ "running-a"; "running-b"; "running-c" ] in
      let recovering_names =
        [ "recovering-a"; "recovering-b"; "recovering-c"; "recovering-d" ]
      in
      let target_names = running_names @ recovering_names in
      let phase_counts :
          Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
        { running = 3; failing = 4; recovering = 4 }
      in
      let phase_snapshot :
          Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
        { counts = phase_counts
        ; running_names
        ; recovering_names
        ; configuration_blocked_names = []
        ; phase_values = []
        ; phase_details = []
        }
      in
      let execution_snapshot :
          Server_routes_http_runtime_fleet_scan.keeper_execution_snapshot =
        { owners = []; executable_names = [ "running-a" ] }
      in
      let fleet_safety =
        Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
          ~bootable_names:target_names
          ~autoboot_scan:
            { autoboot_names = target_names; read_errors = [] }
          ~phase_snapshot
          ~execution_snapshot
          ~phase_counts
          ~paused_keepers_json:(`Assoc [ ("count", `Int 0) ])
          ()
      in
      let open Yojson.Safe.Util in
      Alcotest.(check int)
        "canonical capacity comes only from the execution snapshot"
        1
        (fleet_safety |> member "executable_keeper_fiber_count" |> to_int);
      Alcotest.(check int)
        "phase counts do not conceal executable shortfall"
        6
        (fleet_safety |> member "reaction_capacity_shortfall_count" |> to_int);
      Alcotest.(check bool)
        "capacity verdict uses executable truth"
        true
        (fleet_safety |> member "reaction_capacity_below_target" |> to_bool);
      Alcotest.(check string)
        "partial executable capacity degrades the fleet"
        "degraded"
        (fleet_safety |> member "status" |> to_string);
      Alcotest.(check bool)
        "partial executable capacity requires operator action"
        true
        (fleet_safety |> member "operator_action_required" |> to_bool))
;;

let test_health_json_keeps_in_flight_running_keeper_executable () =
  with_temp_dir "health-in-flight-running-executable" (fun dir ->
    let config_root = make_config_root dir in
    let keeper_name = "in-flight-running" in
    write_config_root_keeper_toml config_root keeper_name;
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        let meta =
          make_keeper_meta
            ~name:keeper_name
            ~trace_id:"trace-in-flight-running"
            ()
          |> fun meta ->
          { meta with
            autoboot_enabled = true
          ; proactive = { enabled = true }
          }
        in
        write_keeper_meta_exn config meta;
        with_running_keeper_metas ~owner_inventory:false config [ meta ] (fun () ->
          Eio.Switch.run (fun sw ->
          (match
             Keeper_owner_registry.install_from_store
               ~sw
               ~operation_runner:None
           ~on_turn_slot_released:None
               config
           with
           | Ok _ -> ()
           | Error error ->
             Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
          match
            Keeper_owner_registry.run_maintenance_if_idle
              ~base_path:dir
              ~keeper_name
              (fun () ->
                let execution_snapshot =
                  Server_routes_http_runtime_fleet_scan.keeper_execution_snapshot
                    config
                in
                let phase_snapshot =
                  Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot
                    ~base_path:dir
                    ()
                in
                Server_routes_http_runtime_fleet_scan
                .keeper_fleet_safety_health_json
                  ~bootable_names:[ keeper_name ]
                  ~autoboot_scan:
                    { autoboot_names = [ keeper_name ]; read_errors = [] }
                  ~phase_snapshot
                  ~execution_snapshot
                  ~base_path:dir
                  ~phase_counts:phase_snapshot.counts
                  ~paused_keepers_json:(`Assoc [ ("count", `Int 0) ])
                  ())
          with
          | Error error ->
            Alcotest.fail (Keeper_owner_registry.command_error_to_string error)
          | Ok (`Busy _) -> Alcotest.fail "test Keeper Owner was busy"
          | Ok (`Ran fleet_safety) ->
            let open Yojson.Safe.Util in
            Alcotest.(check int) "in-flight Keeper remains executable" 1
              (fleet_safety |> member "executable_keeper_fiber_count" |> to_int);
            Alcotest.(check bool) "in-flight Keeper needs no operator action" false
              (fleet_safety |> member "operator_action_required" |> to_bool);
            Alcotest.(check (list string)) "in-flight Keeper is running" []
              (keepers_not_running fleet_safety)))))

let test_health_json_blocked_count_matches_blocked_names_with_non_target_capacity () =
  with_temp_dir "health-blocked-count-non-target-capacity" (fun dir ->
    let config_root = make_base_path_config_root dir in
    List.iter
      (write_config_root_keeper_toml config_root)
      [ "target-missing"; "target-running" ];
    with_explicit_test_config_root config_root @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = Mcp_server.workspace_config state in
        let target_running =
          make_keeper_meta ~name:"target-running" ~trace_id:"trace-target-running" ()
        in
        let target_missing =
          make_keeper_meta ~name:"target-missing" ~trace_id:"trace-target-missing" ()
        in
        let non_target_running =
          make_keeper_meta
            ~name:"non-target-running"
            ~trace_id:"trace-non-target-running"
            ()
          |> fun meta -> { meta with proactive = { enabled = false } }
        in
        List.iter
          (write_keeper_meta_exn config)
          [ target_running; target_missing; non_target_running ];
        with_running_keeper_metas config [ target_running; non_target_running ]
          (fun () ->
            let request = Httpun.Request.create `GET "/health" in
            let json = Server_routes_http_runtime.make_health_json request in
            let open Yojson.Safe.Util in
            let fleet_safety = json |> member "keeper_fleet_safety" in
            Alcotest.(check int)
              "proactive-disabled Running keeper counts as reaction capacity"
              2
              (fleet_safety |> member "executable_keeper_fiber_count" |> to_int);
            Alcotest.(check int) "capacity shortfall remains numeric capacity" 1
              (fleet_safety |> member "reaction_capacity_shortfall_count" |> to_int);
            Alcotest.(check (list string)) "health names blocked target keepers"
              [ "example"; "target-missing" ]
              (keepers_not_running fleet_safety);
            Alcotest.(check int) "count matches the names not running" 2
              (List.length (keepers_not_running fleet_safety)))))

let test_health_json_distinguishes_failing_executable_keepers () =
  with_temp_dir "health-failing-executable-keepers" (fun dir ->
    let config_root = make_base_path_config_root dir in
    List.iter
      (write_config_root_keeper_toml config_root)
      [ "capacity-paused"; "capacity-failing" ];
    with_explicit_test_config_root config_root @@ fun () ->
    let previous_state = Server_auth.For_testing.snapshot_server_state () in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.For_testing.restore_server_state @@ previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.For_testing.create_state ~base_path:dir in
        Server_auth.For_testing.restore_server_state @@ Some state;
        let config = (Mcp_server.workspace_config state) in
        let paused =
          make_keeper_meta ~name:"capacity-paused" ~trace_id:"trace-capacity-paused"
            ~paused:true ()
        in
        let failing =
          make_keeper_meta ~name:"capacity-failing"
            ~trace_id:"trace-capacity-failing" ()
        in
        List.iter (write_keeper_meta_exn config) [ paused; failing ];
        with_running_keeper_metas config [ failing ] (fun () ->
          mark_keeper_failing config failing;
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          Alcotest.(check int) "health exposes failing keeper fibers" 1
            (fleet_safety |> member "failing_keeper_fiber_count" |> to_int);
          Alcotest.(check int) "health exposes executable keeper fibers" 1
            (fleet_safety |> member "executable_keeper_fiber_count" |> to_int);
          Alcotest.(check (list string)) "health exposes recovering keeper names"
            [ "capacity-failing" ]
            (fleet_safety |> member "recovering_keeper_names" |> to_list
             |> List.map to_string);
          Alcotest.(check (list string)) "health exposes executable keeper names"
            [ "capacity-failing" ]
            (fleet_safety |> member "executable_keeper_names" |> to_list
             |> List.map to_string);
          Alcotest.(check bool) "health does not mark no executable fibers" false
            (fleet_safety |> member "no_executable_keeper_fibers" |> to_bool);
          Alcotest.(check string) "health marks degraded not blocked" "degraded"
            (fleet_safety |> member "status" |> to_string);
          Alcotest.(check string) "health marks executable shortfall blocker"
            "reaction_capacity_below_target"
            (fleet_safety |> member "blocker" |> to_string);
          Alcotest.(check bool) "health still asks for operator action" true
            (fleet_safety |> member "operator_action_required" |> to_bool))))

let test_health_json_blocks_terminal_configuration_failures () =
  let keeper_name = "config-failing" in
  let phase_counts : Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
    { running = 0; failing = 1; recovering = 1 }
  in
  let phase_snapshot : Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
    { counts = phase_counts
    ; running_names = []
    ; recovering_names = [ keeper_name ]
    ; configuration_blocked_names = [ keeper_name ]
    ; phase_values = [ keeper_name, Keeper_state_machine.Failing ]
    ; phase_details = []
    }
  in
  let execution_snapshot :
      Server_routes_http_runtime_fleet_scan.keeper_execution_snapshot =
    { owners = []; executable_names = [ keeper_name ] }
  in
  let fleet_safety =
    Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
      ~bootable_names:[ keeper_name ]
      ~autoboot_scan:{ autoboot_names = [ keeper_name ]; read_errors = [] }
      ~phase_snapshot
      ~execution_snapshot
      ~phase_counts
      ~paused_keepers_json:(`Assoc [ "count", `Int 0 ])
      ()
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "failing fiber remains visible" 1
    (fleet_safety |> member "failing_keeper_fiber_count" |> to_int);
  Alcotest.(check int) "executable fiber remains visible" 1
    (fleet_safety |> member "executable_keeper_fiber_count" |> to_int);
  Alcotest.(check int) "configuration blocker count" 1
    (fleet_safety |> member "configuration_blocked_keeper_count" |> to_int);
  Alcotest.(check (list string))
    "configuration blocker names"
    [ keeper_name ]
    (fleet_safety |> member "configuration_blocked_keeper_names" |> to_list
     |> List.map to_string);
  Alcotest.(check bool) "all targets blocked by configuration" true
    (fleet_safety |> member "all_target_keepers_configuration_blocked" |> to_bool);
  Alcotest.(check string) "fleet status" "blocked"
    (fleet_safety |> member "status" |> to_string);
  Alcotest.(check string) "typed blocker" "turn_configuration_error"
    (fleet_safety |> member "blocker" |> to_string);
  Alcotest.(check bool) "operator action required" true
    (fleet_safety |> member "operator_action_required" |> to_bool);
  let healthy_name = "healthy" in
  let partial_phase_counts :
      Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
    { running = 1; failing = 1; recovering = 1 }
  in
  let partial_phase_snapshot =
    { phase_snapshot with
      counts = partial_phase_counts
    ; running_names = [ healthy_name ]
    ; phase_values =
        [ keeper_name, Keeper_state_machine.Failing
        ; healthy_name, Keeper_state_machine.Running
        ]
    }
  in
  let partial =
    Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
      ~bootable_names:[ keeper_name; healthy_name ]
      ~autoboot_scan:
        { autoboot_names = [ keeper_name; healthy_name ]; read_errors = [] }
      ~phase_snapshot:partial_phase_snapshot
      ~execution_snapshot:
        { owners = []; executable_names = [ keeper_name; healthy_name ] }
      ~phase_counts:partial_phase_counts
      ~paused_keepers_json:(`Assoc [ "count", `Int 0 ])
      ()
  in
  Alcotest.(check bool) "partial fleet is not fully blocked" false
    (partial |> member "all_target_keepers_configuration_blocked" |> to_bool);
  Alcotest.(check string) "partial fleet is degraded" "degraded"
    (partial |> member "status" |> to_string);
  Alcotest.(check bool) "partial config failure still needs operator" true
    (partial |> member "operator_action_required" |> to_bool)

let test_health_json_degrades_recovering_turn_failures () =
  let keeper_name = "transient-failing" in
  let phase_counts : Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
    { running = 0; failing = 1; recovering = 1 }
  in
  let phase_snapshot : Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
    { counts = phase_counts
    ; running_names = []
    ; recovering_names = [ keeper_name ]
    ; configuration_blocked_names = []
    ; phase_values = [ keeper_name, Keeper_state_machine.Failing ]
    ; phase_details = []
    }
  in
  let fleet_safety =
    Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
      ~bootable_names:[ keeper_name ]
      ~autoboot_scan:{ autoboot_names = [ keeper_name ]; read_errors = [] }
      ~phase_snapshot
      ~execution_snapshot:{ owners = []; executable_names = [ keeper_name ] }
      ~phase_counts
      ~paused_keepers_json:(`Assoc [ "count", `Int 0 ])
      ()
  in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "recovering failure remains executable" 1
    (fleet_safety |> member "executable_keeper_fiber_count" |> to_int);
  Alcotest.(check int) "recovering failure count" 1
    (fleet_safety |> member "recovering_keeper_fiber_count" |> to_int);
  Alcotest.(check string) "recovering fleet is degraded" "degraded"
    (fleet_safety |> member "status" |> to_string);
  Alcotest.(check string) "recovering blocker is explicit" "turn_failure_recovering"
    (fleet_safety |> member "blocker" |> to_string);
  Alcotest.(check bool) "automatic recovery does not demand operator action" false
    (fleet_safety |> member "operator_action_required" |> to_bool)

let test_health_json_reaction_ledger_unavailable_shape () =
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () -> Server_auth.For_testing.restore_server_state @@ previous_state)
    (fun () ->
       Server_auth.For_testing.restore_server_state @@ None;
       let request = Httpun.Request.create `GET "/health" in
       let json = Server_routes_http_runtime.make_health_json request in
       let open Yojson.Safe.Util in
       let reaction_ledger = json |> member "keeper_reaction_ledger" in
       Alcotest.(check string) "unavailable reaction ledger status" "unavailable"
         (reaction_ledger |> member "status" |> to_string);
       Alcotest.(check int) "unavailable reaction ledger reasons empty" 0
         (reaction_ledger |> member "status_reasons" |> to_list |> List.length);
       Alcotest.(check int) "unavailable durable queue count" 0
         (reaction_ledger |> member "durable_event_queue_count" |> to_int);
       Alcotest.(check int) "unavailable durable discovery count" 0
         (reaction_ledger
          |> member "durable_event_queue_discovered_keeper_count"
          |> to_int);
       Alcotest.(check bool) "unavailable durable discovery error null" true
         (reaction_ledger |> member "durable_event_queue_discovery_error" = `Null);
       ignore
         (reaction_ledger
          |> member "durable_event_queue_stale_after_sec"
          |> to_float);
       Alcotest.(check int) "unavailable durable stale count" 0
         (reaction_ledger |> member "durable_event_queue_stale_count" |> to_int);
       Alcotest.(check int) "unavailable durable stale keeper count" 0
         (reaction_ledger
          |> member "durable_event_queue_stale_keeper_count"
          |> to_int);
       Alcotest.(check int) "unavailable durable stale rows empty" 0
         (reaction_ledger
          |> member "durable_event_queue_stale_by_keeper"
          |> to_list
          |> List.length))

let test_health_json_owner_unavailable_shape () =
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () -> Server_auth.For_testing.restore_server_state @@ previous_state)
    (fun () ->
       Server_auth.For_testing.restore_server_state @@ None;
       let request = Httpun.Request.create `GET "/health" in
       let json = Server_routes_http_runtime.make_health_json request in
       let open Yojson.Safe.Util in
       let owner = json |> member "keeper_owner" in
       Alcotest.(check string) "unavailable Keeper Owner status" "unavailable"
         (owner |> member "status" |> to_string);
       Alcotest.(check int) "unavailable shutdown keeper count" 0
         (owner |> member "shutdown_keeper_count" |> to_int))

let test_health_json_surfaces_log_ring_summary () =
  Log.set_level Log.Info;
  Log.emit Log.Warn ~module_name:"HealthTest"
    "health-log-ring-summary-marker";
  let marker_seen =
    Log.Ring.recent ~limit:50 ~module_filter:"HealthTest" ()
    |> List.exists (fun (entry : Log.Ring.entry) ->
        entry.level = Log.Warn
        && String.equal entry.module_name "HealthTest"
        && String.equal entry.message "health-log-ring-summary-marker")
  in
  let request = Httpun.Request.create `GET "/health" in
  let json = Server_routes_http_runtime.make_health_json request in
  let open Yojson.Safe.Util in
  let logs = json |> member "logs" in
  let latest = logs |> member "latest" in
  Alcotest.(check string) "log ring active" "active"
    (logs |> member "status" |> to_string);
  Alcotest.(check bool) "total entries positive" true
    (logs |> member "total_entries" |> to_int > 0);
  Alcotest.(check bool) "retained entries positive" true
    (logs |> member "retained_entries" |> to_int > 0);
  Alcotest.(check bool) "recent window positive" true
    (logs |> member "recent_window" |> to_int > 0);
  Alcotest.(check bool) "recent warning count positive" true
    (logs |> member "recent_warnings" |> to_int > 0);
  Alcotest.(check bool) "warning marker retained in ring" true marker_seen;
  Alcotest.(check bool) "latest excludes message text" true
    (latest |> member "message" = `Null);
  Alcotest.(check bool) "latest excludes details payload" true
    (latest |> member "details" = `Null);
  ignore (logs |> member "file_sink" |> member "enabled" |> to_bool)

let test_health_json_surfaces_internal_mcp_auth_diagnostics () =
  with_temp_dir "health-internal-mcp-auth" @@ fun dir ->
  with_env Auth.internal_keeper_token_env_key None @@ fun () ->
  with_cwd dir @@ fun () ->
  Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
  let request = Httpun.Request.create `GET "/health" in
  let open Yojson.Safe.Util in
  let degraded =
    Server_routes_http_runtime.make_health_json request
    |> member "internal_mcp_auth"
  in
  let missing_names json =
    json |> member "missing" |> to_list |> List.map to_string
  in
  Alcotest.(check string) "auth schema" "masc.internal_mcp_auth.v1"
    (degraded |> member "schema" |> to_string);
  Alcotest.(check string) "missing token degrades" "degraded"
    (degraded |> member "status" |> to_string);
  Alcotest.(check (list string)) "missing token reasons"
    [ "env_token"; "token_hash_file" ]
    (missing_names degraded);
  Alcotest.(check bool) "env token absent" false
    (degraded |> member "env_token_present" |> to_bool);
  Alcotest.(check bool) "hash file absent" false
    (degraded |> member "token_hash_file_present" |> to_bool);
  Alcotest.(check bool) "not ready" false
    (degraded |> member "keeper_internal_runtime_mcp_ready" |> to_bool);
  let raw_token = Auth.ensure_internal_keeper_token dir in
  let ready =
    Server_routes_http_runtime.make_health_json request
    |> member "internal_mcp_auth"
  in
  Alcotest.(check string) "verified token is ok" "ok"
    (ready |> member "status" |> to_string);
  Alcotest.(check bool) "env token present" true
    (ready |> member "env_token_present" |> to_bool);
  Alcotest.(check bool) "hash file present" true
    (ready |> member "token_hash_file_present" |> to_bool);
  Alcotest.(check bool) "env token verifies" true
    (ready |> member "env_token_verifies" |> to_bool);
  Alcotest.(check bool) "ready" true
    (ready |> member "keeper_internal_runtime_mcp_ready" |> to_bool);
  Alcotest.(check bool) "no operator action when ready" false
    (ready |> member "operator_action_required" |> to_bool);
  Alcotest.(check string) "ready operator next action" "none"
    (ready |> member "operator_next_action" |> to_string);
  Alcotest.(check bool) "raw token not exposed" false
    (String_util.contains_substring (Yojson.Safe.to_string ready) raw_token);
  let hash_file = Auth.internal_keeper_token_hash_file dir in
  write_file hash_file " \n";
  let empty_hash =
    Server_routes_http_runtime.make_health_json request
    |> member "internal_mcp_auth"
  in
  Alcotest.(check bool) "empty hash is absent" false
    (empty_hash |> member "token_hash_file_present" |> to_bool);
  Alcotest.(check bool) "empty hash asks for hash file" true
    (List.mem "token_hash_file" (missing_names empty_hash));
  Alcotest.(check bool) "empty hash is not mismatch" false
    (List.mem "token_hash_mismatch" (missing_names empty_hash));
  write_file hash_file (Auth.sha256_hash (raw_token ^ "-stale"));
  let mismatch =
    Server_routes_http_runtime.make_health_json request
    |> member "internal_mcp_auth"
  in
  Alcotest.(check bool) "mismatch keeps hash present" true
    (mismatch |> member "token_hash_file_present" |> to_bool);
  Alcotest.(check bool) "mismatch reason is explicit" true
    (List.mem "token_hash_mismatch" (missing_names mismatch))

let check_otel_health_shape label json =
  let open Yojson.Safe.Util in
  let otel = json |> member "otel" in
  Alcotest.(check bool) (label ^ " otel object") true
    (match otel with `Assoc _ -> true | _ -> false);
  ignore (otel |> member "enabled" |> to_bool);
  Alcotest.(check bool) (label ^ " otel status bounded") true
    (List.mem
       (otel |> member "status" |> to_string)
       [ "ok"; "inactive"; "degraded"; "disabled" ]);
  ignore (otel |> member "endpoint" |> to_string);
  ignore (otel |> member "service_name" |> to_string);
  ignore (otel |> member "exporter_active" |> to_bool);
  ignore (otel |> member "exporter_degraded" |> to_bool);
  ignore (otel |> member "consecutive_failures" |> to_int)
;;

let rec check_unique_object_keys path = function
  | `Assoc fields ->
    let keys = List.map fst fields in
    Alcotest.(check int)
      (Printf.sprintf "%s has unique object keys" path)
      (List.length keys)
      (List.length (List.sort_uniq String.compare keys));
    List.iter
      (fun (key, value) ->
        check_unique_object_keys (Printf.sprintf "%s.%s" path key) value)
      fields
  | `List values ->
    List.iteri
      (fun index value ->
        check_unique_object_keys (Printf.sprintf "%s[%d]" path index) value)
      values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> ()
;;

let test_health_response_default_is_light_probe () =
  let request = Httpun.Request.create `GET "/health" in
  let json = Server_routes_http_runtime.make_health_response_json request in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "default health detail" "probe"
    (json |> member "health_detail" |> to_string);
  Alcotest.(check string) "full health pointer" "/health?full=1"
    (json |> member "full_health_url" |> to_string);
  Alcotest.(check bool) "startup stays on default health" true
    (match json |> member "startup" with `Assoc _ -> true | _ -> false);
  Alcotest.(check bool) "paths stay on default health" true
    (match json |> member "paths" with `Assoc _ -> true | _ -> false);
  Alcotest.(check bool) "internal mcp auth stays on default health" true
    (match json |> member "internal_mcp_auth" with `Assoc _ -> true | _ -> false);
  check_otel_health_shape "default health" json;
  Alcotest.(check bool) "default health skips reaction ledger" true
    (json |> member "keeper_reaction_ledger" = `Null)

let test_health_response_full_query_uses_snapshot_cache () =
  with_temp_dir "health-full-snapshot-cache" (fun dir ->
      let config_root = make_config_root dir in
      with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
      with_config_input "MASC_BASE_PATH" (Some dir) @@ fun () ->
      let previous_state = Server_auth.For_testing.snapshot_server_state () in
      Config_dir_resolver.reset ();
      Server_routes_http_runtime.For_testing.reset_full_health_snapshot ();
      Fun.protect
        ~finally:(fun () ->
          Server_auth.For_testing.restore_server_state @@ previous_state;
          Config_dir_resolver.reset ();
          Server_routes_http_runtime.For_testing.reset_full_health_snapshot ())
        (fun () ->
          Server_auth.For_testing.restore_server_state @@ Some (Mcp_server.For_testing.create_state ~base_path:dir);
          let request = Httpun.Request.create `GET "/health?full=1" in
          let first =
            Server_routes_http_runtime.make_health_response_json request
          in
          let open Yojson.Safe.Util in
          Alcotest.(check string) "full health detail" "full"
            (first |> member "health_detail" |> to_string);
          check_otel_health_shape "full health" first;
          Alcotest.(check bool) "full health includes snapshot metadata" true
            (match first |> member "full_health_snapshot" with
             | `Assoc _ -> true
             | _ -> false);
          let first_snapshot_status =
            first |> member "full_health_snapshot" |> member "status"
            |> to_string
          in
          Alcotest.(check bool) "first full health status is bounded" true
            (List.mem first_snapshot_status
               [ "warming"; "ready"; "stale"; "error" ]);
          Alcotest.(check bool)
            "full health response keeps reaction ledger shape"
            true
            (match first |> member "keeper_reaction_ledger" with
             | `Assoc _ -> true
             | _ -> false);
          Alcotest.(check bool)
            "full health response keeps recovery activation shape"
            true
            (match first |> member "publication_recovery_activation" with
             | `Assoc _ -> true
             | _ -> false);
          Server_routes_http_runtime.For_testing.refresh_full_health_snapshot_now
            request;
          let refreshed =
            Server_routes_http_runtime.make_health_response_json request
          in
          check_unique_object_keys "$" refreshed;
          Alcotest.(check string) "refreshed snapshot is ready" "ready"
            (refreshed |> member "full_health_snapshot" |> member "status"
           |> to_string);
          Alcotest.(check bool) "ready snapshot has no stale reason" true
            (refreshed |> member "full_health_snapshot"
             |> member "stale_reason" = `Null);
          Alcotest.(check bool) "ready snapshot has no stale age" true
            (refreshed |> member "full_health_snapshot"
             |> member "stale_age_ms" = `Null);
          Alcotest.(check bool)
            "refreshed full health keeps reaction ledger"
            true
            (match refreshed |> member "keeper_reaction_ledger" with
             | `Assoc _ -> true
             | _ -> false);
          Alcotest.(check string)
            "refreshed full health keeps recovery activation"
            "unavailable"
            (refreshed |> member "publication_recovery_activation"
             |> member "status" |> to_string)))

let test_full_health_refresh_timing_uses_dedicated_budget () =
  let interval_sec, timeout_sec, ttl_sec =
    Server_routes_http_runtime.For_testing.full_health_refresh_timing ()
  in
  Alcotest.(check (float 0.001)) "full health timeout uses dedicated budget"
    Env_config_runtime.Dashboard.full_health_refresh_timeout_sec
    timeout_sec;
  Alcotest.(check bool) "shell full budget remains configured" true
    (Env_config_runtime.Dashboard.shell_timeout_sec > 0.0);
  Alcotest.(check bool) "full health timeout is positive" true
    (timeout_sec >= 1.0);
  Alcotest.(check bool) "full health interval exceeds timeout" true
    (interval_sec > timeout_sec);
  Alcotest.(check bool) "snapshot ttl covers refresh interval" true
    (ttl_sec >= interval_sec *. 2.0)

let test_full_health_refresh_timeout_preserves_last_snapshot () =
  Server_routes_http_runtime.For_testing.reset_full_health_snapshot ();
  let request = Httpun.Request.create `GET "/health?full=1" in
  Server_routes_http_runtime.For_testing.refresh_full_health_snapshot_now request;
  let before = Server_routes_http_runtime.make_health_response_json request in
  let open Yojson.Safe.Util in
  let before_reaction_ledger = before |> member "keeper_reaction_ledger" in
  let timeout_failure =
    Proactive_refresh.Timed_out
      { label = "full_health_snapshot"
      ; phase = Proactive_refresh.Refresh
      ; timeout_s = 16.0
      ; elapsed_s = 17.0
      }
  in
  Server_routes_http_runtime.For_testing.mark_full_health_snapshot_failure
    timeout_failure;
  let after = Server_routes_http_runtime.make_health_response_json request in
  Alcotest.(check string) "timeout marks snapshot stale" "stale"
    (after |> member "full_health_snapshot" |> member "status" |> to_string);
  Alcotest.(check bool) "timeout marks timed out component" true
    (after |> member "full_health_snapshot" |> member "component_timed_out"
     |> to_bool);
  Alcotest.(check bool) "timeout keeps last-good marker" true
    (after |> member "full_health_snapshot" |> member "last_good_available"
     |> to_bool);
  Alcotest.(check string)
    "timeout error is surfaced"
    (Proactive_refresh.failure_message timeout_failure)
    (after |> member "full_health_snapshot" |> member "error" |> to_string);
  Alcotest.(check string) "timeout stale reason" "last_good_refresh_timeout"
    (after |> member "full_health_snapshot" |> member "stale_reason" |> to_string);
  Alcotest.(check bool) "timeout stale age is surfaced" true
    (match after |> member "full_health_snapshot" |> member "stale_age_ms" with
     | `Int age -> age >= 0
     | _ -> false);
  Alcotest.(check bool) "timeout records stale-since timestamp" true
    (match after |> member "full_health_snapshot" |> member "stale_since_ts" with
     | `Float _ | `Int _ -> true
     | _ -> false);
  Alcotest.(check string) "timeout preserves previous heavy fields"
    (Yojson.Safe.to_string before_reaction_ledger)
    (after |> member "keeper_reaction_ledger" |> Yojson.Safe.to_string)

let test_full_health_cold_refresh_timeout_is_timeout_not_error () =
  Server_routes_http_runtime.For_testing.reset_full_health_snapshot ();
  let request = Httpun.Request.create `GET "/health?full=1" in
  let timeout_failure =
    Proactive_refresh.Timed_out
      { label = "full_health_snapshot"
      ; phase = Proactive_refresh.Refresh
      ; timeout_s = 16.0
      ; elapsed_s = 17.0
      }
  in
  Server_routes_http_runtime.For_testing.mark_full_health_snapshot_failure
    timeout_failure;
  let after = Server_routes_http_runtime.make_health_response_json request in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "cold timeout status" "timeout"
    (after |> member "full_health_snapshot" |> member "status" |> to_string);
  Alcotest.(check bool) "cold timeout marks metadata timeout" true
    (after |> member "full_health_snapshot" |> member "component_timed_out"
     |> to_bool);
  Alcotest.(check bool) "cold timeout has no last good" false
    (after |> member "full_health_snapshot" |> member "last_good_available"
     |> to_bool);
  Alcotest.(check string) "cold timeout stale reason" "refresh_timeout"
    (after |> member "full_health_snapshot" |> member "stale_reason" |> to_string);
  Alcotest.(check bool) "cold timeout stale age is surfaced" true
    (match after |> member "full_health_snapshot" |> member "stale_age_ms" with
     | `Int age -> age >= 0
     | _ -> false)

let test_health_response_survives_deleted_cwd () =
  with_temp_dir "health-deleted-cwd" (fun dir ->
      let deleted_cwd = Filename.concat dir "deleted-cwd" in
      Unix.mkdir deleted_cwd 0o755;
      with_env "MASC_BASE_PATH" (Some dir) @@ fun () ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      let saved_cwd = Sys.getcwd () in
      let expected_base_path =
        try Unix.realpath dir with
        | Unix.Unix_error _ -> dir
      in
      Config_dir_resolver.reset ();
      Unix.chdir deleted_cwd;
      Unix.rmdir deleted_cwd;
      Fun.protect
        ~finally:(fun () ->
          Unix.chdir saved_cwd;
          Config_dir_resolver.reset ())
        (fun () ->
          let request = Httpun.Request.create `GET "/health" in
          let json =
            Server_routes_http_runtime.make_health_response_json request
          in
          let open Yojson.Safe.Util in
          Alcotest.(check string)
            "deleted cwd health still returns probe"
            "probe"
            (json |> member "health_detail" |> to_string);
          Alcotest.(check string)
            "deleted cwd resolver falls back to base path"
            expected_base_path
            (json
             |> member "paths"
             |> member "effective_base_path"
             |> to_string)))

let execution_label = function
  | Server_runtime_bootstrap.Parallel -> "parallel"
  | Server_runtime_bootstrap.Serial -> "serial"

let check_lazy_group group ~name ~execution ~tasks =
  Alcotest.(check string) "group name" name group.Server_runtime_bootstrap.group_name;
  Alcotest.(check string)
    (name ^ " execution")
    execution
    (execution_label group.Server_runtime_bootstrap.execution);
  Alcotest.(check (list string))
    (name ^ " tasks")
    tasks
    group.Server_runtime_bootstrap.task_names

let test_lazy_startup_plan_groups_independent_tasks () =
  let groups = Server_runtime_bootstrap.lazy_startup_plan () in
  Alcotest.(check (list string))
    "group order"
    [ "initialize"; "cleanup" ]
    (List.map
       (fun group -> group.Server_runtime_bootstrap.group_name)
       groups);
  match groups with
  | [ initialize; cleanup ] ->
      check_lazy_group initialize ~name:"initialize" ~execution:"parallel"
        ~tasks:[ "restore_sessions" ];
      check_lazy_group cleanup ~name:"cleanup" ~execution:"parallel"
        ~tasks:[ "jsonl_prune"; "microvm_guest_sweep" ];
      Alcotest.(check (list string))
        "flattened task order"
        [
          "restore_sessions";
          "jsonl_prune";
          "microvm_guest_sweep";
        ]
        (Server_runtime_bootstrap.lazy_startup_task_names ())
  | _ -> Alcotest.fail "unexpected lazy startup group shape"

let test_keeper_lifecycle_refresh_invalidates_projection_snapshot () =
  with_temp_dir "keeper-lifecycle-projection" (fun dir ->
    let config = Workspace.default_config dir in
    let compute_count = ref 0 in
    let read_snapshot () =
      Dashboard_projection_cache.get_or_compute_snapshot_json
        ~config
        ~actor:(Some "lifecycle-test")
        (fun _ ->
           incr compute_count;
           `Assoc [ "revision", `Int !compute_count ])
    in
    let revision =
      Yojson.Safe.Util.(read_snapshot () |> member "revision" |> to_int)
    in
    Alcotest.(check int) "initial revision" 1 revision;
    let cached_revision =
      Yojson.Safe.Util.(read_snapshot () |> member "revision" |> to_int)
    in
    Alcotest.(check int) "snapshot is cached" 1 cached_revision;
    Alcotest.(check int) "compute before lifecycle" 1 !compute_count;
    Server_bootstrap_loops.For_testing.refresh_dashboard_for_keeper_lifecycle
      ~config
      ~keeper_name:"purged-keeper"
      (Keeper_lifecycle_events.Custom_event
         { verb = Keeper_lifecycle_events.Purged; phase = None });
    let refreshed_revision =
      Yojson.Safe.Util.(read_snapshot () |> member "revision" |> to_int)
    in
    Alcotest.(check int) "purge invalidates snapshot" 2 refreshed_revision;
    Alcotest.(check int) "compute after lifecycle" 2 !compute_count)

let test_startup_state_json () =
  Server_startup_state.reset ();
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok;
  Server_startup_state.prepare_lazy_tasks
    ~tasks:[ "restore_sessions"; "keeper_bootstrap" ]
  |> Result.get_ok;
  Server_startup_state.finish_lazy_task ~task:"restore_sessions";
  Server_startup_state.fail_lazy_task ~task:"keeper_bootstrap"
    ~error:"keeper failed";
  let json = Server_startup_state.to_yojson () in
  Alcotest.(check string) "phase becomes degraded" "degraded"
    (json_string_field "phase" json);
  Alcotest.(check bool) "state remains ready" true
    (json_bool_field "state_ready" json);
  Alcotest.(check string) "last error recorded" "keeper failed"
    (json_string_field "last_error" json);
  Alcotest.(check (list string))
    "startup snapshot exposes only lifecycle and diagnostics"
    (List.sort String.compare
       [ "phase"; "state_ready"; "pending_lazy_tasks"; "last_error";
         "path_diagnostics"; "config_resolution"; "elapsed_sec";
         "watchdog_timeout_sec"; "product" ])
    (json |> json_assoc |> List.map fst |> List.sort String.compare);
  let product = List.assoc "product" (json_assoc json) in
  Alcotest.(check (list string))
    "product snapshot exposes only owned state dimensions"
    (List.sort String.compare
       [ "lifecycle"; "lazy_tasks"; "readiness"; "last_error";
         "flat_phase" ])
    (product |> json_assoc |> List.map fst |> List.sort String.compare)

let test_startup_state_catalog_degraded_survives_lazy_activation () =
  Server_startup_state.reset ();
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok;
  Server_startup_state.prepare_lazy_tasks ~tasks:[ "restore_sessions" ]
  |> Result.get_ok;
  Server_startup_state.mark_degraded
    ~error:"startup catalog validation failed: synthetic";
  Server_startup_state.finish_lazy_task ~task:"restore_sessions";
  let current = Server_startup_state.snapshot () in
  Alcotest.(check string) "phase stays degraded after lazy task completes"
    "degraded"
    (Server_startup_state.phase_to_string current.phase);
  Alcotest.(check bool) "ready flag stays true after degradation" true
    current.state_ready;
  Alcotest.(check (option string))
    "catalog validation error is preserved"
    (Some "startup catalog validation failed: synthetic")
    current.last_error

let test_startup_state_concurrent_lazy_completions_preserve_all_updates () =
  let previous = Server_startup_state.snapshot () in
  Fun.protect
    ~finally:(fun () -> Server_startup_state.For_testing.restore previous)
    (fun () ->
      let tasks = List.init 4 (Printf.sprintf "lazy-%d") in
      for _iteration = 1 to 32 do
        Server_startup_state.reset ();
        Server_startup_state.mark_state_ready () |> Result.get_ok;
        Server_startup_state.prepare_lazy_tasks ~tasks |> Result.get_ok;
        let ready = Atomic.make 0 in
        let workers =
          List.map
            (fun task ->
              Domain.spawn (fun () ->
                ignore (Atomic.fetch_and_add ready 1 : int);
                while Atomic.get ready < List.length tasks do
                  Domain.cpu_relax ()
                done;
                Server_startup_state.finish_lazy_task ~task))
            tasks
        in
        List.iter Domain.join workers;
        Alcotest.(check (list string))
          "all concurrent completions are retained"
          []
          (Server_startup_state.pending_lazy_tasks ())
      done)

let test_startup_state_liveness () =
  Server_startup_state.reset ();
  Alcotest.(check bool) "is_live returns true even during init" true
    (Server_startup_state.is_live ());
  Alcotest.(check bool) "elapsed_since_start is non-negative" true
    (Server_startup_state.elapsed_since_start () >= 0.0)

let test_startup_state_readiness_before_init () =
  Server_startup_state.reset ();
  let current = Server_startup_state.snapshot () in
  Alcotest.(check bool) "not ready before init" false current.state_ready;
  Alcotest.(check string) "phase is blocking" "blocking"
    (Server_startup_state.phase_to_string current.phase)

let test_startup_state_readiness_after_init () =
  Server_startup_state.reset ();
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok;
  let current = Server_startup_state.snapshot () in
  Alcotest.(check bool) "ready after init" true current.state_ready;
  Alcotest.(check string) "phase is ready" "ready"
    (Server_startup_state.phase_to_string current.phase)

let test_mcp_transport_requires_explicit_readiness () =
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () -> Server_auth.For_testing.restore_server_state @@ previous_state)
    (fun () ->
       Server_startup_state.reset ();
       Server_startup_state.mark_blocking ();
       Server_auth.For_testing.restore_server_state @@
         Some
           (Mcp_server.For_testing.create_state
              ~base_path:(Filename.get_temp_dir_name ()));
       let deps = Server_routes_http_common.mcp_transport_http_deps () in
       Alcotest.(check bool)
         "state publication alone does not admit MCP"
         false
         (deps.is_ready ());
       Server_startup_state.mark_state_ready ()
       |> Result.get_ok;
       Alcotest.(check bool)
         "explicit readiness admits MCP"
         true
         (deps.is_ready ()))

let test_startup_state_lazy_inventory_does_not_publish_readiness () =
  Server_startup_state.reset ();
  Server_startup_state.mark_blocking ();
  (match
     Server_startup_state.prepare_lazy_tasks
       ~tasks:[ "restore_sessions" ]
   with
   | Ok () -> ()
   | Error error ->
     Alcotest.fail
       (Server_startup_state.lazy_prepare_error_to_string error));
  let current = Server_startup_state.snapshot () in
  Alcotest.(check bool) "lazy inventory remains not ready" false current.state_ready;
  Alcotest.(check string) "startup remains blocking" "blocking"
    (Server_startup_state.phase_to_string current.phase);
  Alcotest.(check (list string))
    "autoboot observes the complete lazy barrier"
    [ "restore_sessions" ]
    current.pending_lazy_tasks;
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok;
  let ready = Server_startup_state.snapshot () in
  Alcotest.(check bool) "consumer ACK may publish readiness" true ready.state_ready;
  Alcotest.(check string) "pending lazy work projects lazy phase" "lazy"
    (Server_startup_state.phase_to_string ready.phase)

let test_startup_failure_disposition_requires_readiness_for_degraded_serving () =
  Alcotest.(check bool)
    "pre-ready failure is fatal"
    true
    (match
       Server_runtime_bootstrap.startup_failure_disposition ~state_ready:false
     with
     | Server_runtime_bootstrap.Fatal_pre_ready -> true
     | Server_runtime_bootstrap.Degraded_after_ready -> false);
  Alcotest.(check bool)
    "post-ready failure may degrade"
    true
    (match
       Server_runtime_bootstrap.startup_failure_disposition ~state_ready:true
     with
     | Server_runtime_bootstrap.Degraded_after_ready -> true
     | Server_runtime_bootstrap.Fatal_pre_ready -> false)

let test_watchdog_timeout_env () =
  with_env "MASC_STARTUP_WATCHDOG_SEC" (Some "90") (fun () ->
      Alcotest.(check (float 0.1)) "reads env" 90.0
        (Server_startup_state.watchdog_timeout_sec ()));
  with_env "MASC_STARTUP_WATCHDOG_SEC" (Some "10") (fun () ->
      Alcotest.(check (float 0.1)) "clamps to 30 min" 30.0
        (Server_startup_state.watchdog_timeout_sec ()));
  with_env "MASC_STARTUP_WATCHDOG_SEC" (Some "999") (fun () ->
      Alcotest.(check (float 0.1)) "clamps to 600 max" 600.0
        (Server_startup_state.watchdog_timeout_sec ()));
  with_env "MASC_STARTUP_WATCHDOG_SEC" None (fun () ->
      Alcotest.(check (float 0.1)) "default 240" 240.0
        (Server_startup_state.watchdog_timeout_sec ()))

let test_startup_state_json_includes_watchdog () =
  Server_startup_state.reset ();
  let json = Server_startup_state.to_yojson () in
  let elapsed =
    match Yojson.Safe.Util.member "elapsed_sec" json with
    | `Float v -> v
    | _ -> Alcotest.failf "elapsed_sec missing or not float"
  in
  Alcotest.(check bool) "elapsed_sec present and non-negative" true
    (elapsed >= 0.0);
  let watchdog =
    match Yojson.Safe.Util.member "watchdog_timeout_sec" json with
    | `Float v -> v
    | _ -> Alcotest.failf "watchdog_timeout_sec missing or not float"
  in
  Alcotest.(check bool) "watchdog_timeout_sec is positive" true
    (watchdog > 0.0)

let test_startup_state_json_includes_runtime_resolution () =
  Server_startup_state.reset ();
  let path_diagnostics =
    `Assoc
      [
        ("effective_base_path", `String "/tmp/runtime-root");
        ("effective_masc_root", `String "/tmp/runtime-root/.masc");
      ]
  in
  let config_resolution =
    `Assoc
      [
        ( "config_root",
          `Assoc
            [
              ("path", `String "/tmp/runtime-root/.masc/config");
              ("exists", `Bool true);
              ("source", `String "local_masc");
            ] );
      ]
  in
  Server_startup_state.note_runtime_resolution ~path_diagnostics
    ~config_resolution;
  let json = Server_startup_state.to_yojson () in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "startup path diagnostics surfaced"
    "/tmp/runtime-root"
    (json |> member "path_diagnostics" |> member "effective_base_path"
   |> to_string);
  Alcotest.(check string) "startup config resolution surfaced"
    "/tmp/runtime-root/.masc/config"
    (json |> member "config_resolution" |> member "config_root" |> member "path"
   |> to_string)

let test_create_server_state_records_runtime_resolution () =
  with_temp_dir "startup-create-state" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      with_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
        Server_runtime_bootstrap.init_runtime_context env
      in
      Eio.Switch.run @@ fun sw ->
      Server_startup_state.reset ();
      ignore
        (Server_runtime_bootstrap.create_server_state ~sw ~base_path:dir ~clock
           ~mono_clock ~net ~proc_mgr ~fs ());
      let json = Server_startup_state.to_yojson () in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "create_server_state records config root"
        (Filename.concat dir ".masc/config")
        (json |> member "config_resolution" |> member "config_root" |> member "path"
       |> to_string);
      Alcotest.(check string) "create_server_state records effective masc root"
        (Unix.realpath (Filename.concat dir Common.masc_dirname))
        (json |> member "path_diagnostics" |> member "effective_masc_root"
       |> to_string))

let test_create_server_state_preserves_raw_input_base_path () =
  with_temp_dir "startup-create-state-raw-input" (fun dir ->
      let repo = Filename.concat dir "repo" in
      let raw_input = Filename.concat dir Common.masc_dirname in
      mkdir_p repo;
      mkdir_p raw_input;
      ignore (make_config_root repo);
      with_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_BASE_PATH" None @@ fun () ->
      with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
        Server_runtime_bootstrap.init_runtime_context env
      in
      Eio.Switch.run @@ fun sw ->
      Server_startup_state.reset ();
      ignore
        (Server_runtime_bootstrap.create_server_state ~sw ~base_path:raw_input
           ~clock ~mono_clock ~net ~proc_mgr ~fs ());
      let json = Server_startup_state.to_yojson () in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "raw input base path preserved in diagnostics"
        raw_input
        (json |> member "path_diagnostics" |> member "input_base_path"
       |> to_string);
      Alcotest.(check (option string)) "raw input env preserved"
        (Some raw_input)
        ((Host_config.from_env ()).base_path_raw);
      Alcotest.(check string) "normalized env remains effective workspace root"
        dir (Sys.getenv "MASC_BASE_PATH"))

let test_prompt_markdown_dir_ignores_repo_seed_prompts () =
  with_temp_dir "startup-prompts" (fun dir ->
      let config_root = Filename.concat dir "config" in
      let repo_prompts = Filename.concat config_root "prompts" in
      let expected = Filename.concat dir ".masc/config/prompts" in
      Fs_compat.mkdir_p repo_prompts;
      Fs_compat.mkdir_p expected;
      write_file (Filename.concat config_root "runtime.toml") "";
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd dir @@ fun () ->
      Config_dir_resolver.reset ();
      let resolved =
        Fun.protect
          ~finally:(fun () -> Config_dir_resolver.reset ())
          (fun () ->
             Prompt_defaults.resolve_prompt_markdown_dir
               ~workspace_path:dir ~base_path:dir)
      in
      Alcotest.(check string) "repo seed prompts are not active config"
        (canonical_path expected) (canonical_path resolved))

let test_prompt_markdown_dir_does_not_use_repo_seed () =
  with_temp_dir "startup-prompts-no-opt-in" (fun dir ->
      let config_root = Filename.concat dir "config" in
      let repo_prompts = Filename.concat config_root "prompts" in
      let expected = Filename.concat dir ".masc/config/prompts" in
      Fs_compat.mkdir_p repo_prompts;
      Fs_compat.mkdir_p expected;
      write_file (Filename.concat config_root "runtime.toml") "";
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd dir @@ fun () ->
      Config_dir_resolver.reset ();
      let resolved =
        Fun.protect
          ~finally:(fun () -> Config_dir_resolver.reset ())
          (fun () ->
             Prompt_defaults.resolve_prompt_markdown_dir
               ~workspace_path:dir ~base_path:dir)
      in
      Alcotest.(check string)
        "temp workspace keeps resolved default prompt dir without repo seed"
        (canonical_path expected) (canonical_path resolved))

let test_prompt_markdown_dir_honors_masc_config_dir_override () =
  with_temp_dir "startup-prompts-override" (fun dir ->
      let workspace_prompts = Filename.concat dir "config/prompts" in
      let override_root = Filename.concat dir "override-config" in
      let override_prompts = Filename.concat override_root "prompts" in
      Fs_compat.mkdir_p workspace_prompts;
      Fs_compat.mkdir_p override_prompts;
      with_env "MASC_CONFIG_DIR" (Some override_root) @@ fun () ->
      Config_dir_resolver.reset ();
      let resolved =
        Fun.protect
          ~finally:(fun () -> Config_dir_resolver.reset ())
          (fun () ->
             Prompt_defaults.resolve_prompt_markdown_dir
               ~workspace_path:dir ~base_path:dir)
      in
      Alcotest.(check string) "resolved config root wins over workspace prompts"
        override_prompts resolved)

let test_prompt_markdown_dir_prefers_resolved_config_dir_over_cwd () =
  with_temp_dir "startup-prompts-priority" (fun dir ->
      let cwd_prompts = Filename.concat dir "config/prompts" in
      let resolved_config = Filename.concat dir ".masc/config" in
      let resolved_prompts = Filename.concat resolved_config "prompts" in
      Fs_compat.mkdir_p cwd_prompts;
      Fs_compat.mkdir_p resolved_prompts;
      with_cwd dir @@ fun () ->
      with_env "MASC_CONFIG_DIR" (Some resolved_config) @@ fun () ->
      Config_dir_resolver.reset ();
      Fun.protect
        ~finally:(fun () -> Config_dir_resolver.reset ())
        (fun () ->
          let resolved =
            Prompt_defaults.resolve_prompt_markdown_dir
              ~workspace_path:(Filename.concat dir "workspace")
              ~base_path:(Filename.concat dir "workspace")
          in
          Alcotest.(check string)
            "resolved config prompts win over cwd fallback"
            resolved_prompts resolved))

let test_main_eio_serves_health_before_lazy_startup () =
  with_temp_dir "startup-health" (fun dir ->
      let exe = Masc_test_runtime.find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int port;
            "--base-path";
            dir;
          |]
          env Unix.stdin log_fd log_fd
      in
      Unix.close log_fd;
      Fun.protect
        ~finally:(fun () -> stop_process pid)
        (fun () ->
          if not (wait_for_health ~pid ~port ~timeout_s:5.0) then begin
            prerr_endline
              (Printf.sprintf
                 "main_eio did not expose /health within timeout in this environment.\nlog:\n%s"
                 (read_file log_file));
            Alcotest.skip ()
          end))

let test_main_eio_fresh_bootstrap_and_mcp_handshake () =
  with_temp_dir "startup-fresh-boot-e2e" (fun dir ->
      let exe = Masc_test_runtime.find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      let expected_config = Filename.concat dir ".masc/config" in
      let workspace_config = Workspace.default_config dir in
      ignore (Workspace.init workspace_config ~agent_name:(Some "startup-test"));
      let fenced_keeper =
        make_keeper_meta
          ~name:"restart-fenced-keeper"
          ~trace_id:"trace-restart-fenced-keeper"
          ()
      in
      write_keeper_meta_exn workspace_config fenced_keeper;
      let expected_backlog_version =
        match Workspace_backlog.read_backlog_r workspace_config with
        | Ok backlog -> backlog.version
        | Error detail -> Alcotest.fail detail
      in
      let operation_id =
        Keeper_shutdown_types.Operation_id.of_string
          "shutdown-00000000-0000-4000-8000-000000000001"
        |> Result.get_ok
      in
      let now = Masc_domain.now_iso () in
      let fenced_operation : Keeper_shutdown_types.t =
        { schema_version = Keeper_shutdown_types.schema_version
        ; revision = 0
        ; operation_id
        ; keeper_name = fenced_keeper.name
        ; lane_ownership = Keeper_shutdown_types.Dormant_meta
        ; trace_id = fenced_keeper.runtime.trace_id
        ; actor = "startup-test"
        ; cleanup_intent =
            { reason = Keeper_shutdown_types.Operator_stop_retain_meta
            ; remove_session = false
            }
        ; turn_disposition = Keeper_shutdown_types.No_inflight_turn
        ; expected_backlog_version
        ; owned_task_ids = []
        ; join_evidence = None
        ; phase = Keeper_shutdown_types.Prepared
        ; created_at = now
        ; updated_at = now
        }
      in
      (match Keeper_shutdown_store.persist_new ~config:workspace_config fenced_operation with
       | Ok () -> ()
       | Error error ->
         Alcotest.fail (Keeper_shutdown_store.error_to_string error));
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_KEEPER_BOOTSTRAP_ENABLED", "false");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int port;
            "--base-path";
            dir;
          |]
          env Unix.stdin log_fd log_fd
      in
      Unix.close log_fd;
      Fun.protect
        ~finally:(fun () -> stop_process pid)
        (fun () ->
          if not (wait_for_startup_phase ~pid ~port ~timeout_s:10.0 "ready") then begin
            Alcotest.failf
              "main_eio fresh boot did not reach startup.phase=ready within timeout.\nlog:\n%s"
              (read_file log_file)
          end;
          let health_headers, health_body =
            curl_request_capture ~output_dir:dir ~name:"health" ~method_:"GET"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/health" port) ()
          in
          ignore health_headers;
          let health_json = parse_json_response_file health_body in
          let startup =
            Yojson.Safe.Util.member "startup" health_json
          in
          let config_root_path =
            Yojson.Safe.Util.(
              health_json
              |> member "startup"
              |> member "config_resolution"
              |> member "config_root"
              |> member "path"
              |> to_string)
          in
          let effective_base_path =
            Yojson.Safe.Util.(
              health_json |> member "paths" |> member "effective_base_path"
              |> to_string)
          in
          Alcotest.(check string) "startup phase ready" "ready"
            Yojson.Safe.Util.(startup |> member "phase" |> to_string);
          Alcotest.(check bool)
            "durable shutdown admission restores after Owner inventory install"
            false
            (String_util.contains_substring
               (read_file log_file)
               "Keeper owner inventory is not installed");
          Alcotest.(check string) "effective base path matches fresh dir"
            (canonical_path dir) (canonical_path effective_base_path);
          Alcotest.(check string) "config root matches fresh dir"
            (canonical_path expected_config) (canonical_path config_root_path);
          let init_headers, init_body =
            curl_request_capture
              ~output_dir:dir ~name:"initialize" ~method_:"POST"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/mcp" port)
              ~headers:[ "Content-Type: application/json"; main_eio_auth_header ]
              ~payload:
                {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fresh-boot-test","version":"1.0"}}}|}
              ()
          in
          Alcotest.(check (option int)) "initialize http 200" (Some 200)
            (http_status_from_headers init_headers);
          let init_json = parse_json_response_file init_body in
          Alcotest.(check string) "initialize protocol" "2025-11-25"
            Yojson.Safe.Util.(
              init_json |> member "result" |> member "protocolVersion" |> to_string);
          let session_id =
            require_header_value init_headers "Mcp-Session-Id"
          in
          let protocol_version =
            require_header_value init_headers "Mcp-Protocol-Version"
          in
          let notify_headers, _notify_body =
            curl_request_capture
              ~output_dir:dir ~name:"initialized" ~method_:"POST"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/mcp" port)
              ~headers:
                [
                  "Content-Type: application/json";
                  "Accept: application/json, text/event-stream";
                  main_eio_auth_header;
                  "Mcp-Session-Id: " ^ session_id;
                  "Mcp-Protocol-Version: " ^ protocol_version;
                ]
              ~payload:
                {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|}
              ()
          in
          let notify_code =
            require_http_status_from_headers notify_headers
          in
          Alcotest.(check bool) "notifications/initialized accepted" true
            (List.mem notify_code [ 200; 202; 204 ]);
          let tools_headers, tools_body =
            curl_request_capture
              ~output_dir:dir ~name:"tools-list" ~method_:"POST"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/mcp" port)
              ~headers:
                [
                  "Content-Type: application/json";
                  "Accept: application/json, text/event-stream";
                  main_eio_auth_header;
                  "Mcp-Session-Id: " ^ session_id;
                  "Mcp-Protocol-Version: " ^ protocol_version;
                ]
              ~payload:
                {|{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}|}
              ()
          in
          Alcotest.(check (option int)) "tools/list http 200" (Some 200)
            (http_status_from_headers tools_headers);
          let tools_json = parse_json_response_file tools_body in
          let tool_names =
            Yojson.Safe.Util.(
              tools_json |> member "result" |> member "tools" |> to_list
              |> List.filter_map (fun tool ->
                     match member "name" tool with
                     | `String name -> Some name
                     | _ -> None))
          in
          Alcotest.(check bool) "tools/list nonempty" true (tool_names <> []);
          Alcotest.(check bool) "canonical tool present" true
            (List.mem "masc_status" tool_names)))

let test_main_eio_preserves_cli_agent_mcp_token_file () =
  with_temp_dir "startup-codex-token-preserve" (fun dir ->
      let exe = Masc_test_runtime.find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      let auth_dir = Filename.concat dir ".masc/auth" in
      let token_path = Filename.concat auth_dir "codex-mcp-client.token" in
      Fs_compat.mkdir_p auth_dir;
      let seed_raw_token = "stale-codex-raw-token" in
      let seeded_hash =
        match
          Auth.save_raw_token_credential dir
            ~agent_name:"codex-mcp-client" ~role:Masc_domain.Worker
            ~raw_token:seed_raw_token
        with
        | Ok cred -> cred.token
        | Error err ->
            Alcotest.failf "failed to seed stale codex credential: %s"
              (Masc_domain.masc_error_to_string err)
      in
      Auth.save_private_text_file token_path seeded_hash;
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_KEEPER_BOOTSTRAP_ENABLED", "false");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int port;
            "--base-path";
            dir;
          |]
          env Unix.stdin log_fd log_fd
      in
      Unix.close log_fd;
      Fun.protect
        ~finally:(fun () -> stop_process pid)
        (fun () ->
          if not (wait_for_startup_phase ~pid ~port ~timeout_s:10.0 "ready") then begin
            prerr_endline
              (Printf.sprintf
                 "main_eio codex token preserve test did not reach startup.phase=ready within timeout in this environment.\nlog:\n%s"
                 (read_file log_file));
            Alcotest.skip ()
          end;
          let preserved_raw = String.trim (read_file token_path) in
          let preserved_mode = (Unix.stat token_path).Unix.st_perm land 0o777 in
          Alcotest.(check string) "startup preserves unmanaged client token file"
            seeded_hash preserved_raw;
          Alcotest.(check int) "token file is private" 0o600 preserved_mode;
          let credential =
            match Auth.load_credential dir "codex-mcp-client" with
            | Some cred -> cred
            | None -> Alcotest.fail "missing codex-mcp-client credential after startup"
          in
          Alcotest.(check bool) "existing role preserved" true
            (credential.role = Masc_domain.Worker);
          Alcotest.(check string) "seeded raw token hashes to stored credential"
            credential.token (Auth.sha256_hash seed_raw_token);
          match
            Auth.verify_token dir ~agent_name:"codex-mcp-client"
              ~token:seed_raw_token
          with
           | Ok _ -> ()
           | Error err ->
             Alcotest.failf "seeded raw token should verify: %s"
               (Masc_domain.masc_error_to_string err)))

let test_sync_bootable_keeper_credentials_mints_keeper_token () =
  with_temp_dir "startup-keeper-credential-sync" (fun dir ->
      with_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_basepath_keeper_toml dir "omicron-improver";
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
        Server_runtime_bootstrap.init_runtime_context env
      in
      Eio.Switch.run @@ fun sw ->
      let state =
        Server_runtime_bootstrap.create_server_state ~sw ~base_path:dir ~clock
          ~mono_clock ~net ~proc_mgr ~fs ()
      in
      Server_runtime_bootstrap.bootstrap_server_state_blocking state;
      Server_runtime_bootstrap.sync_bootable_keeper_credentials state;
      let internal_raw_token =
        match Sys.getenv_opt "MASC_INTERNAL_MCP_TOKEN" with
        | Some raw when String.trim raw <> "" -> String.trim raw
        | _ -> Alcotest.fail "missing internal keeper token after startup sync"
      in
      let raw_token_path =
        Filename.concat (Auth.auth_dir dir) "omicron-improver.token"
      in
      let raw_token = String.trim (read_file raw_token_path) in
      let credential =
        match Auth.load_credential dir "omicron-improver" with
        | Some cred -> cred
        | None ->
            Alcotest.fail
              "missing omicron-improver credential after startup sync"
      in
      Alcotest.(check bool) "internal keeper token hash persisted" true
        (Sys.file_exists (Auth.internal_keeper_token_hash_file dir));
      Alcotest.(check string) "raw token hashes to keeper credential"
        credential.token (Auth.sha256_hash raw_token);
      Alcotest.(check bool) "keeper bearer separated from internal token" false
        (String.equal raw_token internal_raw_token);
      match
        Auth.verify_token dir ~agent_name:"omicron-improver"
          ~token:raw_token
      with
      | Ok resolved_cred ->
          Alcotest.(check string) "keeper credential resolves exact agent"
            "omicron-improver" resolved_cred.agent_name
      | Error err ->
          Alcotest.failf "bootable keeper token should verify exactly: %s"
            (Masc_domain.masc_error_to_string err))

let test_sync_admin_token_env_repairs_raw_token_file () =
  with_temp_dir "startup-admin-token-sync" (fun dir ->
      let stale_token = "stale-admin-token" in
      let current_token = "current-admin-token" in
      (match
         Auth.save_raw_token_credential dir ~agent_name:"admin"
           ~role:Masc_domain.Admin ~raw_token:stale_token
       with
       | Ok _ -> ()
       | Error error ->
           Alcotest.failf "failed to seed stale admin credential: %s"
             (Masc_domain.masc_error_to_string error));
      let token_file = Filename.concat (Auth.auth_dir dir) "admin.token" in
      Auth.save_private_text_file token_file stale_token;
      with_env "MASC_ADMIN_TOKEN" (Some current_token) @@ fun () ->
      let state = Mcp_server.For_testing.create_state ~base_path:dir in
      Server_runtime_startup_credentials.sync_admin_token_env state;
      Alcotest.(check (option string)) "raw token file follows startup env"
        (Some current_token) (Auth.load_raw_token dir ~agent_name:"admin");
      Alcotest.(check int) "startup raw token file is private" 0o600
        ((Unix.stat token_file).Unix.st_perm land 0o777);
      match Auth.verify_token dir ~agent_name:"admin" ~token:current_token with
      | Ok credential ->
          Alcotest.(check bool) "startup token keeps admin role" true
            (credential.role = Masc_domain.Admin)
      | Error error ->
          Alcotest.failf "startup admin bearer should verify: %s"
            (Masc_domain.masc_error_to_string error))

let test_sync_bootable_keeper_credentials_rotates_shared_keeper_tokens () =
  with_temp_dir "startup-keeper-credential-rotate" (fun dir ->
      with_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_basepath_keeper_toml dir "delta";
      write_basepath_keeper_toml dir "omega";
      let shared_raw_token = "shared-keeper-bootstrap-token" in
      let seed agent_name =
        match
          Auth.save_raw_token_credential dir ~agent_name
            ~role:Masc_domain.Worker ~raw_token:shared_raw_token
        with
        | Ok _ ->
            Auth.save_private_text_file
              (Filename.concat (Auth.auth_dir dir) (agent_name ^ ".token"))
              shared_raw_token
        | Error err ->
            Alcotest.failf "failed to seed shared credential for %s: %s"
              agent_name (Masc_domain.masc_error_to_string err)
      in
      seed "delta";
      seed "omega";
      Alcotest.(check int) "seeded one duplicate group"
        1 (List.length (Auth.audit_token_uniqueness dir));
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
        Server_runtime_bootstrap.init_runtime_context env
      in
      Eio.Switch.run @@ fun sw ->
      let state =
        Server_runtime_bootstrap.create_server_state ~sw ~base_path:dir ~clock
          ~mono_clock ~net ~proc_mgr ~fs ()
      in
      Server_runtime_bootstrap.bootstrap_server_state_blocking state;
      Server_runtime_bootstrap.sync_bootable_keeper_credentials state;
      let delta =
        match Auth.load_credential dir "delta" with
        | Some cred -> cred
        | None -> Alcotest.fail "missing delta credential"
      in
      let executor =
        match Auth.load_credential dir "omega" with
        | Some cred -> cred
        | None -> Alcotest.fail "missing omega credential"
      in
      Alcotest.(check bool) "boot repair made keeper tokens unique" false
        (String.equal delta.token executor.token);
      Alcotest.(check int) "audit clean after boot repair"
        0 (List.length (Auth.audit_token_uniqueness dir));
      [ "delta"; "omega" ]
      |> List.iter (fun agent_name ->
             let raw_token_path =
               Filename.concat (Auth.auth_dir dir) (agent_name ^ ".token")
             in
             let raw_token = String.trim (read_file raw_token_path) in
             match Auth.verify_token dir ~agent_name ~token:raw_token with
             | Ok cred ->
                 Alcotest.(check string)
                   (agent_name ^ " rotated raw token verifies")
                   agent_name cred.agent_name
             | Error err ->
                 Alcotest.failf
                   "%s rotated raw token should verify after boot repair: %s"
                   agent_name (Masc_domain.masc_error_to_string err)))

let test_main_eio_rejects_same_base_path_on_second_server () =
  with_temp_dir "startup-base-path-owner-lock" (fun dir ->
      let exe = Masc_test_runtime.find_main_eio_exe () in
      let primary_port = find_free_port () in
      let secondary_port = find_free_port_from (primary_port + 1) in
      let primary_log = Filename.concat dir "primary.log" in
      let secondary_log = Filename.concat dir "secondary.log" in
      let open_log path =
        Unix.openfile path [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_KEEPER_BOOTSTRAP_ENABLED", "false");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let primary_fd = open_log primary_log in
      let primary_pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int primary_port;
            "--base-path";
            dir;
          |]
          env Unix.stdin primary_fd primary_fd
      in
      Unix.close primary_fd;
      let secondary_pid = ref None in
      Fun.protect
        ~finally:(fun () ->
          (match !secondary_pid with
           | Some pid -> stop_process pid
           | None -> ());
          stop_process primary_pid)
        (fun () ->
          if not (wait_for_health ~pid:primary_pid ~port:primary_port ~timeout_s:5.0)
          then begin
            prerr_endline
              (Printf.sprintf
                 "primary main_eio did not expose /health within timeout in this environment.\nlog:\n%s"
                 (read_file primary_log));
            Alcotest.skip ()
          end;
          let secondary_fd = open_log secondary_log in
          let pid =
            Unix.create_process_env exe
              [|
                exe;
                "--host";
                "127.0.0.1";
                "--port";
                string_of_int secondary_port;
                "--base-path";
                dir;
              |]
              env Unix.stdin secondary_fd secondary_fd
          in
          secondary_pid := Some pid;
          Unix.close secondary_fd;
          if not (wait_for_process_exit ~pid ~timeout_s:5.0) then
            Alcotest.failf
              "secondary main_eio stayed alive despite shared base path\nlog:\n%s"
              (read_file secondary_log);
          let secondary_text = read_file secondary_log in
          Alcotest.(check bool) "secondary log mentions base-path owner" true
            (String_util.contains_substring secondary_text "already owns base path");
          Alcotest.(check bool) "secondary log mentions primary pid" true
            (String_util.contains_substring secondary_text (string_of_int primary_pid));
          Alcotest.(check bool) "primary server stays healthy" true
            (wait_for_health ~pid:primary_pid ~port:primary_port ~timeout_s:1.0)))

let test_main_eio_invalid_runtime_stays_degraded_but_serves_dashboard () =
  with_temp_dir "startup-invalid-runtime" (fun dir ->
      let exe = Masc_test_runtime.find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_invalid_local_only_runtime dir;
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_KEEPER_BOOTSTRAP_ENABLED", "false");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int port;
            "--base-path";
            dir;
          |]
          env Unix.stdin log_fd log_fd
      in
      Unix.close log_fd;
      Fun.protect
        ~finally:(fun () -> stop_process pid)
        (fun () ->
          if not (wait_for_startup_phase ~pid ~port ~timeout_s:10.0 "degraded") then begin
            prerr_endline
              (Printf.sprintf
                 "main_eio invalid runtime did not reach startup.phase=degraded within timeout in this environment.\nlog:\n%s"
                 (read_file log_file));
            Alcotest.skip ()
          end;
          let health_headers, health_body =
            curl_request_capture ~output_dir:dir ~name:"health-invalid" ~method_:"GET"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/health" port) ()
          in
          ignore health_headers;
          let health_json = parse_json_response_file health_body in
          let startup = Yojson.Safe.Util.member "startup" health_json in
          Alcotest.(check string) "startup phase degraded" "degraded"
            Yojson.Safe.Util.(startup |> member "phase" |> to_string);
          Alcotest.(check bool) "startup remains ready" true
            Yojson.Safe.Util.(startup |> member "state_ready" |> to_bool);
          let startup_error =
            Yojson.Safe.Util.(startup |> member "last_error" |> to_string)
          in
          Alcotest.(check bool) "last error mentions catalog validation" true
            (String.starts_with ~prefix:"startup catalog validation failed:" startup_error)))

let test_main_eio_partial_catalog_stays_ready_and_surfaces_rejections () =
  with_temp_dir "startup-partial-runtime" (fun dir ->
      let exe = Masc_test_runtime.find_main_eio_exe () in
      let port = find_free_port () in
      let mock_port = find_free_port_from (port + 1) in
      let mock_pid =
        start_mock_openai_server ~port:mock_port
          ~response:(openai_text_response "ok")
      in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_partially_invalid_runtime ~base_path:dir
        ~valid_model:(Printf.sprintf "custom:stable@http://127.0.0.1:%d/v1" mock_port);
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_KEEPER_BOOTSTRAP_ENABLED", "false");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int port;
            "--base-path";
            dir;
          |]
          env Unix.stdin log_fd log_fd
      in
      Unix.close log_fd;
      Fun.protect
        ~finally:(fun () ->
          stop_process pid;
          stop_process mock_pid)
        (fun () ->
          if not (wait_for_startup_phase ~pid ~port ~timeout_s:10.0 "ready") then begin
            prerr_endline
              (Printf.sprintf
                 "main_eio partial catalog did not reach startup.phase=ready within timeout in this environment.\nlog:\n%s"
                 (read_file log_file));
            Alcotest.skip ()
          end;
          let health_headers, health_body =
            curl_request_capture ~output_dir:dir ~name:"health-partial" ~method_:"GET"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/health" port) ()
          in
          ignore health_headers;
          let health_json = parse_json_response_file health_body in
          let startup = Yojson.Safe.Util.member "startup" health_json in
          Alcotest.(check string) "startup phase stays ready" "ready"
            Yojson.Safe.Util.(startup |> member "phase" |> to_string);
          Alcotest.(check bool) "startup remains ready" true
            Yojson.Safe.Util.(startup |> member "state_ready" |> to_bool);
          Alcotest.(check bool) "last error remains unset" true
            Yojson.Safe.Util.(startup |> member "last_error" |> to_string_option = None)))

let test_main_eio_invalid_default_partial_catalog_stays_degraded () =
  with_temp_dir "startup-default-invalid-partial-runtime" (fun dir ->
      let exe = Masc_test_runtime.find_main_eio_exe () in
      let port = find_free_port () in
      let mock_port = find_free_port_from (port + 1) in
      let mock_pid =
        start_mock_openai_server ~port:mock_port
          ~response:(openai_text_response "ok")
      in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_partially_invalid_default_runtime ~base_path:dir
        ~valid_model:(Printf.sprintf "custom:stable@http://127.0.0.1:%d/v1" mock_port);
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_KEEPER_AUTONOMOUS_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_KEEPER_BOOTSTRAP_ENABLED", "false");
            ("MASC_USE_H2", "0");
            ("DUNE_SOURCEROOT", project_root ());
          ]
      in
      let pid =
        Unix.create_process_env exe
          [|
            exe;
            "--host";
            "127.0.0.1";
            "--port";
            string_of_int port;
            "--base-path";
            dir;
          |]
          env Unix.stdin log_fd log_fd
      in
      Unix.close log_fd;
      Fun.protect
        ~finally:(fun () ->
          stop_process pid;
          stop_process mock_pid)
        (fun () ->
          if not (wait_for_startup_phase ~pid ~port ~timeout_s:10.0 "degraded") then begin
            prerr_endline
              (Printf.sprintf
                 "main_eio default-invalid partial catalog did not reach startup.phase=degraded within timeout in this environment.\nlog:\n%s"
                 (read_file log_file));
            Alcotest.skip ()
          end;
          let health_headers, health_body =
            curl_request_capture ~output_dir:dir ~name:"health-default-invalid"
              ~method_:"GET"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/health" port) ()
          in
          ignore health_headers;
          let health_json = parse_json_response_file health_body in
          let startup = Yojson.Safe.Util.member "startup" health_json in
          Alcotest.(check string) "startup phase degraded" "degraded"
            Yojson.Safe.Util.(startup |> member "phase" |> to_string);
          let startup_error =
            Yojson.Safe.Util.(startup |> member "last_error" |> to_string)
          in
          let rejection_prefix = "startup catalog validation failed: " in
          if not (String.starts_with ~prefix:rejection_prefix startup_error) then
            Alcotest.failf
              "last error missing catalog rejection prefix: %S"
              startup_error;
          let rejection_json =
            String.sub startup_error (String.length rejection_prefix)
              (String.length startup_error - String.length rejection_prefix)
            |> Yojson.Safe.from_string
          in
          let rejection_errors =
            Yojson.Safe.Util.(rejection_json |> member "errors" |> to_list)
            |> List.map Yojson.Safe.Util.to_string
          in
          Alcotest.(check bool) "last error includes default-profile failure" true
            (List.exists
               (fun error ->
                  String_util.contains_substring error "required default profile")
               rejection_errors)))

let test_transition_projection_cursor_commits_before_isolated_owner_recovery () =
  let cursor_committed = ref false in
  let processed = ref [] in
  Server_bootstrap_maintenance.Recovery_for_testing.consume_owner_projection_batch
    ~commit_cursor:(fun () -> cursor_committed := true)
    ~keeper_name:Fun.id
    ~recover_owner:(fun owner ->
      Alcotest.(check bool)
        "cursor commits before owner activation"
        true
        !cursor_committed;
      processed := owner :: !processed;
      if String.equal owner "first" then failwith "injected owner activation failure")
    [ "first"; "second" ];
  Alcotest.(check (list string))
    "ordinary first-owner failure does not starve the next owner"
    [ "first"; "second" ]
    (List.rev !processed)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Alcotest.run "Server_runtime_bootstrap"
    [
      ( "bootstrap",
        [
          Alcotest.test_case
            "transition projection cursor commits before isolated owner recovery"
            `Quick
            test_transition_projection_cursor_commits_before_isolated_owner_recovery;
          Alcotest.test_case
            "gRPC tool arguments fail closed before dispatch"
            `Quick
            test_grpc_tool_arguments_fail_closed_before_dispatch;
          Alcotest.test_case
            "model catalog installs explicit env override"
            `Quick test_model_catalog_configuration_installs_explicit_env_override;
          Alcotest.test_case
            "model catalog ignores legacy discovery inputs"
            `Quick test_model_catalog_configuration_ignores_legacy_discovery_inputs;
          Alcotest.test_case
            "model catalog overlay installs config-root overlay"
            `Quick test_model_catalog_overlay_installs_config_root_overlay;
          Alcotest.test_case
            "model catalog overlay absent is a no-op"
            `Quick test_model_catalog_overlay_absent_is_noop;
          Alcotest.test_case
            "model catalog overlay invalid fails loud"
            `Quick test_model_catalog_overlay_invalid_fails_loud;
          Alcotest.test_case
            "explicit model catalog replacement precedes overlay"
            `Quick test_explicit_model_catalog_replacement_precedes_overlay;
          Alcotest.test_case
            "model catalog configuration delegates to agent_core ambient catalog"
            `Quick
            test_model_catalog_configuration_delegates_to_agent_core_ambient;
          Alcotest.test_case
            "bootstrap base-path config copies shared seed only"
            `Quick
            test_bootstrap_base_path_config_root_copies_shared_seed_but_not_keepers;
          Alcotest.test_case
            "bootstrap base-path config backfills prompts and catalog overlay"
            `Quick
            test_bootstrap_base_path_config_root_backfills_missing_prompts_and_overlay;
          Alcotest.test_case
            "bootstrap base-path config skips explicit override"
            `Quick
            test_bootstrap_base_path_config_root_skips_explicit_config_override;
          Alcotest.test_case
            "startup config resolution defaults to bootstrapped root"
            `Quick test_startup_config_resolution_defaults_to_bootstrapped_root;
          Alcotest.test_case
            "startup config resolution preserves explicit override"
            `Quick test_startup_config_resolution_preserves_explicit_override;
          Alcotest.test_case
            "bootstrap base-path config collapses .masc input path"
            `Quick test_bootstrap_base_path_config_root_collapses_masc_input;
          Alcotest.test_case "config_bootstrap_mode parses env var" `Quick
            test_config_bootstrap_mode_parses_env;
          Alcotest.test_case
            "bootstrap empty mode creates scaffold without files"
            `Quick test_bootstrap_empty_mode_creates_scaffold_without_files;
          Alcotest.test_case "bootstrap skip mode creates nothing" `Quick
            test_bootstrap_skip_mode_creates_nothing;
          Alcotest.test_case "constructors stay pure" `Quick
            test_constructor_is_pure;
          Alcotest.test_case "restore_persisted_sessions uses flat agents dir"
            `Quick test_restore_persisted_sessions_uses_flat_agents_dir;
          Alcotest.test_case "keeper paths use cluster root" `Quick
            test_keeper_paths_use_cluster_root;
          Alcotest.test_case "tool usage log uses cluster root" `Quick
            test_tool_usage_log_uses_cluster_root;
          Alcotest.test_case "keeper tool call log uses cluster root" `Quick
            test_keeper_tool_call_log_uses_cluster_root;
          Alcotest.test_case "workspace init bootstraps keeper runtime dirs" `Quick
            test_workspace_init_bootstraps_keeper_runtime_dirs;
          Alcotest.test_case "otel exporter setup failure is soft" `Quick
            test_otel_exporter_setup_failure_is_soft;
          Alcotest.test_case "otel exporter setup is background" `Quick
            test_otel_exporter_setup_does_not_block_maintenance_wiring;
          Alcotest.test_case "lazy startup plan parallelizes independent tasks"
            `Quick test_lazy_startup_plan_groups_independent_tasks;
          Alcotest.test_case
            "keeper lifecycle refresh invalidates projection snapshot"
            `Quick
            test_keeper_lifecycle_refresh_invalidates_projection_snapshot;
          Alcotest.test_case "startup state json reports lazy failure" `Quick
            test_startup_state_json;
          Alcotest.test_case
            "startup catalog degradation survives lazy activation"
            `Quick
            test_startup_state_catalog_degraded_survives_lazy_activation;
          Alcotest.test_case
            "startup state retains concurrent lazy completions"
            `Quick
            test_startup_state_concurrent_lazy_completions_preserve_all_updates;
          Alcotest.test_case "liveness probe is always true" `Quick
            test_startup_state_liveness;
          Alcotest.test_case
            "health json surfaces durable paused keepers"
            `Quick test_health_json_surfaces_durable_paused_keepers;
          Alcotest.test_case
            "health json surfaces Keeper Owner turn"
            `Quick test_health_json_observes_owner_turn;
          Alcotest.test_case
            "health json surfaces board event collection failure"
            `Quick test_health_json_surfaces_board_event_collection_failure;
          Alcotest.test_case
            "health json surfaces keeper identity config/meta drift"
            `Quick
            test_keeper_identity_drift_health_json_surfaces_config_meta_split;
          Alcotest.test_case
            "health json treats explicit autoboot base as materializable"
            `Quick
            test_keeper_identity_drift_treats_explicit_autoboot_base_as_materializable;
          Alcotest.test_case
            "health json reports unclassified persisted pause without mutation"
            `Quick test_health_json_reports_unclassified_timeout_pause_without_mutation;
          Alcotest.test_case
            "health json reports dormant task owner as advisory"
            `Quick
            test_health_json_reports_dormant_task_owner_as_advisory;
          Alcotest.test_case
            "health json keeps awaiting verification in system LLM lane"
            `Quick
            test_health_json_keeps_awaiting_verification_in_system_llm_lane;
          Alcotest.test_case
            "health json reports non-keeper active task owner as advisory"
            `Quick
            test_health_json_reports_non_keeper_active_task_owner_as_advisory;
          Alcotest.test_case
            "health json preserves active task owner meta read error"
            `Quick
            test_health_json_preserves_active_task_owner_meta_read_error;
          Alcotest.test_case
            "health json degrades recovery-backed owner scan"
            `Quick test_health_json_degrades_recovery_backed_owner_scan;
          Alcotest.test_case
            "health json reuses canonical owner execution snapshot"
            `Quick
            test_health_json_reuses_canonical_owner_execution_snapshot;
          Alcotest.test_case
            "health json capacity uses execution snapshot"
            `Quick
            test_health_json_capacity_uses_execution_snapshot;
          Alcotest.test_case
            "health json keeps in-flight Running Keeper executable"
            `Quick
            test_health_json_keeps_in_flight_running_keeper_executable;
          Alcotest.test_case
            "health json blocked count matches named target blockers"
            `Quick
            test_health_json_blocked_count_matches_blocked_names_with_non_target_capacity;
          Alcotest.test_case
            "health json distinguishes failing executable keepers"
            `Quick test_health_json_distinguishes_failing_executable_keepers;
          Alcotest.test_case
            "health json blocks terminal configuration failures"
            `Quick test_health_json_blocks_terminal_configuration_failures;
          Alcotest.test_case
            "health json degrades recovering turn failures"
            `Quick test_health_json_degrades_recovering_turn_failures;
          Alcotest.test_case
            "health json reaction ledger unavailable shape"
            `Quick test_health_json_reaction_ledger_unavailable_shape;
          Alcotest.test_case
            "health json Keeper Owner unavailable shape"
            `Quick test_health_json_owner_unavailable_shape;
          Alcotest.test_case "health json surfaces log ring summary" `Quick
            test_health_json_surfaces_log_ring_summary;
          Alcotest.test_case
            "health json surfaces internal mcp auth diagnostics"
            `Quick
            test_health_json_surfaces_internal_mcp_auth_diagnostics;
          Alcotest.test_case "default health response is light probe" `Quick
            test_health_response_default_is_light_probe;
          Alcotest.test_case "full health query uses snapshot cache" `Quick
            test_health_response_full_query_uses_snapshot_cache;
          Alcotest.test_case "full health refresh timeout is independent"
            `Quick
            test_full_health_refresh_timing_uses_dedicated_budget;
          Alcotest.test_case
            "full health refresh timeout preserves last snapshot" `Quick
            test_full_health_refresh_timeout_preserves_last_snapshot;
          Alcotest.test_case
            "full health cold refresh timeout is timeout" `Quick
            test_full_health_cold_refresh_timeout_is_timeout_not_error;
          Alcotest.test_case "health response survives deleted cwd" `Quick
            test_health_response_survives_deleted_cwd;
          Alcotest.test_case "readiness false before init" `Quick
            test_startup_state_readiness_before_init;
          Alcotest.test_case "readiness true after init" `Quick
            test_startup_state_readiness_after_init;
          Alcotest.test_case
            "startup recovery settles disk-only keeper message request"
            `Quick
            test_keeper_msg_startup_recovery_settles_disk_only_running_request;
          Alcotest.test_case "MCP requires explicit readiness" `Quick
            test_mcp_transport_requires_explicit_readiness;
          Alcotest.test_case
            "lazy inventory stays blocking until explicit readiness"
            `Quick
            test_startup_state_lazy_inventory_does_not_publish_readiness;
          Alcotest.test_case
            "pre-ready init failure cannot degrade-continue"
            `Quick
            test_startup_failure_disposition_requires_readiness_for_degraded_serving;
          Alcotest.test_case "watchdog timeout env parsing" `Quick
            test_watchdog_timeout_env;
          Alcotest.test_case "startup json includes watchdog fields" `Quick
            test_startup_state_json_includes_watchdog;
          Alcotest.test_case "startup json includes runtime resolution" `Quick
            test_startup_state_json_includes_runtime_resolution;
          Alcotest.test_case
            "create_server_state records runtime resolution"
            `Quick test_create_server_state_records_runtime_resolution;
          Alcotest.test_case
            "create_server_state preserves raw input base path"
            `Quick test_create_server_state_preserves_raw_input_base_path;
          Alcotest.test_case
            "prompt markdown dir ignores repo seed prompts"
            `Quick test_prompt_markdown_dir_ignores_repo_seed_prompts;
          Alcotest.test_case
            "prompt markdown dir does not use repo seed"
            `Quick test_prompt_markdown_dir_does_not_use_repo_seed;
          Alcotest.test_case "prompt markdown dir honors MASC_CONFIG_DIR override"
            `Quick test_prompt_markdown_dir_honors_masc_config_dir_override;
          Alcotest.test_case
            "prompt markdown dir prefers resolved config dir over cwd fallback"
            `Quick
            test_prompt_markdown_dir_prefers_resolved_config_dir_over_cwd;
          Alcotest.test_case "main_eio serves health before lazy startup"
            `Slow test_main_eio_serves_health_before_lazy_startup;
          Alcotest.test_case
            "main_eio fresh bootstrap and MCP handshake"
            `Slow test_main_eio_fresh_bootstrap_and_mcp_handshake;
          Alcotest.test_case
            "main_eio preserves unmanaged mcp client token file"
            `Slow test_main_eio_preserves_cli_agent_mcp_token_file;
          Alcotest.test_case
            "startup sync mints bootable keeper credentials"
            `Quick test_sync_bootable_keeper_credentials_mints_keeper_token;
          Alcotest.test_case
            "startup admin env sync repairs raw token file"
            `Quick test_sync_admin_token_env_repairs_raw_token_file;
          Alcotest.test_case
            "startup sync rotates shared bootable keeper tokens"
            `Quick
            test_sync_bootable_keeper_credentials_rotates_shared_keeper_tokens;
          Alcotest.test_case
            "main_eio rejects second server on same base path"
            `Slow test_main_eio_rejects_same_base_path_on_second_server;
          Alcotest.test_case
            "main_eio partial catalog stays ready and surfaces rejections"
            `Slow
            test_main_eio_partial_catalog_stays_ready_and_surfaces_rejections;
          Alcotest.test_case
            "main_eio invalid default partial catalog stays degraded"
            `Slow
            test_main_eio_invalid_default_partial_catalog_stays_degraded;
          Alcotest.test_case
            "main_eio invalid runtime stays degraded but serves dashboard"
            `Slow
            test_main_eio_invalid_runtime_stays_degraded_but_serves_dashboard;
        ] );
    ]
