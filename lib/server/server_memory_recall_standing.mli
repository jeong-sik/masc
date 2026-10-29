(** The memory recall gate as this server reads it now, for every Keeper whose
    declaration it has: [GET /api/v1/runtime/config/memory-recall].

    A settings form shows an operator what a choice would do, and until now
    could not show what the server does today: whether a key for the lane is
    set, whether the environment switch is on, which Keepers the judgment
    reaches. The answer is {!Keeper_memory_recall_standing.of_keeper}, the one
    a turn gets, so the form and the turn cannot disagree. It reads the gate
    as loaded: a runtime.toml edited on disk and not yet loaded does not show
    here. *)

type keeper =
  { name : string
  ; standing : Keeper_memory_recall_standing.t
  }

type t =
  { lane : (unit, Keeper_memory_recall_standing.reason) result
        (** [Ok ()] when a key for at least one destination is set. The lane
            says [Lane_disabled] or [No_armed_destination] otherwise. It does
            not depend on the recall switch, so it is told even when no Keeper
            is in scope. *)
  ; keepers : keeper list  (** Sorted by name, each once. *)
  }

val read : keepers_dir:string -> (t, string) result
(** [Error] when the directory of Keeper declarations cannot be read: the
    list of Keepers is then unknown, and an empty one would say that nobody is
    judged. *)

val to_yojson : generated_at:string -> t -> Yojson.Safe.t
(** [{ "generated_at", "lane", "keepers": [ { "name", "standing" } ] }].
    [lane] is {!Keeper_memory_recall_standing.lane_armed_word} or a
    {!Keeper_memory_recall_standing.reason_to_string} word; [standing] is
    {!Keeper_memory_recall_standing.judged_word} or such a word. One string
    each, so a Keeper cannot be both judged and given a reason. *)
