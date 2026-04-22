open Masc_mcp

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

let with_clean_base_path_env f =
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" None @@ fun () ->
  with_env "MASC_BASE_PATH_RESOLUTION_SOURCE" None f

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

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
  write_file (Filename.concat config "cascade.json") "{\"seed\":\"repo\"}";
  write_file (Filename.concat config "tool_policy.toml")
    "[groups.base]\ntools = [\"keeper_time_now\"]\n[presets.minimal]\ngroups = [\"base\"]\n";
  write_file (Filename.concat config "prompts/keeper.unified.system.md") "prompt";
  write_file (Filename.concat config "keepers/example.toml") "[keeper]\ngoal = \"example\"\n";
  write_file (Filename.concat config "personas/example.txt") "persona";
  config

let write_basepath_keeper_toml base_path name =
  let keepers_dir =
    Filename.concat (Filename.concat (Filename.concat base_path ".masc") "config")
      "keepers"
  in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (name ^ ".toml"))
    {|[keeper]
goal = "example"
room_scope = "current"
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
      Filename.concat root "_build/default/masc-mcp/bin/main_eio.exe";
    ]
    @ List.concat_map
        (fun base ->
          [
            Filename.concat base "bin/main_eio.exe";
            Filename.concat base "_build/default/bin/main_eio.exe";
            Filename.concat base "_build/default/masc-mcp/bin/main_eio.exe";
          ])
        build_roots
    @ [
      Filename.concat shared_root "_build/default/bin/main_eio.exe";
      Filename.concat shared_root "_build/default/masc-mcp/bin/main_eio.exe";
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

let write_invalid_local_only_cascade base_path =
  let config_root = Filename.concat base_path ".masc/config" in
  mkdir_p config_root;
  write_file
    (Filename.concat config_root "cascade.json")
    {|{
  "local_only_models": ["ollama:qwen3.6:35b-a3b-mlx-bf16"]
}|}

let write_partially_invalid_cascade ~base_path ~valid_model =
  let config_root = Filename.concat base_path ".masc/config" in
  mkdir_p config_root;
  write_file
    (Filename.concat config_root "cascade.json")
    (Printf.sprintf
       {|{
  "big_three_models": ["%s"],
  "broken_profile_models": ["__nonexistent_provider_sentinel__:fake"]
}|}
       valid_model)

let write_partially_invalid_default_cascade ~base_path ~valid_model =
  let config_root = Filename.concat base_path ".masc/config" in
  mkdir_p config_root;
  write_file
    (Filename.concat config_root "cascade.json")
    (Printf.sprintf
       {|{
  "big_three_models": ["__nonexistent_provider_sentinel__:fake"],
  "tool_rerank_models": ["%s"]
}|}
       valid_model)

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

let test_force_jsonl_fallback_env () =
  with_env "MASC_STORAGE_TYPE" (Some "memory") @@ fun () ->
  Server_runtime_bootstrap.force_jsonl_fallback_env ();
  Alcotest.(check string) "storage type forced to filesystem" "filesystem"
    (Sys.getenv "MASC_STORAGE_TYPE")

let test_default_oas_cascade_timeout_tracks_keeper_timeout () =
  with_env "OAS_CASCADE_MODEL_TIMEOUT_SEC" None @@ fun () ->
  with_env "MASC_KEEPER_OAS_TIMEOUT_SEC" (Some "300") @@ fun () ->
  Server_runtime_bootstrap.ensure_default_oas_cascade_timeout_env ();
  Alcotest.(check string) "derived timeout reserves room for fallbacks" "60"
    (Sys.getenv "OAS_CASCADE_MODEL_TIMEOUT_SEC")

let test_default_oas_cascade_timeout_keeps_explicit_override () =
  with_env "OAS_CASCADE_MODEL_TIMEOUT_SEC" (Some "45") @@ fun () ->
  with_env "MASC_KEEPER_OAS_TIMEOUT_SEC" (Some "300") @@ fun () ->
  Server_runtime_bootstrap.ensure_default_oas_cascade_timeout_env ();
  Alcotest.(check string) "explicit override wins" "45"
    (Sys.getenv "OAS_CASCADE_MODEL_TIMEOUT_SEC")

let test_bootstrap_base_path_config_root_copies_versioned_config () =
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
      Alcotest.(check string) "cascade copied" "{\"seed\":\"repo\"}"
        (read_file (Filename.concat config_root "cascade.json"));
      Alcotest.(check bool) "tool policy copied" true
        (Sys.file_exists (Filename.concat config_root "tool_policy.toml"));
      Alcotest.(check bool) "prompt copied" true
        (Sys.file_exists
           (Filename.concat config_root "prompts/keeper.unified.system.md"));
      Alcotest.(check bool) "keeper TOML copied" true
        (Sys.file_exists (Filename.concat config_root "keepers/example.toml")))

let test_bootstrap_base_path_config_root_preserves_existing_root_without_refill () =
  with_temp_dir "startup-config-preserve" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      let base_path = Filename.concat dir "base" in
      let config_root = Filename.concat base_path ".masc/config" in
      mkdir_p config_root;
      write_file (Filename.concat config_root "cascade.json") "{\"seed\":\"local\"}";
      mkdir_p (Filename.concat config_root "personas");
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
      Alcotest.(check string) "existing cascade preserved" "{\"seed\":\"local\"}"
        (read_file (Filename.concat config_root "cascade.json"));
      Alcotest.(check bool) "keepers dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "keepers"));
      Alcotest.(check bool) "prompts dir scaffolded" true
        (Sys.is_directory (Filename.concat config_root "prompts"));
      Alcotest.(check bool) "versioned keeper not resurrected" false
        (Sys.file_exists (Filename.concat config_root "keepers/example.toml"));
      Alcotest.(check bool) "versioned prompt not resurrected" false
        (Sys.file_exists
           (Filename.concat config_root "prompts/keeper.unified.system.md"));
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
      write_file (Filename.concat config_root "cascade.json") "{}";
      write_file (Filename.concat config_root "tool_policy.toml")
        "[groups.base]\ntools = [\"keeper_time_now\"]\n[presets.minimal]\ngroups = [\"base\"]\n";
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      let resolution =
        Server_runtime_bootstrap.startup_config_resolution ~base_path
      in
      let expected = config_root in
      Alcotest.(check string) "returns base-path config root" expected
        resolution.Config_dir_resolver.config_root.path;
      Alcotest.(check (option string)) "env remains effectively unset" None
        (Env_config_core.config_dir_opt ()))

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
      mkdir_p (Filename.concat base_path ".masc");
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_cwd repo @@ fun () ->
      Server_runtime_bootstrap.bootstrap_base_path_config_root
        ~base_path:(Filename.concat base_path ".masc");
      Alcotest.(check bool) "config root created under parent .masc" true
        (Sys.file_exists (Filename.concat base_path ".masc/config/cascade.json"));
      Alcotest.(check bool) "nested .masc/.masc config not created" false
        (Sys.file_exists
           (Filename.concat base_path ".masc/.masc/config/cascade.json")))
let test_constructor_is_pure () =
  with_temp_dir "startup-pure" (fun dir ->
      let agents_dir = Coord.agents_dir (Coord.default_config dir) in
      Fs_compat.mkdir_p agents_dir;
      write_file (Filename.concat agents_dir "alice.json") "{}";
      let state = Mcp_server.create_state ~base_path:dir in
      Alcotest.(check int) "constructor does not restore persisted sessions" 0
        (List.length (Session.connected_agents state.Mcp_server.session_registry)))

let test_restore_persisted_sessions_uses_flat_agents_dir () =
  with_temp_dir "startup-scope" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let agents = Coord.agents_dir state.Mcp_server.room_config in
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
          let config = Coord.default_config dir in
          let keeper_dir = Keeper_types.keeper_dir config in
          let expected_root =
            Filename.concat
              (Filename.concat (Filename.concat dir ".masc") "clusters")
              "cluster-alpha"
          in
          Alcotest.(check bool) "keeper dir under cluster root" true
            (String.starts_with ~prefix:expected_root keeper_dir)))

let test_tool_usage_log_uses_cluster_root () =
  with_temp_dir "startup-tool-usage-cluster" (fun dir ->
      with_env "MASC_CLUSTER_NAME" (Some "cluster-alpha") (fun () ->
          Tool_usage_log.init ~base_path:dir ~cluster_name:"cluster-alpha" ();
          Tool_usage_log.log_call
            ~tool_name:"keeper_tasks_list" ~success:true
            ~caller:(Some "oracle");
          let expected_dir =
            Filename.concat
              (Filename.concat
                 (Filename.concat (Filename.concat dir ".masc") "clusters")
                 "cluster-alpha")
              "tool_usage"
          in
          let legacy_dir =
            Filename.concat (Filename.concat dir ".masc") "tool_usage"
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
                     (Filename.concat (Filename.concat dir ".masc") "clusters")
                     "cluster-alpha")
                  "tool_calls"
              in
              let legacy_dir =
                Filename.concat (Filename.concat dir ".masc") "tool_calls"
              in
              Alcotest.(check bool) "cluster tool_calls dir exists" true
                (Sys.file_exists expected_dir && Sys.is_directory expected_dir);
              Alcotest.(check bool) "legacy tool_calls dir absent" false
                (Sys.file_exists legacy_dir);
              Alcotest.(check int) "tool_call row readable from cluster store"
                1
                (List.length (Keeper_tool_call_log.read_recent ~n:10 ())))))

let test_room_init_bootstraps_keeper_runtime_dirs () =
  with_temp_dir "startup-keeper-dirs" (fun dir ->
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:None);
      let root_dir = Coord.masc_root_dir config in
      let keeper_dir = Filename.concat root_dir "keepers" in
      let traces_dir = Filename.concat root_dir "traces" in
      Alcotest.(check bool) "keeper dir exists" true
        (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir);
      Alcotest.(check bool) "traces dir exists" true
        (Sys.file_exists traces_dir && Sys.is_directory traces_dir);
      Alcotest.(check bool) "perpetual dir not recreated" false
        (Sys.file_exists (Filename.concat root_dir "perpetual")))

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
    Keeper_types.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String trace_id);
          ("goal", `String ("goal-" ^ name));
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
          ("updated_at", `String updated_at);
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta -> Keeper_types.meta_to_json meta |> Yojson.Safe.pretty_to_string
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

let test_migrate_resident_keeper_dirs_promotes_valid_meta () =
  with_temp_dir "startup-legacy-keepers" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let keepers_dir = Filename.concat masc_root "keepers" in
      let legacy_dir = Filename.concat masc_root "resident-keepers" in
      let quarantine_dir =
        Filename.concat masc_root "_quarantine/_replaced/resident-keepers"
      in
      Fs_compat.mkdir_p keepers_dir;
      Fs_compat.mkdir_p legacy_dir;
      write_file (Filename.concat keepers_dir "sangsu.json")
        {|{"name":"sangsu","created_at":"2026-03-26T15:53:16Z","updated_at":"2026-03-26T17:44:32Z"}|};
      write_file (Filename.concat legacy_dir "sangsu.json")
        (make_keeper_meta_json ());
      write_file (Filename.concat legacy_dir "other.json")
        (make_keeper_meta_json ~name:"other" ~trace_id:"trace-other-live" ());
      Server_runtime_bootstrap.migrate_legacy_dirs state;
      let read_meta_exn path =
        match Keeper_types.read_meta_file_path path with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.failf "missing keeper meta at %s" path
        | Error err -> Alcotest.failf "failed to read keeper meta %s: %s" path err
      in
      let sangsu_meta =
        read_meta_exn (Filename.concat keepers_dir "sangsu.json")
      in
      let other_meta =
        read_meta_exn (Filename.concat keepers_dir "other.json")
      in
      Alcotest.(check string) "sangsu trace promoted from resident-keepers"
        "trace-sangsu-live" (Keeper_id.Trace_id.to_string sangsu_meta.runtime.trace_id);
      Alcotest.(check string) "other keeper migrated from resident-keepers"
        "trace-other-live" (Keeper_id.Trace_id.to_string other_meta.runtime.trace_id);
      Alcotest.(check bool) "legacy dir removed after merge" false
        (Sys.file_exists legacy_dir);
      Alcotest.(check bool) "replaced stale keeper quarantined" true
        (Sys.file_exists (Filename.concat quarantine_dir "sangsu.json")))

let test_migrate_resident_keeper_dirs_keeps_fresher_current_meta () =
  with_temp_dir "startup-legacy-keepers-current-wins" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let keepers_dir = Filename.concat masc_root "keepers" in
      let legacy_dir = Filename.concat masc_root "resident-keepers" in
      let quarantine_path =
        Filename.concat masc_root "_quarantine/resident-keepers/sangsu.json"
      in
      Fs_compat.mkdir_p keepers_dir;
      Fs_compat.mkdir_p legacy_dir;
      write_file (Filename.concat keepers_dir "sangsu.json")
        (make_keeper_meta_json ~updated_at:"2026-03-29T11:36:57Z" ());
      write_file (Filename.concat legacy_dir "sangsu.json")
        (make_keeper_meta_json ~updated_at:"2026-03-29T10:36:57Z" ());
      Server_runtime_bootstrap.migrate_legacy_dirs state;
      let current_meta =
        match
          Keeper_types.read_meta_file_path
            (Filename.concat keepers_dir "sangsu.json")
        with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "missing current keeper meta"
        | Error err -> Alcotest.failf "failed to read current keeper meta: %s" err
      in
      Alcotest.(check string) "fresher current meta preserved"
        "2026-03-29T11:36:57Z" current_meta.updated_at;
      Alcotest.(check bool) "older legacy keeper quarantined" true
        (Sys.file_exists quarantine_path))

let test_migrate_resident_keeper_dirs_use_source_scoped_quarantine_path () =
  with_temp_dir "startup-resident-keepers-quarantine-source" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let keepers_dir = Filename.concat masc_root "keepers" in
      let legacy_dir = Filename.concat masc_root "resident-keepers" in
      Fs_compat.mkdir_p keepers_dir;
      Fs_compat.mkdir_p legacy_dir;
      write_file (Filename.concat keepers_dir "sangsu.json")
        (make_keeper_meta_json ~updated_at:"2026-03-29T12:36:57Z" ());
      write_file (Filename.concat legacy_dir "sangsu.json")
        (make_keeper_meta_json ~updated_at:"2026-03-29T11:36:57Z" ());
      Server_runtime_bootstrap.migrate_legacy_dirs state;
      Alcotest.(check bool) "resident keeper quarantined under source dir" true
        (Sys.file_exists
           (Filename.concat masc_root
              "_quarantine/resident-keepers/sangsu.json")))

let test_blocking_bootstrap_promotes_legacy_keeper_meta_before_autoboot () =
  with_temp_dir "startup-blocking-legacy-keepers" (fun dir ->
      write_basepath_keeper_toml dir "sangsu";
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let legacy_dir = Filename.concat masc_root "resident-keepers" in
      let legacy_trace_dir = Filename.concat masc_root "perpetual" in
      Fs_compat.mkdir_p legacy_dir;
      Fs_compat.mkdir_p legacy_trace_dir;
      write_file (Filename.concat legacy_dir "sangsu.json")
        (make_keeper_meta_json ());
      write_file (Filename.concat legacy_trace_dir "ckpt-1.json") {|{"ok":true}|};
      Server_runtime_bootstrap.bootstrap_server_state_blocking state;
      Alcotest.(check bool) "legacy keeper meta promoted during blocking bootstrap"
        true
        (Sys.file_exists
           (Filename.concat (Keeper_types.keeper_dir state.Mcp_server.room_config)
              "sangsu.json"));
      Alcotest.(check bool) "legacy dir removed before later startup readers" false
        (Sys.file_exists legacy_dir);
      Alcotest.(check bool) "legacy traces stay deferred to lazy startup" true
        (Sys.file_exists legacy_trace_dir);
      Alcotest.(check (list string))
        "autoboot sees promoted keepers on first scan"
        [ "sangsu" ]
        (Keeper_types.keepalive_keeper_names state.Mcp_server.room_config))

let test_blocking_bootstrap_flattens_room_with_safe_current_room_fallback () =
  with_temp_dir "startup-blocking-room-flatten" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let legacy_tasks = Filename.concat masc_root "rooms/focus-room/tasks" in
      Fs_compat.mkdir_p legacy_tasks;
      write_file (Filename.concat masc_root "current_room") "../escape\n";
      write_file
        (Filename.concat legacy_tasks "backlog.json")
        (Yojson.Safe.to_string
           (Types.backlog_to_yojson
              { tasks = []; last_updated = Types.now_iso (); version = 7 }));
      Server_runtime_bootstrap.bootstrap_server_state_blocking state;
      let root_backlog =
        Yojson.Safe.from_string
          (read_file (Filename.concat masc_root "tasks/backlog.json"))
      in
      Alcotest.(check int) "legacy backlog promoted before init seeds defaults" 7
        Yojson.Safe.Util.(root_backlog |> member "version" |> to_int);
      Alcotest.(check bool) "legacy backlog not quarantined" false
        (Sys.file_exists
           (Filename.concat masc_root
              "_quarantine/rooms/focus-room/tasks/backlog.json")))

let test_blocking_bootstrap_flattens_single_legacy_room_without_current_room () =
  with_temp_dir "startup-blocking-room-single-fallback" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let legacy_tasks = Filename.concat masc_root "rooms/team-room/tasks" in
      Fs_compat.mkdir_p legacy_tasks;
      write_file
        (Filename.concat legacy_tasks "backlog.json")
        (Yojson.Safe.to_string
           (Types.backlog_to_yojson
              { tasks = []; last_updated = Types.now_iso (); version = 11 }));
      Server_runtime_bootstrap.bootstrap_server_state_blocking state;
      let root_backlog =
        Yojson.Safe.from_string
          (read_file (Filename.concat masc_root "tasks/backlog.json"))
      in
      Alcotest.(check int) "single legacy room promoted without current_room" 11
        Yojson.Safe.Util.(root_backlog |> member "version" |> to_int);
      Alcotest.(check bool) "single legacy backlog not quarantined" false
        (Sys.file_exists
           (Filename.concat masc_root
              "_quarantine/rooms/team-room/tasks/backlog.json")))

let test_blocking_bootstrap_skips_flatten_with_multiple_legacy_rooms () =
  with_temp_dir "startup-blocking-room-multi-fallback" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let alpha_tasks = Filename.concat masc_root "rooms/alpha-room/tasks" in
      let beta_tasks = Filename.concat masc_root "rooms/beta-room/tasks" in
      Fs_compat.mkdir_p alpha_tasks;
      Fs_compat.mkdir_p beta_tasks;
      write_file
        (Filename.concat alpha_tasks "backlog.json")
        (Yojson.Safe.to_string
           (Types.backlog_to_yojson
              { tasks = []; last_updated = Types.now_iso (); version = 7 }));
      write_file
        (Filename.concat beta_tasks "backlog.json")
        (Yojson.Safe.to_string
           (Types.backlog_to_yojson
              { tasks = []; last_updated = Types.now_iso (); version = 11 }));
      Server_runtime_bootstrap.bootstrap_server_state_blocking state;
      let root_backlog_path = Filename.concat masc_root "tasks/backlog.json" in
      let root_backlog_promoted =
        if Sys.file_exists root_backlog_path then
          let root_backlog = Yojson.Safe.from_string (read_file root_backlog_path) in
          let version = Yojson.Safe.Util.(root_backlog |> member "version" |> to_int) in
          version = 7 || version = 11
        else
          false
      in
      Alcotest.(check bool)
        "multiple legacy rooms do not promote a legacy backlog into root"
        false root_backlog_promoted;
      Alcotest.(check bool) "alpha-room backlog stays in legacy dir" true
        (Sys.file_exists (Filename.concat alpha_tasks "backlog.json"));
      Alcotest.(check bool) "beta-room backlog stays in legacy dir" true
        (Sys.file_exists (Filename.concat beta_tasks "backlog.json")))

let test_blocking_bootstrap_ignores_whitespace_legacy_room_dirs () =
  with_temp_dir "startup-blocking-room-whitespace" (fun dir ->
      let state = Mcp_server.create_state ~base_path:dir in
      let masc_root = Coord.masc_root_dir state.Mcp_server.room_config in
      let spaced_tasks = Filename.concat masc_root "rooms/focus-room /tasks" in
      Fs_compat.mkdir_p spaced_tasks;
      write_file
        (Filename.concat spaced_tasks "backlog.json")
        (Yojson.Safe.to_string
           (Types.backlog_to_yojson
              { tasks = []; last_updated = Types.now_iso (); version = 13 }));
      Server_runtime_bootstrap.bootstrap_server_state_blocking state;
      let root_backlog_path = Filename.concat masc_root "tasks/backlog.json" in
      let root_backlog_promoted =
        if Sys.file_exists root_backlog_path then
          let root_backlog = Yojson.Safe.from_string (read_file root_backlog_path) in
          let version = Yojson.Safe.Util.(root_backlog |> member "version" |> to_int) in
          version = 13
        else
          false
      in
      Alcotest.(check bool) "whitespace room backlog stays in legacy dir" true
        (Sys.file_exists (Filename.concat spaced_tasks "backlog.json"));
      Alcotest.(check bool)
        "whitespace room backlog does not promote into root" false
        root_backlog_promoted)

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
        ( "cascade_authoring",
          `Assoc
            [
              ("path", `String "/tmp/runtime-root/.masc/config/cascade.toml");
              ("exists", `Bool false);
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
  ;
  Alcotest.(check bool) "startup cascade authoring path surfaced" true
    (match json |> member "config_resolution" |> member "cascade_authoring" |> member "path" with
     | `String value -> String.length value > 0
     | _ -> false)

let test_create_server_state_records_runtime_resolution () =
  with_temp_dir "startup-create-state" (fun dir ->
      let repo = Filename.concat dir "repo" in
      mkdir_p repo;
      ignore (make_config_root repo);
      with_env "MASC_STORAGE_TYPE" (Some "filesystem") @@ fun () ->
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
           ~mono_clock ~net ~proc_mgr ~fs);
      let json = Server_startup_state.to_yojson () in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "create_server_state records config root"
        (Filename.concat dir ".masc/config")
        (json |> member "config_resolution" |> member "config_root" |> member "path"
       |> to_string);
      Alcotest.(check string) "create_server_state records cascade authoring path"
        (Filename.concat dir ".masc/config/cascade.toml")
        (json |> member "config_resolution" |> member "cascade_authoring" |> member "path"
       |> to_string);
      Alcotest.(check string) "create_server_state records effective masc root"
        (Unix.realpath (Filename.concat dir ".masc"))
        (json |> member "path_diagnostics" |> member "effective_masc_root"
       |> to_string))

let test_create_server_state_preserves_raw_input_base_path () =
  with_temp_dir "startup-create-state-raw-input" (fun dir ->
      let repo = Filename.concat dir "repo" in
      let raw_input = Filename.concat dir ".masc" in
      mkdir_p repo;
      mkdir_p raw_input;
      ignore (make_config_root repo);
      with_env "MASC_STORAGE_TYPE" (Some "filesystem") @@ fun () ->
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
           ~clock ~mono_clock ~net ~proc_mgr ~fs);
      let json = Server_startup_state.to_yojson () in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "raw input base path preserved in diagnostics"
        raw_input
        (json |> member "path_diagnostics" |> member "input_base_path"
       |> to_string);
      Alcotest.(check (option string)) "raw input env preserved"
        (Some raw_input)
        (Env_config_core.base_path_raw_opt ());
      Alcotest.(check string) "normalized env remains effective workspace root"
        dir (Sys.getenv "MASC_BASE_PATH"))

let test_prompt_markdown_dir_falls_back_to_resolved_config_dir_with_repo_fallback_opt_in () =
  with_temp_dir "startup-prompts" (fun dir ->
      let config_root = Filename.concat dir "config" in
      let expected = Filename.concat config_root "prompts" in
      Fs_compat.mkdir_p expected;
      write_file (Filename.concat config_root "cascade.json") "{}";
      write_file (Filename.concat config_root "tool_policy.toml")
        "[groups.base]\ntools = [\"keeper_time_now\"]\n[presets.minimal]\ngroups = [\"base\"]\n";
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_ALLOW_REPO_CONFIG_FALLBACK" (Some "true") @@ fun () ->
      with_cwd dir @@ fun () ->
      Config_dir_resolver.reset ();
      let resolved =
        Fun.protect
          ~finally:(fun () -> Config_dir_resolver.reset ())
          (fun () ->
             Prompt_defaults.resolve_prompt_markdown_dir
               ~workspace_path:dir ~base_path:dir)
      in
      Alcotest.(check string) "temp room falls back to resolved prompt dir"
        (canonical_path expected) (canonical_path resolved))

let test_prompt_markdown_dir_does_not_use_repo_fallback_without_opt_in () =
  with_temp_dir "startup-prompts-no-opt-in" (fun dir ->
      let config_root = Filename.concat dir "config" in
      let repo_prompts = Filename.concat config_root "prompts" in
      let home = Filename.concat dir "home" in
      let expected = Filename.concat home ".masc/config/prompts" in
      Fs_compat.mkdir_p repo_prompts;
      write_file (Filename.concat config_root "cascade.json") "{}";
      write_file (Filename.concat config_root "tool_policy.toml")
        "[groups.base]\ntools = [\"keeper_time_now\"]\n[presets.minimal]\ngroups = [\"base\"]\n";
      Fs_compat.mkdir_p home;
      with_env "HOME" (Some home) @@ fun () ->
      with_env "MASC_CONFIG_DIR" None @@ fun () ->
      with_env "MASC_ALLOW_REPO_CONFIG_FALLBACK" None @@ fun () ->
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
        "temp room keeps resolved default prompt dir without repo fallback opt-in"
        expected resolved)

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
        merge_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("MASC_STORAGE_TYPE", "filesystem");
            ("GRAPHQL_API_KEY", "");
            ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
            ("MASC_AUTONOMY_ENABLED", "0");
            ("MASC_ORCHESTRATOR_ENABLED", "0");
            ("MASC_ALLOW_LEGACY_ACCEPT", "1");
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
      Alcotest.(check bool) "tool policy bootstrapped" true
        (Sys.file_exists (Filename.concat expected_config "tool_policy.toml"));
      let env =
        merge_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("MASC_STORAGE_TYPE", "filesystem");
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
              ~headers:[ "Content-Type: application/json" ]
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

let test_main_eio_invalid_cascade_stays_degraded_but_serves_dashboard () =
  with_temp_dir "startup-invalid-cascade" (fun dir ->
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
      write_invalid_local_only_cascade dir;
      let env =
        merge_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("MASC_STORAGE_TYPE", "filesystem");
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
                 "main_eio invalid cascade did not reach startup.phase=degraded within timeout in this environment.\nlog:\n%s"
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
            (String.starts_with ~prefix:"startup catalog validation failed:" startup_error);
          let config_headers, config_body =
            curl_request_capture ~output_dir:dir ~name:"cascade-config-invalid"
              ~method_:"GET"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/api/v1/cascade/config" port)
              ()
          in
          Alcotest.(check (option int)) "cascade config http 200" (Some 200)
            (http_status_from_headers config_headers);
          let config_json = parse_json_response_file config_body in
          Alcotest.(check string) "dashboard cascade surface is live"
            (Filename.concat dir ".masc/config/cascade.json")
            Yojson.Safe.Util.(
              config_json |> member "config_path" |> to_string)))

let test_main_eio_partial_catalog_stays_ready_and_surfaces_rejections () =
  with_temp_dir "startup-partial-cascade" (fun dir ->
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
      write_partially_invalid_cascade ~base_path:dir
        ~valid_model:(Printf.sprintf "custom:stable@http://127.0.0.1:%d/v1" mock_port);
      let env =
        merge_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("MASC_STORAGE_TYPE", "filesystem");
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
            Yojson.Safe.Util.(startup |> member "last_error" |> to_string_option = None);
          let config_headers, config_body =
            curl_request_capture ~output_dir:dir ~name:"cascade-config-partial"
              ~method_:"GET"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/api/v1/cascade/config" port)
              ()
          in
          Alcotest.(check (option int)) "cascade config http 200" (Some 200)
            (http_status_from_headers config_headers);
          let config_json = parse_json_response_file config_body in
          Alcotest.(check string) "partial validation stays validated"
            "validated"
            Yojson.Safe.Util.(
              config_json |> member "validation_status" |> to_string);
          Alcotest.(check int) "one invalid profile is surfaced" 1
            Yojson.Safe.Util.(
              config_json |> member "invalid_profiles" |> to_list |> List.length)))

let test_main_eio_invalid_default_partial_catalog_stays_degraded () =
  with_temp_dir "startup-default-invalid-partial-cascade" (fun dir ->
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
      write_partially_invalid_default_cascade ~base_path:dir
        ~valid_model:(Printf.sprintf "custom:stable@http://127.0.0.1:%d/v1" mock_port);
      let env =
        merge_env_overrides
          [
            ("MASC_BASE_PATH", dir);
            ("MASC_STORAGE_TYPE", "filesystem");
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
          Alcotest.(check bool) "last error mentions default-profile gate" true
            (contains_substring startup_error
               "startup catalog validation failed:"
             &&
             contains_substring startup_error
               "required default profile \"big_three\" failed validation");
          let config_headers, config_body =
            curl_request_capture ~output_dir:dir ~name:"cascade-config-default-invalid"
              ~method_:"GET"
              ~url:(Printf.sprintf "http://127.0.0.1:%d/api/v1/cascade/config" port)
              ()
          in
          Alcotest.(check (option int)) "cascade config http 200" (Some 200)
            (http_status_from_headers config_headers);
          let config_json = parse_json_response_file config_body in
          Alcotest.(check string) "default-invalid partial catalog is invalid"
            "invalid"
            Yojson.Safe.Util.(
              config_json |> member "validation_status" |> to_string);
          Alcotest.(check int) "default-invalid profile is surfaced" 1
            Yojson.Safe.Util.(
              config_json |> member "invalid_profiles" |> to_list |> List.length)))

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Alcotest.run "Server_runtime_bootstrap"
    [
      ( "bootstrap",
        [
          Alcotest.test_case "force_jsonl_fallback_env forces filesystem" `Quick
            test_force_jsonl_fallback_env;
          Alcotest.test_case
            "default OAS cascade timeout tracks keeper timeout"
            `Quick test_default_oas_cascade_timeout_tracks_keeper_timeout;
          Alcotest.test_case
            "default OAS cascade timeout keeps explicit override"
            `Quick test_default_oas_cascade_timeout_keeps_explicit_override;
          Alcotest.test_case
            "bootstrap base-path config copies versioned config"
            `Quick test_bootstrap_base_path_config_root_copies_versioned_config;
          Alcotest.test_case
            "bootstrap base-path config preserves existing root without refill"
            `Quick
            test_bootstrap_base_path_config_root_preserves_existing_root_without_refill;
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
          Alcotest.test_case "room init bootstraps keeper runtime dirs" `Quick
            test_room_init_bootstraps_keeper_runtime_dirs;
          Alcotest.test_case "otel exporter setup failure is soft" `Quick
            test_otel_exporter_setup_failure_is_soft;
          Alcotest.test_case
            "legacy keeper migration promotes valid resident meta"
            `Quick test_migrate_resident_keeper_dirs_promotes_valid_meta;
          Alcotest.test_case
            "legacy keeper migration keeps fresher current meta"
            `Quick test_migrate_resident_keeper_dirs_keeps_fresher_current_meta;
          Alcotest.test_case
            "legacy keeper migration uses source-scoped quarantine paths"
            `Quick
            test_migrate_resident_keeper_dirs_use_source_scoped_quarantine_path;
          Alcotest.test_case
            "blocking bootstrap promotes legacy keeper meta"
            `Quick
            test_blocking_bootstrap_promotes_legacy_keeper_meta_before_autoboot;
          Alcotest.test_case
            "blocking bootstrap flattens room with safe current_room fallback"
            `Quick
            test_blocking_bootstrap_flattens_room_with_safe_current_room_fallback;
          Alcotest.test_case
            "blocking bootstrap flattens single legacy room without current_room"
            `Quick
            test_blocking_bootstrap_flattens_single_legacy_room_without_current_room;
          Alcotest.test_case
            "blocking bootstrap skips flatten with multiple legacy rooms"
            `Quick
            test_blocking_bootstrap_skips_flatten_with_multiple_legacy_rooms;
          Alcotest.test_case
            "blocking bootstrap ignores whitespace legacy room dirs"
            `Quick
            test_blocking_bootstrap_ignores_whitespace_legacy_room_dirs;
          Alcotest.test_case "startup state json reports lazy failure" `Quick
            test_startup_state_json;
          Alcotest.test_case
            "startup catalog degradation survives lazy activation"
            `Quick
            test_startup_state_catalog_degraded_survives_lazy_activation;
          Alcotest.test_case "liveness probe is always true" `Quick
            test_startup_state_liveness;
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
            "prompt markdown dir falls back to resolved config dir with repo fallback opt-in"
            `Quick
            test_prompt_markdown_dir_falls_back_to_resolved_config_dir_with_repo_fallback_opt_in;
          Alcotest.test_case
            "prompt markdown dir does not use repo fallback without opt-in"
            `Quick
            test_prompt_markdown_dir_does_not_use_repo_fallback_without_opt_in;
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
            "main_eio partial catalog stays ready and surfaces rejections"
            `Slow
            test_main_eio_partial_catalog_stays_ready_and_surfaces_rejections;
          Alcotest.test_case
            "main_eio invalid default partial catalog stays degraded"
            `Slow
            test_main_eio_invalid_default_partial_catalog_stays_degraded;
          Alcotest.test_case
            "main_eio invalid cascade stays degraded but serves dashboard"
            `Slow
            test_main_eio_invalid_cascade_stays_degraded_but_serves_dashboard;
        ] );
    ]
