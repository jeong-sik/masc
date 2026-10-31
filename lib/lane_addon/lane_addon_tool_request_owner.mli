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
val reload : store:Lane_addon_store.t -> retained -> (retained option, error) result
(** The current record of [previous]'s ID, carrying [previous]'s request
    without reading the body again. Retain fixes the digest a record names its
    body by, so a record with the same digest, binding and summary names the
    body {!load} already verified; only progress can differ. A record that
    names another digest or binding is an error, and [None] means the record
    is gone (settled or removed). *)
val load_listed : store:Lane_addon_store.t -> Record.t -> (retained, error) result
(** Restore one observed record and its complete body using {!load}, then
    confirm that the record still has the exact discovered identity, summary,
    digest and progress. Changed or disappeared observations are errors.
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
val load_scope : store:Lane_addon_store.t -> scope:string -> (retained list, error) result
(** Discover record identities, then strictly load each unchanged original.
    Missing or changed observations reject the whole result. Unlike
    {!discover}, this explicitly reads every request body in the scope. *)
val prepare_successor : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  request:Yojson.Safe.t -> (Lane_addon_request_progress.successor, error) result
(** Durably stage canonical input before retaining its digest-only successor
    intent. Does not publish an owner record or allow child execution. *)
val load_successor_request : store:Lane_addon_store.t -> scope:string ->
  Lane_addon_request_progress.successor -> (Yojson.Safe.t, error) result
(** Verify the complete canonical input named by a retained successor intent.
    Missing, changed or noncanonical bytes are errors, never permission to
    regenerate an input or create another child. *)
val check_published :
  read_body:(scope:string -> request_digest:string -> (string option, string) result) ->
  directory_name:string -> file_name:string -> Yojson.Safe.t -> (unit, string) result
(** Decode one published record the way {!discover} reads it, with the scope
    and request ID the record names: the complete record, the body
    [read_body] returns for its digest, and its scope directory and filename.
    Reads nothing else and writes nothing. *)
val read_published :
  read_body:(scope:string -> request_digest:string -> (string option, string) result) ->
  directory_name:string -> file_name:string -> Yojson.Safe.t -> (retained, string) result
(** The same strict record/body check as {!check_published}, returning its
    verified original for a consumer's pure payload decoder. The body port is
    read-only; this does not observe live authority or recover progress. *)
val request_of_body : request_digest:string -> string option -> (Yojson.Safe.t, string) result
(** Pure current body validation shared with {!load}: required, canonical JSON
    whose exact bytes match the named digest. No old-body reader or I/O. *)
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
    Retaining the same request again writes that body again; startup cleanup may
    remove it when no active intent or archived record can name it. A record
    whose body is missing is an error.
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
type settle_error = Settle_unavailable of string | Settle_changed
val settle : store:Lane_addon_store.t -> date:string -> Record.t -> (unit, settle_error) result
(** Move one original, its record and then its body, into the settled archive
    under [date], if the scope still holds exactly this record; [Settle_changed]
    otherwise, and nothing moves. A record already in the archive completes
    the move of whatever is left. The caller settles only originals no pass
    needs again and whose body no other record names. The expected-record check
    and move share the scope serializer, under the caller's workspace lease. *)
val settled : store:Lane_addon_store.t -> scope:string -> date:string -> request_id:string ->
  (bool, error) result
(** Whether the archive holds the record of [request_id] under [date]. *)
val settle_error_to_string : settle_error -> string
val update_error_to_string : update_error -> string
val error_to_string : error -> string
