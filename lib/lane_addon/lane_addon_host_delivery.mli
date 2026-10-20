(** Frame-bounded delivery of a host result, with durable request-bound recovery. *)
type owner = { instance_id : string; authority : Yojson.Safe.t }
type error = Refused of string | Storage_failed of string
val restore :
  store:Lane_addon_store.t -> owner:owner -> request:Lane_addon_host_request.t ->
  max_bytes:int -> (Yojson.Safe.t option, error) result
(** Recover retained original-result arguments before trying its source again.
    A continuation itself has no retained original-result link. *)
val arguments :
  store:Lane_addon_store.t -> owner:owner -> request:Lane_addon_host_request.t ->
  max_bytes:int -> result:Yojson.Safe.t -> (Yojson.Safe.t, error) result
(** Small results are delivered inline. Larger results are retained before any
    reference is advertised, together with exact request and current authority.
    A repeated original request reuses its first retained result; another request
    with the same ID cannot replace that link. Record cursors remain available. *)
val read :
  store:Lane_addon_store.t -> owner:owner -> request_id:string ->
  original_request_id:string -> source_id:string option -> sha256:string ->
  offset:int -> max_bytes:int -> (Yojson.Safe.t, error) result
(** Answer a read_result with a base64 slice of the original result JSON. Every
    reply fits the full result-arguments frame. Current authority, original
    request/source and advertised digest must match the retained link. Storage
    Unchanged retained files use bounded range reads. If identical bytes were
    republished, the host revalidates the full digest once and durably refreshes
    its file snapshot. Storage failures never advertise unretained bytes. *)
