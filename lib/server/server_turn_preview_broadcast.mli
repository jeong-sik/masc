(** Tells turns readers which Keepers' shown preview was written.

    The turns answer shows each Keeper's running-turn preview: activity, the
    tail of the response text, the last tool and the preparation phase. A
    streaming provider writes it many times a second
    ({!Keeper_turn_preview_signal}).

    [install ~sw ~clock] installs the preview observer, which only records the
    workspace and Keeper and wakes a fiber forked on [sw]. On each wake the
    fiber sends the active Owner's redacted preview to the observers of that
    workspace's runtime, once for each Keeper recorded since the last send,
    then waits {!post_interval_s} before it sends again. A first write is sent
    at once. The writes during the wait are sent together when it ends. An
    observation carries an Owner correlation key and a preview revision.
    It does not carry the interrupt token or the waiting inventory. The Owner
    lifecycle has its own signal. A send that fails is counted and
    logged, so the fiber never fails its switch. *)

val post_interval_s : float
(** The shortest time between two sends of the fiber. *)

val install : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit
