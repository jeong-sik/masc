type repository_id = string
[@@deriving yojson, show, eq]

type repository_status =
  | Active
  | Paused
  | Cloning
  | Error of string
[@@deriving yojson, show, eq]

(* The word a client reads a repository's status by, and the reading back.
   The HTTP route spelled these four in a match of its own and the TUI
   matched the strings back, so the reason [Error] carries was written to the
   wire beside the word and read by nobody: a repository whose clone or fetch
   failed said "error" on the Workspace surface with the cause nowhere on it.
   One table here means a status added to this type cannot reach the wire
   unnamed, and the reading takes the reason with the word. *)
let status_wire_name = function
  | Active -> "active"
  | Paused -> "paused"
  | Cloning -> "cloning"
  | Error _ -> "error"
;;

let status_error_message = function
  | Error message -> Some message
  | Active | Paused | Cloning -> None
;;

(* [None] for a word this build does not know, and for "error" without the
   message the producer always sends with it: a status that names a failure
   and carries no cause is not a reading this can complete. *)
let status_of_wire_name ~error_message = function
  | "active" -> Some Active
  | "paused" -> Some Paused
  | "cloning" -> Some Cloning
  | "error" -> Option.map (fun message -> Error message) error_message
  | _ -> None
;;

type repository = {
  id : repository_id;
  name : string;
  url : string;
  local_path : string;
  aliases : string list [@default []];
  default_branch : string;
  keepers : string list;
  status : repository_status;
  auto_sync : bool;
  sync_interval : int;
  created_at : int64;
  updated_at : int64;
}
[@@deriving yojson, show, eq]

(* [Otoml.t] is a 3rd-party closed variant with 12 value constructors;
   the on-disk config loaders in this library only ever distinguish
   "table-shaped" (TomlTable / TomlInlineTable) from everything else.
   Enumerating the other 10 once here satisfies warning 4 and means an
   [otoml] version bump that adds a value constructor breaks exactly this
   site instead of several config loaders. *)