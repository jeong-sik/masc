(** Pure approval identity of one immutable media original. This module neither
    consults the queue nor submits, consumes or grants an effect. *)

val input : Keeper_media_reading_original.t -> Yojson.Safe.t
(** A complete content-addressed request reference: original ID/body digest
    and reserved execution ID. The referenced body retains the verified source,
    declaration, prepared invocation and context. This is not a launch handle. *)

val intent :
  Keeper_media_reading_original.t ->
  (Lane_addon_request_approval.intent, string) result
(** Capture the exact Gate identity from the original's workspace, Keeper,
    origin, task and continuation. No current Runtime or turn is consulted.
    The existing Gate submission has no goal input, so the captured goal is
    [None]. A physical origin witness is retained without changing the queue's
    existing logical-origin matching semantics. *)

val validate_progress :
  original:Keeper_media_reading_original.t ->
  Lane_addon_request_progress.t -> (unit, string) result
(** Check original-bound approval facts and require the captured intent before
    a media dispatch fact. The generic progress codec owns phase/order checks.
    An initial automatic Allow requires no fabricated approval ID or wait link.
    This does not establish a live decision, grant consumption, received reply,
    process completion or permission to replay. Other generic facts retain their
    own producer validation boundaries. *)
