(** Tool_output — typed reference for externalized tool payloads (#25096).

    Tool outputs too large for inline transport are persisted in
    {!Tool_blob_store}; the AGENT_CORE [content] field then carries a marker
    rendered by {!encode_for_agent_core}. The marker wire format is unchanged
    ([[masc:blob sha256=… bytes=… mime=… preview=…]], consumed by durable
    keeper histories and the dashboard inspector), but the codec is now
    exact:

    - {!artifact_ref} is [private]: construction goes through
      {!make_artifact_ref}, so every reference in flight has a valid sha256,
      a non-negative byte count, and a non-empty media type.
    - {!decode_from_agent_core} distinguishes [Not_marker], a valid {!Stored}, and
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
  | Unencodable_mime of string
      (** The marker writes mime unquoted between spaces, so a media type with
          a parameter ("text/plain; charset=utf-8") cannot survive the round
          trip. *)

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
    blob reference as JSON rather than its AGENT_CORE marker. The producer and every
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

val normalized_artifact_refs_in_json : Yojson.Safe.t -> artifact_ref list
(** Collect every valid normalized reference nested in typed JSON, deduplicated
    by content address and declared media type in first-occurrence order.
    Malformed wrappers are not references; authoritative decoders remain
    responsible for rejecting them. *)

val normalized_artifact_refs_in_json_strict :
  Yojson.Safe.t -> (artifact_ref list, string) result
(** As {!normalized_artifact_refs_in_json}, but reject the first malformed
    reserved [_blob] wrapper. Durable manifest producers and consumers must
    use this form so they share one closed validity contract. *)

(** {1 Durable result manifests}

    A tool result that itself contains normalized artifact references is
    stored as one typed manifest blob. The durable transcript owns the
    manifest through an exact AGENT_CORE marker, while offline maintenance
    follows only this explicit MIME/schema edge to the referenced child
    artifacts. Arbitrary JSON blobs are never traversed. *)

val artifact_manifest_mime : string

val artifact_manifest_to_json :
  content:string -> structured_content:Yojson.Safe.t -> Yojson.Safe.t

type artifact_manifest_decode =
  | Not_artifact_manifest
  | Invalid_artifact_manifest of { detail : string }
  | Decoded_artifact_manifest of
      { content : string
      ; structured_content : Yojson.Safe.t
      ; artifact_refs : artifact_ref list
      }

val artifact_manifest_of_json : Yojson.Safe.t -> artifact_manifest_decode
(** Strictly decode the closed manifest envelope. The decoded child set is
    derived only from [structured_content] using the normalized reference
    codec above. *)

(** {1 Wire codec} *)

type t =
  | Inline of string
  | Stored of artifact_ref

(** Model-visible projection is owned by the tool descriptor, rather than
    inferred from the tool name or from a bridge-wide magic threshold. *)
type model_projection =
  | Store_above of { threshold_bytes : int }
  | Inline_up_to of { maximum_bytes : int }

val default_model_projection : model_projection
(** Store results larger than the canonical MASC tool-output budget. *)

val bounded_inline_model_projection : model_projection
(** Keep a result inline only while it remains inside that same canonical
    tool-output budget. This is for explicit artifact-page readers. *)

val marker_prefix : string
(** Exact wire-grammar introducer [[masc:blob sha256=]. Prose placeholders
    such as [[masc:blob ...]] are not artifact references. *)

val is_marker : string -> bool

val encode_for_agent_core : t -> string

(** Exact decode outcome. [Invalid_marker] means the input starts with
    {!marker_prefix} but the payload is malformed or fails validation — the
    caller must decide visibly (keep the raw text, log, or fail) rather than
    inherit a silent inline fallback. *)
type decode_result =
  | Not_marker
  | Invalid_marker of { detail : string }
  | Decoded of artifact_ref

val decode_from_agent_core : string -> decode_result
