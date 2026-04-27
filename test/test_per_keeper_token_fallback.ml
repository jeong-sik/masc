(** test_per_keeper_token_fallback — Phase A F1 wiring guard.

    Verifies that [Auth.load_raw_token] reads the raw bearer token from
    [<base_path>/.masc/auth/<agent_name>.token]. This is the data path
    consumed by [Oas_worker_exec_transport.runtime_mcp_policy_of_tool_names]
    when [MASC_MCP_TOKEN] is unset (the CLI subprocess case for
    codex_cli/gemini_cli/kimi_cli that callback into masc-mcp).

    Pre-fix production reality (24h, 2026-04-26): 936 silent_auth events
    /day; subprocess MCP calls degraded with empty Authorization header.
    Post-fix: per-keeper token file fallback fires, [auth_resolve_outcome]
    trace records [source=per_keeper_token_file]. *)

open Alcotest
open Masc_mcp

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
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let raw_token_path base_path agent_name =
  Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")

let seed_raw_token base_path agent_name raw =
  let dir = Auth.auth_dir base_path in
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
    Unix.mkdir dir 0o755
  end;
  Auth.save_private_text_file (raw_token_path base_path agent_name) raw

let test_load_raw_token_reads_seeded_file () =
  with_temp_dir "f1-load-raw" @@ fun base_path ->
  seed_raw_token base_path "keeper-analyst-agent" "secret-bearer-abc123";
  match Auth.load_raw_token base_path ~agent_name:"keeper-analyst-agent" with
  | Some raw ->
      check string "raw token round-trips through file"
        "secret-bearer-abc123" raw
  | None ->
      fail "load_raw_token returned None despite seeded .token file"

let test_load_raw_token_missing_returns_none () =
  with_temp_dir "f1-missing" @@ fun base_path ->
  match Auth.load_raw_token base_path ~agent_name:"never-seeded" with
  | None -> ()
  | Some _ -> fail "load_raw_token returned Some for missing file"

let test_load_raw_token_blank_returns_none () =
  with_temp_dir "f1-blank" @@ fun base_path ->
  seed_raw_token base_path "blank-agent" "   \n  ";
  match Auth.load_raw_token base_path ~agent_name:"blank-agent" with
  | None -> ()
  | Some raw ->
      failf "load_raw_token returned Some(%S) for whitespace-only file" raw

let test_per_keeper_token_label_is_observable () =
  (* Operator-facing trace contract: the label must be exactly the string
     [auth_resolve_outcome] dashboards and ratchets pin against. *)
  check string "Per_keeper_token_file label"
    "per_keeper_token_file"
    (Auth_resolve.token_source_label Per_keeper_token_file)

let () =
  Alcotest.run "per_keeper_token_fallback"
    [
      ( "load_raw_token",
        [
          test_case "reads seeded .token file" `Quick
            test_load_raw_token_reads_seeded_file;
          test_case "missing file -> None" `Quick
            test_load_raw_token_missing_returns_none;
          test_case "whitespace-only file -> None" `Quick
            test_load_raw_token_blank_returns_none;
        ] );
      ( "trace_label",
        [
          test_case "Per_keeper_token_file label stable" `Quick
            test_per_keeper_token_label_is_observable;
        ] );
    ]
