(** Per-keeper stance on the tool-approval gate.

    {!Keeper_tool_approval_policy} decides call by call; this module says
    whether a keeper consults it at all. [Auto] is that policy unchanged.
    [Yolo] skips it — an operator's explicit, loud choice for a keeper they
    are watching.

    What it skips, and what it does not. This stance is read in exactly one
    place: the PreToolUse hook that asks over the open chat stream. An
    external effect that goes to {!Keeper_gate} -- a write to a service this
    Keeper is attached to, a sandbox command, a durable memory write -- is
    decided there, by the workspace Gate mode and this Keeper's own override,
    and reaches its decision whatever this says. So [Yolo] is "stop asking me
    in this chat", not "let everything through": before 2026-08-27 those
    happened to be the same sentence, because writing to somebody else's Jira
    did not reach the Gate at all.

    Durable, reversing an earlier safety stance: overrides persist under the
    workspace gate root and replay into the shared registry at boot, because
    the operator's other authorization choices (runtime.toml, keeper config)
    already survive restarts and this one's silent evaporation caused a real
    incident — after a restart one keeper's [Yolo] was gone and every tool
    call hit its 180s approval timeout until diagnosed. The trade-off is now
    the opposite of what it was: a stance this permissive outlives the
    process that was told to take it, so an operator who wants it gone must
    set [Auto] rather than wait for a restart. An unreadable store at boot
    falls back to the stricter [Auto] default; the error (including the store
    path) is visible through {!last_restore_error}. *)

type mode =
  | Auto  (** The approval policy decides, call by call. *)
  | Yolo
      (** Calls this hook would ask about run unasked. Effects the Gate
          decides are still decided there. *)

val mode_to_string : mode -> string
val mode_of_string : string -> mode option

type t

val create : unit -> t

val shared : unit -> t
(** The instance the running server uses — the gate that consults and the
    HTTP handler that sets have to reach the same stances. [create] stays
    for tests. *)

val resolve : t -> keeper_name:string -> mode
(** A keeper nobody has spoken about is [Auto]. *)

val overrides : t -> (string * mode) list
(** Every keeper currently moved off [Auto], in the order they were set. *)

type override_row =
  { keeper_name : string
  ; mode : mode
  ; actor : string
  ; changed_at : string
  }

val keeper_overrides : base_path:string -> (override_row list, string) result
(** The persisted overrides. A missing file is an empty list; a file that
    cannot be read or decoded is an error (naming the store path), because
    answering "nobody was singled out" would silently fall back to the
    stricter [Auto] default without distinguishing corruption from an empty
    store. *)

type set_outcome =
  | Applied
  | Applied_audit_failed of string
      (** The stance is persisted and live in memory, but writing the
          companion audit-log entry failed. *)

val set :
  t ->
  base_path:string ->
  actor:string ->
  keeper_name:string ->
  mode ->
  (set_outcome, string) result
(** Persists the change beside the other gate state, then updates the
    in-memory registry, so a failed [Yolo] write holds neither; the whole
    read-modify-write is atomic with respect to other in-process writers in
    the single running server process. Setting [Auto] removes the keeper's
    row rather than storing a synonym for the default, so the file lists
    exactly the keepers an operator has moved off [Auto]; if the store file
    cannot be read when revoking to [Auto], the keeper's in-memory override
    is still removed immediately (failing closed to the stricter [Auto]
    stance) while the store read error (noting that repairing the file
    without removing the keeper's row will restore it on restart) is returned
    and recorded in {!last_restore_error}. The change is also written to the
    audit log as actor [actor]; if that record fails ([Sys_error] from the
    audit store setup is caught the same way), [Ok (Applied_audit_failed _)]
    is returned so the caller sees that the stance itself already stands
    durably and in memory — the result is total, it never raises.
*)

val bind : base_path:string -> t -> (unit, string) result
(** Replay the persisted overrides into the registry; the server calls this
    once, synchronously, at boot. A missing file leaves an empty registry;
    an unreadable one keeps whatever the registry held and reports the
    store path and reason via {!last_restore_error}. *)

val last_restore_error : t -> string option
(** The store error the most recent failed {!set} or {!bind} hit, if any.
    Kept (not just logged) so a screen can show that the durable answer is
    unavailable instead of appearing to confirm "no overrides". *)
