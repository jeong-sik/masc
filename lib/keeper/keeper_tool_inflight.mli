(** Keeper_tool_inflight — live registry of in-flight keeper tool calls.

    Thread-safe via {!Eio.Mutex} guarded by {!Eio_guard} (falls through without
    locking when the Eio runtime is not yet active, e.g. in non-Eio tests).

    Authoritative for "what is running now": an entry exists exactly between
    tool-dispatch entry and exit, under all outcomes (success, error, cancel).
    The caller wraps execution in [Fun.protect] so [unregister] runs in the
    [finally] regardless of outcome. Ephemeral (per-process); not ledgered —
    the durable [tool_event] ledger is a separate, Phase B concern.

    RFC-0336 Phase A. *)

type entry = {
  keeper_name : string;
  tool_name : string;
  job_id : string;
  started_at : float;
  deadline_at : float option;
  (** [Some (started_at +. deadline_ms /. 1000.0)] only when a deadline was
      supplied; [None] otherwise. The dashboard renders [None] as "—" — no
      ETA is fabricated. *)
}

val register :
  keeper_name:string ->
  tool_name:string ->
  ?deadline_ms:int ->
  job_id:string ->
  unit ->
  entry
(** Insert an in-flight entry keyed by [job_id]. Idempotent: re-registering the
    same [job_id] replaces the entry. *)

val unregister : job_id:string -> unit
(** Remove the in-flight entry. No-op if [job_id] is absent (already removed,
    or never registered). *)

val list : keeper_name:string -> entry list
(** In-flight entries for [keeper_name], sorted by [started_at] ascending. *)

val list_all : unit -> entry list
(** All in-flight entries, sorted by [started_at] ascending. *)

val clear : unit -> unit
(** Test-only: drop all entries. *)
