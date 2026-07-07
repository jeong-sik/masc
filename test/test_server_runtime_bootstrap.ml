module Types = Masc_domain

open Masc

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
let repo_model_catalog_toml = "[[models]]\nid_prefix = \"repo-runtime\"\n"

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  loop 0

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

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file (Filename.concat root "oas-models.toml") repo_model_catalog_toml;
  write_file (Filename.concat config "runtime.toml") repo_runtime_toml;
  write_file (Filename.concat config "tool_policy.toml")
    "[groups.base]\ntools = [\"keeper_time_now\"]\n";
  write_file (Filename.concat config "prompts/keeper.unified.system.md") "prompt";
  write_file (Filename.concat config "keepers/example.toml") "[keeper]\ngoal = \"example\"\n";
  write_file (Filename.concat config "personas/example.txt") "persona";
  config

let model_catalog_resolution_source_label
    (resolution : Server_runtime_bootstrap.model_catalog_env_resolution)
  =
  Server_runtime_bootstrap.model_catalog_env_source_to_string
    resolution.Server_runtime_bootstrap.source

let capability_manifest_resolution_source_label
    (resolution : Server_runtime_bootstrap.capability_manifest_env_resolution)
  =
  Server_runtime_bootstrap.capability_manifest_env_source_to_string
    resolution.Server_runtime_bootstrap.source

let test_model_catalog_resolution_prefers_explicit_env () =
  let env = function
    | "OAS_MODEL_CATALOG" -> Some "/explicit/oas-models.toml"
    | "MASC_MODEL_CATALOG" -> Some "/ignored/masc-models.toml"
    | _ -> None
  in
  (match
     Server_runtime_bootstrap.resolve_oas_model_catalog_path
       ~env
       ~cwd:"/tmp/outside"
       ~argv0:"/tmp/repo/_build/default/bin/main_eio.exe"
       ()
   with
   | None -> Alcotest.fail "expected explicit OAS_MODEL_CATALOG resolution"
   | Some resolution ->
     Alcotest.(check string)
       "source"
       "OAS_MODEL_CATALOG"
       (model_catalog_resolution_source_label resolution);
     Alcotest.(check string)
       "path"
       "/explicit/oas-models.toml"
       resolution.Server_runtime_bootstrap.path);
  let env = function
    | "MASC_MODEL_CATALOG" -> Some "/explicit/masc-models.toml"
    | _ -> None
  in
  match
    Server_runtime_bootstrap.resolve_oas_model_catalog_path
      ~env
      ~cwd:"/tmp/outside"
      ~argv0:"/tmp/repo/_build/default/bin/main_eio.exe"
      ()
  with
  | None -> Alcotest.fail "expected MASC_MODEL_CATALOG resolution"
  | Some resolution ->
    Alcotest.(check string)
      "source"
      "MASC_MODEL_CATALOG"
      (model_catalog_resolution_source_label resolution);
    Alcotest.(check string)
	      "path"
	      "/explicit/masc-models.toml"
	      resolution.Server_runtime_bootstrap.path

let test_capability_manifest_resolution_prefers_explicit_env () =
  let env = function
    | "OAS_CAPABILITY_MANIFEST" -> Some "/explicit/capability-manifest.json"
    | _ -> None
  in
  with_temp_dir "capability-manifest-bootstrap-explicit" (fun dir ->
    match
      Server_runtime_bootstrap.resolve_oas_capability_manifest_path
        ~env
        ~config_root:dir
        ()
    with
    | None -> Alcotest.fail "expected explicit OAS_CAPABILITY_MANIFEST resolution"
    | Some resolution ->
      Alcotest.(check string)
        "source"
        "OAS_CAPABILITY_MANIFEST"
        (capability_manifest_resolution_source_label resolution);
      Alcotest.(check string)
        "path"
        "/explicit/capability-manifest.json"
        resolution.Server_runtime_bootstrap.path)

let test_capability_manifest_configuration_uses_config_root_file () =
  with_temp_dir "capability-manifest-bootstrap-config-root" (fun config_root ->
    let manifest = Filename.concat config_root "capability-manifest.json" in
    write_file manifest {|{"schema_version":1,"models":[]}|};
    let putenv_calls = ref [] in
    let clear_calls = ref 0 in
    let load_calls = ref [] in
    let set_calls = ref 0 in
    let env _ = None in
    let result =
      Server_runtime_bootstrap.configure_oas_capability_manifest_env
        ~env
        ~config_root
        ~putenv:(fun name value -> putenv_calls := (name, value) :: !putenv_calls)
        ~clear_manifest:(fun () -> incr clear_calls)
        ~load_manifest:(fun path ->
          load_calls := path :: !load_calls;
          Some [])
        ~set_manifest:(fun (_ : Llm_provider.Capability_manifest.t) -> incr set_calls)
        ()
    in
    (match result with
     | None -> Alcotest.fail "expected config-root capability manifest resolution"
     | Some resolution ->
       Alcotest.(check string)
         "source"
         "config-root:capability-manifest.json"
         (capability_manifest_resolution_source_label resolution);
       Alcotest.(check string)
         "path"
         (canonical_path manifest)
         (canonical_path resolution.Server_runtime_bootstrap.path));
    Alcotest.(check (list (pair string string)))
      "putenv"
      [ "OAS_CAPABILITY_MANIFEST", manifest ]
      (List.rev !putenv_calls);
    Alcotest.(check int) "clear manifest cache" 1 !clear_calls;
    Alcotest.(check (list string)) "load manifest" [ manifest ] (List.rev !load_calls);
    Alcotest.(check int) "set manifest override" 1 !set_calls)

let test_model_catalog_configuration_installs_resolved_catalog () =
  with_temp_dir "model-catalog-bootstrap-install" (fun dir ->
    let repo = Filename.concat dir "repo" in
    let cwd = Filename.concat dir "base" in
    let bin = Filename.concat repo "_build/default/bin/main_eio.exe" in
    let catalog = Filename.concat repo "oas-models.toml" in
    mkdir_p (Filename.dirname bin);
    mkdir_p cwd;
    write_file bin "";
    write_file catalog "[[models]]\nid_prefix = \"example\"\n";
    let putenv_calls = ref [] in
    let clear_calls = ref 0 in
    let load_calls = ref [] in
    let set_calls = ref 0 in
    let result =
      Server_runtime_bootstrap.configure_oas_model_catalog_env
        ~env:(fun _ -> None)
        ~cwd
        ~argv0:bin
        ~putenv:(fun name value -> putenv_calls := (name, value) :: !putenv_calls)
        ~clear_catalog:(fun () -> incr clear_calls)
        ~load_catalog:(fun path ->
          load_calls := path :: !load_calls;
          Some Llm_provider.Model_catalog.empty)
        ~set_catalog:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_calls)
        ()
    in
    (match result with
     | None -> Alcotest.fail "expected executable-parent model catalog resolution"
     | Some resolution ->
       Alcotest.(check string)
         "source"
         "argv0-parent:oas-models.toml"
         (model_catalog_resolution_source_label resolution);
       Alcotest.(check string)
         "path"
         (canonical_path catalog)
         (canonical_path resolution.Server_runtime_bootstrap.path));
    Alcotest.(check (list (pair string string)))
      "putenv"
      [ "OAS_MODEL_CATALOG", catalog ]
      (List.rev !putenv_calls);
    Alcotest.(check int) "clear catalog cache" 1 !clear_calls;
    Alcotest.(check (list string)) "load catalog" [ catalog ] (List.rev !load_calls);
    Alcotest.(check int) "set catalog override" 1 !set_calls)

let test_model_catalog_configuration_prefers_config_root_catalog () =
  with_temp_dir "model-catalog-bootstrap-config-root" (fun dir ->
    let config_root = Filename.concat dir "config-root" in
    let outside = Filename.concat dir "outside" in
    let catalog = Filename.concat config_root "oas-models.toml" in
    mkdir_p config_root;
    mkdir_p outside;
    write_file catalog "[[models]]\nid_prefix = \"config-root-runtime\"\n";
    let putenv_calls = ref [] in
    let clear_calls = ref 0 in
    let load_calls = ref [] in
    let set_calls = ref 0 in
    let result =
      Server_runtime_bootstrap.configure_oas_model_catalog_env
        ~env:(fun _ -> None)
        ~config_root
        ~cwd:outside
        ~argv0:(Filename.concat outside "main_eio.exe")
        ~putenv:(fun name value -> putenv_calls := (name, value) :: !putenv_calls)
        ~clear_catalog:(fun () -> incr clear_calls)
        ~load_catalog:(fun path ->
          load_calls := path :: !load_calls;
          Some Llm_provider.Model_catalog.empty)
        ~set_catalog:(fun (_ : Llm_provider.Model_catalog.t) -> incr set_calls)
        ()
    in
    (match result with
     | None -> Alcotest.fail "expected config-root model catalog resolution"
     | Some resolution ->
       Alcotest.(check string)
         "source"
         "config-root:oas-models.toml"
         (model_catalog_resolution_source_label resolution);
       Alcotest.(check string)
         "path"
         (canonical_path catalog)
         (canonical_path resolution.Server_runtime_bootstrap.path));
    Alcotest.(check (list (pair string string)))
      "putenv"
      [ "OAS_MODEL_CATALOG", catalog ]
      (List.rev !putenv_calls);
    Alcotest.(check int) "clear catalog cache" 1 !clear_calls;
    Alcotest.(check (list string)) "load catalog" [ catalog ] (List.rev !load_calls);
    Alcotest.(check int) "set catalog override" 1 !set_calls)

let test_model_catalog_resolution_uses_executable_parent_when_cwd_is_base_path () =
  with_temp_dir "model-catalog-bootstrap" (fun dir ->
    let repo = Filename.concat dir "repo" in
    let bin_dir = Filename.concat repo "_build/default/bin" in
    mkdir_p bin_dir;
    let outside = Filename.concat dir "base-path" in
    Unix.mkdir outside 0o755;
    let catalog = Filename.concat repo "oas-models.toml" in
    write_file catalog "# repo-local OAS catalog\n";
    let argv0 = Filename.concat bin_dir "main_eio.exe" in
    let env _ = None in
    match
      Server_runtime_bootstrap.resolve_oas_model_catalog_path
        ~env
        ~cwd:outside
        ~argv0
        ()
    with
    | None ->
      Alcotest.fail
        "expected repo oas-models.toml from executable parent when cwd has no catalog"
    | Some resolution ->
      Alcotest.(check string)
        "source"
        "argv0-parent:oas-models.toml"
        (model_catalog_resolution_source_label resolution);
      Alcotest.(check string)
        "path"
        (canonical_path catalog)
        (canonical_path resolution.Server_runtime_bootstrap.path))

let test_model_catalog_resolution_resolves_relative_argv0_from_process_cwd () =
  with_temp_dir "model-catalog-bootstrap-relative" (fun dir ->
    let repo = Filename.concat dir "repo" in
    let bin_dir = Filename.concat repo "_build/default/bin" in
    mkdir_p bin_dir;
    let outside = Filename.concat dir "base-path" in
    Unix.mkdir outside 0o755;
    let catalog = Filename.concat repo "oas-models.toml" in
    write_file catalog "# repo-local OAS catalog\n";
    let env _ = None in
    with_cwd repo @@ fun () ->
    match
      Server_runtime_bootstrap.resolve_oas_model_catalog_path
        ~env
        ~cwd:outside
        ~argv0:"./_build/default/bin/main_eio.exe"
        ()
    with
    | None ->
      Alcotest.fail
        "expected repo oas-models.toml from relative executable argv0"
    | Some resolution ->
      Alcotest.(check string)
        "source"
        "argv0-parent:oas-models.toml"
        (model_catalog_resolution_source_label resolution);
      Alcotest.(check string)
        "path"
        (canonical_path catalog)
        (canonical_path resolution.Server_runtime_bootstrap.path))

let test_model_catalog_configuration_delegates_to_agent_sdk_ambient () =
  with_temp_dir "model-catalog-bootstrap-agent-sdk" (fun dir ->
    let putenv_calls = ref [] in
    let preload_calls = ref 0 in
    let env _ = None in
    let result =
      Server_runtime_bootstrap.configure_oas_model_catalog_env
        ~env
        ~cwd:dir
        ~argv0:(Filename.concat dir "main_eio.exe")
        ~putenv:(fun name value -> putenv_calls := (name, value) :: !putenv_calls)
        ~preload_agent_sdk_catalog:(fun () -> incr preload_calls)
        ~agent_sdk_catalog:(fun () -> Some Llm_provider.Model_catalog.empty)
        ()
    in
    Alcotest.(check bool) "no explicit path resolution" true (Option.is_none result);
    Alcotest.(check int) "preload called once" 1 !preload_calls;
    Alcotest.(check int) "does not write OAS_MODEL_CATALOG" 0
      (List.length !putenv_calls))

let write_config_root_keeper_toml config_root name =
  write_file
    (Filename.concat (Filename.concat config_root "keepers") (name ^ ".toml"))
    (Printf.sprintf "[keeper]\ngoal = \"goal-%s\"\n" name)

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
goal = "example"
proactive_enabled = false
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
  match Unix.fork () with
  | 0 ->
      let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
      Unix.listen socket 16;
      let payload =
        Printf.sprintf
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
          (String.length response) response
      in
      let buffer = Bytes.create 4096 in
      let rec loop () =
        let client, _ = Unix.accept socket in
        Fun.protect
          ~finally:(fun () -> Unix.close client)
          (fun () ->
            ignore
              (try Unix.read client buffer 0 (Bytes.length buffer)
               with Unix.Unix_error _ -> 0);
            ignore (Unix.write_substring client payload 0 (String.length payload)));
        loop ()
      in
      loop ()
  | pid ->
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

let find_main_eio_exe () =
  let root = project_root () in
  let shared_root =
    root |> Filename.dirname |> Filename.dirname |> Filename.dirname
  in
  let build_roots = [ root; Filename.dirname root; shared_root ] in
  let candidates =
    [
      Filename.concat root "bin/main_eio.exe";
      Filename.concat root "_build/default/bin/main_eio.exe";
      Filename.concat root "_build/default/masc/bin/main_eio.exe";
    ]
    @ List.concat_map
        (fun base ->
          [
            Filename.concat base "bin/main_eio.exe";
            Filename.concat base "_build/default/bin/main_eio.exe";
            Filename.concat base "_build/default/masc/bin/main_eio.exe";
          ])
        build_roots
    @ [
      Filename.concat shared_root "_build/default/bin/main_eio.exe";
      Filename.concat shared_root "_build/default/masc/bin/main_eio.exe";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "main_eio executable not found"

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
      Alcotest.(check bool) "tool policy not copied (deleted module)" false
        (Sys.file_exists (Filename.concat config_root "tool_policy.toml"));
      Alcotest.(check string) "model catalog copied" repo_model_catalog_toml
        (read_file (Filename.concat config_root "oas-models.toml"));
      Alcotest.(check bool) "prompt copied" true
        (Sys.file_exists
           (Filename.concat config_root "prompts/keeper.unified.system.md"));
      Alcotest.(check bool) "keepers dir created" true
        (Sys.file_exists (Filename.concat config_root "keepers"));
      Alcotest.(check bool) "repo keeper TOML not copied" false
        (Sys.file_exists (Filename.concat config_root "keepers/example.toml")))

let test_bootstrap_base_path_config_root_backfills_missing_prompts_and_catalog () =
  with_temp_dir "startup-config-preserve" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      let config_root = Filename.concat base_path ".masc/config" in
      mkdir_p config_root;
      write_file (Filename.concat config_root "runtime.toml") local_runtime_toml;
      mkdir_p (Filename.concat config_root "personas");
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
           (Filename.concat config_root "prompts/keeper.unified.system.md"));
      Alcotest.(check string) "backfilled prompt content" "prompt"
        (read_file (Filename.concat config_root "prompts/keeper.unified.system.md"));
      Alcotest.(check string) "model catalog backfilled" repo_model_catalog_toml
        (read_file (Filename.concat config_root "oas-models.toml"));
      Alcotest.(check bool) "versioned persona not resurrected" false
        (Sys.file_exists (Filename.concat config_root "personas/example.txt"));
      Alcotest.(check bool) "tool policy not backfilled" false
        (Sys.file_exists (Filename.concat config_root "tool_policy.toml")))

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
      mkdir_p (Filename.concat config_root "personas");
      write_file (Filename.concat config_root "runtime.toml") "";
      write_file (Filename.concat config_root "tool_policy.toml")
        "[groups.base]\ntools = [\"keeper_time_now\"]\n";
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
      Alcotest.(check bool) "personas dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "personas"));
      Alcotest.(check bool) "prompts dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "prompts"));
      Alcotest.(check bool) "runtime not copied" false
        (Sys.file_exists (Filename.concat config_root "runtime.toml"));
      Alcotest.(check bool) "tool policy not copied" false
        (Sys.file_exists (Filename.concat config_root "tool_policy.toml"));
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
      let state = Mcp_server.create_state ~base_path:dir in
      Alcotest.(check int) "constructor does not restore persisted sessions" 0
        (List.length (Session.connected_agents state.Mcp_server.session_registry)))

let test_restore_persisted_sessions_uses_flat_agents_dir () =
  with_temp_dir "startup-scope" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
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
            ~tool_name:"keeper_tasks_list" ~success:true
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
          Alcotest.(check int) "tool_usage row readable from cluster store" 1
            (List.length (Tool_usage_log.read_recent ~n:10 ()))))

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

let make_keeper_meta_json ?(name = "sangsu")
    ?(trace_id = "trace-sangsu-live")
    ?(updated_at = "2026-03-29T10:36:57Z") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String trace_id);
          ("goal", `String ("goal-" ^ name));
          ("runtime_id", `String (fixture_runtime_id ()));
          ("updated_at", `String updated_at);
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta -> Keeper_meta_json.meta_to_json meta |> Yojson.Safe.pretty_to_string
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

let make_keeper_meta ?(paused = false) ?(name = "sangsu")
    ?(trace_id = "trace-sangsu-live")
    ?(updated_at = "2026-03-29T10:36:57Z") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String trace_id);
          ("goal", `String ("goal-" ^ name));
          ("runtime_id", `String (fixture_runtime_id ()));
          ("updated_at", `String updated_at);
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta ->
      {
        meta with
        paused;
        auto_resume_after_sec = (if paused then Some 3600.0 else None);
      }
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
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    reclaim_policy = None;
    do_not_reclaim_reason = None;
  }

let terminal_fixture_epoch = 0.0

let write_keeper_meta_exn config meta =
  match Keeper_meta_store.write_meta config meta with
  | Ok () -> ()
  | Error err -> Alcotest.fail ("keeper meta write failed: " ^ err)

let with_running_keeper_metas config metas f =
  let base_path = config.Workspace.base_path in
  List.iter
    (fun (meta : Keeper_meta_contract.keeper_meta) ->
      Keeper_registry.unregister ~base_path meta.name;
      ignore (Keeper_registry.register ~base_path meta.name meta))
    metas;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (meta : Keeper_meta_contract.keeper_meta) ->
          Keeper_registry.unregister ~base_path meta.name)
        metas)
    f

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
    (Keeper_state_machine.Turn_failed { consecutive = 1; max_allowed = 10 })

let mark_keeper_stopped config (meta : Keeper_meta_contract.keeper_meta) =
  dispatch_keeper_event config meta Keeper_state_machine.Stop_requested;
  dispatch_keeper_event config meta Keeper_state_machine.Drain_complete

let mark_keeper_zombie config (meta : Keeper_meta_contract.keeper_meta) =
  dispatch_keeper_event config meta
    (Keeper_state_machine.Terminal_failure_detected
       { reason = "terminal fixture structural failure" })

let exhaust_keeper_restart_budget config (meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_registry.dispatch_event
      ~base_path:config.Workspace.base_path
      meta.name
      Keeper_state_machine.Restart_budget_exhausted
  with
  | Ok _ -> ()
  | Error err ->
    Alcotest.fail
      ("keeper restart-budget exhaustion failed: "
       ^ Keeper_state_machine.transition_error_to_string err)

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
  Keeper_registry.record_restart ~base_path meta.name;
  Keeper_registry.record_restart ~base_path meta.name;
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
            reason = None;
          }));
  Keeper_registry.set_last_error_entry ~base_path ~name:meta.name
    (Printf.sprintf
       "synthetic cancelled by parent sk-testsecret at %s/private/state.json"
       base_path);
  Keeper_registry.record_crash ~base_path meta.name 1780000000.0
    (Printf.sprintf
       "synthetic crash record github_pat_secret at %s/crash.log"
       base_path);
  Keeper_registry.mark_dead ~base_path meta.name ~at:1780000001.0

let test_health_json_surfaces_durable_paused_keepers () =
  with_temp_dir "health-durable-paused-keepers" (fun dir ->
      let config_root = make_config_root dir in
      List.iter
        (write_config_root_keeper_toml config_root)
        [ "durable-paused" ];
      with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
      let previous_state = !Server_auth.server_state in
      Config_dir_resolver.reset ();
      Fun.protect
        ~finally:(fun () ->
          Server_auth.server_state := previous_state;
          Config_dir_resolver.reset ())
        (fun () ->
          let state = Mcp_server.create_state ~base_path:dir in
          Server_auth.server_state := Some state;
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
          let fd_pressure = json |> member "keeper_fd_pressure" in
          let fd_accountant = json |> member "fd_accountant" in
          let runtime_truth = json |> member "runtime_truth" in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          let reaction_ledger = json |> member "keeper_reaction_ledger" in
          let durable_names =
            paused |> member "durable_names" |> to_list |> List.map to_string
          in
	          let names = paused |> member "names" |> to_list |> List.map to_string in
	          Alcotest.(check int) "durable paused count" 1
	            (paused |> member "durable_count" |> to_int);
	          Alcotest.(check int) "registry paused count" 0
	            (paused |> member "registry_paused_count" |> to_int);
	          Alcotest.(check string) "legacy running count semantics"
	            "legacy alias for registry_paused_count"
	            (paused |> member "running_count_semantics" |> to_string);
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
          Alcotest.(check string) "pause kind" "auto_recoverable"
            (durable_paused_detail |> member "pause_kind" |> to_string);
          Alcotest.(check bool) "pause missing root cause" true
            (durable_paused_detail |> member "missing_pause_root_cause" |> to_bool);
          Alcotest.(check bool) "pause detail keeps autoboot" true
            (durable_paused_detail |> member "autoboot_enabled" |> to_bool);
          Alcotest.(check (option (float 0.0001))) "pause detail auto resume"
            (Some 3600.0)
            (durable_paused_detail |> member "auto_resume_after_sec" |> to_float_option);
          Alcotest.(check bool) "union includes durable paused keeper" true
            (List.exists (( = ) "durable-paused") names);
          Alcotest.(check bool) "union excludes active durable keeper" false
            (List.exists (( = ) "durable-active") names);
          Alcotest.(check int) "durable read errors" 0
            (paused |> member "read_error_count" |> to_int);
          Alcotest.(check int) "health exposes requested 24-keeper FD budget"
            24
            (fd_pressure |> member "requested_keepers" |> to_int);
          Alcotest.(check int) "health exposes target 24-keeper FD budget" 24
            (fd_pressure |> member "target_keeper_count" |> to_int);
          ignore (fd_pressure |> member "status" |> to_string);
          ignore (fd_pressure |> member "admission_blocked" |> to_bool);
          ignore
            (fd_pressure |> member "admission_decision" |> member "status" |> to_string);
          ignore (fd_accountant |> member "fd_open" |> to_int);
          ignore (fd_accountant |> member "fd_limit" |> to_int);
          ignore (fd_accountant |> member "pressure_active" |> to_bool);
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
          ignore (runtime_truth |> member "fd_open" |> to_int);
          ignore (runtime_truth |> member "fd_limit" |> to_int);
          ignore (runtime_truth |> member "fd_pressure_active" |> to_bool);
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
              ignore (row |> member "in_flight" |> to_int);
              ignore (row |> member "configured_concurrency" |> to_int);
              ignore (row |> member "effective_concurrency" |> to_int))
            Fd_accountant.all_kinds;
          Alcotest.(check int) "health exposes bootable keeper count" 1
            (fleet_safety |> member "bootable_keeper_count" |> to_int);
          Alcotest.(check int) "health exposes autoboot keeper count" 1
            (fleet_safety |> member "autoboot_enabled_keeper_count" |> to_int);
          Alcotest.(check int) "health exposes paused autoboot keeper count" 1
            (fleet_safety |> member "paused_autoboot_enabled_keeper_count" |> to_int);
          Alcotest.(check int) "health exposes target reaction capacity" 1
            (fleet_safety |> member "target_reaction_capacity_count" |> to_int);
          Alcotest.(check int) "health exposes minimum running fibers" 1
            (fleet_safety |> member "minimum_running_fibers" |> to_int);
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

let test_health_json_surfaces_keeper_turn_admission_pressure () =
  with_temp_dir "health-turn-admission-pressure" (fun dir ->
    let config_root = make_config_root dir in
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Keeper_turn_admission.For_testing.reset ();
    Fun.protect
      ~finally:(fun () ->
        Keeper_turn_admission.For_testing.reset ();
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let keeper_name = "example" in
        Eio.Switch.run (fun sw ->
          let started, set_started = Eio.Promise.create () in
          let release, set_release = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
            ignore
              (Keeper_turn_admission.run_serialized
                 ~base_path:dir
                 ~keeper_name
                 (fun () ->
                   Eio.Promise.resolve set_started ();
                   Eio.Promise.await release)));
          Eio.Promise.await started;
          for _ = 1 to Keeper_turn_admission.max_waiting_chat_requests do
            Eio.Fiber.fork ~sw (fun () ->
              ignore
                (Keeper_turn_admission.run_serialized
                   ~base_path:dir
                   ~keeper_name
                   (fun () -> ())))
          done;
          (match
             Keeper_turn_admission.run_serialized
               ~base_path:dir
               ~keeper_name
               (fun () -> ())
           with
           | `Rejected _ -> ()
           | `Ran () ->
             Alcotest.fail "chat request beyond the waiting cap was not rejected");
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let admission = json |> member "keeper_turn_admission" in
          Alcotest.(check string) "turn admission health degraded"
            "degraded"
            (admission |> member "status" |> to_string);
          Alcotest.(check int) "turn admission health full queue count"
            1
            (admission |> member "chat_waiting_full_keeper_count" |> to_int);
          Alcotest.(check int) "turn admission health rejection count"
            1
            (admission |> member "chat_rejected_total_count" |> to_int);
          Alcotest.(check bool) "turn admission health reason surfaced"
            true
            (admission |> member "status_reasons" |> to_list
             |> List.map to_string
             |> List.exists (String.equal "chat_waiting_queue_full"));
          Alcotest.(check bool)
            "top-level health preserves turn admission reason"
            true
            (json |> member "operator_action_reasons" |> to_list
             |> List.map to_string
             |> List.exists
                  (String.equal
                     "keeper_turn_admission:chat_waiting_queue_full"));
          let runtime_resolution =
            `Assoc
              (Server_routes_http_runtime.keeper_fleet_runtime_resolution_fields ())
          in
          let runtime_admission =
            runtime_resolution |> member "keeper_turn_admission"
          in
          Alcotest.(check int)
            "runtime resolution exposes turn admission full queue count"
            1
            (runtime_admission |> member "chat_waiting_full_keeper_count"
             |> to_int);
          Alcotest.(check int)
            "runtime resolution exposes turn admission rejection count"
            1
            (runtime_admission |> member "chat_rejected_total_count" |> to_int);
          let light_runtime_resolution =
            `Assoc
              (Server_routes_http_runtime.keeper_fleet_runtime_resolution_light_fields ())
          in
          let light_runtime_admission =
            light_runtime_resolution |> member "keeper_turn_admission"
          in
          Alcotest.(check int)
            "light runtime resolution exposes turn admission full queue count"
            1
            (light_runtime_admission |> member "chat_waiting_full_keeper_count"
             |> to_int);
          Eio.Promise.resolve set_release ())))

let test_health_json_surfaces_board_event_collection_failure () =
  with_temp_dir "health-board-event-collection-failure" (fun dir ->
    let config_root = make_config_root dir in
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Keeper_heartbeat_loop_board_events.For_testing.reset ();
    Fun.protect
      ~finally:(fun () ->
        Keeper_heartbeat_loop_board_events.For_testing.reset ();
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
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
        Alcotest.(check int) "board collection failed keeper count"
          1
          (collection |> member "failed_keeper_count" |> to_int);
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
          "runtime resolution exposes board collection failed keeper count"
          1
          (runtime_collection |> member "failed_keeper_count" |> to_int);
        let light_runtime_resolution =
          `Assoc
            (Server_routes_http_runtime.keeper_fleet_runtime_resolution_light_fields ())
        in
        let light_runtime_collection =
          light_runtime_resolution |> member "keeper_board_event_collection"
        in
        Alcotest.(check int)
          "light runtime resolution exposes board collection failed keeper count"
          1
          (light_runtime_collection |> member "failed_keeper_count" |> to_int)))

let test_keeper_identity_drift_health_json_surfaces_config_meta_split () =
  with_temp_dir "keeper-identity-drift" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    write_config_root_keeper_toml config_root "mad-improver";
    write_file
      (Filename.concat (Filename.concat config_root "keepers") "operator.toml")
      "[keeper]\ngoal = \"operator\"\nautoboot_enabled = false\n";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = Mcp_server.workspace_config state in
        write_keeper_meta_exn config
          (make_keeper_meta ~name:"masc-improver" ~trace_id:"trace-masc-improver" ());
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
          [ "masc-improver"; "operator" ]
          (json |> member "persisted_meta_names" |> to_list |> List.map to_string);
        Alcotest.(check (list string)) "configured without meta"
          [ "mad-improver" ]
          (json |> member "configured_without_meta_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list string)) "meta without config"
          [ "masc-improver" ]
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
      "[keeper]\nautoboot_enabled = true\ninstructions = \"default keeper\"\n";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
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

let test_health_json_keeps_timeout_pause_without_policy_manual () =
  with_temp_dir "health-timeout-paused-without-policy" (fun dir ->
    let config_root = make_config_root dir in
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        let timeout_paused =
          { (make_keeper_meta
               ~name:"timeout-without-policy"
               ~trace_id:"trace-timeout-without-policy"
               ~paused:true
               ())
            with
            auto_resume_after_sec = None;
            runtime =
              { (make_keeper_meta ()).runtime with
                last_blocker =
                  Some
                    (Keeper_meta_contract.blocker_info_of_class
                       ~detail:"turn_timeout"
                       Keeper_meta_contract.Turn_timeout);
              };
          }
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
        Alcotest.(check string) "pause kind" "auto_recoverable"
          (detail |> member "pause_kind" |> to_string);
        Alcotest.(check bool) "effective auto resume is present" true
          (Option.is_some
             (detail |> member "auto_resume_after_sec" |> to_float_option));
        Alcotest.(check (option (float 0.0001))) "persisted auto resume remains absent"
          None
          (detail |> member "persisted_auto_resume_after_sec" |> to_float_option);
        Alcotest.(check string) "auto resume source" "implicit_turn_timeout"
          (detail |> member "auto_resume_source" |> to_string);
        Alcotest.(check string) "last blocker class" "turn_timeout"
          (detail |> member "last_blocker" |> member "klass" |> to_string)))

let test_health_json_reports_dormant_task_owner_as_advisory () =
  with_temp_dir "health-active-task-owner-without-fiber" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    write_file
      (Filename.concat (Filename.concat config_root "keepers") "executor.toml")
      "[keeper]\ngoal = \"goal-executor\"\nautoboot_enabled = false\n";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = Mcp_server.workspace_config state in
        let executor =
          make_keeper_meta ~name:"executor" ~trace_id:"trace-executor" ()
        in
        write_keeper_meta_exn config executor;
        let task =
          make_task
            ~id:"task-active-owner"
            ~title:"Active keeper task"
            ~status:
              (Types.InProgress
                 {
                   assignee = executor.Keeper_meta_contract.agent_name;
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

let test_health_json_ignores_stale_active_task_alias_when_agent_executable () =
  with_temp_dir "health-active-task-owner-executable-alias" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    List.iter (write_config_root_keeper_toml config_root) [ "executor"; "executor-stale" ];
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = Mcp_server.workspace_config state in
        let executor =
          make_keeper_meta ~name:"executor" ~trace_id:"trace-executor" ()
        in
        let stale_executor =
          {
            (make_keeper_meta
               ~name:"executor-stale"
               ~trace_id:"trace-executor-stale"
               ())
            with
            Keeper_meta_contract.agent_name = executor.agent_name;
          }
        in
        write_keeper_meta_exn config executor;
        write_keeper_meta_exn config stale_executor;
        let task =
          make_task
            ~id:"task-active-owner"
            ~title:"Active keeper task"
            ~status:
              (Types.InProgress
                 {
                   assignee = executor.Keeper_meta_contract.agent_name;
                   started_at = "2026-06-26T00:00:01Z";
                 })
            ()
        in
        Workspace.write_backlog config
          { Types.tasks = [ task ]; last_updated = "2026-06-26T00:00:02Z"; version = 2 };
        let phase_counts :
            Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
          { running = 1; failing = 0; recovering = 0; executable = 1 }
        in
        let phase_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
          {
            counts = phase_counts;
            running_names = [ executor.name ];
            recovering_names = [];
            executable_names = [ executor.name ];
            phase_values = [ (executor.name, Keeper_state_machine.Running) ];
            phase_details =
              [
                ( executor.name
                , {
                    phase = "running";
                    last_failure_reason = None;
                    last_error = None;
                    restart_count = 0;
                    dead_since_ts = None;
                    latest_crash_at = None;
                    latest_crash_reason = None;
                  } );
              ];
          }
        in
        let fleet_safety =
          Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
            ~bootable_names:[]
            ~autoboot_scan:
              Server_routes_http_runtime_fleet_scan.empty_autoboot_keeper_scan
            ~phase_snapshot
            ~phase_counts
            ~paused_keepers_json:(`Assoc [ ("count", `Int 0) ])
            ()
        in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "health remains ok" "ok"
          (fleet_safety |> member "status" |> to_string);
        Alcotest.(check bool) "health does not flag stale alias" false
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber"
           |> to_bool);
        Alcotest.(check int) "health reports no active owner rows" 0
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_count"
           |> to_int);
        Alcotest.(check bool) "health does not require operator action" false
          (fleet_safety |> member "operator_action_required" |> to_bool)))

let test_health_json_degrades_on_active_task_owner_without_keeper_binding () =
  with_temp_dir "health-active-task-owner-without-binding" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = Mcp_server.workspace_config state in
        let assignee = "missing-keeper-agent" in
        let task =
          make_task
            ~id:"task-active-owner-without-binding"
            ~title:"Active keeper task without binding"
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
        Alcotest.(check string) "health marks missing binding degraded"
          "degraded"
          (fleet_safety |> member "status" |> to_string);
        Alcotest.(check string) "health marks missing binding blocker"
          "active_task_owner_without_executable_fiber"
          (fleet_safety |> member "blocker" |> to_string);
        Alcotest.(check bool) "health exposes missing binding flag" true
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber"
           |> to_bool);
        Alcotest.(check int) "health exposes missing binding row count" 1
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_count"
           |> to_int);
        Alcotest.(check (list string)) "health has no keeper names"
          []
          (fleet_safety
           |> member "active_task_owner_without_executable_fiber_names"
           |> to_list
           |> List.map to_string);
        let active_owner_tasks =
          fleet_safety
          |> member "active_task_owner_without_executable_fiber_tasks"
          |> to_list
        in
        Alcotest.(check int) "health exposes missing binding task row" 1
          (List.length active_owner_tasks);
        let active_owner_task = List.hd active_owner_tasks in
        Alcotest.(check bool) "missing binding row keeper null" true
          (active_owner_task |> member "keeper" = `Null);
        Alcotest.(check bool) "missing binding row name null" true
          (active_owner_task |> member "name" = `Null);
        Alcotest.(check string) "missing binding row agent" assignee
          (active_owner_task |> member "agent_name" |> to_string);
        Alcotest.(check string) "missing binding row task id"
          "task-active-owner-without-binding"
          (active_owner_task |> member "task_id" |> to_string);
        Alcotest.(check string) "missing binding action"
          "create_keeper_or_reassign_task"
          (active_owner_task |> member "action" |> to_string);
        Alcotest.(check (list string)) "health names missing binding assignee"
          [ assignee ]
          (fleet_safety |> member "blocked_keeper_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list (pair string string)))
          "health explains missing binding blocker"
          [ (assignee, "no_keeper_binding") ]
          (fleet_safety |> member "blocked_keeper_reasons" |> to_list
           |> List.map (fun row ->
                ( row |> member "agent_name" |> to_string
                , row |> member "reason" |> to_string )));
        Alcotest.(check bool) "health asks operator action" true
          (fleet_safety |> member "operator_action_required" |> to_bool)))

let test_health_json_reports_non_keeper_active_task_owner_as_advisory () =
  with_temp_dir "health-non-keeper-active-task-owner" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
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
          (fleet_safety |> member "blocked_keeper_names" |> to_list
           |> List.map to_string);
        Alcotest.(check bool) "health does not ask operator action" false
          (fleet_safety |> member "operator_action_required" |> to_bool)))

let test_health_json_preserves_active_task_owner_meta_read_error () =
  with_temp_dir "health-active-task-owner-meta-read-error" (fun dir ->
    let config_root = make_config_root dir in
    Sys.remove (Filename.concat (Filename.concat config_root "keepers") "example.toml");
    write_config_root_keeper_toml config_root "broken";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
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
          { running = 0; failing = 0; recovering = 0; executable = 0 }
        in
        let phase_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
          {
            counts = phase_counts;
            running_names = [];
            recovering_names = [];
            executable_names = [];
            phase_values = [];
            phase_details = [];
          }
        in
        let fleet_safety =
          Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
            ~bootable_names:[]
            ~autoboot_scan:
              Server_routes_http_runtime_fleet_scan.empty_autoboot_keeper_scan
            ~phase_snapshot
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

let test_health_json_degrades_when_reaction_capacity_below_target () =
  with_temp_dir "health-reaction-capacity-below-target" (fun dir ->
    let config_root = make_config_root dir in
    List.iter
      (write_config_root_keeper_toml config_root)
      [
        "capacity-paused";
        "capacity-running-a";
        "capacity-running-b";
        "capacity-missing";
      ];
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        let paused =
          make_keeper_meta ~name:"capacity-paused" ~trace_id:"trace-capacity-paused"
            ~paused:true ()
        in
        let paused =
          {
            paused with
            runtime =
              {
                paused.runtime with
                last_blocker =
                  Some
                    (Keeper_meta_contract.blocker_info_of_class
                       ~detail:"no_progress loop detected"
                       Keeper_meta_contract.No_progress_loop);
              };
          }
        in
        let running_a =
          make_keeper_meta ~name:"capacity-running-a"
            ~trace_id:"trace-capacity-running-a" ()
        in
        let running_b =
          make_keeper_meta ~name:"capacity-running-b"
            ~trace_id:"trace-capacity-running-b" ()
        in
        let runtime_only =
          make_keeper_meta ~name:"runtime-only" ~trace_id:"trace-runtime-only" ()
        in
        List.iter
          (write_keeper_meta_exn config)
          [ paused; running_a; running_b; runtime_only ];
        with_running_keeper_metas config
          [ paused; running_a; running_b; runtime_only ]
          (fun () ->
            let request = Httpun.Request.create `GET "/health" in
            let json = Server_routes_http_runtime.make_health_json request in
            let open Yojson.Safe.Util in
            let paused_keepers = json |> member "paused_keepers" in
            let fleet_safety = json |> member "keeper_fleet_safety" in
            Alcotest.(check int) "health exposes running reaction capacity" 3
              (fleet_safety |> member "effective_reaction_capacity_count" |> to_int);
            Alcotest.(check int) "health exposes executable reaction capacity" 3
              (fleet_safety |> member "executable_reaction_capacity_count" |> to_int);
            Alcotest.(check (list string))
              "health excludes paused registry entries from running capacity"
              [ "capacity-running-a"; "capacity-running-b"; "runtime-only" ]
              (fleet_safety |> member "running_keeper_names" |> to_list
               |> List.map to_string);
            Alcotest.(check int) "health exposes failing keeper count" 0
              (fleet_safety |> member "failing_keeper_fiber_count" |> to_int);
            Alcotest.(check int) "health exposes target reaction capacity" 4
              (fleet_safety |> member "target_reaction_capacity_count" |> to_int);
            Alcotest.(check int) "health exposes paused autoboot target separately" 1
              (fleet_safety
               |> member "paused_autoboot_enabled_keeper_count"
               |> to_int);
            Alcotest.(check (list string))
              "health keeps durable paused keeper in paused inventory"
              [ "capacity-paused" ]
              (paused_keepers |> member "durable_names" |> to_list
               |> List.map to_string);
          Alcotest.(check int) "health exposes minimum running fibers" 2
            (fleet_safety |> member "minimum_running_fibers" |> to_int);
          Alcotest.(check bool) "health is not below minimum margin" false
            (fleet_safety |> member "low_running_fiber_margin" |> to_bool);
          Alcotest.(check bool) "health marks capacity below target" true
            (fleet_safety |> member "reaction_capacity_below_target" |> to_bool);
          Alcotest.(check int) "health exposes capacity shortfall" 1
            (fleet_safety |> member "reaction_capacity_shortfall_count" |> to_int);
          Alcotest.(check int) "health exposes executable capacity shortfall" 1
            (fleet_safety
             |> member "executable_reaction_capacity_shortfall_count"
             |> to_int);
          Alcotest.(check int) "health exposes blocked keeper count" 2
            (fleet_safety |> member "blocked_count" |> to_int);
          Alcotest.(check (list string)) "health exposes blocked keeper names"
            [ "capacity-missing"; "example" ]
            (fleet_safety |> member "blocked_keeper_names" |> to_list
             |> List.map to_string);
          Alcotest.(check (list (pair string string)))
            "health explains blocked keeper reasons"
            [ ("capacity-missing", "not_registered"); ("example", "not_registered") ]
            (fleet_safety |> member "blocked_keeper_reasons" |> to_list
             |> List.map (fun row ->
                  (row |> member "keeper" |> to_string, row |> member "reason" |> to_string)));
          let blocked_detail name =
            fleet_safety |> member "blocked_keeper_reasons" |> to_list
            |> List.find (fun row -> row |> member "keeper" |> to_string = name)
          in
          Alcotest.(check string) "health keeps typed row name alias"
            "capacity-missing"
            (blocked_detail "capacity-missing" |> member "name" |> to_string);
          Alcotest.(check string) "health suggests missing target action"
            "start_or_recover_keeper"
            (blocked_detail "capacity-missing" |> member "action" |> to_string);
          Alcotest.(check string) "health suggests unregistered action"
            "start_or_recover_keeper"
            (blocked_detail "example" |> member "action" |> to_string);
          Alcotest.(check bool) "health reports bootstrap enabled" true
            (fleet_safety |> member "keeper_bootstrap_enabled" |> to_bool);
          Alcotest.(check bool) "health has no bootstrap blocker" true
            (fleet_safety |> member "keeper_bootstrap_blocker" = `Null);
          Alcotest.(check string) "health marks fleet degraded" "degraded"
            (fleet_safety |> member "status" |> to_string);
          Alcotest.(check string) "health marks target-capacity blocker"
            "reaction_capacity_below_target"
            (fleet_safety |> member "blocker" |> to_string);
          Alcotest.(check bool) "health fleet asks for operator action" true
            (fleet_safety |> member "operator_action_required" |> to_bool);
          Alcotest.(check string) "health overall status keeps strongest action state"
            "blocked"
            (json |> member "overall_status" |> to_string);
          Alcotest.(check bool) "health top-level asks for operator action" true
            (json |> member "operator_action_required" |> to_bool);
          Alcotest.(check bool) "health top-level names fleet blocker" true
            (json |> member "operator_action_reasons" |> to_list
             |> List.map to_string
             |> List.exists
                  (String.equal
                     "keeper_fleet_safety:reaction_capacity_below_target"));
          ())))

let test_health_json_blocked_count_matches_blocked_names_with_non_target_capacity () =
  with_temp_dir "health-blocked-count-non-target-capacity" (fun dir ->
    let config_root = make_config_root dir in
    List.iter
      (write_config_root_keeper_toml config_root)
      [ "target-missing"; "target-running" ];
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
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
            Alcotest.(check int) "health counts all running capacity" 2
              (fleet_safety |> member "effective_reaction_capacity_count" |> to_int);
            Alcotest.(check int) "capacity shortfall remains numeric capacity" 1
              (fleet_safety |> member "reaction_capacity_shortfall_count" |> to_int);
            Alcotest.(check (list string)) "health names blocked target keepers"
              [ "example"; "target-missing" ]
              (fleet_safety |> member "blocked_keeper_names" |> to_list
               |> List.map to_string);
            Alcotest.(check int) "blocked count matches blocked keeper names" 2
              (fleet_safety |> member "blocked_count" |> to_int);
            Alcotest.(check int) "blocked_keepers alias matches names" 2
              (fleet_safety |> member "blocked_keepers" |> to_int))))

let test_health_json_exposes_disabled_keeper_bootstrap_blocker () =
  with_temp_dir "health-keeper-bootstrap-disabled" (fun dir ->
    let config_root = make_config_root dir in
    write_config_root_keeper_toml config_root "boot-disabled";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        let phase_counts :
            Server_routes_http_runtime_fleet_scan.keeper_phase_counts =
          { running = 0; failing = 0; recovering = 0; executable = 0 }
        in
        let phase_snapshot :
            Server_routes_http_runtime_fleet_scan.keeper_phase_snapshot =
          {
            counts = phase_counts;
            running_names = [];
            recovering_names = [];
            executable_names = [];
            phase_values = [];
            phase_details = [];
          }
        in
        let paused_keepers_json =
          Server_routes_http_runtime_fleet_scan.durable_paused_keeper_scan config
          |> Server_routes_http_runtime_fleet_scan
             .paused_keepers_health_json_of_scan
               ~running_names:[]
        in
        let fleet_safety =
          Server_routes_http_runtime_fleet_scan.keeper_fleet_safety_health_json
            ~keeper_bootstrap_enabled:false
            ~phase_snapshot
            ~phase_counts
            ~paused_keepers_json
            ()
        in
        let open Yojson.Safe.Util in
        Alcotest.(check string) "health selects disabled bootstrap blocker"
          "keeper_bootstrap_disabled"
          (fleet_safety |> member "blocker" |> to_string);
        Alcotest.(check bool) "health reports bootstrap disabled" false
          (fleet_safety |> member "keeper_bootstrap_enabled" |> to_bool);
        Alcotest.(check string) "health exposes bootstrap blocker"
          "keeper_bootstrap_disabled"
          (fleet_safety |> member "keeper_bootstrap_blocker" |> to_string);
        let blocked_detail name =
          fleet_safety |> member "blocked_keeper_reasons" |> to_list
          |> List.find (fun row -> row |> member "keeper" |> to_string = name)
        in
        let detail = blocked_detail "boot-disabled" in
        Alcotest.(check string) "health explains disabled bootstrap row"
          "keeper_bootstrap_disabled"
          (detail |> member "reason" |> to_string);
        Alcotest.(check string) "health suggests bootstrap recovery"
          "enable_keeper_bootstrap_or_start_manually"
          (detail |> member "action" |> to_string);
        Alcotest.(check bool) "row reports bootstrap disabled" false
          (detail |> member "keeper_bootstrap_enabled" |> to_bool);
        Alcotest.(check string) "row exposes bootstrap blocker"
          "keeper_bootstrap_disabled"
          (detail |> member "keeper_bootstrap_blocker" |> to_string)))

let test_health_json_ignores_persisted_only_keeper_for_capacity_target () =
  with_temp_dir "health-persisted-only-keeper-target" (fun dir ->
    let config_root = make_config_root dir in
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        write_keeper_meta_exn config
          (make_keeper_meta ~name:"retired-keeper" ~trace_id:"trace-retired" ());
        let request = Httpun.Request.create `GET "/health" in
        let json = Server_routes_http_runtime.make_health_json request in
        let open Yojson.Safe.Util in
        let fleet_safety = json |> member "keeper_fleet_safety" in
        Alcotest.(check int) "health only targets configured autoboot keepers" 1
          (fleet_safety |> member "target_reaction_capacity_count" |> to_int);
        Alcotest.(check (list string))
          "health excludes persisted-only keepers from autoboot target"
          [ "example" ]
          (fleet_safety |> member "autoboot_enabled_keeper_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list string))
          "health excludes persisted-only keepers from blocked target"
          [ "example" ]
          (fleet_safety |> member "blocked_keeper_names" |> to_list
           |> List.map to_string);
        Alcotest.(check (list (pair string string)))
          "health explains remaining configured blocked target"
          [ ("example", "not_registered") ]
          (fleet_safety |> member "blocked_keeper_reasons" |> to_list
           |> List.map (fun row ->
                ( row |> member "keeper" |> to_string
                , row |> member "reason" |> to_string )))))

let test_health_json_explains_phase_paused_capacity_blocker () =
  with_temp_dir "health-phase-paused-capacity-blocker" (fun dir ->
    let config_root = make_config_root dir in
    write_config_root_keeper_toml config_root "phase-paused";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        let phase_paused =
          make_keeper_meta ~name:"phase-paused" ~trace_id:"trace-phase-paused" ()
        in
        write_keeper_meta_exn config phase_paused;
        with_running_keeper_metas config [ phase_paused ] (fun () ->
          (match
             Keeper_registry.dispatch_event ~base_path:config.Workspace.base_path
               phase_paused.name Keeper_state_machine.Operator_pause
           with
          | Ok _ -> ()
          | Error err ->
            Alcotest.fail
              ("keeper pause transition failed: "
               ^ Keeper_state_machine.transition_error_to_string err));
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          Alcotest.(check (list string))
            "health includes phase-paused keeper in blocked targets"
            [ "example"; "phase-paused" ]
            (fleet_safety |> member "blocked_keeper_names" |> to_list
             |> List.map to_string);
          Alcotest.(check (list (pair string string)))
            "health explains phase-paused blocked keeper"
            [ ("example", "not_registered"); ("phase-paused", "phase_paused") ]
            (fleet_safety |> member "blocked_keeper_reasons" |> to_list
             |> List.map (fun row ->
	                  ( row |> member "keeper" |> to_string
	                  , row |> member "reason" |> to_string ))))))

let test_health_json_exposes_dead_keeper_registry_cause () =
  with_temp_dir "health-phase-dead-registry-cause" (fun dir ->
    let config_root = make_config_root dir in
    write_config_root_keeper_toml config_root "phase-dead";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        let phase_dead =
          make_keeper_meta ~name:"phase-dead" ~trace_id:"trace-phase-dead" ()
        in
        write_keeper_meta_exn config phase_dead;
        with_running_keeper_metas config [ phase_dead ] (fun () ->
          mark_keeper_dead_with_registry_cause config phase_dead;
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          let blocked_detail name =
            fleet_safety |> member "blocked_keeper_reasons" |> to_list
            |> List.find (fun row -> row |> member "keeper" |> to_string = name)
          in
          let detail = blocked_detail "phase-dead" in
          Alcotest.(check string) "health explains dead keeper reason" "phase_dead"
            (detail |> member "reason" |> to_string);
          Alcotest.(check string) "health exposes dead phase" "dead"
            (detail |> member "phase" |> to_string);
          Alcotest.(check string) "health suggests dead keeper recovery"
            "inspect_dead_keeper_root_cause"
            (detail |> member "action" |> to_string);
          let last_failure_reason =
            detail |> member "last_failure_reason" |> to_string
          in
          Alcotest.(check bool) "health preserves failure reason class" true
            (contains_substring last_failure_reason "provider_runtime_error");
          Alcotest.(check bool) "health redacts failure reason token" false
            (contains_substring last_failure_reason "sk-testsecret");
          Alcotest.(check bool) "health redacts failure reason base path" false
            (contains_substring last_failure_reason config.Workspace.base_path);
          Alcotest.(check bool) "health marks redacted failure reason" true
            (contains_substring last_failure_reason "[REDACTED]");
          Alcotest.(check bool) "health marks redacted failure reason path" true
            (contains_substring last_failure_reason "[REDACTED_PATH]");
          let last_error = detail |> member "last_error" |> to_string in
          Alcotest.(check bool) "health preserves last error class" true
            (contains_substring last_error "synthetic cancelled by parent");
          Alcotest.(check bool) "health redacts last error token" false
            (contains_substring last_error "sk-testsecret");
          Alcotest.(check bool) "health redacts last error base path" false
            (contains_substring last_error config.Workspace.base_path);
          Alcotest.(check bool) "health marks redacted last error" true
            (contains_substring last_error "[REDACTED]");
          Alcotest.(check bool) "health marks redacted last error path" true
            (contains_substring last_error "[REDACTED_PATH]");
          Alcotest.(check int) "health surfaces registry restart count" 2
            (detail |> member "restart_count" |> to_int);
          Alcotest.(check (option (float 0.0001)))
            "health surfaces registry dead timestamp" (Some 1780000001.0)
            (detail |> member "dead_since_ts" |> to_float_option);
          Alcotest.(check (option (float 0.0001)))
            "health surfaces latest crash timestamp" (Some 1780000000.0)
            (detail |> member "latest_crash_at" |> to_float_option);
          let latest_crash_reason =
            detail |> member "latest_crash_reason" |> to_string
          in
          Alcotest.(check bool) "health preserves crash reason class" true
            (contains_substring latest_crash_reason "synthetic crash record");
          Alcotest.(check bool) "health redacts crash reason token" false
            (contains_substring latest_crash_reason "github_pat_secret");
          Alcotest.(check bool) "health redacts crash reason base path" false
            (contains_substring latest_crash_reason config.Workspace.base_path);
          Alcotest.(check bool) "health marks redacted crash reason" true
            (contains_substring latest_crash_reason "[REDACTED]");
          Alcotest.(check bool) "health marks redacted crash reason path" true
            (contains_substring latest_crash_reason "[REDACTED_PATH]"))))

let test_health_json_explains_terminal_capacity_blocker
    ~dir_name
    ~keeper_name
    ~trace_id
    ~expected_phase
    ~expected_action
    mark_terminal =
  with_temp_dir dir_name (fun dir ->
    let config_root = make_config_root dir in
    write_config_root_keeper_toml config_root keeper_name;
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = Mcp_server.workspace_config state in
        let terminal = make_keeper_meta ~name:keeper_name ~trace_id () in
        write_keeper_meta_exn config terminal;
        with_running_keeper_metas config [ terminal ] (fun () ->
          mark_terminal config terminal;
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          Alcotest.(check (list string))
            "health includes terminal keeper in blocked targets"
            (List.sort String.compare [ keeper_name; "example" ])
            (fleet_safety |> member "blocked_keeper_names" |> to_list
             |> List.map to_string);
          Alcotest.(check (list (pair string string)))
            "health explains terminal blocked keeper"
            (List.sort compare
               [ (keeper_name, "phase_" ^ expected_phase); ("example", "not_registered") ])
            (fleet_safety |> member "blocked_keeper_reasons" |> to_list
             |> List.map (fun row ->
                  ( row |> member "keeper" |> to_string
                  , row |> member "reason" |> to_string )));
          let terminal_detail =
            fleet_safety |> member "blocked_keeper_reasons" |> to_list
            |> List.find (fun row ->
                 row |> member "keeper" |> to_string = keeper_name)
          in
          Alcotest.(check string) "health reports typed terminal phase"
            expected_phase
            (terminal_detail |> member "phase" |> to_string);
          Alcotest.(check bool) "health marks terminal phase terminal" true
            (terminal_detail |> member "terminal_phase" |> to_bool);
          Alcotest.(check string)
            "health reports terminal keeper action"
            expected_action
            (terminal_detail |> member "action" |> to_string))))

let test_health_json_explains_dead_capacity_blocker_as_terminal () =
  test_health_json_explains_terminal_capacity_blocker
    ~dir_name:"health-dead-capacity-blocker"
    ~keeper_name:"dead-capacity"
    ~trace_id:"trace-dead-capacity"
    ~expected_phase:"dead"
    ~expected_action:"inspect_dead_keeper_root_cause"
    (fun config meta ->
      Keeper_registry.mark_dead
        ~base_path:config.Workspace.base_path
        meta.name
        ~at:terminal_fixture_epoch)

let test_health_json_explains_stopped_capacity_blocker_as_terminal () =
  test_health_json_explains_terminal_capacity_blocker
    ~dir_name:"health-stopped-capacity-blocker"
    ~keeper_name:"stopped-capacity"
    ~trace_id:"trace-stopped-capacity"
    ~expected_phase:"stopped"
    ~expected_action:"restart_or_disable_stopped_keeper"
    mark_keeper_stopped

let test_health_json_explains_zombie_capacity_blocker_as_terminal () =
  test_health_json_explains_terminal_capacity_blocker
    ~dir_name:"health-zombie-capacity-blocker"
    ~keeper_name:"zombie-capacity"
    ~trace_id:"trace-zombie-capacity"
    ~expected_phase:"zombie"
    ~expected_action:"repair_terminal_keeper_failure"
    mark_keeper_zombie

let test_health_json_distinguishes_failing_executable_keepers () =
  with_temp_dir "health-failing-executable-keepers" (fun dir ->
    let config_root = make_config_root dir in
    List.iter
      (write_config_root_keeper_toml config_root)
      [ "capacity-paused"; "capacity-failing" ];
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
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
          Alcotest.(check int) "health exposes no healthy running fibers" 0
            (fleet_safety |> member "healthy_running_keeper_fiber_count" |> to_int);
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
          Alcotest.(check bool) "health marks no running fibers" true
            (fleet_safety |> member "no_running_fibers" |> to_bool);
          Alcotest.(check bool) "health does not mark no executable fibers" false
            (fleet_safety |> member "no_executable_keeper_fibers" |> to_bool);
          Alcotest.(check string) "health marks degraded not blocked" "degraded"
            (fleet_safety |> member "status" |> to_string);
          Alcotest.(check string) "health marks healthy-running blocker"
            "no_healthy_running_keeper_fibers"
            (fleet_safety |> member "blocker" |> to_string);
          Alcotest.(check bool) "health still asks for operator action" true
            (fleet_safety |> member "operator_action_required" |> to_bool))))

let test_health_json_explains_nonrecoverable_failing_keeper () =
  with_temp_dir "health-nonrecoverable-failing-keeper" (fun dir ->
    let config_root = make_config_root dir in
    write_config_root_keeper_toml config_root "capacity-failing";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        let failing =
          make_keeper_meta ~name:"capacity-failing"
            ~trace_id:"trace-capacity-failing" ()
        in
        write_keeper_meta_exn config failing;
        with_running_keeper_metas config [ failing ] (fun () ->
          mark_keeper_failing config failing;
          Keeper_registry.set_failure_reason
            ~base_path:config.Workspace.base_path
            failing.name
            (Some
               (Keeper_registry.Stale_turn_timeout
                  (Keeper_registry.Idle_turn { stall_seconds = 2268.0 })));
          terminate_keeper_fiber config failing;
          exhaust_keeper_restart_budget config failing;
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          Alcotest.(check (list string))
            "health includes nonrecoverable failing keeper in blocked targets"
            [ "capacity-failing"; "example" ]
            (fleet_safety |> member "blocked_keeper_names" |> to_list
             |> List.map to_string);
          Alcotest.(check (list (pair string string)))
            "health explains nonrecoverable failing keeper"
            [ ("capacity-failing", "phase_dead"); ("example", "not_registered") ]
            (fleet_safety |> member "blocked_keeper_reasons" |> to_list
             |> List.map (fun row ->
                  ( row |> member "keeper" |> to_string
                  , row |> member "reason" |> to_string )));
          let capacity_row =
            fleet_safety |> member "blocked_keeper_reasons" |> to_list
            |> List.find_opt (fun row ->
                 String.equal
                   "capacity-failing"
                   (row |> member "keeper" |> to_string))
          in
          match capacity_row with
          | None -> Alcotest.fail "missing capacity-failing blocked row"
          | Some row ->
            Alcotest.(check string) "health exposes dead phase" "dead"
              (row |> member "phase" |> to_string);
            Alcotest.(check string) "health exposes typed stale failure reason"
              "stale_turn_timeout(idle_turn(2268s))"
              (row |> member "last_failure_reason" |> to_string);
            Alcotest.(check string) "health recommends keeper recovery action"
              "keeper_recover"
              (row |> member "operator_action_type" |> to_string);
            Alcotest.(check string) "health recommends recovery tool"
              "masc_keeper_recover"
              (row |> member "operator_tool_name" |> to_string);
            Alcotest.(check bool) "health marks recovery as confirm-required"
              true
              (row |> member "operator_action_confirm_required" |> to_bool))))

let test_health_json_redacts_registry_failure_reason () =
  with_temp_dir "health-redacts-registry-failure-reason" (fun dir ->
    let config_root = make_config_root dir in
    write_config_root_keeper_toml config_root "secret-failing";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = Mcp_server.workspace_config state in
        let failing =
          make_keeper_meta ~name:"secret-failing" ~trace_id:"trace-secret" ()
        in
        write_keeper_meta_exn config failing;
        with_running_keeper_metas config [ failing ] (fun () ->
          let base_path = config.Workspace.base_path in
          let keeper_secret = "keeper-secret-value" in
          let secret_env_dir =
            Filename.concat
              (Keeper_secret_projection.secret_root ~base_path ~keeper_name:failing.name)
              "env"
          in
          mkdir_p secret_env_dir;
          write_file (Filename.concat secret_env_dir "TOKEN") keeper_secret;
          mark_keeper_failing config failing;
          Keeper_registry.set_failure_reason
            ~base_path
            failing.name
            (Some
               (Keeper_registry.Provider_runtime_error
                  {
                    code = "provider_failed";
                    detail =
                      Printf.sprintf
                        "Bearer ghp_healthsecret %s path=%s"
                        keeper_secret
                        (Filename.concat base_path "private/token.txt");
                    provider_id = Some "provider-internal";
                    http_status = Some 500;
                    runtime_id = Some "runtime-internal";
                    reason = None;
                  }));
          terminate_keeper_fiber config failing;
          exhaust_keeper_restart_budget config failing;
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          let failing_row =
            fleet_safety |> member "blocked_keeper_reasons" |> to_list
            |> List.find_opt (fun row ->
                 String.equal
                   "secret-failing"
                   (row |> member "keeper" |> to_string))
          in
          match failing_row with
          | None -> Alcotest.fail "missing secret-failing blocked row"
          | Some row ->
              let reason = row |> member "last_failure_reason" |> to_string in
              Alcotest.(check bool) "redacts bearer token" false
                (contains_substring reason "ghp_healthsecret");
              Alcotest.(check bool) "redacts exact keeper secret" false
                (contains_substring reason keeper_secret);
              Alcotest.(check bool) "redacts workspace base path" false
                (contains_substring reason base_path);
              Alcotest.(check bool) "retains explicit redaction marker" true
                (contains_substring reason "[REDACTED]");
              Alcotest.(check bool) "retains workspace path redaction marker" true
                (contains_substring reason "[REDACTED_PATH]"))))

let test_health_json_uses_crash_log_when_restore_clears_failure_reason () =
  with_temp_dir "health-restored-crash-log-keeper" (fun dir ->
    let config_root = make_config_root dir in
    write_config_root_keeper_toml config_root "restored-crash-log";
    with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
    let previous_state = !Server_auth.server_state in
    Config_dir_resolver.reset ();
    Fun.protect
      ~finally:(fun () ->
        Server_auth.server_state := previous_state;
        Config_dir_resolver.reset ())
      (fun () ->
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = Mcp_server.workspace_config state in
        let restored =
          make_keeper_meta ~name:"restored-crash-log"
            ~trace_id:"trace-restored-crash-log" ()
        in
        write_keeper_meta_exn config restored;
        with_running_keeper_metas config [ restored ] (fun () ->
          let base_path = config.Workspace.base_path in
          let stale_reason = "stale_turn_timeout(idle_turn(2268s))" in
          mark_keeper_failing config restored;
          Keeper_registry.set_failure_reason
            ~base_path
            restored.name
            (Some
               (Keeper_registry.Stale_turn_timeout
                  (Keeper_registry.Idle_turn { stall_seconds = 2268.0 })));
          terminate_keeper_fiber config restored;
          Keeper_registry.record_crash ~base_path restored.name 1234.0 stale_reason;
          exhaust_keeper_restart_budget config restored;
          Keeper_registry.restore_supervisor_state
            ~base_path
            restored.name
            ~restart_count:10
            ~last_restart_ts:1234.0
            ~crash_log:(Keeper_registry.crash_log_of ~base_path restored.name);
          (match Keeper_registry.get ~base_path restored.name with
           | Some entry ->
             Alcotest.(check bool) "restore cleared typed failure reason" true
               (Option.is_none entry.Keeper_registry.last_failure_reason)
           | None -> Alcotest.fail "missing restored keeper registry entry");
          let request = Httpun.Request.create `GET "/health" in
          let json = Server_routes_http_runtime.make_health_json request in
          let open Yojson.Safe.Util in
          let fleet_safety = json |> member "keeper_fleet_safety" in
          let restored_row =
            fleet_safety |> member "blocked_keeper_reasons" |> to_list
            |> List.find_opt (fun row ->
                 String.equal
                   "restored-crash-log"
                   (row |> member "keeper" |> to_string))
          in
          match restored_row with
          | None -> Alcotest.fail "missing restored-crash-log blocked row"
          | Some row ->
            Alcotest.(check string) "health exposes dead phase after restore" "dead"
              (row |> member "phase" |> to_string);
            Alcotest.(check string)
              "health falls back to restored crash-log failure reason"
              stale_reason
              (row |> member "last_failure_reason" |> to_string))))

let test_health_json_reaction_ledger_cursor_sweep_clears_pending () =
  with_temp_dir "health-reaction-ledger-cursor-sweep" (fun dir ->
    with_env "MASC_BASE_PATH" (Some dir) (fun () ->
      Fun.protect
        ~finally:(fun () ->
          Server_auth.server_state := None;
          Config_dir_resolver.reset ())
        (fun () ->
        Config_dir_resolver.reset ();
        let state = Mcp_server.create_state ~base_path:dir in
        Server_auth.server_state := Some state;
        let config = (Mcp_server.workspace_config state) in
        write_keeper_meta_exn config
          (make_keeper_meta ~name:"cursor-swept" ~trace_id:"trace-cursor" ());
        let stimulus post_id updated_at : Keeper_event_queue.stimulus =
          { post_id
          ; urgency = Immediate
          ; arrived_at = updated_at +. 10.0
          ; payload =
              Keeper_event_queue.Board_signal
                { kind = Keeper_event_queue.Post_created
                ; author = ""
                ; title = ""
                ; content = ""
                ; hearth = None
                ; updated_at = Some updated_at
                }
          }
        in
        List.iter
          (Keeper_reaction_ledger.record_event_queue_stimulus
             ~base_path:dir
             ~keeper_name:"cursor-swept")
          [ stimulus "health-post-1" 10.0; stimulus "health-post-2" 20.0 ];
        Keeper_reaction_ledger.record_board_cursor_ack
          ~base_path:dir
          ~keeper_name:"cursor-swept"
          ~cursor_ts:20.0
          ~post_id:(Some "health-post-2")
          ();
        let request = Httpun.Request.create `GET "/health" in
        let json = Server_routes_http_runtime.make_health_json request in
        let open Yojson.Safe.Util in
        let reaction_ledger = json |> member "keeper_reaction_ledger" in
        Alcotest.(check string) "health cursor-swept reaction ledger ok"
          "ok"
          (reaction_ledger |> member "status" |> to_string);
        Alcotest.(check int) "health cursor-swept pending stimuli" 0
          (reaction_ledger |> member "pending_stimulus_count" |> to_int);
        Alcotest.(check bool)
          "health cursor-swept reaction ledger clears operator action"
          false
          (reaction_ledger |> member "operator_action_required" |> to_bool))))

let test_health_json_reaction_ledger_unavailable_shape () =
  let previous_state = !Server_auth.server_state in
  Fun.protect
    ~finally:(fun () -> Server_auth.server_state := previous_state)
    (fun () ->
       Server_auth.server_state := None;
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
    (contains_substring (Yojson.Safe.to_string ready) raw_token);
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
    (json |> member "keeper_reaction_ledger" = `Null);
  Alcotest.(check bool) "default health skips cdal snapshot" true
    (json |> member "cdal" = `Null)

let test_health_response_full_query_uses_snapshot_cache () =
  with_temp_dir "health-full-snapshot-cache" (fun dir ->
      let config_root = make_config_root dir in
      with_env "MASC_CONFIG_DIR" (Some config_root) @@ fun () ->
      with_config_input "MASC_BASE_PATH" (Some dir) @@ fun () ->
      let previous_state = !Server_auth.server_state in
      Config_dir_resolver.reset ();
      Server_routes_http_runtime.For_testing.reset_full_health_snapshot ();
      Fun.protect
        ~finally:(fun () ->
          Server_auth.server_state := previous_state;
          Config_dir_resolver.reset ();
          Server_routes_http_runtime.For_testing.reset_full_health_snapshot ())
        (fun () ->
          Server_auth.server_state := Some (Mcp_server.create_state ~base_path:dir);
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
          Alcotest.(check bool) "full health skips retired cdal snapshot" true
            (first |> member "cdal" = `Null);
          Server_routes_http_runtime.For_testing.refresh_full_health_snapshot_now
            request;
          let refreshed =
            Server_routes_http_runtime.make_health_response_json request
          in
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
          Alcotest.(check bool)
            "refreshed full health skips retired cdal snapshot"
            true
            (refreshed |> member "cdal" = `Null)))

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
  let timeout_error =
    Failure
      "refresh_timeout label=full_health_snapshot phase=refresh timeout_s=16.0 \
       elapsed_s=17.0"
  in
  Server_routes_http_runtime.For_testing.mark_full_health_snapshot_error timeout_error;
  let after = Server_routes_http_runtime.make_health_response_json request in
  Alcotest.(check string) "timeout marks snapshot stale" "stale"
    (after |> member "full_health_snapshot" |> member "status" |> to_string);
  Alcotest.(check bool) "timeout marks timed out component" true
    (after |> member "full_health_snapshot" |> member "component_timed_out"
     |> to_bool);
  Alcotest.(check bool) "timeout keeps last-good marker" true
    (after |> member "full_health_snapshot" |> member "last_good_available"
     |> to_bool);
  Alcotest.(check string) "timeout error is surfaced" (Printexc.to_string timeout_error)
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
  let timeout_error =
    Failure
      "refresh_timeout label=full_health_snapshot phase=refresh timeout_s=16.0 \
       elapsed_s=17.0"
  in
  Server_routes_http_runtime.For_testing.mark_full_health_snapshot_error timeout_error;
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
     | _ -> false);
  Alcotest.(check bool) "cold timeout omits retired cdal component" true
    (after |> member "cdal" = `Null)

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
    [ "initialize"; "tool_state"; "cleanup" ]
    (List.map
       (fun group -> group.Server_runtime_bootstrap.group_name)
       groups);
  match groups with
  | [ initialize; tool_state; cleanup ] ->
      check_lazy_group initialize ~name:"initialize" ~execution:"parallel"
        ~tasks:
          [
            "restore_sessions";
            "reconcile_active_agents";
            "prompt_bootstrap";
            "keeper_history_migration";
          ];
      check_lazy_group tool_state ~name:"tool_state" ~execution:"serial"
        ~tasks:[ "telemetry_warmup"; "tool_metrics_restore" ];
      check_lazy_group cleanup ~name:"cleanup" ~execution:"serial"
        ~tasks:[ "jsonl_prune" ];
      Alcotest.(check (list string))
        "flattened task order"
        [
          "restore_sessions";
          "reconcile_active_agents";
          "prompt_bootstrap";
          "keeper_history_migration";
          "telemetry_warmup";
          "tool_metrics_restore";
          "jsonl_prune";
        ]
        (Server_runtime_bootstrap.lazy_startup_task_names ())
  | _ -> Alcotest.fail "unexpected lazy startup group shape"

let test_startup_state_json () =
  Server_startup_state.reset ~backend_mode:"postgres-native" ();
  Server_startup_state.mark_state_ready ~backend_mode:"postgres-native";
  Server_startup_state.activate_lazy ~backend_mode:"postgres-native"
    ~tasks:[ "restore_sessions"; "keeper_bootstrap" ];
  Server_startup_state.finish_lazy_task ~task:"restore_sessions";
  Server_startup_state.fail_lazy_task ~task:"keeper_bootstrap"
    ~error:"keeper failed";
  let json = Server_startup_state.to_yojson () in
  Alcotest.(check string) "phase becomes degraded" "degraded"
    (json_string_field "phase" json);
  Alcotest.(check bool) "state remains ready" true
    (json_bool_field "state_ready" json);
  Alcotest.(check string) "last error recorded" "keeper failed"
    (json_string_field "last_error" json)

let test_startup_state_catalog_degraded_survives_lazy_activation () =
  Server_startup_state.reset ~backend_mode:"filesystem" ();
  Server_startup_state.mark_state_ready ~backend_mode:"filesystem";
  Server_startup_state.activate_lazy ~backend_mode:"filesystem"
    ~tasks:[ "restore_sessions" ];
  Server_startup_state.mark_degraded
    ~error:"startup catalog validation failed: synthetic";
  Server_startup_state.finish_lazy_task ~task:"restore_sessions";
  let current = Server_startup_state.(!state) in
  Alcotest.(check string) "phase stays degraded after lazy task completes"
    "degraded"
    (Server_startup_state.phase_to_string current.phase);
  Alcotest.(check bool) "ready flag stays true after degradation" true
    current.state_ready;
  Alcotest.(check (option string))
    "catalog validation error is preserved"
    (Some "startup catalog validation failed: synthetic")
    current.last_error

let test_startup_state_liveness () =
  Server_startup_state.reset ~backend_mode:"unknown" ();
  Alcotest.(check bool) "is_live returns true even during init" true
    (Server_startup_state.is_live ());
  Alcotest.(check bool) "elapsed_since_start is non-negative" true
    (Server_startup_state.elapsed_since_start () >= 0.0)

let test_startup_state_readiness_before_init () =
  Server_startup_state.reset ~backend_mode:"postgres-native" ();
  let current = Server_startup_state.(!state) in
  Alcotest.(check bool) "not ready before init" false current.state_ready;
  Alcotest.(check string) "phase is blocking" "blocking"
    (Server_startup_state.phase_to_string current.phase)

let test_startup_state_readiness_after_init () =
  Server_startup_state.reset ~backend_mode:"filesystem" ();
  Server_startup_state.mark_state_ready ~backend_mode:"filesystem";
  let current = Server_startup_state.(!state) in
  Alcotest.(check bool) "ready after init" true current.state_ready;
  Alcotest.(check string) "phase is ready" "ready"
    (Server_startup_state.phase_to_string current.phase)

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
  Server_startup_state.reset ~backend_mode:"filesystem" ();
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
  Server_startup_state.reset ~backend_mode:"filesystem" ();
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
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock, mono_clock, net, _domain_mgr, proc_mgr, fs =
        Server_runtime_bootstrap.init_runtime_context env
      in
      Eio.Switch.run @@ fun sw ->
      Server_startup_state.reset ~backend_mode:"filesystem" ();
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
      Server_startup_state.reset ~backend_mode:"filesystem" ();
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
      write_file (Filename.concat config_root "tool_policy.toml")
        "[groups.base]\ntools = [\"keeper_time_now\"]\n";
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
      write_file (Filename.concat config_root "tool_policy.toml")
        "[groups.base]\ntools = [\"keeper_time_now\"]\n";
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
      let exe = find_main_eio_exe () in
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
            ("MASC_AUTONOMY_ENABLED", "0");
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
      let exe = find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      let expected_config = Filename.concat dir ".masc/config" in
      Alcotest.(check bool) "tool policy not bootstrapped (deleted module)" false
        (Sys.file_exists (Filename.concat expected_config "tool_policy.toml"));
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_AUTONOMY_ENABLED", "0");
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
                 "main_eio fresh boot did not reach startup.phase=ready within timeout in this environment.\nlog:\n%s"
                 (read_file log_file));
            Alcotest.skip ()
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
      let exe = find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
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
            ("MASC_AUTONOMY_ENABLED", "0");
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

let test_sync_bootable_keeper_credentials_mints_keeper_alias_token () =
  with_temp_dir "startup-keeper-credential-sync" (fun dir ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_basepath_keeper_toml dir "masc-improver";
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
        Filename.concat (Auth.auth_dir dir) "keeper-masc-improver-agent.token"
      in
      let raw_token = String.trim (read_file raw_token_path) in
      let credential =
        match Auth.load_credential dir "keeper-masc-improver-agent" with
        | Some cred -> cred
        | None ->
            Alcotest.fail
              "missing keeper-masc-improver-agent credential after startup sync"
      in
      Alcotest.(check bool) "internal keeper token hash persisted" true
        (Sys.file_exists (Auth.internal_keeper_token_hash_file dir));
      Alcotest.(check string) "raw token hashes to keeper credential"
        credential.token (Auth.sha256_hash raw_token);
      Alcotest.(check bool) "keeper bearer separated from internal token" false
        (String.equal raw_token internal_raw_token);
      match
        Auth.verify_token dir ~agent_name:"keeper-masc-improver-agent"
          ~token:raw_token
      with
      | Ok alias_cred ->
          Alcotest.(check string) "keeper credential resolves exact agent"
            "keeper-masc-improver-agent" alias_cred.agent_name
      | Error err ->
          Alcotest.failf "bootable keeper token should verify exactly: %s"
            (Masc_domain.masc_error_to_string err))

let test_sync_bootable_keeper_credentials_rotates_shared_keeper_tokens () =
  with_temp_dir "startup-keeper-credential-rotate" (fun dir ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_basepath_keeper_toml dir "analyst";
      write_basepath_keeper_toml dir "executor";
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
      seed "keeper-analyst-agent";
      seed "keeper-executor-agent";
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
      let analyst =
        match Auth.load_credential dir "keeper-analyst-agent" with
        | Some cred -> cred
        | None -> Alcotest.fail "missing keeper-analyst-agent credential"
      in
      let executor =
        match Auth.load_credential dir "keeper-executor-agent" with
        | Some cred -> cred
        | None -> Alcotest.fail "missing keeper-executor-agent credential"
      in
      Alcotest.(check bool) "boot repair made keeper tokens unique" false
        (String.equal analyst.token executor.token);
      Alcotest.(check int) "audit clean after boot repair"
        0 (List.length (Auth.audit_token_uniqueness dir));
      [ "keeper-analyst-agent"; "keeper-executor-agent" ]
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
      let exe = find_main_eio_exe () in
      let primary_port = find_free_port () in
      let secondary_port = find_free_port_from (primary_port + 1) in
      let primary_log = Filename.concat dir "primary.log" in
      let secondary_log = Filename.concat dir "secondary.log" in
      let open_log path =
        Unix.openfile path [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_AUTONOMY_ENABLED", "0");
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
            (contains_substring secondary_text "already owns base path");
          Alcotest.(check bool) "secondary log mentions primary pid" true
            (contains_substring secondary_text (string_of_int primary_pid));
          Alcotest.(check bool) "primary server stays healthy" true
            (wait_for_health ~pid:primary_pid ~port:primary_port ~timeout_s:1.0)))

let test_main_eio_invalid_runtime_stays_degraded_but_serves_dashboard () =
  with_temp_dir "startup-invalid-runtime" (fun dir ->
      let exe = find_main_eio_exe () in
      let port = find_free_port () in
      let log_file = Filename.concat dir "server.log" in
      let log_fd =
        Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
      in
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
      with_cwd (project_root ()) @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path:dir;
      write_invalid_local_only_runtime dir;
      let env =
        main_eio_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_AUTONOMY_ENABLED", "0");
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
      let exe = find_main_eio_exe () in
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
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
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
            ("MASC_AUTONOMY_ENABLED", "0");
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
      let exe = find_main_eio_exe () in
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
      with_env "MASC_PERSONAS_DIR" None @@ fun () ->
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
            ("MASC_AUTONOMY_ENABLED", "0");
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
                  contains_substring error "required default profile")
               rejection_errors)))

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Alcotest.run "Server_runtime_bootstrap"
    [
      ( "bootstrap",
        [
          Alcotest.test_case
            "model catalog resolution prefers explicit env"
            `Quick test_model_catalog_resolution_prefers_explicit_env;
          Alcotest.test_case
            "capability manifest resolution prefers explicit env"
            `Quick test_capability_manifest_resolution_prefers_explicit_env;
          Alcotest.test_case
            "capability manifest configuration uses config root"
            `Quick test_capability_manifest_configuration_uses_config_root_file;
          Alcotest.test_case
            "model catalog configuration installs resolved catalog"
            `Quick test_model_catalog_configuration_installs_resolved_catalog;
          Alcotest.test_case
            "model catalog configuration prefers config-root catalog"
            `Quick test_model_catalog_configuration_prefers_config_root_catalog;
          Alcotest.test_case
            "model catalog resolution falls back to executable parent"
            `Quick
            test_model_catalog_resolution_uses_executable_parent_when_cwd_is_base_path;
          Alcotest.test_case
            "model catalog resolution uses process cwd for relative argv0"
            `Quick
            test_model_catalog_resolution_resolves_relative_argv0_from_process_cwd;
          Alcotest.test_case
            "model catalog configuration delegates to agent_sdk ambient catalog"
            `Quick
            test_model_catalog_configuration_delegates_to_agent_sdk_ambient;
          Alcotest.test_case
            "bootstrap base-path config copies shared seed only"
            `Quick
            test_bootstrap_base_path_config_root_copies_shared_seed_but_not_keepers;
          Alcotest.test_case
            "bootstrap base-path config backfills prompts and catalog"
            `Quick
            test_bootstrap_base_path_config_root_backfills_missing_prompts_and_catalog;
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
          Alcotest.test_case "lazy startup plan parallelizes independent tasks"
            `Quick test_lazy_startup_plan_groups_independent_tasks;
          Alcotest.test_case "startup state json reports lazy failure" `Quick
            test_startup_state_json;
          Alcotest.test_case
            "startup catalog degradation survives lazy activation"
            `Quick
            test_startup_state_catalog_degraded_survives_lazy_activation;
          Alcotest.test_case "liveness probe is always true" `Quick
            test_startup_state_liveness;
          Alcotest.test_case
            "health json surfaces durable paused keepers"
            `Quick test_health_json_surfaces_durable_paused_keepers;
          Alcotest.test_case
            "health json surfaces turn admission pressure"
            `Quick test_health_json_surfaces_keeper_turn_admission_pressure;
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
            "health json keeps timeout pause without policy manual"
            `Quick test_health_json_keeps_timeout_pause_without_policy_manual;
          Alcotest.test_case
            "health json reports dormant task owner as advisory"
            `Quick
            test_health_json_reports_dormant_task_owner_as_advisory;
          Alcotest.test_case
            "health json ignores stale active task alias when agent executable"
            `Quick
            test_health_json_ignores_stale_active_task_alias_when_agent_executable;
          Alcotest.test_case
            "health json degrades on active task owner without keeper binding"
            `Quick
            test_health_json_degrades_on_active_task_owner_without_keeper_binding;
          Alcotest.test_case
            "health json reports non-keeper active task owner as advisory"
            `Quick
            test_health_json_reports_non_keeper_active_task_owner_as_advisory;
          Alcotest.test_case
            "health json preserves active task owner meta read error"
            `Quick
            test_health_json_preserves_active_task_owner_meta_read_error;
          Alcotest.test_case
            "health json degrades when reaction capacity is below target"
            `Quick test_health_json_degrades_when_reaction_capacity_below_target;
          Alcotest.test_case
            "health json blocked count matches named target blockers"
            `Quick
            test_health_json_blocked_count_matches_blocked_names_with_non_target_capacity;
          Alcotest.test_case
            "health json exposes disabled keeper bootstrap blocker"
            `Quick
            test_health_json_exposes_disabled_keeper_bootstrap_blocker;
          Alcotest.test_case
            "health json ignores persisted-only keeper for capacity target"
            `Quick
            test_health_json_ignores_persisted_only_keeper_for_capacity_target;
          Alcotest.test_case
            "health json explains phase-paused capacity blocker"
            `Quick test_health_json_explains_phase_paused_capacity_blocker;
          Alcotest.test_case
            "health json explains dead capacity blocker as terminal"
            `Quick test_health_json_explains_dead_capacity_blocker_as_terminal;
          Alcotest.test_case
            "health json explains stopped capacity blocker as terminal"
            `Quick test_health_json_explains_stopped_capacity_blocker_as_terminal;
          Alcotest.test_case
            "health json explains zombie capacity blocker as terminal"
            `Quick test_health_json_explains_zombie_capacity_blocker_as_terminal;
          Alcotest.test_case
            "health json exposes dead keeper registry cause"
            `Quick test_health_json_exposes_dead_keeper_registry_cause;
          Alcotest.test_case
            "health json distinguishes failing executable keepers"
            `Quick test_health_json_distinguishes_failing_executable_keepers;
          Alcotest.test_case
            "health json explains nonrecoverable failing keeper"
            `Quick test_health_json_explains_nonrecoverable_failing_keeper;
          Alcotest.test_case
            "health json redacts registry failure reason"
            `Quick test_health_json_redacts_registry_failure_reason;
          Alcotest.test_case
            "health json restores crash-log failure reason"
            `Quick
            test_health_json_uses_crash_log_when_restore_clears_failure_reason;
          Alcotest.test_case
            "health json reaction ledger cursor sweep clears pending"
            `Quick test_health_json_reaction_ledger_cursor_sweep_clears_pending;
          Alcotest.test_case
            "health json reaction ledger unavailable shape"
            `Quick test_health_json_reaction_ledger_unavailable_shape;
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
            `Quick test_sync_bootable_keeper_credentials_mints_keeper_alias_token;
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
