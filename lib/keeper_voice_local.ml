(** Keeper_voice_local — Local voice session management for keepers.

    Provides a singleton Voice_session_manager backed by the local filesystem,
    eliminating the need for an external Voice MCP server for session tracking.
    TTS (agent_speak) still uses direct HTTP endpoints (ElevenLabs, etc).

    @since 2.95.0 *)

let resolved_base_path_opt () =
  match (Host_config.from_env ()).base_path with
  | Some path -> Some path
  | None -> Workspace_utils_backend_setup.find_git_root (Sys.getcwd ())

let masc_base_dir () =
  match resolved_base_path_opt () with
  | Some base_path -> Workspace_utils.masc_dir_from_base_path ~base_path
  | None -> Common.masc_dirname

(** Singleton session manager, lazily initialized. Creation and restore may
    perform filesystem effects, so one cooperative cross-context lock owns the
    slow path. Readers use the immutable atomic lifecycle snapshot. *)
type lifecycle =
  | Uninitialized
  | Ready of Voice_session_manager.t

let lifecycle = Atomic.make Uninitialized
let initialization_lock = Cross_context_mutex.create ()

let get_session_manager () =
  match Atomic.get lifecycle with
  | Ready mgr -> mgr
  | Uninitialized ->
    Cross_context_mutex.with_lock initialization_lock (fun () ->
      match Atomic.get lifecycle with
      | Ready mgr -> mgr
      | Uninitialized ->
        let mgr = Voice_session_manager.create ~config_path:(masc_base_dir ()) in
        Voice_session_manager.restore mgr;
        Atomic.set lifecycle (Ready mgr);
        mgr)
