(** Persistence loaders. Posts and comments serve quiescent startup; votes
    and reactions also serve explicit reload under their persistence/state
    interval. All four refuse model replacement while deletion work is
    pending. Counts include accepted duplicate physical rows. *)
val load_persisted_posts : Board_types.store -> (int, string * exn) result
val load_persisted_comments : Board_types.store -> (int, string * exn) result
val load_persisted_votes : Board_types.store -> (int, string * exn) result
(** Owns persistence and publishes the vote model under the state lock.
    A complete source replaces the ledger and recalculates counts; valid
    orphan votes remain stored. Partial rows are display-only. Neither load
    nor a normal write settles unknown effects or unfinished publication. *)
val load_persisted_reactions : Board_types.store -> (int, string * exn) result

(** Rebuild current reply counts and timestamp high-water marks after loading
    comments, before votes. Quiescent startup only; emits the existing log. *)
val recalculate_reply_counts : Board_types.store -> unit
