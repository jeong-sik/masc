(** The server-owned Librarian loop, one per keeper (RFC librarian-lifecycle
    §4.3).

    The loop's life is the server switch, not the keeper's: it starts with the
    server, runs once at once, and from then on runs when woken -- by a turn
    that recorded its end line, by a change in the keeper's pending inputs --
    and parks when there is nothing to do. A keeper that is stopped still has
    a loop, so a backlog left by a keeper that went down is read without
    waiting for it to come back; a keeper that restarts does not wait for its
    Librarian, and nothing joins a loop but a purge.

    A pass reads the keeper's turn-boundary log, read positions and
    checkpoint from disk ({!Keeper_librarian_durable_consumer}) and drains
    every unread turn while each pass advances; a pass that stops -- nothing
    left, a Memory commit that did not land, a typed error -- ends the run and
    the loop waits for the next wake. It does not retry on a timer (I5). A
    wake that arrives during a run is kept, so the run is followed by another
    (§4.3). Then, when the keeper's pending inputs changed since they were
    last organised, one round with no messages organises them (§4.4 row 9).

    Loops are keyed by the keeper's runtime directory, so two clusters with a
    keeper of the same name have two loops. *)

(** How the last pass of a loop ended, for the operator surfaces. *)
type pass_end =
  | Off  (** The Librarian setting is [Disabled] or [Invalid]. *)
  | Lane_unconfigured
      (** The [librarian_exact] lane is not in the exact-output registry; the
          wake was dropped and the next one is tried again. *)
  | Drained  (** Nothing left unread when the pass ended. *)
  | Not_committed  (** The Memory commit of the last range did not land. *)
  | Stopped of Keeper_librarian_durable_consumer.error
  | Raised of string  (** The pass raised; the text is the exception. *)

type measurement =
  { measured_at : float
  ; last_pass : pass_end
  }

(** Record the server switch and become the target of
    {!Keeper_librarian_queue_signal.changed}. Call once, on the server's
    root domain, before any loop is started. *)
val init : sw:Eio.Switch.t -> unit

(** Start a loop for every keeper whose metadata is on disk, stopped keepers
    included, each pending its first pass. Loops that already exist are left
    alone. *)
val boot : config:Workspace.config -> unit

(** Start the loop of [keeper_name] if it has none; the loop starts pending.
    Called where a keeper is created. *)
val ensure : config:Workspace.config -> keeper_name:string -> unit

(** Mark the loop pending and unpark it. A keeper with no loop gets one. A
    wake for a loop being retired is dropped. Safe from any domain. *)
val wake : base_path:string -> keeper_name:string -> unit

(** Cancel the loop of [keeper_name], wait until it has exited, and hold a
    tombstone so that no wake starts another while the caller removes the
    keeper's files in the callback. The tombstone is dropped when the callback
    returns or raises, so a caller cannot forget the release. A keeper with no
    loop retires at once. *)
val retire : config:Workspace.config -> keeper_name:string -> (unit -> 'a) -> 'a

val last_measurement : config:Workspace.config -> keeper_name:string -> measurement option

module For_testing : sig
  (** A loop whose pass is [pass] instead of the durable consumer, on
      [sw], keyed by [key]. *)
  val start_with
    :  sw:Eio.Switch.t
    -> key:string
    -> pass:(unit -> pass_end)
    -> unit

  val wake_key : string -> unit
  val retire_key : string -> (unit -> 'a) -> 'a
  val measurement_key : string -> measurement option
  val is_parked : string -> bool
  val reset : unit -> unit
end
