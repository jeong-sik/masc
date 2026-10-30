type repository_id = string
[@@deriving yojson, show, eq]

type repository_status =
  | Active
  | Paused
  | Cloning
  | Error of string
[@@deriving yojson, show, eq]

val status_wire_name : repository_status -> string
(** The word a client reads this status by. *)

val status_error_message : repository_status -> string option
(** The cause [Error] carries, which the word alone does not say. *)

val status_of_wire_name :
  error_message:string option -> string -> repository_status option
(** The status a client read, or [None] for a word this build does not know
    and for ["error"] without the message that names its cause. *)

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
