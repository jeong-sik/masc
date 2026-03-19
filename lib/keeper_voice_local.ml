(** Keeper_voice_local — Local voice session management for keepers.

    Provides a singleton Voice_session_manager backed by the local filesystem,
    eliminating the need for an external Voice MCP server for session tracking.
    TTS (agent_speak) still uses direct HTTP endpoints (ElevenLabs, etc).

    @since 2.95.0 *)

let masc_base_dir () =
  match Sys.getenv_opt "ME_ROOT" with
  | Some root when String.trim root <> "" -> Filename.concat root ".masc"
  | _ -> ".masc"

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
