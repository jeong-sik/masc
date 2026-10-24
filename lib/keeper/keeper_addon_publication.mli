(** Commit a canonical companion notice, then admit its original Keeper source
    durably before issuing a wake hint or acknowledging the publisher. *)
type error = Publication_failed of Lane_addon_companion_publication.error
  | Queue_unconfirmed
val error_to_string : error -> string
val deliver : fs:Eio.Fs.dir_ty Eio.Path.t -> config:Workspace.config ->
  origin:Lane_addon_companion_origin.record -> output_schema:Yojson.Safe.t ->
  event:Lane_addon_companion_publication.event -> (unit,error) result
(** Same-ID retry reconciles the same record and durable queue/consumption
    evidence. A successful return means admission, not a resumed Keeper turn.
    The caller must hold the original private publisher's owner scope through
    this call; reading an origin record alone is not publication authority. *)
