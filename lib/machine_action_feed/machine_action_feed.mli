(** A short, in-memory record of what a Keeper did to a shared machine lane
    (DOS, MSX, ...), for a spectator to read.

    This is not the checkpoint-replay ledger each lane already keeps
    ([Dos_lane.entry], [Msx_lane.entry]): that ledger is the authority for
    "what keys reached the guest, in order", is bounded by the machine's own
    step count, and a checkpoint's saved copy of it is replayed to rebuild
    continuity on restore. This is a separate, human-facing feed of "what a
    Keeper did" -- one short line per tool call, spanning load, save, restore,
    pass and eject too, none of which touch the replay ledger. It is never
    persisted and never read back for anything but display. *)

type entry = {
  at : float;  (** [Unix.gettimeofday ()]: wall clock for a human, not a step or frame ordinal *)
  who : string;
  action : string;
      (** A few words: ["step 1,000"], ["press a,b"], ["save quick"],
          ["pass -> cao-cao"]. Never truncated here -- a renderer with a
          column width does that. *)
}

val cap : int
(** How many recent entries a lane keeps. Older entries fall off silently:
    this is a spectator convenience, not a record anything depends on being
    complete. *)

val push : entry -> entry list -> entry list
(** [push e existing] is [e] consed onto [existing] and trimmed to {!cap}.
    [existing] and the result are both newest-first. *)

val to_json : entry -> Yojson.Safe.t
val to_json_list : entry list -> Yojson.Safe.t
(** [{"at": <float>, "who": <string>, "action": <string>}], newest first —
    the same order {!push} keeps, so a caller never re-sorts. *)
