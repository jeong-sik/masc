(** Keeper_context_core_accessors — the half of [Keeper_context_core] this
    module defines.

    [Keeper_context_core] includes it and its own .mli is what callers see, so
    nothing here was ever exported on its own. Without this file every value
    below is exported by default, which switches off warning 32 for all of them
    -- an .mli is where a dead value in this module would show.

    Declarations are the ones [keeper_context_core.mli] already carries for
    these names. *)

type working_context = Keeper_types.working_context
type session_context = Keeper_types.session_context

(* The .ml includes this module, so its values reach callers through here.
   Mirroring the include keeps that surface unchanged; this file only closes
   the values [Keeper_context_core_accessors] defines itself. *)
include module type of Keeper_context_core_history

val message_count : working_context -> int

(** Re-export of [Agent_core.Types.text_of_message]. *)
val text_of_message : Agent_core.Types.message -> string

(** Construct a fresh working context with the given system prompt.

    [~eio:true] selects the AGENT_CORE context backend required when the context can
    be touched by Eio fibers. Use [~eio:false] only for synchronous tests or
    serialization fixtures. *)
val create : eio:bool -> system_prompt:string -> working_context

val set_system_prompt :
  working_context -> system_prompt:string -> working_context

val append : working_context -> Agent_core.Types.message -> working_context

val append_many : working_context -> Agent_core.Types.message list -> working_context

(** Push the exact working-context message count into the AGENT_CORE [Context.t]
    (Session scope). Provider token usage is response telemetry and is not a
    measure of the current checkpoint's context size. *)
val sync_agent_core_context : working_context -> working_context

val checkpoint_of_context : working_context -> Agent_core.Checkpoint.t

val agent_core_context_of_context : working_context -> Agent_core.Context.t

val system_prompt_of_context : working_context -> string

val messages_of_context : working_context -> Agent_core.Types.message list

val role_to_string : Agent_core.Types.role -> string

(** [Some] only for the four wire-format names; callers must
    handle [None] explicitly (#8623). *)
val role_of_string_opt : string -> Agent_core.Types.role option

val message_to_json : Agent_core.Types.message -> Yojson.Safe.t

val message_of_json : Yojson.Safe.t -> Agent_core.Types.message

(** Project a JSONL entry to its visible-text rendering used by
    history classification. *)
val text_of_history_jsonl_json : Yojson.Safe.t -> string

val create_session : session_id:string -> base_dir:string -> session_context

val log_keeper_exn : label:string -> exn -> unit

