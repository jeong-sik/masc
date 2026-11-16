(** A host refusal made before this original was admitted. Its evidence binds
    the original record and both destinations; reading it needs no body or
    current worker. Caller owns the physical Keeper and serialized Memory lane. *)
type replaced = {
  captured : Lane_addon_captured_destination.t;
  current : Lane_addon_captured_destination.t;
}
val replaced_to_json : replaced -> Yojson.Safe.t
val confirm_replaced : captured:Lane_addon_captured_destination.t ->
  Yojson.Safe.t -> (replaced, string) result
(** The shared strict pre-admission ending used by the history request and by
    record-only recovery. Encoding does not confer live authority. *)

val retained : original:Lane_addon_tool_request_owner.Record.t ->
  captured:Lane_addon_captured_destination.t -> (bool, string) result
(** Strictly validate an existing [Before_dispatch] replacement refusal.
    Other phases return [false]; malformed replacement evidence is an error. *)

val confirm_no_execution : store:Lane_addon_store.t ->
  original:Lane_addon_tool_request_owner.Record.t -> exact_digest:string -> (unit, string) result
(** Require that neither an original Exact record nor an execution proof
    exists. An open or terminal host record is no permission to recreate input. *)

val refuse : store:Lane_addon_store.t -> original:Lane_addon_tool_request_owner.Record.t ->
  exact_digest:string -> captured:Lane_addon_captured_destination.t ->
  current:Lane_addon_captured_destination.t ->
  (Lane_addon_tool_request_owner.Record.t, Lane_addon_submit_once.error) result
(** Only [Captured] or [Admission_wait], after fresh complete Runtime authority
    supplied a ready replacement [current]. Persist [Before_dispatch] evidence;
    save uncertainty grants no wake, archive or fresh request. No body is read. *)

val released_cut : store:Lane_addon_store.t -> original:Lane_addon_tool_request_owner.Record.t ->
  exact:Lane_addon_exact.request -> captured:Lane_addon_captured_destination.t -> (bool, string) result
(** A retained policy decision released this history original's host-confirmed [Cut]
    under a ready replacement declaration. Validate both the bound disposition
    and current host record/proofs; never substitute a live worker comparison.
    The caller binds [exact] to the original. Its validated [Rejected Execution]
    history never reached a judgment or domain commit. Store calls are blocking
    and must be offloaded from Eio. *)

val release_cut : store:Lane_addon_store.t -> original:Lane_addon_tool_request_owner.Record.t ->
  exact:Lane_addon_exact.request -> captured:Lane_addon_captured_destination.t ->
  current:Lane_addon_captured_destination.t ->
  (Lane_addon_tool_request_owner.Record.t, Lane_addon_submit_once.error) result
(** Persist [Refusal_settled] as a source-unconsumed replacement disposition,
    preserving the original [Cut] refusal. Caller supplies fresh ready Runtime
    authority, a bound original and its live physical owner.
    This operator policy permits another provider call under a new request ID;
    it neither moves input cursors nor claims the old provider never received it. *)

val ended_payload : original:Lane_addon_tool_request_owner.Record.t ->
  exact:Lane_addon_exact.request -> captured:Lane_addon_captured_destination.t -> (bool, string) result
(** Pure bound ending evidence for a replacement lineage. Accept only the
    strict pre-admission declaration refusal, the typed host declaration
    refusal, or a Cut with its strict retained release disposition. Other
    terminal causes return false. This validates owned payloads and grants
    no host execution, live configuration or publication authority. *)

val ended : store:Lane_addon_store.t -> original:Lane_addon_tool_request_owner.Record.t ->
  exact:Lane_addon_exact.request -> captured:Lane_addon_captured_destination.t -> (bool, string) result
(** Confirm {!ended_payload} against the original host record and execution
    proofs. A pre-admission ending requires both to be absent. A host ending
    must retain its exact typed cause with no completed execution proof.
    The caller binds [exact] to the complete original. Offload the whole call. *)
