(** Conservative live-original readers of Gate decisions. This projection
    reads generic owner metadata and approval facts only; it does not restore
    a media payload or establish execution authority. *)
type t
val read : base_path:string -> (t, string) result
(** Strictly scan canonical workspace original metadata once per install
    observation. Any malformed record or intent binding rejects the inventory.
    The caller preserves deliveries when this observation is unavailable. *)
val protects :
  t -> approval_id:string ->
  matches:(Keeper_approval_request_fingerprint.exact_request -> bool) -> bool
(** Protect an exact intent even before its wait link is retained, and protect
    a linked ID even if its current queue request differs. [matches] compares
    only the supplied queue snapshot fields; it performs no I/O. *)
