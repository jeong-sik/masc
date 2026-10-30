(** The memory recall gate as this server reads it now, for every Keeper whose
    declaration it has: [GET /api/v1/runtime/config/memory-recall].

    A settings form shows an operator what a choice would do, and until now
    could not show what the server does today: whether a key for the lane is
    set, whether the environment switch is on, which Keepers the judgment
    reaches. The answer for a Keeper is {!Keeper_memory_recall_standing.of_keeper},
    the function a turn asks first. It reads the gate as loaded: a runtime.toml
    edited on disk and not yet loaded does not show here.

    The reads are not one snapshot: the lane, then the environment switch and
    the gate once per Keeper. A policy published meanwhile can show in a
    response as a lane that says one thing next to Keepers that say another;
    the next request is right. *)

type keeper =
  { name : string
  ; standing : Keeper_memory_recall_standing.t
  }

type t =
  { lane : (unit, Keeper_memory_recall_standing.reason) result
        (** [Ok ()] when a key for at least one destination is set. Otherwise
            a reason for which {!Keeper_memory_recall_standing.is_lane_reason}
            holds. It does not depend on the recall switch, so it is told even
            when no Keeper is in scope. *)
  ; keepers : keeper list
        (** Sorted by name, each once. A file name that is not a Keeper name
            is left out. *)
  }

val read : keepers_dir:string -> (t, string) result
(** The Keepers are the [.toml] files of [keepers_dir], by file name. A
    declaration whose [keeper.name] differs from its file name is listed under
    the file name: telling it apart takes loading the file. [Error] when the
    directory cannot be read: the list of Keepers is then unknown, and an empty
    one would say that nobody is judged. *)

val to_yojson : generated_at:string -> t -> Yojson.Safe.t
(** [{ "generated_at", "lane", "keepers": [ { "name", "standing" } ] }].
    [lane] is {!Keeper_memory_recall_standing.lane_armed_word} or a
    {!Keeper_memory_recall_standing.reason_to_string} word; [standing] is
    {!Keeper_memory_recall_standing.judged_word} or such a word. One string
    each, so a Keeper cannot be both judged and given a reason. *)
