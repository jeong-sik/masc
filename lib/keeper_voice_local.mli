(** Keeper_voice_local — local-filesystem-backed singleton
    {!Voice_session_manager} for keeper voice sessions.

    Eliminates the external Voice MCP dependency for session
    tracking; TTS (agent_speak) still goes through direct HTTP
    endpoints (ElevenLabs, etc).

    Internal: 4 helpers stay private —
    \[trim_opt\] (string trim + empty-to-None coercion),
    \[resolved_base_path_opt\] / \[masc_base_dir\] (base-path
    resolution chain), and the \[session_manager_ref] lazy
    singleton cell.  All consumed only inside
    {!get_session_manager}.

    @since 2.95.0 *)

val get_session_manager : unit -> Voice_session_manager.t
(** [get_session_manager ()] returns the process-wide singleton
    {!Voice_session_manager.t}, lazily initialised on first call:

    + Resolve [config_path] from [Env_config_core.base_path_opt]
      with fallback chain (git root via
      [Coord_utils_backend_setup.find_git_root], then
      [Common.masc_dirname]).
    + [Voice_session_manager.create ~config_path].
    + [Voice_session_manager.restore mgr] (rehydrates persisted
      sessions from disk).

    Thread-safety: safe under a single Eio domain — all fibers
    share one OS thread, so the underlying [ref] read/write
    cannot race.  No [Eio.Mutex] needed.  Zombie session cleanup
    happens lazily inside {!Voice_session_manager} at
    session-start time, so callers do not need to schedule a
    reaper. *)
