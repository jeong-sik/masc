(** What a Keeper's Memory commit log ([<keeper>.memory-log.jsonl]) says for
    the memory health row: the newest Librarian commit time and the facts the
    Keeper held after each hour's last commit. *)

type facts_at_hour =
  { recorded_at : float  (** [at] of the hour's last committed line *)
  ; facts : int  (** facts held after that commit *)
  }

val trend_hours : int
(** 168, a week of clock hours. *)

type t =
  { last_success_at : float option
  ; facts_by_hour : facts_at_hour list
      (** Oldest first, one point per clock hour with a committed line from
          any cause, over the {!trend_hours} hours that end with the newest
          such hour. *)
  ; read_error : string option
      (** A failed inspection or read of the commit log. *)
  }

val read : keepers_dir:string -> keeper_id:string -> t
(** Read the Keeper's commit log and project its hourly fact trend. A missing
    commit log returns no commits and no read error. *)

val within : now:float -> facts_at_hour list -> facts_at_hour list
(** The points in the {!trend_hours} clock hours that end with [now]'s hour.
    A point after [now]'s hour is left out too. *)

val facts_by_hour_to_json : facts_at_hour list -> Yojson.Safe.t
(** An array of [{"recorded_at", "facts"}] objects in the order given. *)

val facts_by_hour_of_json : Yojson.Safe.t -> (facts_at_hour list, string) result
(** Takes an array of at most {!trend_hours} objects with exactly those two
    members: a finite [recorded_at] and a non-negative int [facts]. Each point
    must be in a later clock hour than the one before it. *)
