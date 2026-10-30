(** The operator's view of a verification request's submitted evidence.

    The store's serializer persists the snapshot, and a binary artifact there
    is a reference, a hash and the path of a filed body. An operator reading
    the evidence needs the picture itself, so this projection adds one field,
    [preview], to every [artifact_binary] item and changes nothing else:
    {!Workspace_verification_store.submitted_evidence_item_to_yojson} stays the
    persistence format and the judge serializers stay as they are.

    [preview] is a closed sum on the wire.
    - [{"state":"inline","body_base64"}]: the image bytes, at
      most {!Tool_shard_limits.verification_evidence_max_bytes} each and
      {!Tool_shard_limits.verification_operator_preview_budget_bytes} in
      total per response.
    - [{"state":"withheld","reason", ...}]: why the bytes are not here. The
      item still carries its reference, size and hash. *)

type withheld_reason =
  | Not_image_format
      (** the item is not an image the terminal can show: a PDF, audio,
          video or archive, or no binary item at all *)
  | Body_not_filed
      (** the snapshot was decoded from persistence, so no body was filed *)
  | Body_unreadable  (** the filed body cannot be read back *)
  | Body_identity_mismatch of Workspace_verification_store.binary_body_identity_mismatch
      (** The filed bytes differ from the size or SHA-256 recorded at submission. *)
  | Over_delivery_ceiling of { bytes : int; ceiling : int }
      (** the body is [bytes] long and one image may be [ceiling] *)
  | Over_response_budget
      (** earlier images in this response used the whole inline budget *)

type preview =
  | Inline of { body_base64 : string }
      (** the image's bytes; the reader identifies the format from them *)
  | Withheld of withheld_reason

val preview_to_yojson : preview -> Yojson.Safe.t

val previews :
  base_path:string ->
  Workspace_verification_store.submitted_evidence_item list ->
  preview option list
(** One entry per item, in order: [Some] for a binary artifact, [None] for
    every other kind. Images are admitted in item order until
    {!Tool_shard_limits.verification_operator_preview_budget_bytes} is spent;
    a later image is [Withheld Over_response_budget]. *)

val access_to_yojson :
  base_path:string ->
  Workspace_verification_store.submitted_evidence_access ->
  Yojson.Safe.t
(** {!Workspace_verification_store.submitted_evidence_access_to_yojson} with
    [preview] added to each binary item. Every other field and item is byte
    for byte what the persistence serializer writes. *)

val file_to_yojson :
  base_path:string ->
  index:int ->
  Workspace_verification_store.submitted_evidence_access ->
  (Yojson.Safe.t, string) result
(** Export one zero-based item of this exact retained submission. Text is the
    stored snapshot, never a reread of a producer path. Truncated text is
    refused. Binary bodies use the store's size/hash checked reader, including
    PDF/audio/video bodies that have no inline image preview. *)
