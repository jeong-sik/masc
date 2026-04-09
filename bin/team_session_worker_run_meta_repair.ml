open Cmdliner

module Lib = Masc_mcp

let run base_path session_id worker_run_id apply =
  let config = Lib.Room.default_config base_path in
  match
    Lib.Team_session_worker_run_meta.repair_session ~config ~session_id
      ?worker_run_id ~dry_run:(not apply) ()
  with
  | Ok summary ->
      summary
      |> Lib.Team_session_worker_run_meta.repair_summary_to_yojson
      |> Yojson.Safe.pretty_to_string
      |> print_endline
  | Error msg ->
      prerr_endline msg;
      exit 1

let base_path_arg =
  let doc =
    "Workspace path that owns the .masc state. Defaults to the current working \
     directory."
  in
  Arg.(value & opt string (Sys.getcwd ()) & info [ "base-path" ] ~docv:"DIR" ~doc)

let session_id_arg =
  let doc = "Team session id to repair." in
  Arg.(required & opt (some string) None & info [ "session-id" ] ~docv:"SESSION" ~doc)

let worker_run_id_arg =
  let doc = "Optional single worker_run_id to repair instead of the full session." in
  Arg.(value & opt (some string) None & info [ "worker-run-id" ] ~docv:"WORKER_RUN" ~doc)

let apply_arg =
  let doc = "Write repaired meta back to disk. Without this flag the command is dry-run only." in
  Arg.(value & flag & info [ "apply" ] ~doc)

let cmd =
  let doc =
    "Repair historical worker_run meta for a team session using persisted OAS \
     evidence and proof artifacts."
  in
  let info = Cmd.info "masc-team-session-worker-run-meta-repair" ~doc in
  Cmd.v info
    Term.(const run $ base_path_arg $ session_id_arg $ worker_run_id_arg $ apply_arg)

let () = exit (Cmd.eval cmd)
