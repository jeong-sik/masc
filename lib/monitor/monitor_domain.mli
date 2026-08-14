(** Pure domain for keeper monitors (RFC-0379).

    A monitor watches one runtime condition and fires a wake when the
    condition's observed state *transitions*. The first observation only
    establishes the baseline and never fires, so a server boot cannot storm
    every registered monitor at once. Decision logic here is pure; observing
    and waking live in [Monitor_runner]. *)

type trigger =
  | Port_up of
      { host : string
      ; port : int
      }
  | Port_down of
      { host : string
      ; port : int
      }
  | File_changed of { path : string }

(** One observation of a trigger's target. Ports and HTTP collapse to
    reachability; files carry the identity pair that detects rewrites even
    when the mtime resolution would hide them. *)
type observation =
  | Reachable
  | Unreachable
  | File_snapshot of
      { mtime : float
      ; inode : int
      }
  | File_absent

type t =
  { id : string
  ; keeper : string
  ; trigger : trigger
  ; payload : Yojson.Safe.t
  ; expires_at : float
  ; max_fires : int
  ; fired_count : int
  ; created_at : float
  ; last_observation : observation option
      (** [None] until the runner's first observation, and again after every
          server restart: persisted records reload without their baseline, so
          transitions that happened while the server was down are never fired
          retroactively (RFC-0379 §2.5). *)
  }

type fire_decision =
  | Fire of
      { from_ : observation
      ; to_ : observation
      }
  | Hold

val decide : trigger -> prev:observation option -> current:observation -> fire_decision
(** Exhaustive transition matrix. [prev = None] is always [Hold] (baseline).
    [Port_up] fires only on [Unreachable] -> [Reachable]; [Port_down] on
    [Reachable] -> [Unreachable]; [File_changed] on any change of the snapshot pair, including
    absent -> present and present -> absent. Observations that cannot belong
    to the trigger (a file snapshot for a port trigger) are [Hold]: the
    runner produced an incoherent pair and must not wake anyone on it. *)

val expired : t -> now:float -> bool
val exhausted : t -> bool
(** [exhausted] is true once [fired_count >= max_fires]; the store deletes
    the record at that point, so persisted exhausted rows are a defect. *)

val validate_create :
  keeper:string ->
  trigger:trigger ->
  expires_at:float ->
  max_fires:int ->
  now:float ->
  (unit, string) result
(** Fail-closed creation checks: non-blank keeper, host/path/url non-blank,
    port within 1-65535, [expires_at] strictly in the future, [max_fires]
    at least 1. *)

val max_active_monitors_per_keeper : int

val trigger_to_yojson : trigger -> Yojson.Safe.t
val trigger_of_yojson : Yojson.Safe.t -> (trigger, string) result
val observation_label : observation -> string
(** Stable short label per observation kind, identical to the codec's
    ["kind"] value: reachable / unreachable / file_snapshot / file_absent. *)

val observation_to_yojson : observation -> Yojson.Safe.t
val observation_of_yojson : Yojson.Safe.t -> (observation, string) result

val to_yojson : t -> Yojson.Safe.t
(** [last_observation] is intentionally not serialized (see the field doc). *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Closed decode: unknown fields, missing fields, and unknown kinds are
    errors, never defaults. Decoded records always carry
    [last_observation = None]. *)
