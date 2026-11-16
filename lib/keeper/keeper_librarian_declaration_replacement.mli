(** A host refusal made before this original was admitted. Its evidence binds
    the original record and both destinations; reading it needs no body or
    current worker. Caller owns the physical Keeper and serialized Memory lane. *)
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
