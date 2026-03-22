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
      let config = Lib.Room_utils.default_config dir in
      Eio.Switch.run @@ fun sw ->
      f ~env ~sw ~config)

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
  check bool "executor pool runs compute off the caller domain" true
    (result_domain <> caller_domain)

let () =
  run "dashboard_http_core"
    [
      ( "executor_pool",
        [
          test_case "no pool stays on caller domain" `Quick
            test_run_dashboard_compute_without_pool_stays_in_current_domain;
          test_case "pool uses executor domain" `Quick
            test_run_dashboard_compute_with_pool_uses_executor_domain;
        ] );
    ]
