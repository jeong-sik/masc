(** Immutable approval facts of an existing original request. These pure values
    do not submit, observe, resolve or consume an approval. Progress owns their
    phase/order guards; the media owner verifies their original binding. *)

type intent
type wait

val intent :
  request_id:string -> request_digest:string ->
  request:Keeper_approval_request_fingerprint.exact_request ->
  (intent, string) result
(** Bind one original ID/body digest and complete captured Gate identity.
    Compute the intent digest from those canonical bytes. *)

val original_request_id : intent -> string
val original_request_digest : intent -> string
val request : intent -> Keeper_approval_request_fingerprint.exact_request
val intent_digest : intent -> string
val equal_intent : intent -> intent -> bool
val intent_to_json : intent -> Yojson.Safe.t
val intent_of_json : Yojson.Safe.t -> (intent, string) result
(** Reject missing/extra/duplicate fields and malformed nested values or hashes;
    recompute the complete intent digest. Decoding supplies no live approval. *)

val wait : intent -> approval_id:string -> input_hash:string -> (wait, string) result
(** Link the actual observed approval ID to this intent. The supplied input
    hash must equal its exact request hash. This records a wait, never Allow. *)
val approval_id : wait -> string
val wait_input_hash : wait -> string
val wait_intent_digest : wait -> string
val wait_matches_intent : intent -> wait -> bool
val equal_wait : wait -> wait -> bool
val wait_to_json : wait -> Yojson.Safe.t
val wait_of_json : Yojson.Safe.t -> (wait, string) result
(** Strict data-only decoding. The caller must subsequently check
    [wait_matches_intent] against the retained intent; a well-formed digest
    alone does not establish that link or an approval decision. *)
