module Types = Masc_domain

module Lib = Masc_mcp

open Alcotest

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let with_eio f =
  Eio_main.run @@ fun env ->
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Fun.protect
    ~finally:(fun () -> Time_compat.clear_clock ())
    (fun () -> f env)

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let make_config_root root =
  let config = Filename.concat root "config" in
  mkdir_p (Filename.concat config "prompts");
  mkdir_p (Filename.concat config "keepers");
  mkdir_p (Filename.concat config "personas");
  write_file (Filename.concat config "cascade.json") "{}";
  config

(* OCaml stdlib lacks Unix.unsetenv; putenv name "" is only an
   approximation. Code that treats [""] as missing is fine, but
   Sys.getenv_opt (or Option.is_some checks on it) still sees the
   variable as present, so tests must not assume true unset semantics. *)
let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
  | Some v -> Unix.putenv name v
  | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_list_masc_tools_exposes_board_and_keeper_schemas () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run (fun sw ->
        match
          Lib.Worker_runtime.list_masc_tools ~sw ~auth_token:None
            ~session_id:"worker-test"
            ~names:
              (Some
                 [
                   "masc_board_post";
                   "masc_board_list";
                 ])
            ()
        with
        | Ok schemas ->
            let names =
              List.map (fun (schema : Types.tool_schema) -> schema.name) schemas
            in
            check bool "masc_board_post" true (List.mem "masc_board_post" names);
            check bool "masc_board_list" true (List.mem "masc_board_list" names)
        | Error err -> failf "expected schema lookup to succeed: %s" err)

let test_worker_runtime_config_prefers_env_override () =
  with_temp_dir "worker-runtime-config" @@ fun root ->
  let config_dir = make_config_root root in
  write_file
    (Filename.concat config_dir "worker-runtime.json")
    {|{
  "worker_spawn": {
    "backend": "docker",
    "docker": {
      "image": "masc-worker-runtime:test"
    }
  }
}|};
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  with_env "MASC_WORKER_RUNTIME_BACKEND" None @@ fun () ->
  Lib.Config_dir_resolver.reset ();
  Lib.Worker_runtime_config.reset ();
  check string "file config enables docker backend" "docker"
    (Lib.Worker_execution_backend.to_string
       (Lib.Worker_runtime_config.backend ()));
  with_env "MASC_WORKER_RUNTIME_BACKEND" (Some "local_playground") @@ fun () ->
  Lib.Config_dir_resolver.reset ();
  Lib.Worker_runtime_config.reset ();
  check string "env override forces local backend" "local_playground"
    (Lib.Worker_execution_backend.to_string
       (Lib.Worker_runtime_config.backend ()))

let test_worker_runtime_helper_protocol_roundtrip () =
  let run_result : Lib.Worker_container_types.run_result =
    {
      output = "ok";
      model_used = "custom:test@http://127.0.0.1:19001";
      input_tokens = Some 11;
      output_tokens = Some 7;
      cost_usd = Some 0.01;
      tool_call_count = 2;
      tool_names = [ "file_read"; "shell_exec" ];
      session_id = "worker-session";
      raw_trace_run = None;
      api_response = None;
      proof = None;
    }
  in
  let encoded =
    Lib.Worker_runtime_helper_protocol.success_json run_result
    |> Yojson.Safe.to_string
  in
  match Lib.Worker_runtime_helper_protocol.parse_stdout encoded with
  | Ok (Ok decoded) ->
      check string "output" run_result.output decoded.output;
      check string "model" run_result.model_used decoded.model_used;
      check (option int) "input_tokens" run_result.input_tokens
        decoded.input_tokens;
      check (list string) "tool_names" run_result.tool_names
        decoded.tool_names
  | Ok (Error payload) ->
      failf "expected success envelope, got helper error: %s" payload.message
  | Error err ->
      failf "expected helper envelope decode to succeed: %s" err

let test_worker_runtime_invalid_config_fails_closed () =
  with_temp_dir "worker-runtime-invalid" @@ fun root ->
  let config_dir = make_config_root root in
  write_file
    (Filename.concat config_dir "worker-runtime.json")
    {|{ "worker_spawn": { "backend": "docker", |};
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  with_env "MASC_WORKER_RUNTIME_BACKEND" None @@ fun () ->
  Lib.Config_dir_resolver.reset ();
  Lib.Worker_runtime_config.reset ();
  check string "malformed config resolves to fail-closed docker backend" "docker"
    (Lib.Worker_execution_backend.to_string
       (Lib.Worker_runtime_config.backend ()));
  check string "malformed config clears docker image" ""
    (Lib.Worker_runtime_config.docker_image ())

let test_rewrite_custom_model_label_for_container () =
  let rewritten =
    Lib.Worker_runtime_docker.rewrite_model_label_for_container
      "custom:qwen-test@http://127.0.0.1:19001"
  in
  check string "loopback custom label rewritten to host alias"
    "custom:qwen-test@http://host.docker.internal:19001" rewritten

let test_run_process_with_timeout_returns_124_on_timeout () =
  with_eio @@ fun env ->
  let result =
    Lib.Worker_runtime_docker.run_process_with_timeout
      ~clock_opt:(Some (Eio.Stdenv.clock env)) ~timeout_sec:1
      ~prog:"/bin/sh" ~argv:[ "/bin/sh"; "-c"; "trap '' TERM; kill -STOP $$" ]
      ~env:(Unix.environment ()) ()
  in
  check int "timeout exit code" 124 result.exit_code

let test_run_worker_oas_rejects_invalid_explicit_model_label () =
  with_temp_dir "worker-runtime-local" @@ fun root ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Fun.protect
    ~finally:(fun () -> Time_compat.clear_clock ())
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let spec : Lib.Worker_execution_spec.t =
        {
          base_path = root;
          worker_name = "worker-local";
          model_label = "not-a-model-label";
          working_dir = None;
          runtime_backend = Masc_mcp.Worker_execution_backend.Local_playground;
          thinking_enabled = Some false;
          worker_run_id = Some "run-local";
          role = Some "worker";
          selection_note = Some "invalid label";
          prompt = "Say hello.";
          timeout_sec = 30;
        }
      in
      match
        Lib.Worker_runtime.run_worker_oas ~sw
          ~net:(Eio.Stdenv.net env)
          ~room_config:None spec ()
      with
      | Ok _ ->
          fail "expected invalid explicit model label to fail before execution"
      | Error err ->
          check bool "mentions rejected label" true
            (String.contains err 'n' && String.contains err '-');
          check bool "does not use removed team-session stub" false
            (Astring.String.is_infix
               ~affix:"Worker_run_once removed (team session layer)"
               err))

let test_worker_execution_spec_rejects_removed_fields () =
  let json =
    Yojson.Safe.from_string
      {|{
  "base_path": "/tmp/base",
  "worker_name": "worker",
  "model_label": "custom:qwen@http://127.0.0.1:19001",
  "runtime_backend": "docker",
  "prompt": "hello",
  "timeout_sec": 30,
  "allowed_tools": ["masc_status"]
}|}
  in
  match Lib.Worker_execution_spec.of_yojson json with
  | Ok _ -> fail "expected removed worker spec field to be rejected"
  | Error msg ->
      check bool "mentions removed field" true
        (Astring.String.is_infix ~affix:"allowed_tools" msg)

let () =
  Alcotest.run "worker_runtime"
    [
      ( "tool_schemas",
        [ test_case "includes board and keeper tools for local workers" `Quick
            test_list_masc_tools_exposes_board_and_keeper_schemas ] );
      ( "config",
        [ test_case "worker runtime config env override" `Quick
            test_worker_runtime_config_prefers_env_override ] );
      ( "helper_protocol",
        [ test_case "worker helper envelope roundtrip" `Quick
            test_worker_runtime_helper_protocol_roundtrip ] );
      ( "fail_closed",
        [ test_case "malformed worker runtime config fails closed" `Quick
            test_worker_runtime_invalid_config_fails_closed ] );
      ( "rewrites",
        [ test_case "custom loopback model label rewritten for container" `Quick
            test_rewrite_custom_model_label_for_container ] );
      ( "process_timeout",
        [ test_case "timeout maps to exit code 124" `Quick
            test_run_process_with_timeout_returns_124_on_timeout ] );
      ( "local_runtime",
        [ test_case "invalid explicit model label fails before local worker execution"
            `Quick
            test_run_worker_oas_rejects_invalid_explicit_model_label ] );
      ( "spec_schema",
        [ test_case "removed worker spec fields are rejected" `Quick
            test_worker_execution_spec_rejects_removed_fields ] );
    ]
