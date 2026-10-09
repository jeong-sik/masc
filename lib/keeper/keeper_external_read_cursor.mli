(** Admission order for external evidence, independent of the wall clock.
    Serialized by the existing per-Keeper Librarian lane. Existing atom and
    official progress formats remain unchanged. A missing cursor starts at the
    beginning of the external log, favoring replay over dropping old evidence.
    A prepared read is acknowledged only after Memory commits its range; the
    existing Memory WAL receipts repair interruption before acknowledgement. *)
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
