(** Original host-side request and progress. The request body is stored once,
    named by its digest; one small record holds the identity, that digest, the
    consumer's summary of the request and the progress, and only the record is
    rewritten as progress advances.
    Caller holds the workspace process lease and serializes retains and
    progress updates. *)
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
  | Invalid_request of string
type installation = Configuration of string | Manual of string
val installation_id : installation -> string
(** Canonical identity used by original request retention and worker state.
    A configured declaration and a manual instance with equal names are distinct. *)
val installation_of_id : string -> (installation, string) result
(** Decode only the complete canonical identity produced by [installation_id].
    Missing/unknown kinds, blank names and noncanonical JSON are errors. This
    identifies an original owner; it does not establish live export authority. *)
(** One record as {!discover} reads it, without the request body. *)
module Record : sig
  type t
  val scope : t -> string
  val request_id : t -> string
  val installation_id : t -> string
  val package_id : t -> string
  val tool : t -> string
  val request_digest : t -> string
  val summary : t -> Yojson.Safe.t
  (** The consumer's canonical index of the request, fixed at {!retain}. The
      store does not read it; the consumer checks it against the request. *)
  val progress : t -> Lane_addon_request_progress.t
end
type retained = private {
  scope : string;
  request_id : string;
  installation_id : string;
  package_id : string;
  tool : string;
  request_digest : string;
  summary : Yojson.Safe.t;
  request : Yojson.Safe.t;
  progress : Lane_addon_request_progress.t;
}
val request_digest : Yojson.Safe.t -> (string, string) result
(** The digest a record names a request by: of its canonical JSON bytes. *)
val to_json : retained -> Yojson.Safe.t
(** Complete immutable binding and progress metadata, without the original
    body. Used to preserve an exact pre-fence observation and compare it. *)
val load : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  (retained option, error) result
(** Read the record and the complete original canonical request it names
    through the verified durable store. [None] means the key is absent;
    malformed, changed or unreadable records, and a missing body or one whose
    bytes do not match the record's digest, are errors. This restores a known
    ID, not restart discovery or permission to dispatch or commit. The caller
    owns workspace authority. *)
val discover : store:Lane_addon_store.t -> scope:string -> (Record.t list, error) result
(** Read and strictly validate every published record in this scope, including
    its exact hashed filename, canonical summary and complete progress
    history, without reading any request body; {!load} reads and checks the
    body. Any
    malformed, misnamed, vanished or unreadable published record rejects the
    inventory; no partial list is returned as complete. No directories,
    requests or dispatches are created. Results are observations; load/advance
    and actual workspace authority must be revalidated by the original
    serialized owner. *)
type observation_issue = Malformed_owner_metadata
type observation = private { records : Record.t list; issues : observation_issue list }
val observe : store:Lane_addon_store.t -> scope:string -> (observation, error) result
(** Observe individually valid metadata without reading request bodies.
    Malformed JSON or owner schema becomes an unattributable issue alongside
    known records. A mismatched physical scope/key, filesystem, ownership,
    sync or directory error rejects the whole observation. This partial,
    non-atomic view grants no execution authority and does not change the
    strict contract of {!discover}. Load each record again before using it. *)
val reload : store:Lane_addon_store.t -> retained -> (retained option, error) result
(** The current record of [previous]'s ID, carrying [previous]'s request
    without reading the body again. Retain fixes the digest a record names its
    body by, so a record with the same digest, binding and summary names the
    body {!load} already verified; only progress can differ. A record that
    names another digest or binding is an error, and [None] means the record
    is gone (settled or removed). *)
val load_record : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  (Record.t option, error) result
(** One record as {!discover} reads it, by its ID, without reading the request
    body. [None] means the key is absent. The record's summary is the
    consumer's to check; {!load} reads and checks the body. *)
val load_listed : store:Lane_addon_store.t -> Record.t -> (retained, error) result
(** Restore one observed record and its complete body using {!load}, then
    confirm that the record still has the discovered identity: scope, request
    ID, binding, tool, digest and summary. Its progress is the record's as
    read now, which another writer may have advanced since the listing; every
    write to a record is compare-and-set against what its writer read. A
    changed identity or a disappeared record is an error.
    Consumers may select known typed subjects before reading their bodies;
    this operation does not turn a partial selection into a complete scope
    inventory or authorize any effect. *)
val discover_all : store:Lane_addon_store.t -> (retained list, error) result
(** Validate the directory and record identity of each published scope, then
    strictly load each original body. This observation is not an atomic
    cross-scope snapshot or permission for effects. *)
val fold_all :
  store:Lane_addon_store.t ->
  init:'a ->
  f:('a -> retained -> 'a) ->
  ('a, error) result
(** Same strict all-scope validation and body restoration as {!discover_all},
    passing one restored original at a time to [f] so callers do not retain
    every original request body in memory simultaneously. Any scope, record or
    body error rejects the whole fold without returning partial results. *)
val fold_all_records :
  store:Lane_addon_store.t ->
  init:'a ->
  f:('a -> Record.t -> ('a, error) result) ->
  ('a, error) result
(** The same all-scope directory and record validation as {!fold_all}, passing
    each record without its body. A caller that needs one original's request
    reads it with {!load_listed} inside [f]; an error [f] returns rejects the
    whole fold. Bodies [f] does not read are not validated. *)
val load_scope : store:Lane_addon_store.t -> scope:string -> (retained list, error) result
(** Discover record identities, then strictly load each original whose
    identity is unchanged ({!load_listed}). A missing record or a changed
    identity rejects the whole result. Each record's progress is as read when
    that record was loaded, so the result is not one snapshot of the scope.
    Unlike {!discover}, this explicitly reads every request body in the
    scope. *)
val prepare_successor : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  request:Yojson.Safe.t -> (Lane_addon_request_progress.successor, error) result
(** Durably stage canonical input before retaining its digest-only successor
    intent. Does not publish an owner record or allow child execution. *)
val load_successor_request : store:Lane_addon_store.t -> scope:string ->
  Lane_addon_request_progress.successor -> (Yojson.Safe.t, error) result
(** Verify the complete canonical input named by a retained successor intent.
    Missing, changed or noncanonical bytes are errors, never permission to
    regenerate an input or create another child. *)
module Published_reader : sig
  type t
  val create :
    read_body:(scope:string -> request_digest:string -> (string option, string) result) -> t
  (** A read-only decoder owned by one preflight scope scan. Every read calls
      the supplied port again. Only successful digest/JSON/canonical checks
      are reused, and only when the newly read bytes equal the verified bytes
      exactly, under the same scope and digest. Missing, changed and unreadable
      bodies cannot borrow a previous verdict. Discard the reader after the
      scope scan; it observes no live authority and authorizes no effects. *)
  val request : t -> scope:string -> request_digest:string -> (Yojson.Safe.t, string) result
  val read : t -> directory_name:string -> file_name:string -> Yojson.Safe.t -> (retained, string) result
  (** Decode the complete current record and its physical scope/file identity,
      then read its current body through {!request}. Returns the verified
      original for the consumer's pure payload decoder. *)
end
val decode_published : directory_name:string -> file_name:string -> Yojson.Safe.t ->
  (Record.t, string) result
(** Strictly decode a record and verify the scope-directory and request-file
    identities it names. Does not read its body or authorize any effect. *)
val retain : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  installation_id:string -> package_id:string -> tool:string -> summary:Yojson.Safe.t ->
  request:Yojson.Safe.t -> (unit, error) result
(** Persist the complete canonical request before dispatch: its body first,
    then the record that names it with [summary]. Same input, summary and
    original destination is idempotent and preserves advanced progress; the
    request is compared by its digest. Invalid JSON is refused before writing. A retain
    interrupted between the two writes leaves a body no record names.
    Retaining the same request again writes that body again; startup inventory
    preserves bodies that no observed active intent or archived record names.
    A record whose body is missing is an error.
    Publication failure is not proof of absence: a retry strictly reads the
    original record again. *)
type update_error = Ownership_error of error | State_conflict | Invalid_transition of string
type publication = Stored of retained | Already_stored of retained | Unconfirmed of string
val advance_events : store:Lane_addon_store.t -> expected:retained ->
  events:Lane_addon_request_progress.event list -> (publication, update_error) result
(** Validate a nonempty list of canonical events in order, then check the
    entire original expected record and publish the final progress once.
    Empty lists and invalid transitions are refused before reading or writing
    the record; no partial batch is published.
    Only the record is read and rewritten; the body it names is neither
    read nor written, and the request is compared by its digest. An exact
    already-stored next history is acknowledged without writing;
    [Already_stored] does not permit another dispatch or effect. Any other tail
    is [State_conflict]. This is an expected-record check under the caller's
    lease and serialization, not a filesystem or cross-process CAS.

    [Unconfirmed] means save failed and publication may already be visible.
    Reload the original key; never infer absence or invent a replacement ID.
    Cancellation propagates and likewise does not prove publication absent.
    This API records trusted host facts; it performs no worker/domain effects. *)
val advance : store:Lane_addon_store.t -> expected:retained ->
  event:Lane_addon_request_progress.event -> (publication, update_error) result
(** {!advance_events} for one event, with the same publication contract. *)
module For_testing : sig
  val fold_all : store:Lane_addon_store.t -> after_inventory:(unit -> unit) ->
    init:'a -> f:('a -> retained -> 'a) -> ('a, error) result
  (** Invoke the hook after inventory and before restoring the listed records. *)
  val fold_all_records : store:Lane_addon_store.t -> after_inventory:(unit -> unit) ->
    init:'a -> f:('a -> Record.t -> ('a, error) result) -> ('a, error) result
  (** {!fold_all_records} with the same hook. *)
  val advance_events :
    save:(Lane_addon_store.t -> scope:string -> request_id:string -> Yojson.Safe.t ->
      (unit, string) result) ->
    store:Lane_addon_store.t -> expected:retained ->
    events:Lane_addon_request_progress.event list -> (publication, update_error) result
  (** The same canonical batch transition and publication path, with only the
      final writer injected. The writer receives the original store and key
      and the complete next record. An error, including one reported after a
      successful write, returns [Unconfirmed]; exceptions and cancellation
      propagate. No writer is called for a rejected or already-stored batch.
      Production {!advance_events} uses [Lane_addon_store.save_tool_request_owner]. *)
end
val listed : retained -> Record.t
(** The record {!discover} lists for this retained original, without its body. *)
val record_to_json : Record.t -> Yojson.Safe.t
(** Complete canonical owner metadata, including the original destination,
    summary and progress. Carries no request body or execution authority. *)
val load_settled : store:Lane_addon_store.t -> scope:string -> date:string -> request_id:string ->
  (Record.t option, error) result
(** Strict current owner-schema decoding of an archived record under its
    exact scope, date and ID. Does not restore its removed body, prove a
    domain commit/ACK or authorize settlement. *)
type settle_error = Settle_unavailable of string | Settle_changed
val settle : store:Lane_addon_store.t -> date:string -> Record.t -> (unit, settle_error) result
(** Move one original's record into the settled archive under [date], then
    remove its body, if the scope still holds exactly this record;
    [Settle_changed] otherwise, and nothing changes. A record already in the
    archive completes the settle, removing a body still left. The caller settles only originals no pass
    needs again and whose body no other record names. The expected-record check
    and move share the scope serializer, under the caller's workspace lease. *)
val settled : store:Lane_addon_store.t -> scope:string -> date:string -> request_id:string ->
  (bool, error) result
(** Whether the archive holds the record of [request_id] under [date]. *)
val settle_error_to_string : settle_error -> string
val update_error_to_string : update_error -> string
val error_to_string : error -> string
