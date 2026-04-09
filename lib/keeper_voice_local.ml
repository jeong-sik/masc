(** Keeper_voice_local — Local voice session management for keepers.

    Provides a singleton Voice_session_manager backed by the local filesystem,
    eliminating the need for an external Voice MCP server for session tracking.
    TTS (agent_speak) still uses direct HTTP endpoints (ElevenLabs, etc).

    @since 2.95.0 *)

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let resolved_base_path_opt () =
  match Env_config_core.base_path_opt () with
  | Some path -> Some path
  | None -> Room_utils_backend_setup.find_git_root (Sys.getcwd ())

let masc_base_dir () =
  match resolved_base_path_opt () with
  | Some base_path -> Filename.concat base_path ".masc"
  | None -> ".masc"

(** Singleton session manager, lazily initialized.
    Thread-safety: safe under single Eio domain — all fibers share one
    OS thread, so [ref] read/write cannot race. No Eio.Mutex needed.
    Voice_session_manager.restore is called once on first access;
    subsequent calls to [get_session_manager] return the cached value.
    Zombie session cleanup happens inside Voice_session_manager at
    session-start time (expired sessions are reaped lazily). *)
let session_manager_ref : Voice_session_manager.t option ref = ref None

let get_session_manager () =
  match !session_manager_ref with
  | Some mgr -> mgr
  | None ->
    let mgr = Voice_session_manager.create ~config_path:(masc_base_dir ()) in
    Voice_session_manager.restore mgr;
    session_manager_ref := Some mgr;
    mgr
