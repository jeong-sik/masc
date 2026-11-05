(** The vocabulary the History page modules share: the two dated stores a
    Task's history is read from, what a continuation cursor and an error
    carry, and the dated file names that order both stores.
    [Task_history_page] includes this module. *)

type source = Activity | Audit

type availability = Observed | Not_created

val sources : source list

val source_name : source -> string

type position = { file : string; device : int; inode : int; before : int; anchor : string }

type ceiling = { file : string; size : int }

type cursor = { task : string; workspace : string; ceilings : ceiling list; inventory : string; position : position }

type error = Invalid_request | Invalid_cursor | Source_changed
  | Invalid_event of { file : string; offset : int }
  | Invalid_layout of { entry : string } | Source_unavailable

type page = { task_id : string; cursor : cursor option; sources : (source * availability) list;
  events : Yojson.Safe.t list; next_cursor : cursor option }

val hash : string -> string

val dated_parts : string -> (source * string * string) option

val compare_relative : string -> string -> int
