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

val observation_matches_floor_preparation : observation -> after:int -> through:int ->
  atom:Keeper_memory_os_current.durable_range_id option ->
  official:Keeper_memory_os_current.official_range_id option -> bool
(** A pending message-floor preparation has the original range identity with
    unread-message coverage added by its completed program. This compares the
    original range and cursor coordinates while ignoring only those holes. *)
val restore_original_preparation : runtime_keepers_dir:string -> keeper_name:string ->
  expected:observation -> original:observation -> (unit, string) result
(** Only for an explicitly fenced history original inside its serialized
    Memory lane and held source locks. Compare the current complete observation
    and restore that original's exact preparation at the same offset. Does not
    recover a publication, acknowledge input or change the offset. The caller
    verifies the immutable source/range and absence of its Memory effect. *)

type token
val read : memory_keepers_dir:string -> runtime_keepers_dir:string -> keeper_name:string ->
  (token, string) result
val offset : token -> int
(** Count of complete admission rows already included in a committed Memory pass;
    not a byte offset or a wall-clock timestamp. *)
val prepare : memory_keepers_dir:string -> runtime_keepers_dir:string -> keeper_name:string -> token -> through:int ->
  atom:Keeper_memory_os_current.durable_range_id option ->
  official:Keeper_memory_os_current.official_range_id option -> (unit, string) result
(** Reject a backwards [through] or an advancing request without a Memory
    identity before reading or recovering an existing pending cursor. When a
    preparation is pending, also reject a requested range already observed as
    committed before recovering the pending cursor. Memory receipt reads can
    still recover a publication, reconcile evidence and dispatch its commit
    notification. A concurrent Memory commit after that observation is not
    fenced. Valid preparations can still recover a previously committed pending
    cursor. The caller serializes this Keeper. *)
val acknowledge : runtime_keepers_dir:string -> keeper_name:string -> (unit, string) result

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string
val inspect : keepers_dir:string -> keeper_id:string -> (bool, string) result
(** Read-only durable-store validation; false means absent. Never reconciles a
    pending receipt or writes cursor state. *)
