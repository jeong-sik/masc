(** Keeper_voice_local — local-filesystem-backed singleton
    {!Voice_session_manager} for keeper voice sessions.

    Eliminates the external Voice MCP dependency for session
    tracking; TTS (agent_speak) still goes through direct HTTP
    endpoints (ElevenLabs, etc).

    Internal helpers stay private —
    \[resolved_base_path_opt\] / \[masc_base_dir\] (base-path
    resolution chain), plus the atomic lifecycle and cooperative
    initialisation lock. All are consumed only inside
    {!get_session_manager}.

    @since 2.95.0 *)

val get_session_manager : unit -> Voice_session_manager.t
(** [get_session_manager ()] returns the process-wide singleton
    {!Voice_session_manager.t}, lazily initialised on first call:

    + Resolve [config_path] from [Env_config_core.base_path_opt]
      with fallback chain (git root via
      [Workspace_utils_backend_setup.find_git_root], then
      [Common.masc_dirname]).
    + [Voice_session_manager.create ~config_path].
    + [Voice_session_manager.restore mgr] (rehydrates persisted
      sessions from disk).

    The completed manager is published once as an immutable atomic lifecycle
    state. The effectful create/restore slow path is serialized across Eio
    fibers, threads, and Domains by a cooperative cross-context lock. *)
