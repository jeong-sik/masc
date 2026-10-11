(** Immutable received Child snapshot histories, independent of Root settlement.
    Public transport views never grant runtime/binding/publication ownership. *)
module Read = Masc.Keeper_child_content_read

type error = Transport of string | Http_refused of int | Invalid_json of string
  | Invalid_response of Read.decode_error | Service of Read.failure
  | Persistence of Read.receiver * Read.error_code | Receiver_read of Read.receiver * error
  | History_rewritten of Read.receiver * string
(** History rewrite includes same-incarnation rollback or changed prior immutable
    correlations/timestamp. Only human text/model may change on a full Audit. *)
type read_mode = Poll | Audit
type store = private
  { receiver : Read.receiver; store_id : string; cursor : Read.cursor option
  ; records : Read.record list; error : error option; attempted : Read.cursor option
  ; cleanup_failures : string list; coverage : Read.coverage }
(** Ordered snapshots; never Task-folded or merged by provider envelope UUID.
    Old disappeared/incarnation histories retain last-observed redaction only. *)
type t
val empty : t
val failed : t -> error -> t
val stores : t -> store list
val errors : t -> error list
val diagnostics : t -> string list
val error_text : error -> string
val read : mode:read_mode -> keeper_name:string ->
  fetch:(string -> (int * string,string) result) -> previous:t -> (t,error) result
(** Caller supplies actual guarded authenticated fetch and owns workspace/cache
    lifetime and read epoch mailbox admission; Keeper equality/DTO is not auth.
    Poll reads unchecked hints, exact changed suffixes only; same attempted hint
    avoids repeated failed audits, and cannot erase an audited failure. Failure
    retains prior snapshots/cursor; healthy receivers may advance independently.
    Audit reads full current-incarnation records even unchanged tail, refreshing
    public body/model redaction only as supplied in that full response. Same-store
    tail regression or changed prior immutable identity refuses and retains cache.
    A changed Poll after such a refusal requests the full prefix again. Rewrite
    remains the primary failure through transient errors until full comparison
    succeeds; a valid suffix alone cannot clear it.
    Absent older stores remain last-observed, current redaction coverage unknown.
    No automatic global/history redaction guarantee or receiver liveness inferred.
    Full ticket3/store/sequence/composite identity is preserved, no arbitrary cap.
    There is no asynchronous launch, global registry or input/body heuristic here. *)
