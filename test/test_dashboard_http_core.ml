module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_http_core" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let with_test_env f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      with_env "MASC_STORAGE_TYPE" "filesystem" @@ fun () ->
      with_env "MASC_POSTGRES_URL" "" @@ fun () ->
      with_env "DATABASE_URL" "" @@ fun () ->
      with_env "SUPABASE_DB_URL" "" @@ fun () ->
      with_env "SB_PG_URL" "" @@ fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      Eio.Switch.run @@ fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () -> f ~env ~sw ~config))

let with_pg_test_env f =
  match Env_config_core.postgres_url_opt () with
  | None -> ()
  | Some url ->
      let dir = test_dir () in
      Fun.protect
        ~finally:(fun () -> cleanup_dir dir)
        (fun () ->
          with_env "MASC_STORAGE_TYPE" "postgres" @@ fun () ->
          with_env "MASC_POSTGRES_URL" url @@ fun () ->
          with_env "DATABASE_URL" "" @@ fun () ->
          with_env "SUPABASE_DB_URL" "" @@ fun () ->
          with_env "SB_PG_URL" "" @@ fun () ->
          Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
          Eio.Switch.run @@ fun sw ->
          Eio_context.with_test_env
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~sw
            (fun () ->
              match
                try
                  Ok
                    (Room_utils.default_config_eio ~sw
                       ~env:(env :> Caqti_eio.stdenv) dir)
                with
                | Invalid_argument _ -> Error `Backend_unavailable
              with
              | Error `Backend_unavailable -> ()
              | Ok config ->
                  match config.Room_utils.backend with
                  | Room_utils.PostgresNative _ -> f ~env ~sw ~config
                  | Room_utils.Memory _ | Room_utils.FileSystem _ -> ()))

let test_run_dashboard_compute_without_pool_stays_in_current_domain () =
  with_test_env @@ fun ~env ~sw ~config ->
  let caller_domain = Domain.self () in
  let result_domain =
    Lib.Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~config
      (fun ~config:_ ~sw:_ -> Domain.self ())
  in
  check bool "no pool keeps compute on caller domain" true
    (result_domain = caller_domain)

let test_run_dashboard_compute_with_pool_uses_executor_domain () =
  (* All backends offload to the executor pool when available.
     FileSystem key_index is domain-safe via Stdlib.Mutex; Eio.Mutex
     is domain-safe via Stdlib.Mutex internally.  Offloading isolates
     dashboard compute from keeper turns on the main domain. *)
  with_test_env @@ fun ~env ~sw ~config ->
  let exec_pool =
    Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
  in
  Lib.Server_dashboard_http_core.set_executor_pool exec_pool;
  let caller_domain = Domain.self () in
  let result_domain =
    Lib.Server_dashboard_http_core.run_dashboard_compute
      ~sw
      ~clock:(Eio.Stdenv.clock env)
      ~config
      (fun ~config:_ ~sw:_ -> Domain.self ())
  in
  check bool "non-PG backend offloads to executor pool domain" true
    (result_domain <> caller_domain)

let test_run_dashboard_compute_without_pool_uses_isolated_pg_backend () =
  with_pg_test_env @@ fun ~env ~sw ~config ->
  match config.Room_utils.backend with
  | Room_utils.PostgresNative shared_backend ->
      let reused_shared_pool =
        Lib.Server_dashboard_http_core.run_dashboard_compute
          ~net:(Eio.Stdenv.net env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~sw
          ~clock:(Eio.Stdenv.clock env)
          ~config
          (fun ~config ~sw:_ ->
            match config.Room_utils.backend with
            | Room_utils.PostgresNative readonly_backend ->
                Backend.Postgres.get_pool shared_backend
                == Backend.Postgres.get_pool readonly_backend
            | Room_utils.Memory _ | Room_utils.FileSystem _ ->
                Alcotest.fail "expected postgres backend during readonly compute")
      in
      check bool "no pool uses isolated postgres backend" false
        reused_shared_pool
  | Room_utils.Memory _ | Room_utils.FileSystem _ -> ()

let test_dashboard_shell_http_json_includes_paths () =
  with_test_env @@ fun ~env:_ ~sw:_ ~config ->
  let json = Lib.Server_dashboard_http_core.dashboard_shell_http_json config in
  let open Yojson.Safe.Util in
  let fields =
    match json with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "dashboard shell payload must be an object"
  in
  let paths =
    match List.assoc_opt "paths" fields with
    | Some value -> value
    | None -> Alcotest.fail "paths key missing from dashboard shell payload"
  in
  let config_resolution =
    List.assoc_opt "config_resolution" fields
    |> Option.value ~default:`Null
  in
  let runtime_resolution =
    List.assoc_opt "runtime_resolution" fields
    |> Option.value ~default:`Null
  in
  let effective_base_path = paths |> member "effective_base_path" |> to_string in
  let effective_masc_root = paths |> member "effective_masc_root" |> to_string in
  let expected_masc_root = Unix.realpath (Filename.concat config.base_path ".masc") in
  check bool "paths present" true
    (match paths with `Assoc _ -> true | _ -> false);
  check bool "paths key present" true
    (List.mem_assoc "paths" fields);
  check bool "config_resolution key present" true
    (List.mem_assoc "config_resolution" fields);
  check bool "runtime_resolution key present" true
    (List.mem_assoc "runtime_resolution" fields);
  check string "effective_base_path matches config" (Unix.realpath config.base_path)
    effective_base_path;
  check string "effective_masc_root matches config" expected_masc_root
    effective_masc_root;
  check bool "paths include cwd" true
    (match paths |> member "cwd" with
     | `String value -> String.length value > 0
     | _ -> false);
  check bool "shell config resolution is object or null" true
    (match config_resolution with
     | `Assoc _ | `Null -> true
     | _ -> false);
  check bool "shell config root path surfaced when available" true
    (match config_resolution with
     | `Null -> true
     | _ -> (
         match config_resolution |> member "config_root" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false));
  check bool "shell runtime resolution is object or null" true
    (match runtime_resolution with
     | `Assoc _ | `Null -> true
     | _ -> false);
  check bool "shell runtime data root path surfaced when available" true
    (match runtime_resolution with
     | `Null -> true
     | _ -> (
         match runtime_resolution |> member "data_root" |> member "path" with
         | `String value -> String.length value > 0
         | _ -> false));
  check bool "shell runtime warnings surfaced as list when available" true
    (match runtime_resolution with
     | `Null -> true
     | _ -> (
         match runtime_resolution |> member "warnings" with
         | `List _ -> true
         | _ -> false))

let () =
  run "dashboard_http_core"
    [
      ( "executor_pool",
        [
          test_case "no pool stays on caller domain" `Quick
            test_run_dashboard_compute_without_pool_stays_in_current_domain;
          test_case "pg no pool uses isolated backend" `Quick
            test_run_dashboard_compute_without_pool_uses_isolated_pg_backend;
          test_case "pool uses executor domain" `Quick
            test_run_dashboard_compute_with_pool_uses_executor_domain;
          test_case "shell payload includes paths diagnostics" `Quick
            test_dashboard_shell_http_json_includes_paths;
        ] );
    ]
