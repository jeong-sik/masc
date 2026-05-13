open Alcotest
module Routes = Masc_mcp.Server_routes_http_routes_dashboard
module Keeper_api = Masc_mcp.Server_dashboard_http_keeper_api
module Auth = Masc_mcp.Auth
module Types = Masc_domain

type http_result =
  { status : int option
  ; body : string
  ; curl_exit : int
  ; stderr : string
  }

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with
   | End_of_file -> ());
  Buffer.contents buf
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)
;;

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)
;;

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let trim_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
;;

let parse_status header_raw =
  let lines = String.split_on_char '\n' header_raw |> List.map trim_cr in
  let rec find_http = function
    | [] -> None
    | line :: rest ->
      if String.length line >= 5 && String.sub line 0 5 = "HTTP/"
      then (
        match String.split_on_char ' ' line with
        | _proto :: code :: _ ->
          (try Some (int_of_string code) with
           | _ -> None)
        | _ -> None)
      else find_http rest
  in
  find_http lines
;;

let contains_substr needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h
    then false
    else if String.sub haystack i n = needle
    then true
    else loop (i + 1)
  in
  n = 0 || loop 0
;;

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
;;

let find_main_eio_exe () =
  let env_override = Sys.getenv_opt "MASC_MAIN_EIO_EXE" in
  let candidates =
    match env_override with
    | Some p -> [ p ]
    | None ->
      let build_roots = [ "."; ".."; "../.."; "../../.."; "../../../.." ] in
      let build_candidates =
        List.map
          (fun root -> Filename.concat root "_build/default/bin/main_eio.exe")
          build_roots
      in
      [ "./bin/main_eio.exe"
      ; "../bin/main_eio.exe"
      ; "../../bin/main_eio.exe"
      ; "../../../bin/main_eio.exe"
      ; "../../../../bin/main_eio.exe"
      ]
      @ build_candidates
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
    fail
      "main_eio executable not found. Set MASC_MAIN_EIO_EXE or build with `dune build \
       bin/main_eio.exe`."
;;

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.setsockopt socket Unix.SO_REUSEADDR true;
       match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
       | () ->
         (match Unix.getsockname socket with
         | Unix.ADDR_INET (_, port) -> Some port
         | _ -> fail "unexpected socket address")
       | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) -> None)
;;

let mock_openai_text_response ?(id = "chatcmpl-dashboard-routes") text =
  Printf.sprintf
    {|{"id":"%s","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}|}
    id text
;;

let wait_for_tcp_listener ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close socket)
      (fun () ->
         match Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) with
         | () -> true
         | exception Unix.Unix_error _ ->
           if Unix.gettimeofday () > deadline
           then false
           else (
             Unix.sleepf 0.05;
             loop ()))
  in
  loop ()
;;

let with_mock_model f =
  let port =
    match find_free_port () with
    | Some port -> port
    | None -> Alcotest.skip ()
  in
  let rec wait_child_exit ~pid ~deadline =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () > deadline
      then false
      else (
        Unix.sleepf 0.05;
        wait_child_exit ~pid ~deadline)
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  let response_body = mock_openai_text_response "pong" in
  match Unix.fork () with
  | 0 ->
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
    let server = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt server Unix.SO_REUSEADDR true;
    Unix.bind server (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
    Unix.listen server 16;
    let response =
      Printf.sprintf
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
        (String.length response_body)
        response_body
    in
    let rec serve () =
      let client, _addr = Unix.accept server in
      Fun.protect
        ~finally:(fun () -> Unix.close client)
        (fun () ->
           let buffer = Bytes.create 4096 in
           (try ignore (Unix.read client buffer 0 (Bytes.length buffer)) with
            | Unix.Unix_error _ -> ());
           try ignore (Unix.write_substring client response 0 (String.length response)) with
           | Unix.Unix_error _ -> ());
      serve ()
    in
    serve ()
  | pid ->
    let cleanup () =
      (try Unix.kill pid Sys.sigterm with
       | _ -> ());
      ignore (wait_child_exit ~pid ~deadline:(Unix.gettimeofday () +. 1.0))
    in
    if not (wait_for_tcp_listener ~port ~timeout_s:2.0)
    then (
      cleanup ();
      fail (Printf.sprintf "mock model server failed to listen on port %d" port));
    Fun.protect
      ~finally:cleanup
      (fun () ->
         f (Printf.sprintf "custom:mock@http://127.0.0.1:%d/v1" port))
;;

let wait_for_health ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline
    then false
    else (
      let res =
        let header_file = Filename.temp_file "dashboard-keeper-health-" ".hdr" in
        let body_file = Filename.temp_file "dashboard-keeper-health-" ".body" in
        let url = Printf.sprintf "http://127.0.0.1:%d/health" port in
        let args =
          [| "curl"
           ; "-sS"
           ; "--http1.1"
           ; "--max-time"
           ; "1"
           ; "-X"
           ; "GET"
           ; "-o"
           ; body_file
           ; "-D"
           ; header_file
           ; url
          |]
        in
        let ic, oc, ec = Unix.open_process_args_full "curl" args (Unix.environment ()) in
        close_out_noerr oc;
        let _stdout = read_all ic in
        let stderr = read_all ec in
        let curl_exit =
          match Unix.close_process_full (ic, oc, ec) with
          | Unix.WEXITED code -> code
          | Unix.WSIGNALED code -> 128 + code
          | Unix.WSTOPPED code -> 256 + code
        in
        let status = parse_status (read_file header_file) in
        let body = read_file body_file in
        (try Sys.remove header_file with
         | _ -> ());
        (try Sys.remove body_file with
         | _ -> ());
        { status; body; curl_exit; stderr }
      in
      match res.status with
      | Some 200 when contains_substr "\"state_ready\":true" res.body -> true
      | _ ->
        Unix.sleepf 0.1;
        loop ())
  in
  loop ()
;;

let wait_pid_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () > deadline
      then false
      else (
        Unix.sleepf 0.05;
        loop ())
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()
;;

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
;;

let has_env_override key overrides =
  List.exists (fun (name, _value) -> String.equal name key) overrides
;;

let repo_config_path name =
  Filename.concat (Filename.concat (Masc_test_deps.find_project_root ()) "config") name
;;

let split_model_spec spec =
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
;;

let cascade_toml ?(route_target = "default") ?(extra_route_targets = [])
    ?(invalid_profiles = []) valid_model profiles =
  let model_id, endpoint = split_model_spec valid_model in
  let profile_toml ~valid name =
    Printf.sprintf
      {|
[tier.%s]
members = [%S]

[tier-group.%s]
tiers = [%S]
|}
      name
      (if valid then "custom.mock" else "missing_provider.fake")
      name
      name
  in
  let routes_toml =
    ("keeper_turn", route_target)
    :: List.mapi
         (fun index target ->
            (Printf.sprintf "assignable_%d" (index + 1), target))
         extra_route_targets
    |> List.map (fun (route_name, target) ->
           Printf.sprintf "[routes.%s]\ntarget = \"tier-group.%s\"\n" route_name target)
    |> String.concat "\n"
  in
  Printf.sprintf
    {|[providers.custom]
protocol = "openai-http"
endpoint = %S

[models.mock]
api-name = %S
max-context = 128000
tools-support = true

[custom.mock]
%s
%s

%s
|}
    endpoint
    model_id
    (profiles |> List.map (profile_toml ~valid:true) |> String.concat "\n")
    (invalid_profiles |> List.map (profile_toml ~valid:false) |> String.concat "\n")
    routes_toml
;;

let with_temp_config_root cascade_toml f =
  let root = Filename.temp_file "dashboard-keeper-config-" "" in
  (try Sys.remove root with
   | _ -> ());
  Unix.mkdir root 0o755;
  let cleanup () = rm_rf root in
  Fun.protect
    ~finally:cleanup
    (fun () ->
       mkdir_p (Filename.concat root "personas");
       mkdir_p (Filename.concat root "keepers");
       mkdir_p (Filename.concat root "prompts");
       write_file (Filename.concat root "cascade.toml") cascade_toml;
       write_file
         (Filename.concat root "tool_policy.toml")
         (read_file (repo_config_path "tool_policy.toml"));
       f root)
;;

let with_config_dir config_root f =
  let prev = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
       (match prev with
        | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
        | None -> Unix.putenv "MASC_CONFIG_DIR" "");
       Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
       Unix.putenv "MASC_CONFIG_DIR" config_root;
       Masc_mcp.Config_dir_resolver.reset ();
       f ())
;;

let run_curl_post ?body ?token ~port ~path () =
  let header_file = Filename.temp_file "dashboard-keeper-post-" ".hdr" in
  let body_file = Filename.temp_file "dashboard-keeper-post-" ".body" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let base_args =
    [ "curl"
    ; "-sS"
    ; "--http1.1"
    ; "--max-time"
    ; "10"
    ; "-X"
    ; "POST"
    ; "-o"
    ; body_file
    ; "-D"
    ; header_file
    ]
  in
  let data_file =
    match body with
    | None -> None
    | Some payload ->
      let path = Filename.temp_file "dashboard-keeper-post-" ".json" in
      write_file path payload;
      Some path
  in
  let args =
    let args =
      match data_file with
      | Some payload_path ->
        base_args
        @ [ "-H"; "Content-Type: application/json"; "--data-binary"; "@" ^ payload_path ]
      | None -> base_args
    in
    let args =
      match token with
      | Some raw_token ->
        args @ [ "-H"; Printf.sprintf "Authorization: Bearer %s" raw_token ]
      | None -> args
    in
    Array.of_list (args @ [ url ])
  in
  let ic, oc, ec = Unix.open_process_args_full "curl" args (Unix.environment ()) in
  close_out_noerr oc;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let status = parse_status (read_file header_file) in
  let body = read_file body_file in
  (try Sys.remove header_file with
   | _ -> ());
  (try Sys.remove body_file with
   | _ -> ());
  Option.iter
    (fun path ->
       try Sys.remove path with
       | _ -> ())
    data_file;
  { status; body; curl_exit; stderr }
;;

let run_curl_get ?token ~port ~path () =
  let header_file = Filename.temp_file "dashboard-keeper-get-" ".hdr" in
  let body_file = Filename.temp_file "dashboard-keeper-get-" ".body" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let base_args =
    [ "curl"
    ; "-sS"
    ; "--http1.1"
    ; "--max-time"
    ; "10"
    ; "-X"
    ; "GET"
    ; "-o"
    ; body_file
    ; "-D"
    ; header_file
    ]
  in
  let args =
    let args =
      match token with
      | Some raw_token ->
          base_args @ [ "-H"; Printf.sprintf "Authorization: Bearer %s" raw_token ]
      | None -> base_args
    in
    Array.of_list (args @ [ url ])
  in
  let ic, oc, ec = Unix.open_process_args_full "curl" args (Unix.environment ()) in
  close_out_noerr oc;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let status = parse_status (read_file header_file) in
  let body = read_file body_file in
  (try Sys.remove header_file with
   | _ -> ());
  (try Sys.remove body_file with
   | _ -> ());
  { status; body; curl_exit; stderr }
;;

let execution_keeper_paused body keeper_name =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body in
  let keepers = json |> member "keepers" |> to_list in
  match
    List.find_opt
      (fun row -> row |> member "name" |> to_string = keeper_name)
      keepers
  with
  | Some row -> (
      match row |> member "paused" with
      | `Bool value -> value
      | `Null -> false
      | _ -> false)
  | None -> fail ("keeper missing from execution payload: " ^ keeper_name)
;;

let profile_names body =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body in
  match json |> member "profiles" with
  | `List items ->
      List.filter_map
        (function
          | `String value -> Some value
          | _ -> None)
        items
  | _ -> []
;;

let invalid_profile_names body =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body in
  match json |> member "invalid_profiles" with
  | `List items ->
      List.filter_map
        (fun item ->
           match item |> member "name" with
           | `String value -> Some value
           | _ -> None)
        items
  | _ -> []
;;

let keeper_profile_cascade_name body keeper_name =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string body in
  let rows = json |> member "keeper_profiles" |> to_list in
  match
    List.find_opt
      (fun row -> row |> member "keeper" |> to_string = keeper_name)
      rows
  with
  | Some row -> row |> member "cascade_name" |> to_string
  | None -> fail ("keeper profile missing from cascade config: " ^ keeper_name)
;;

let make_keeper_meta_json ?(name = "route_shadow_demo") ?(paused = true) () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
          ; "trace_id", `String ("trace-" ^ name ^ "-seed")
          ; "goal", `String "Route shadow regression fixture"
          ; "cascade_name", `String Masc_mcp.(Keeper_config.default_cascade_name ())
          ; "updated_at", `String "2026-04-04T00:00:00Z"
          ; "paused", `Bool paused
          ])
  with
  | Ok meta -> Masc_mcp.Keeper_types.meta_to_json meta |> Yojson.Safe.pretty_to_string
  | Error err -> fail ("keeper meta fixture parse failed: " ^ err)
;;

let write_keeper_toml_fixture ~config_root ~keeper_name =
  let keepers_dir = Filename.concat config_root "keepers" in
  mkdir_p keepers_dir;
  write_file
    (Filename.concat keepers_dir (keeper_name ^ ".toml"))
    (Printf.sprintf
       "[keeper]\npersona_name = %S\nsandbox_profile = \"local\"\n"
       keeper_name)
;;

let seed_auth_and_keeper ~base_path ~keeper_name =
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "bootstrap-admin"));
  Fs_compat.mkdir_p (Masc_mcp.Keeper_types.keeper_dir config);
  write_file
    (Masc_mcp.Keeper_types.keeper_meta_path config keeper_name)
    (make_keeper_meta_json ~name:keeper_name ());
  ignore
    (Masc_mcp.Auth.enable_auth
       base_path
       ~require_token:true
       ~agent_name:"bootstrap-admin");
  let admin_token =
    match
      Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin
    with
    | Ok (token, _cred) -> token
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  config, admin_token
;;

let seed_agent_file ?(agent_type = "worker") ?(capabilities = []) config agent_name =
  let timestamp = Masc_domain.now_iso () in
  let agent : Masc_domain.agent =
    {
      id = None;
      name = agent_name;
      agent_type;
      status = Masc_domain.Active;
      capabilities;
      current_task = None;
      joined_at = timestamp;
      last_seen = timestamp;
      meta = None;
    }
  in
  let agent_file =
    Filename.concat (Masc_mcp.Coord.agents_dir config)
      (Masc_mcp.Coord.safe_filename agent_name ^ ".json")
  in
  Masc_mcp.Coord.write_json config agent_file (Masc_domain.agent_to_yojson agent)
;;

let append_execution_receipt
    ?(tool_contract_result :
       Masc_mcp.Keeper_execution_receipt.tool_contract_result =
      Contract_satisfied_completion)
    ?(tools_used = [ "keeper_fs_read" ])
    ?(cascade_fallback_applied = true)
    ?(cascade_outcome : Masc_mcp.Keeper_execution_receipt.cascade_outcome =
      Cascade_passed_to_next_model)
    ?(degraded_retry_applied = true)
    ?(degraded_retry_cascade =
      Some Masc_mcp.Keeper_config.local_recovery_cascade_name)
    ?(fallback_reason = Some Masc_mcp.Keeper_error_classify.Turn_timeout)
    config ~keeper_name =
  let meta =
    match Masc_mcp.Keeper_types.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> fail ("keeper meta missing for receipt: " ^ keeper_name)
    | Error err -> fail ("read_meta failed for receipt: " ^ err)
  in
  let started_at =
    iso_of_unix (Unix.gettimeofday () +. 2.0)
  in
  let ended_at =
    iso_of_unix (Unix.gettimeofday () +. 3.0)
  in
  let receipt : Masc_mcp.Keeper_execution_receipt.t =
    {
      keeper_name = meta.name;
      agent_name = meta.agent_name;
      trace_id = Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id;
      generation = meta.runtime.generation;
      turn_count = Some 2;
      current_task_id = None;
      goal_ids = meta.active_goal_ids;
      outcome = `Ok;
      terminal_reason_code = "completed";
      response_text_present = true;
      model_used = Some "custom:mock";
      requested_tools = [ "keeper_task_claim"; "keeper_fs_read" ];
      reported_tools = [ "Read" ];
      observed_tools = [ "keeper_fs_read" ];
      canonical_tools = [ "keeper_fs_read" ];
      unexpected_tools = [ "WebSearch" ];
      tools_used;
      tool_contract_result;
      tool_surface =
        {
          turn_lane = Masc_mcp.Keeper_agent_tool_surface.Lane_tool_required;
          tool_surface_class = Masc_mcp.Keeper_agent_tool_surface.Surface_mixed;
          tool_requirement = Masc_mcp.Keeper_agent_tool_surface.Required;
          visible_tool_count = 2;
          tool_gate_enabled = true;
          tool_surface_fallback_used = false;
          required_tools = [];
          missing_required_tools = [];
        };
      sandbox_kind =
        Masc_mcp.Keeper_execution_receipt.sandbox_kind_of_meta meta;
      sandbox_root = Some config.base_path;
      network_mode = meta.network_mode;
      approval_profile = Some "trusted_local";
      approval_profile_derived = false;
      cascade_name =
        Masc_mcp.Keeper_execution_receipt.cascade_name_of_string
          (Masc_mcp.Keeper_types.cascade_name_of_meta meta);
      cascade_selected_model = Some "custom:mock";
      cascade_attempt_count = 2;
      cascade_fallback_applied;
      cascade_outcome;
      degraded_retry_applied;
      degraded_retry_cascade =
        Option.map Masc_mcp.Keeper_execution_receipt.cascade_name_of_string
          degraded_retry_cascade;
      fallback_reason;
      cascade_rotation_attempts =
        (match degraded_retry_cascade, fallback_reason with
         | Some retry_cascade, Some reason ->
           [
             {
               from_cascade =
                 Masc_mcp.Keeper_execution_receipt.cascade_name_of_string
                   (Masc_mcp.Keeper_types.cascade_name_of_meta meta);
               to_cascade =
                 Masc_mcp.Keeper_execution_receipt.cascade_name_of_string
                   retry_cascade;
               reason;
               outcome =
                 Masc_mcp.Keeper_execution_receipt.Rotation_retry_scheduled;
               slot_release_at_phase = None;
               productive_phase_elapsed_ms = Some 174000;
               retry_phase_elapsed_ms = Some 0;
               error_kind =
                 Some
                   (Masc_mcp.Keeper_execution_receipt.error_kind_of_string
                      "internal");
               error_message = Some "turn timeout";
               recorded_at = ended_at;
             };
           ]
         | _ -> []);
      stop_reason = Some Masc_mcp.Cascade_runner.Completed;
      error_kind = None;
      error_message = None;
      started_at;
      ended_at;
    }
  in
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let base_dir =
    Filename.concat
      (Masc_mcp.Keeper_types.keeper_dir config)
      (keeper_name ^ "/execution-receipts")
  in
  let month_dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p month_dir;
  Fs_compat.append_jsonl
    (Filename.concat month_dir day)
    (Masc_mcp.Keeper_execution_receipt.to_json receipt)
;;

let with_seeded_server ?(env_overrides = []) f =
  let run_with_env_overrides env_overrides =
    let exe = find_main_eio_exe () in
    let port =
      match find_free_port () with
      | Some p -> p
      | None -> Alcotest.skip ()
    in
    let log_file = Filename.temp_file "dashboard-keeper-routes-" ".log" in
    let base_path = Filename.temp_file "dashboard-keeper-base-" "" in
    let keeper_name = "route_shadow_demo" in
    (try Sys.remove base_path with
     | _ -> ());
    Unix.mkdir base_path 0o755;
    let config, admin_token = seed_auth_and_keeper ~base_path ~keeper_name in
    let log_fd =
      Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
    in
    let env =
      merge_env_overrides
        ([ "MASC_AUTONOMY_ENABLED", "0"
         ; "GRAPHQL_API_KEY", ""
         ; "GRAPHQL_URL", "http://127.0.0.1:9/graphql"
         ; "MASC_BASE_PATH", base_path
         ; "MASC_POSTGRES_URL", ""
         ; "DATABASE_URL", ""
         ; "SUPABASE_DB_URL", ""
         ; "SB_PG_URL", ""
         ; "MASC_BOARD_BACKEND", "jsonl"
         ]
         @ env_overrides)
    in
    let argv =
      [| exe
       ; "--host"
       ; "127.0.0.1"
       ; "--port"
       ; string_of_int port
       ; "--base-path"
       ; base_path
      |]
    in
    let pid = Unix.create_process_env exe argv env Unix.stdin log_fd log_fd in
    Unix.close log_fd;
    let cleanup () =
      (try Unix.kill pid Sys.sigterm with
       | _ -> ());
      if not (wait_pid_exit ~pid ~timeout_s:2.0)
      then (
        try Unix.kill pid Sys.sigkill with
        | _ -> ());
      ignore (wait_pid_exit ~pid ~timeout_s:1.0);
      rm_rf log_file;
      rm_rf base_path
    in
    if not (wait_for_health ~port ~timeout_s:45.0)
    then (
      let logs = read_file log_file in
      cleanup ();
      fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs));
    Fun.protect ~finally:cleanup (fun () -> f ~port ~config ~admin_token ~keeper_name)
  in
  if has_env_override "MASC_CONFIG_DIR" env_overrides
  then run_with_env_overrides env_overrides
  else
    with_mock_model @@ fun valid_model ->
    with_temp_config_root
      (cascade_toml valid_model [ "default"; "keeper_unified" ])
    @@ fun config_root ->
    run_with_env_overrides (("MASC_CONFIG_DIR", config_root) :: env_overrides)
;;

let check_route path expected =
  let actual = Keeper_api.classify_keeper_post_route path in
  if actual <> expected
  then
    failf
      "expected %s for %s"
      (match expected with
       | Keeper_api.Keeper_post_tools -> "tools"
       | Keeper_api.Keeper_post_config -> "config"
       | Keeper_api.Keeper_post_boot -> "boot"
       | Keeper_api.Keeper_post_shutdown -> "shutdown"
       | Keeper_api.Keeper_post_reset -> "reset"
       | Keeper_api.Keeper_post_clear -> "clear"
       | Keeper_api.Keeper_post_checkpoints -> "checkpoints"
       | Keeper_api.Keeper_post_directive -> "directive"
       | Keeper_api.Keeper_post_unknown -> "unknown")
      path
;;

let test_keeper_post_route_classification () =
  check_route "/api/v1/keepers/sangsu/tools" Keeper_api.Keeper_post_tools;
  check_route "/api/v1/keepers/sangsu/config" Keeper_api.Keeper_post_config;
  check_route "/api/v1/keepers/sangsu/boot" Keeper_api.Keeper_post_boot;
  check_route "/api/v1/keepers/sangsu/shutdown" Keeper_api.Keeper_post_shutdown;
  check_route "/api/v1/keepers/sangsu/reset" Keeper_api.Keeper_post_reset;
  check_route "/api/v1/keepers/sangsu/clear" Keeper_api.Keeper_post_clear;
  check_route "/api/v1/keepers/sangsu/checkpoints" Keeper_api.Keeper_post_checkpoints;
  check_route "/api/v1/keepers/sangsu/directive" Keeper_api.Keeper_post_directive;
  check_route "/api/v1/keepers/sangsu" Keeper_api.Keeper_post_unknown;
  check_route "/api/v1/keepers//boot" Keeper_api.Keeper_post_unknown
;;

let require_status label expected result =
  match result.status with
  | Some code ->
    if code <> expected
    then
      fail
        (Printf.sprintf
           "%s expected HTTP %d but got %d (curl_exit=%d stderr=%s body=%s)"
           label
           expected
           code
           result.curl_exit
           result.stderr
           result.body)
  | None ->
    fail
      (Printf.sprintf
         "%s missing HTTP status (curl_exit=%d stderr=%s body=%s)"
         label
         result.curl_exit
         result.stderr
         result.body)
;;

let test_keeper_lifecycle_routes_do_not_fall_through_to_generic_404 () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let boot_path = Printf.sprintf "/api/v1/keepers/%s/boot" keeper_name in
  let shutdown_path = Printf.sprintf "/api/v1/keepers/%s/shutdown" keeper_name in
  let clear_path = Printf.sprintf "/api/v1/keepers/%s/clear" keeper_name in
  let boot_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:boot_path ()
  in
  require_status "boot route returns 200" 200 boot_result;
  check
    bool
    "boot route is not generic 404"
    false
    (contains_substr {|{"error":"not found"}|} boot_result.body);
  check
    bool
    "boot route reaches lifecycle handler"
    true
    (contains_substr {|"action":"boot"|} boot_result.body);
  (match Masc_mcp.Keeper_types.read_meta config keeper_name with
   | Ok (Some meta) ->
       check bool "boot resumes paused keeper meta" false meta.paused
   | Ok None -> fail "keeper meta missing after boot route"
   | Error err -> fail ("failed to read keeper meta after boot route: " ^ err));
  let execution_after_boot =
    run_curl_get ~port ~path:"/api/v1/dashboard/execution" ()
  in
  require_status "execution GET returns 200 after boot" 200 execution_after_boot;
  check bool "execution reflects resumed keeper after boot" false
    (execution_keeper_paused execution_after_boot.body keeper_name);
  let shutdown_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:shutdown_path ()
  in
  require_status "shutdown route returns 200" 200 shutdown_result;
  check
    bool
    "shutdown route is not generic 404"
    false
    (contains_substr {|{"error":"not found"}|} shutdown_result.body);
  check
    bool
    "shutdown route reaches lifecycle handler"
    true
    (contains_substr {|"action":"shutdown"|} shutdown_result.body);
  (match Masc_mcp.Keeper_types.read_meta config keeper_name with
   | Ok (Some meta) ->
       let updated_meta =
         {
           meta with
           continuity_summary = "stale continuity snapshot";
           updated_at = Masc_mcp.Keeper_types.now_iso ();
           runtime =
             {
               meta.runtime with
               last_continuity_update_ts = 1234.0;
             };
         }
       in
       (match Masc_mcp.Keeper_types.write_meta ~force:true config updated_meta with
        | Ok () -> ()
        | Error err -> fail ("failed to seed continuity summary: " ^ err))
   | Ok None -> fail "keeper meta missing before clear route"
   | Error err -> fail ("failed to read keeper meta before clear: " ^ err));
  let clear_result =
    run_curl_post
      ~body:{|{"reason":"reset stale continuity","preserve_system_prompt":true}|}
      ~token:admin_token
      ~port
      ~path:clear_path
      ()
  in
  require_status "clear route returns 200" 200 clear_result;
  check
    bool
    "clear route is not generic 404"
    false
    (contains_substr {|{"error":"not found"}|} clear_result.body);
  check
    bool
    "clear route reaches lifecycle handler"
    true
    (contains_substr {|"action":"clear"|} clear_result.body);
  check
    bool
    "clear route reports continuity cleanup"
    true
    (contains_substr {|"continuity_cleared":true|} clear_result.body);
  (match Masc_mcp.Keeper_types.read_meta config keeper_name with
   | Ok (Some meta) ->
       check string "clear resets continuity summary" "" meta.continuity_summary;
       check (float 0.0001) "clear resets continuity freshness" 0.0
         meta.runtime.last_continuity_update_ts
   | Ok None -> fail "keeper meta missing after clear route"
   | Error err -> fail ("failed to read keeper meta after clear: " ^ err));
  match Masc_mcp.Keeper_types.read_meta config keeper_name with
  | Ok (Some meta) -> check bool "shutdown persists paused keeper meta" true meta.paused
  | Ok None -> fail "keeper meta missing after shutdown route"
  | Error err -> fail ("failed to read keeper meta after shutdown: " ^ err)
;;

let test_keeper_directive_resume_updates_paused_meta () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let directive_path =
    Printf.sprintf "/api/v1/keepers/%s/directive" keeper_name
  in
  let resume_result =
    run_curl_post
      ~body:{|{"action":"resume"}|}
      ~token:admin_token
      ~port
      ~path:directive_path
      ()
  in
  require_status "directive route returns 200" 200 resume_result;
  check
    bool
    "directive route reaches lifecycle handler"
    true
    (contains_substr {|"action":"resume"|} resume_result.body);
  let execution_after_resume =
    run_curl_get ~port ~path:"/api/v1/dashboard/execution" ()
  in
  require_status "execution GET returns 200 after directive" 200 execution_after_resume;
  check bool "execution reflects resumed keeper after directive" false
    (execution_keeper_paused execution_after_resume.body keeper_name);
  match Masc_mcp.Keeper_types.read_meta config keeper_name with
  | Ok (Some meta) ->
      check bool "directive resume clears paused keeper meta" false meta.paused
  | Ok None -> fail "keeper meta missing after directive resume"
  | Error err ->
      fail ("failed to read keeper meta after directive resume: " ^ err)
;;

let test_agent_purge_route_removes_plain_agent_artifacts () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name:_ ->
  let requested_agent_name = "worker-swift-fox" in
  let agent_name = "worker-swift-fox-001" in
  seed_agent_file ~capabilities:[ "coding" ] config agent_name;
  ignore
    (Masc_mcp.Auth.create_token config.base_path ~agent_name ~role:Masc_domain.Admin);
  let metrics_dir = Masc_mcp.Metrics_store_eio.agent_metrics_dir config agent_name in
  Fs_compat.mkdir_p metrics_dir;
  write_file (Filename.concat metrics_dir "2026-04.jsonl") "{}\n";
  let purge_result =
    run_curl_post
      ~body:(Printf.sprintf {|{"agent_name":"%s"}|} requested_agent_name)
      ~token:admin_token
      ~port
      ~path:"/api/v1/dashboard/agents/purge"
      ()
  in
  require_status "agent purge route returns 200" 200 purge_result;
  check bool "agent purge identifies plain agent" true
    (contains_substr {|"target_kind":"agent"|} purge_result.body);
  let open Yojson.Safe.Util in
  let purge_json = Yojson.Safe.from_string purge_result.body in
  let cleanup_rows = purge_json |> member "cleanup_results" |> to_list in
  check int "agent purge returns one normalized cleanup row" 1
    (List.length cleanup_rows);
  let cleanup_row =
    cleanup_rows
    |> List.find (fun row ->
         row |> member "agent_name" |> to_string = agent_name)
  in
  check int "agent purge reports pending confirms" 0
    (cleanup_row |> member "pending_confirms_removed" |> to_int);
  (* The route runs inside [main_eio.exe], not this test process. A plain
     seeded file-backed agent has no in-process server heartbeat to stop. *)
  check int "agent purge reports server-process stopped heartbeats" 0
    (cleanup_row |> member "heartbeats_stopped" |> to_int);
  check string "agent purge reports coord leave" (agent_name ^ " left the namespace")
    (cleanup_row |> member "coord_leave_result" |> to_string);
  check bool "agent file removed" false
    (Sys.file_exists
       (Filename.concat (Masc_mcp.Coord.agents_dir config)
          (Masc_mcp.Coord.safe_filename agent_name ^ ".json")));
  check bool "agent credential removed" false
    (Sys.file_exists
       (Masc_mcp.Auth.credential_file config.base_path agent_name));
  check bool "agent metrics removed" false (Sys.file_exists metrics_dir)
;;

let test_agent_purge_route_removes_keeper_artifacts_and_toml () =
  with_mock_model @@ fun valid_model ->
  with_temp_config_root
    (cascade_toml valid_model [ "default"; "keeper_unified" ])
  @@ fun config_root ->
  let keeper_name = "route_shadow_demo" in
  let keeper_toml_path =
    Filename.concat (Filename.concat config_root "keepers") (keeper_name ^ ".toml")
  in
  write_keeper_toml_fixture ~config_root ~keeper_name;
  with_seeded_server
    ~env_overrides:[ "MASC_CONFIG_DIR", config_root ]
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let meta =
    match Masc_mcp.Keeper_types.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> fail "keeper meta missing before purge"
    | Error err -> fail ("failed to read keeper meta before purge: " ^ err)
  in
  seed_agent_file
    ~agent_type:"keeper"
    ~capabilities:[ "keeper" ]
    config
    meta.agent_name;
  ignore
    (Masc_mcp.Auth.create_token config.base_path ~agent_name:keeper_name
       ~role:Masc_domain.Admin);
  ignore
    (Masc_mcp.Auth.create_token config.base_path ~agent_name:meta.agent_name
       ~role:Masc_domain.Admin);
  let agent_metrics_dir =
    Masc_mcp.Metrics_store_eio.agent_metrics_dir config meta.agent_name
  in
  Fs_compat.mkdir_p agent_metrics_dir;
  write_file (Filename.concat agent_metrics_dir "2026-04.jsonl") "{}\n";
  append_execution_receipt config ~keeper_name;
  let purge_result =
    run_curl_post
      ~body:(Printf.sprintf {|{"agent_name":"%s"}|} keeper_name)
      ~token:admin_token
      ~port
      ~path:"/api/v1/dashboard/agents/purge"
      ()
  in
  require_status "keeper purge route returns 200" 200 purge_result;
  check bool "keeper purge identifies keeper target" true
    (contains_substr {|"target_kind":"keeper"|} purge_result.body);
  check bool "keeper purge reports toml deletion" true
    (contains_substr {|"removed_keeper_toml":true|} purge_result.body);
  (match Masc_mcp.Keeper_types.read_meta config keeper_name with
   | Ok None -> ()
   | Ok (Some _) -> fail "keeper meta should be removed after purge"
   | Error err -> fail ("failed to read keeper meta after purge: " ^ err));
  check bool "keeper toml removed" false (Sys.file_exists keeper_toml_path);
  check bool "keeper agent file removed" false
    (Sys.file_exists
       (Filename.concat (Masc_mcp.Coord.agents_dir config)
          (Masc_mcp.Coord.safe_filename meta.agent_name ^ ".json")));
  check bool "keeper credential removed" false
    (Sys.file_exists
       (Masc_mcp.Auth.credential_file config.base_path keeper_name));
  check bool "keeper agent credential removed" false
    (Sys.file_exists
       (Masc_mcp.Auth.credential_file config.base_path meta.agent_name));
  check bool "keeper agent metrics removed" false
    (Sys.file_exists agent_metrics_dir);
  check bool "keeper runtime directory removed" false
    (Sys.file_exists
       (Filename.concat (Masc_mcp.Keeper_types.keeper_dir config) keeper_name));
  check bool "keeper session trace removed" false
    (Sys.file_exists
       (Masc_mcp.Keeper_types.keeper_session_dir config
          (Masc_mcp.Keeper_id.Trace_id.to_string meta.runtime.trace_id)))
;;

let test_available_cascade_profiles_filter_invalid_catalog_entries () =
  with_mock_model @@ fun valid_model ->
  with_temp_config_root
    (cascade_toml ~route_target:"good" ~invalid_profiles:[ "broken" ] valid_model
       [ "good" ])
  @@ fun config_root ->
  with_config_dir config_root @@ fun () ->
  check
    (list string)
    "assignable cascades exclude invalid presets"
    [ "good" ]
    (Routes.available_cascade_profiles ());
  let invalid = Routes.invalid_cascade_profiles () in
  check bool "invalid preset is surfaced separately" true
    (List.mem_assoc "tier.broken" invalid
     || List.mem_assoc "tier-group.broken" invalid)
;;

let test_invalid_profile_projection_keeps_internal_names () =
  with_mock_model @@ fun valid_model ->
  let model_id, endpoint = split_model_spec valid_model in
  let cascade_toml =
    Printf.sprintf
      {|[providers.custom]
protocol = "openai-http"
endpoint = %S

[models.mock]
api-name = %S
max-context = 128000
tools-support = true

[custom.mock]

[tier.primary]
members = ["missing_provider.fake"]

[tier.good]
members = ["custom.mock"]

[tier-group.primary]
tiers = ["good"]

[routes.keeper_turn]
target = "tier-group.primary"
|}
      endpoint model_id
  in
  with_temp_config_root cascade_toml @@ fun config_root ->
  with_config_dir config_root @@ fun () ->
  check bool "valid tier-group public name remains assignable" true
    (List.mem "primary" (Routes.available_cascade_profiles ()));
  let invalid = Routes.invalid_cascade_profiles () in
  check bool "invalid tier keeps qualified name" true
    (List.mem_assoc "tier.primary" invalid);
  check bool "valid tier-group is not conflated with invalid tier" false
    (List.mem_assoc "tier-group.primary" invalid)
;;

let test_keeper_cascade_routes_filter_invalid_catalog_entries () =
  with_mock_model @@ fun valid_model ->
  with_temp_config_root
    (cascade_toml ~route_target:"good" ~invalid_profiles:[ "broken" ] valid_model
       [ "good" ])
  @@ fun config_root ->
  with_seeded_server
    ~env_overrides:[ "MASC_CONFIG_DIR", config_root ]
  @@ fun ~port ~config:_ ~admin_token ~keeper_name ->
  let list_result =
    run_curl_get ~port ~path:"/api/v1/keeper/cascades" ()
  in
  require_status "keeper cascades GET returns 200" 200 list_result;
  let profiles = profile_names list_result.body in
  let invalid_profiles = invalid_profile_names list_result.body in
  check bool "valid profile remains assignable" true (List.mem "good" profiles);
  check bool "invalid profile omitted from assignable list" false
    (List.mem "broken" profiles);
  check bool "invalid profile is surfaced in payload" true
    (List.mem "tier.broken" invalid_profiles
     || List.mem "tier-group.broken" invalid_profiles);
  let assign_invalid_result =
    run_curl_post
      ~body:
        (Printf.sprintf
           {|{"keeper":"%s","cascade_name":"broken"}|}
           keeper_name)
      ~token:admin_token
      ~port
      ~path:"/api/v1/keeper/cascade"
      ()
  in
  require_status "invalid cascade assignment returns 409" 409 assign_invalid_result;
  check bool "invalid cascade rejection explains config error" true
    (contains_substr "invalid in active cascade.toml" assign_invalid_result.body)
;;

let test_keeper_cascade_assignment_updates_dashboard_projection () =
  with_mock_model @@ fun valid_model ->
  with_temp_config_root
    (cascade_toml ~route_target:"primary" ~extra_route_targets:[ "alternate" ] valid_model
       [ "primary"; "alternate" ])
  @@ fun config_root ->
  let seeded_keeper_name = "route_shadow_demo" in
  write_keeper_toml_fixture ~config_root ~keeper_name:seeded_keeper_name;
  with_seeded_server
    ~env_overrides:[ "MASC_CONFIG_DIR", config_root ]
  @@ fun ~port ~config:_ ~admin_token ~keeper_name ->
  check string "fixture keeper name" seeded_keeper_name keeper_name;
  let boot_path = Printf.sprintf "/api/v1/keepers/%s/boot" keeper_name in
  let boot_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:boot_path ()
  in
  require_status "boot route registers keeper" 200 boot_result;
  let before =
    run_curl_get ~port ~path:"/api/v1/cascade/config" ()
  in
  require_status "cascade config GET before assignment returns 200" 200 before;
  check string "dashboard starts with seeded meta cascade"
    Masc_mcp.(Keeper_config.default_cascade_name ())
    (keeper_profile_cascade_name before.body keeper_name);
  let assign_result =
    run_curl_post
      ~body:
        (Printf.sprintf
           {|{"keeper":"%s","cascade_name":"alternate"}|}
           keeper_name)
      ~token:admin_token
      ~port
      ~path:"/api/v1/keeper/cascade"
      ()
  in
  require_status "valid cascade assignment returns 200" 200 assign_result;
  let open Yojson.Safe.Util in
  let assign_json = Yojson.Safe.from_string assign_result.body in
  check bool "assignment synced live meta" true
    (assign_json |> member "live_meta_synced" |> to_bool);
  let after =
    run_curl_get ~port ~path:"/api/v1/cascade/config" ()
  in
  require_status "cascade config GET after assignment returns 200" 200 after;
  check string "dashboard projection reflects assigned cascade"
    "alternate"
    (keeper_profile_cascade_name after.body keeper_name);
  let keeper_toml_path =
    Filename.concat (Filename.concat config_root "keepers") (keeper_name ^ ".toml")
  in
  check bool "persistent TOML cascade updated" true
    (contains_substr {|cascade_name = "alternate"|} (read_file keeper_toml_path))
;;

let test_execution_trust_route_surfaces_trust_summary_fields () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token:_ ~keeper_name ->
  append_execution_receipt
    ~cascade_fallback_applied:false
    ~cascade_outcome:Masc_mcp.Keeper_execution_receipt.Cascade_completed
    ~degraded_retry_applied:false
    ~degraded_retry_cascade:None
    ~fallback_reason:None
    config ~keeper_name;
  let result =
    run_curl_get ~port ~path:"/api/v1/dashboard/execution-trust" ()
  in
  require_status "execution trust GET returns 200" 200 result;
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string result.body in
  check string "route surfaces execution trust source" "execution_receipt"
    (json |> member "source" |> to_string);
  check string "route surfaces execution trust health" "ok"
    (json |> member "health" |> to_string);
  check string "route surfaces execution trust dashboard surface"
    "/api/v1/dashboard/execution-trust"
    (json |> member "dashboard_surface" |> to_string);
  let row =
    match json |> member "keepers" |> to_list with
    | keeper :: _ -> keeper
    | [] ->
        Alcotest.failf "expected execution trust keeper row for %s: %s"
          keeper_name result.body
  in
  check bool "route surfaces trust outcome" true
    (List.mem
       (row |> member "trust" |> member "last_outcome" |> to_string)
       [ "receipt_done"; "ok"; "not_run"; "completed" ]);
  check string "route surfaces trust sandbox kind" "local"
    (row |> member "trust" |> member "sandbox" |> member "kind"
     |> to_string);
  check bool "route surfaces trust contract result" true
    (List.mem
       (row |> member "trust" |> member "tool_contract_result" |> to_string)
       [ "satisfied"; "satisfied_completion"; "satisfied_execution"; "unknown" ]);
  check string "route surfaces trust disposition" "Pass"
    (row |> member "trust" |> member "disposition" |> to_string);
  check string "route surfaces trust approval state" "idle"
    (row |> member "trust" |> member "approval_state" |> member "state"
     |> to_string);
  check string "route surfaces execution summary mutation guard"
    "mutation_contract_satisfied"
    (row |> member "trust" |> member "execution_summary"
     |> member "mutation_guard_summary" |> to_string);
  check bool "route surfaces latest causal event field" true
    (match row |> member "trust" |> member "latest_causal_event" with
     | `Null | `Assoc _ -> true
     | _ -> false)
;;

let test_dashboard_bootstrap_route_surfaces_cold_start_contract () =
  with_seeded_server
  @@ fun ~port ~config:_ ~admin_token:_ ~keeper_name:_ ->
  let result =
    run_curl_get ~port ~path:"/api/v1/dashboard/bootstrap" ()
  in
  require_status "bootstrap GET returns 200" 200 result;
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string result.body in
  (match json |> member "served_at" with
   | `String value when String.trim value <> "" -> ()
   | _ -> fail ("bootstrap served_at missing: " ^ result.body));
  check int "bootstrap milestone" 1 (json |> member "milestone" |> to_int);
  List.iter
    (fun key ->
       match json |> member key with
       | `Null -> failf "bootstrap missing slice %s: %s" key result.body
       | _ -> ())
    [ "shell"
    ; "execution"
    ; "planning"
    ; "namespace_truth"
    ; "goals"
    ; "goal_loop_status"
    ]
;;

let test_composite_routes_surface_latest_execution_receipt () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let boot_path = Printf.sprintf "/api/v1/keepers/%s/boot" keeper_name in
  let boot_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:boot_path ()
  in
  require_status "boot route registers keeper before composite read" 200 boot_result;
  append_execution_receipt config ~keeper_name;
  let per_keeper_path =
    Printf.sprintf "/api/v1/keepers/%s/composite" keeper_name
  in
  let per_keeper = run_curl_get ~port ~path:per_keeper_path () in
  require_status "per-keeper composite GET returns 200" 200 per_keeper;
  let open Yojson.Safe.Util in
  let per_keeper_json = Yojson.Safe.from_string per_keeper.body in
  check string "per-keeper composite exposes keeper identity" keeper_name
    (per_keeper_json |> member "keeper" |> to_string);
  let execution = per_keeper_json |> member "execution" in
  check bool "composite exposes latest receipt presence" true
    (execution |> member "latest_receipt_present" |> to_bool);
  check string "composite exposes terminal reason" "completed"
    (execution |> member "terminal_reason_code" |> to_string);
  check bool "composite exposes receipt duration" true
    (match execution |> member "duration_ms" with
     | `Float _ | `Int _ -> true
     | _ -> false);
  check string "composite exposes cascade fallback reason" "turn_timeout"
    (execution |> member "cascade" |> member "fallback_reason" |> to_string);
  check int "composite exposes provider attempt count" 2
    (execution |> member "cascade" |> member "attempt_count" |> to_int);
  let fleet = run_curl_get ~port ~path:"/api/v1/keepers/composite" () in
  require_status "fleet composite GET returns 200" 200 fleet;
  let fleet_json = Yojson.Safe.from_string fleet.body in
  let fleet_snapshot =
    match fleet_json |> member "snapshots" |> to_list with
    | snapshot :: _ -> snapshot
    | [] -> fail "expected at least one fleet composite snapshot"
  in
  check string "fleet composite exposes keeper identity" keeper_name
    (fleet_snapshot |> member "keeper" |> to_string);
  let fleet_execution = fleet_snapshot |> member "execution" in
  check bool "fleet composite exposes latest receipt presence" true
    (fleet_execution |> member "latest_receipt_present" |> to_bool);
  check bool "fleet composite exposes selected model when available" true
    (match fleet_execution |> member "cascade" |> member "selected_model" with
     | `String "custom:mock" | `Null -> true
     | _ -> false)
;;

let test_composite_routes_surface_runtime_recommended_actions () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let boot_path = Printf.sprintf "/api/v1/keepers/%s/boot" keeper_name in
  let boot_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:boot_path ()
  in
  require_status "boot route registers keeper before composite read" 200 boot_result;
  append_execution_receipt ~tool_contract_result:Contract_missing_required_tool_use
    ~tools_used:[] config ~keeper_name;
  let path = Printf.sprintf "/api/v1/keepers/%s/composite" keeper_name in
  let result = run_curl_get ~port ~path () in
  require_status "per-keeper composite GET returns 200" 200 result;
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string result.body in
  let runtime_attention = json |> member "runtime_attention" in
  (match runtime_attention with
   | `Assoc _ -> ()
   | other ->
       Alcotest.failf
         "expected runtime_attention object, got %s in body %s"
         (Yojson.Safe.to_string other)
         result.body);
  check string "composite surfaces blocked runtime attention" "blocked"
    (runtime_attention |> member "state" |> to_string);
  check bool "composite runtime attention needs action" true
    (runtime_attention |> member "needs_attention" |> to_bool);
  check string "composite runtime attention reason" "tool_required_unsatisfied"
    (runtime_attention |> member "reason" |> to_string);
  let actions = json |> member "recommended_actions" |> to_list in
  check bool "composite recommends keeper_probe" true
    (List.exists
       (fun row ->
         row |> member "action_type" |> to_string = "keeper_probe"
         && row |> member "target_id" |> to_string = keeper_name)
       actions);
  check bool "composite recommends keeper_message" true
    (List.exists
       (fun row ->
         row |> member "action_type" |> to_string = "keeper_message"
         && row |> member "target_id" |> to_string = keeper_name)
       actions);
  check bool "tool-contract blocker does not recommend restart" false
    (List.exists
       (fun row -> row |> member "action_type" |> to_string = "keeper_recover")
       actions)
;;

let test_composite_runtime_attention_surfaces_fiber_stop () =
  let base_path = Filename.temp_file "dashboard-keeper-fiber-stop-" "" in
  (try Sys.remove base_path with
   | _ -> ());
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_registry.clear ();
      rm_rf base_path)
    (fun () ->
      let keeper_name = "stop_requested_demo" in
      let config = Masc_mcp.Coord.default_config base_path in
      ignore (Masc_mcp.Coord.init config ~agent_name:(Some "bootstrap-admin"));
      Fs_compat.mkdir_p (Masc_mcp.Keeper_types.keeper_dir config);
      write_file
        (Masc_mcp.Keeper_types.keeper_meta_path config keeper_name)
        (make_keeper_meta_json ~name:keeper_name ~paused:false ());
      let meta =
        match Masc_mcp.Keeper_types.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "keeper meta missing for fiber-stop composite test"
        | Error err -> fail ("read_meta failed: " ^ err)
      in
      let entry =
        Masc_mcp.Keeper_registry.register
          ~base_path:config.base_path keeper_name meta
      in
      Atomic.set entry.fiber_stop true;
      let open Yojson.Safe.Util in
      let json =
        Masc_mcp.Server_dashboard_http.dashboard_keeper_composite_json
          ~config entry
      in
      let runtime_attention = json |> member "runtime_attention" in
      check string "fiber-stop runtime state" "stop_requested"
        (runtime_attention |> member "state" |> to_string);
      check bool "fiber-stop runtime attention needed" true
        (runtime_attention |> member "needs_attention" |> to_bool);
      check bool "fiber-stop flag surfaced" true
        (runtime_attention |> member "fiber_stop_requested" |> to_bool);
      check string "fiber-stop runtime reason" "fiber_stop_requested"
        (runtime_attention |> member "reason" |> to_string);
      check string "fiber-stop runtime source" "registry_fiber_stop"
        (runtime_attention |> member "source" |> to_string);
      let actions = json |> member "recommended_actions" |> to_list in
      check bool "fiber-stop does not recommend keeper_recover" false
        (List.exists
           (fun row -> row |> member "action_type" |> to_string = "keeper_recover")
           actions);
      check bool "fiber-stop recommends keeper_probe" true
        (List.exists
           (fun row -> row |> member "action_type" |> to_string = "keeper_probe")
           actions))
;;

let test_composite_routes_skip_recent_successful_idle_recovery () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token ~keeper_name ->
  let boot_path = Printf.sprintf "/api/v1/keepers/%s/boot" keeper_name in
  let boot_result =
    run_curl_post ~body:"{}" ~token:admin_token ~port ~path:boot_path ()
  in
  require_status "boot route registers keeper before composite read" 200 boot_result;
  append_execution_receipt ~tool_contract_result:Contract_satisfied_execution
    ~tools_used:[ "keeper_fs_read" ]
    ~cascade_fallback_applied:false
    ~cascade_outcome:Masc_mcp.Keeper_execution_receipt.Cascade_completed
    ~degraded_retry_applied:false
    ~degraded_retry_cascade:None
    ~fallback_reason:None config ~keeper_name;
  let path = Printf.sprintf "/api/v1/keepers/%s/composite" keeper_name in
  let result = run_curl_get ~port ~path () in
  require_status "per-keeper composite GET returns 200" 200 result;
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string result.body in
  check bool "seeded keeper exposes live-state boolean" true
    (match json |> member "is_live" with `Bool _ -> true | _ -> false);
  let execution = json |> member "execution" in
  check string "receipt is healthy" "healthy"
    (execution |> member "operator_disposition_reason" |> to_string);
  check int "recent successful idle keeper has no runtime action" 0
    (json |> member "recommended_actions" |> to_list |> List.length)
;;

let test_tool_calls_route_surfaces_coverage_gap_health () =
  with_seeded_server
  @@ fun ~port ~config ~admin_token:_ ~keeper_name ->
  let masc_root = Masc_mcp.Coord.masc_root_dir config in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Masc_mcp.Telemetry_coverage_gap.record
    ~masc_root
    ~source:"tool_call_io"
    ~producer:"keeper_hooks_oas"
    ~durable_store:(Filename.concat masc_root "tool_calls")
    ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
    ~stale_reason:"tool_call_io_append_failed"
    ~keeper_name
    ~trace_id:"trace-tool-call-gap"
    ();
  let result =
    run_curl_get ~port
      ~path:(Printf.sprintf "/api/v1/keepers/%s/tool-calls" keeper_name)
      ()
  in
  require_status "tool calls GET returns 200" 200 result;
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string result.body in
  check string "route surfaces tool_call_io source" "tool_call_io"
    (json |> member "source" |> to_string);
  check string "route surfaces coverage gap health" "coverage_gap"
    (json |> member "health" |> to_string);
  check string "route surfaces coverage gap stale reason"
    "tool_call_io_append_failed"
    (json |> member "stale_reason" |> to_string)
;;

let test_merge_keeper_trace_lines_includes_internal_history () =
  let base_path = Filename.temp_file "dashboard-keeper-trajectory-" "" in
  (try Sys.remove base_path with
   | _ -> ());
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "bootstrap-admin"));
  let trace_id = "trace-route-shadow-demo-seed" in
  let internal_history_path =
    Masc_mcp.Keeper_types.keeper_internal_history_path config trace_id
  in
  Fs_compat.mkdir_p (Filename.dirname internal_history_path);
  write_file
    internal_history_path
    (String.concat
       "\n"
       [ {|{"timestamp":1000.0,"ts_unix":1000.0,"source":"internal_assistant","role":"assistant","content":"first internal thought"}|}
       ; {|{"timestamp":1001.0,"ts_unix":1001.0,"source":"internal_assistant","role":"assistant","content":"second internal thought"}|}
       ]
     ^ "\n");
  let trajectory_lines =
    [
      Masc_mcp.Trajectory.Tool_call
        {
          Masc_mcp.Trajectory.ts = 1002.0;
          ts_iso = "1970-01-01T00:16:42Z";
          turn = 3;
          round = 1;
          tool_name = "masc_tasks";
          args_json = "{}";
          gate_decision = Masc_mcp.Trajectory.Pass;
          result = Some {|{"ok":true}|};
          duration_ms = 12;
          error = None;
          cost_usd = 0.0;
        };
    ]
  in
  let merged =
    Keeper_api.merge_keeper_trace_lines ~config ~trace_id trajectory_lines
  in
  check int "merged entry count" 3 (List.length merged);
  (match List.nth merged 0 with
   | Masc_mcp.Trajectory.Thinking entry ->
     check string "first merged content" "first internal thought" entry.content
   | Masc_mcp.Trajectory.Tool_call _ ->
     fail "expected internal history entry first");
  (match List.nth merged 1 with
   | Masc_mcp.Trajectory.Thinking entry ->
     check string "second merged content" "second internal thought" entry.content
   | Masc_mcp.Trajectory.Tool_call _ ->
     fail "expected internal history entry second");
  (match List.nth merged 2 with
   | Masc_mcp.Trajectory.Tool_call entry ->
     check string "tool entry remains present" "masc_tasks" entry.tool_name
   | Masc_mcp.Trajectory.Thinking _ ->
     fail "expected tool entry last");
  let tool_only =
    List.filter
      (function
        | Masc_mcp.Trajectory.Tool_call _ -> true
        | Masc_mcp.Trajectory.Thinking _ -> false)
      merged
  in
  check int "thinking entries can still be filtered out" 1 (List.length tool_only))
;;

let dashboard_dev_token_test_dir () =
  let path = Filename.temp_file "masc-dashboard-dev-token-" ".tmp" in
  Sys.remove path;
  path
;;

let test_ensure_dashboard_dev_token_rotates_legacy_dashboard_dev_owner () =
  let base_path = dashboard_dev_token_test_dir () in
  mkdir_p (Filename.concat base_path ".masc/auth");
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let legacy_raw =
         match Auth.create_token base_path ~agent_name:"dashboard-dev"
                 ~role:Masc_domain.Admin with
         | Ok (raw, _cred) -> raw
         | Error err -> fail (Masc_domain.masc_error_to_string err)
       in
       let legacy_path = Routes.legacy_dashboard_dev_token_path base_path in
       let canonical_path = Routes.dashboard_dev_token_path base_path in
       Auth.save_private_text_file legacy_path legacy_raw;
       match Routes.ensure_dashboard_dev_token base_path with
       | Error msg -> fail msg
       | Ok raw ->
           check bool "legacy token rotates to canonical owner" true
             (not (String.equal raw legacy_raw));
           check bool "canonical token file written" true
             (Sys.file_exists canonical_path);
           check bool "legacy token file removed" false
             (Sys.file_exists legacy_path);
           (match Auth.verify_token base_path ~agent_name:"dashboard" ~token:raw with
            | Ok cred ->
                check string "canonical credential owner" "dashboard"
                  cred.agent_name
            | Error err ->
                fail (Masc_domain.masc_error_to_string err)))
;;

let test_ensure_dashboard_dev_token_reuses_canonical_dashboard_token () =
  let base_path = dashboard_dev_token_test_dir () in
  mkdir_p (Filename.concat base_path ".masc/auth");
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       let canonical_raw =
         match Auth.create_token base_path ~agent_name:"dashboard"
                 ~role:Masc_domain.Admin with
         | Ok (raw, _cred) -> raw
         | Error err -> fail (Masc_domain.masc_error_to_string err)
       in
       let legacy_raw =
         match Auth.create_token base_path ~agent_name:"dashboard-dev"
                 ~role:Masc_domain.Admin with
         | Ok (raw, _cred) -> raw
         | Error err -> fail (Masc_domain.masc_error_to_string err)
       in
       let legacy_path = Routes.legacy_dashboard_dev_token_path base_path in
       let canonical_path = Routes.dashboard_dev_token_path base_path in
       Auth.save_private_text_file canonical_path canonical_raw;
       Auth.save_private_text_file legacy_path legacy_raw;
       match Routes.ensure_dashboard_dev_token base_path with
       | Error msg -> fail msg
       | Ok raw ->
           check string "canonical token reused" canonical_raw raw;
           check bool "legacy token file cleaned up" false
             (Sys.file_exists legacy_path);
           check bool "canonical token file kept" true
             (Sys.file_exists canonical_path))
;;

let () =
  run
    "dashboard_keeper_routes"
    [ ( "dashboard_keeper_routes"
      , [ test_case
            "classify keeper POST routes"
            `Quick
            test_keeper_post_route_classification
        ; test_case
            "lifecycle POST routes do not fall through to generic 404"
            `Slow
            test_keeper_lifecycle_routes_do_not_fall_through_to_generic_404
        ; test_case
            "directive resume updates paused meta"
            `Slow
            test_keeper_directive_resume_updates_paused_meta
        ; test_case
            "agent purge removes plain agent artifacts"
            `Slow
            test_agent_purge_route_removes_plain_agent_artifacts
        ; test_case
            "agent purge removes keeper artifacts and keeper toml"
            `Slow
            test_agent_purge_route_removes_keeper_artifacts_and_toml
        ; test_case
            "available cascade profiles filter invalid catalog entries"
            `Quick
            test_available_cascade_profiles_filter_invalid_catalog_entries
        ; test_case
            "keeper cascade routes filter invalid catalog entries"
            `Slow
            test_keeper_cascade_routes_filter_invalid_catalog_entries
        ; test_case
            "keeper cascade assignment updates dashboard projection"
            `Slow
            test_keeper_cascade_assignment_updates_dashboard_projection
        ; test_case
            "execution trust route surfaces trust summary fields"
            `Slow
            test_execution_trust_route_surfaces_trust_summary_fields
        ; test_case
            "dashboard bootstrap route surfaces cold-start contract"
            `Slow
            test_dashboard_bootstrap_route_surfaces_cold_start_contract
        ; test_case
            "composite routes surface latest execution receipt"
            `Slow
            test_composite_routes_surface_latest_execution_receipt
        ; test_case
            "composite routes surface runtime recommended actions"
            `Slow
            test_composite_routes_surface_runtime_recommended_actions
        ; test_case
            "composite runtime attention surfaces fiber stop"
            `Quick
            test_composite_runtime_attention_surfaces_fiber_stop
        ; test_case
            "composite routes skip recent successful idle recovery"
            `Slow
            test_composite_routes_skip_recent_successful_idle_recovery
        ; test_case
            "tool calls route surfaces coverage gap health"
            `Slow
            test_tool_calls_route_surfaces_coverage_gap_health
        ; test_case
            "dashboard dev token rotates legacy dashboard-dev owner"
            `Quick
            test_ensure_dashboard_dev_token_rotates_legacy_dashboard_dev_owner
        ; test_case
            "dashboard dev token reuses canonical dashboard token"
            `Quick
            test_ensure_dashboard_dev_token_reuses_canonical_dashboard_token
        ; test_case
            "merge keeper trace lines includes internal history"
            `Quick
            test_merge_keeper_trace_lines_includes_internal_history
        ; test_case
            "invalid profile projection keeps internal names"
            `Quick
            test_invalid_profile_projection_keeps_internal_names
        ] )
    ]
;;
