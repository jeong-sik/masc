(** Tool_output — typed reference for externalized tool payloads (#25096).

    Tool outputs too large for inline transport are persisted in
    {!Tool_blob_store}; the OAS [content] field then carries a marker
    rendered by {!encode_for_oas}. The marker wire format is unchanged
    ([[masc:blob sha256=… bytes=… mime=… preview=…]], consumed by durable
    keeper histories and the dashboard inspector), but the codec is now
    exact:

    - {!artifact_ref} is [private]: construction goes through
      {!make_artifact_ref}, so every reference in flight has a valid sha256,
      a non-negative byte count, and a non-empty media type.
    - {!decode_from_oas} distinguishes [Not_marker], a valid {!Stored}, and
      [Invalid_marker] — a marker-shaped payload that fails to parse is now a
      visible, typed outcome instead of the previous silent [Inline]
      fallback. *)

(** {1 sha256 validation (SSOT, re-exported by {!Tool_blob_store})} *)

type invalid_sha256 =
  | Invalid_sha256_length of { actual : int }
  | Invalid_sha256_character of { index : int; found : char }

val validate_sha256 : string -> (unit, invalid_sha256) result
val invalid_sha256_to_string : invalid_sha256 -> string

(** {1 Typed artifact reference} *)

type artifact_ref = private
  { sha256 : string
  ; bytes : int
  ; preview : string
  ; mime : string
  }

type make_error =
  | Invalid_sha256 of invalid_sha256
  | Negative_bytes of int
  | Empty_mime

val make_artifact_ref :
  sha256:string ->
  bytes:int ->
  preview:string ->
  mime:string ->
  (artifact_ref, make_error) result

val make_error_to_string : make_error -> string

val with_preview : artifact_ref -> string -> artifact_ref
(** Replace the preview, keeping the validated identity fields. Total — the
    existing reference already passed validation. *)

(** The exact structured representation used when a durable consumer stores a
    blob reference as JSON rather than its OAS marker. The producer and every
    durable owner must use this codec; a marker-shaped JSON object is never
    guessed into a reference. *)
val normalized_artifact_ref_to_json : artifact_ref -> Yojson.Safe.t

type normalized_artifact_ref_decode =
  | Not_normalized_artifact_ref
  | Invalid_normalized_artifact_ref of { detail : string }
  | Decoded_normalized_artifact_ref of artifact_ref

val normalized_artifact_ref_of_json :
  Yojson.Safe.t -> normalized_artifact_ref_decode
(** Strictly decode the singleton ["_blob"] wrapper emitted by
    {!normalized_artifact_ref_to_json}. A malformed wrapper is reported
    explicitly so retention code fails closed. *)

(** {1 Wire codec} *)

type t =
  | Inline of string
  | Stored of artifact_ref

val marker_prefix : string
val is_marker : string -> bool

val encode_for_oas : t -> string

(** Exact decode outcome. [Invalid_marker] means the input starts with
    {!marker_prefix} but the payload is malformed or fails validation — the
    caller must decide visibly (keep the raw text, log, or fail) rather than
    inherit a silent inline fallback. *)
type decode_result =
  | Not_marker
  | Invalid_marker of { detail : string }
  | Decoded of artifact_ref

val decode_from_oas : string -> decode_result

type embedded_reference_error =
  { offset : int
  ; detail : string
  }

val artifact_refs_in_text :
  string -> (artifact_ref list, embedded_reference_error) result
(** Parse every exact artifact marker embedded in arbitrary durable text.
    Marker-shaped malformed content fails the whole scan with its byte offset;
    it is never treated as an unreferenced blob. *)
