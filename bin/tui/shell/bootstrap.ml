type cli_args = {
  base_path : string;
  workspace : string;
  port : int;
  reasoning_visibility : Masc_tui_types.reasoning_visibility;
  tool_visibility : Masc_tui_types.tool_visibility;
}

(* Point fd 2 at a file under the base path, so writing to stderr cannot land
   in the frame. Best effort by construction: a surface that cannot open its
   log is still a working surface, and refusing to start over it would trade a
   cosmetic fault for an outage. The failure is reported on the terminal that
   is about to be cleared, which is the last moment a person can see it. *)
let redirect_stderr_off_terminal ~base_path =
  match
    let dir =
      Filename.concat (Common.masc_dir_from_base_path ~base_path) "logs"
    in
    let path =
      Filename.concat dir (Printf.sprintf "masc-tui-%d.log" (Unix.getpid ()))
    in
    (* [O_CREAT] makes the file, not the directory above it. A base path that
       has never had a log written under it -- a fresh workspace, a test's
       temporary root -- therefore failed here on ENOENT, and the surface
       started with its stderr still on the terminal. That is the exact state
       this function exists to avoid, reached by the one cause it could have
       removed itself. *)
    Fs_compat.mkdir_p dir;
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644
    in
    (* No [Fun.protect] around the close: its [Finally_raised] is neither
       [Unix_error] nor [Sys_error], so a raising finaliser would leave this
       match and take the surface down over a descriptor. If [dup2] raises,
       one fd leaks in a process that is one line from reporting it. *)
    Unix.dup2 fd Unix.stderr;
    Unix.close fd;
    path
  with
  | path ->
      Log.Startup.info "stderr redirected to %s" path
  | exception (Unix.Unix_error _ | Sys_error _) ->
      (* Say so before the screen is taken: a surface drawing over a mirror it
         could not move is the state this whole path exists to avoid. *)
      prerr_endline
        "[masc-tui] could not redirect stderr off this terminal; log lines may \
         land in the drawn screen"

let require_interactive_terminal () =
  let term =
    Sys.getenv_opt "TERM"
    |> Option.value ~default:""
    |> String.lowercase_ascii
    |> String.trim
  in
  if
    (not (Unix.isatty Unix.stdin))
    || not (Unix.isatty Unix.stdout)
    || String.equal term "dumb"
  then begin
    prerr_endline
      "masc-tui requires interactive TTY stdin/stdout and TERM other than dumb";
    exit 2
  end

let parse_args () =
  let port = ref None in
  (* Named so the R13 footer-fact scan does not read the setter's [ := ] as a
     quoted [Port:] label split across the flag tuple's strings. *)
  let set_selected_port value = port := Some value in
  let workspace = ref "" in
  let base_path = ref "" in
  let reasoning_visibility = ref "folded" in
  let tool_visibility = ref "compact" in

  let specs = [
    ("--version", Arg.Unit (fun () -> print_endline Build_version.current; exit 0),
      "Print this executable's build version and exit");
    ("--build-commit", Arg.Unit (fun () ->
        match Build_commit_generated.commit with
        | Some commit -> print_endline commit; exit 0
        | None -> prerr_endline "build commit is not embedded"; exit 1),
      "Print the Git commit embedded at build time and exit");
    ( "--port", Arg.Int set_selected_port
    , "MASC server port (environment or saved workspace value when omitted)" );
    ("--workspace", Arg.Set_string workspace, "Workspace name (default: from base path)");
    ( "--base-path",
      Arg.Set_string base_path,
      "Workspace/base path; .masc lives below it (default: MASC_BASE_PATH, then a cwd holding .masc/config, then the recorded default)" );
    ( "--base",
      Arg.Set_string base_path,
      "Alias for --base-path" );
    ( "--reasoning",
      Arg.Symbol ([ "hidden"; "folded"; "full" ], fun value -> reasoning_visibility := value),
      "Keeper chat reasoning default: hidden, folded, or full" );
    ( "--tool-view",
      Arg.Symbol ([ "compact"; "results"; "full" ], fun value -> tool_visibility := value),
      "Keeper chat tool-call default: compact, results, or full" );
  ] in

  Arg.parse specs (fun _ -> ()) "masc-tui [OPTIONS]";

  (* The same order `masc start` boots in, so
     the screen and the server it starts or joins read one workspace. A cwd is
     used only when it holds .masc/config; with none the TUI names the choices
     instead of observing an empty directory. *)
  let base_path =
    let flag = if String.trim !base_path = "" then None else Some !base_path in
    match Workspace_root.resolve_current ~flag with
    | Ok resolved -> resolved.Workspace_root.root
    | Error error -> prerr_endline (Workspace_root.error_message error); exit 1
  in

  let port =
    match
      Workspace_connection.resolve ~base_path:(Some base_path) ~cli:!port
        ~environment:(Env_config_core.raw_value_opt Env_config_core.http_port_env_key)
    with
    | Ok value -> Workspace_connection.to_int value
    | Error error -> prerr_endline (Workspace_connection.error_message error); exit 1
  in

  let workspace = if !workspace <> "" then !workspace else Filename.basename base_path in

  let reasoning_visibility =
    match !reasoning_visibility with
    | "hidden" -> Masc_tui_types.Reasoning_hidden
    | "folded" -> Masc_tui_types.Reasoning_folded
    | "full" -> Masc_tui_types.Reasoning_full
    | _ -> Masc_tui_types.Reasoning_hidden
  in
  let tool_visibility =
    match !tool_visibility with
    | "compact" -> Masc_tui_types.Tools_compact
    | "results" -> Masc_tui_types.Tools_results
    | "full" -> Masc_tui_types.Tools_full
    | _ -> Masc_tui_types.Tools_compact
  in
  { base_path; workspace; port; reasoning_visibility; tool_visibility }

let run_with_eio_context f =
  Masc_tui_domains.use_ui_heap ();
  try
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            Eio_guard.enable ();
            Eio.Switch.on_release sw Eio_guard.disable;
            (* The workspace server owns its lifetime independently of this UI. *)
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            (* Without this, Process_eio falls back to a Unix path that waits on
               Unix.select. Eio is cooperative, so that blocks the whole domain
               rather than one fiber: a microphone capture forked to keep the
               UI responsive froze every key instead, for as long as the
               recorder ran. The server and fusion_run already init here; the
               TUI did not, and nothing it spawned had been long enough to
               notice until a capture ran for 15 s. *)
            Process_eio.init
              ~cwd_default:(Eio.Stdenv.cwd env)
              ~proc_mgr:(Eio.Stdenv.process_mgr env)
              ~clock:(Eio.Stdenv.clock env);
            Domain_pool_ref.set
              (Masc_tui_domains.start_worker_pool ~sw (Eio.Stdenv.domain_mgr env));
            Eio_context.set_env env;
            Eio_context.set_switch sw;
            Eio_context.set_net (Eio.Stdenv.net env);
            Eio_context.set_clock (Eio.Stdenv.clock env);
            Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
            Masc_tui_http.start_io_domain ~sw ~env;
            f ()))
  with
  | Exit_journal.Break -> ()
  | exn ->
      (* An uncaught exception is the abnormal end the exit line exists to
         name; the [at_exit] writer still runs while the exception unwinds. *)
      Exit_journal.note (Masc_tui_exit_reason.Exception (Printexc.to_string exn));
      raise exn
