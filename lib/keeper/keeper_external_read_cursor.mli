(** Admission order for external evidence, independent of the wall clock.
    Serialized by the existing per-Keeper Librarian lane. Existing atom and
    official progress formats remain unchanged. A missing cursor starts at the
    beginning of the external log, favoring replay over dropping old evidence.
    A prepared read is acknowledged only after Memory commits its range; the
    existing Memory WAL receipts repair interruption before acknowledgement.
    Receipt comparison includes exact unread coverage, whose verified records
    are durably archived before acknowledgement can discard the pending ID. *)
(** Read-only snapshot of the original cursor, including after, pending through
    and complete atom/official receipt identities. Missing state is the original
    zero cursor. This is data, not a token or a recovery/ACK capability. *)
type observation
val observe : runtime_keepers_dir:string -> keeper_name:string -> (observation, string) result
val observation_to_json : observation -> Yojson.Safe.t
val observation_of_json : Yojson.Safe.t -> (observation, string) result
val observation_offset : observation -> int
val observation_matches_preparation : observation -> after:int -> through:int ->
  atom:Keeper_memory_os_current.durable_range_id option ->
  official:Keeper_memory_os_current.official_range_id option -> bool
(** Exact stored preparation comparison only. Does not construct a token or
    inspect/repair current Memory receipts. Equal through/after expects no pending. *)

type token
val read : memory_keepers_dir:string -> runtime_keepers_dir:string -> keeper_name:string ->
  (token, string) result
val offset : token -> int
(** Count of complete admission rows already included in a committed Memory pass;
    not a byte offset or a wall-clock timestamp. *)
val prepare : memory_keepers_dir:string -> runtime_keepers_dir:string -> keeper_name:string -> token -> through:int ->
  atom:Keeper_memory_os_current.durable_range_id option ->
  official:Keeper_memory_os_current.official_range_id option -> (unit, string) result
val acknowledge : runtime_keepers_dir:string -> keeper_name:string -> (unit, string) result

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string
val inspect : keepers_dir:string -> keeper_id:string -> (bool, string) result
(** Read-only durable-store validation; false means absent. Never reconciles a
    pending receipt or writes cursor state. *)
