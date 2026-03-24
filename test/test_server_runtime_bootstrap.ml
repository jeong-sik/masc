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

let with_pg_envs f =
  with_env "MASC_STORAGE_TYPE" (Some "postgres") @@ fun () ->
  with_env "MASC_POSTGRES_URL" (Some "postgresql://primary/db") @@ fun () ->
  with_env "DATABASE_URL" (Some "postgresql://fallback/db") @@ fun () ->
  with_env "SUPABASE_DB_URL" (Some "postgresql://supabase/db") @@ fun () ->
  with_env "SB_PG_URL" (Some "postgresql://sb/db") f

let test_force_jsonl_fallback_env () =
  with_pg_envs (fun () ->
      Server_runtime_bootstrap.force_jsonl_fallback_env ();
      Alcotest.(check string) "storage type forced to filesystem" "filesystem"
        (Sys.getenv "MASC_STORAGE_TYPE");
      List.iter
        (fun name ->
          Alcotest.(check string)
            (Printf.sprintf "%s cleared" name) "" (Sys.getenv name))
        [ "MASC_POSTGRES_URL"; "DATABASE_URL"; "SUPABASE_DB_URL"; "SB_PG_URL" ])

let () =
  Alcotest.run "Server_runtime_bootstrap"
    [
      ( "env",
        [
          Alcotest.test_case "force_jsonl_fallback_env clears pg envs" `Quick
            test_force_jsonl_fallback_env;
        ] );
    ]
