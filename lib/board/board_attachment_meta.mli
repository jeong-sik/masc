(** Board_attachment_meta — pure-data carrier for board post attachments.

    Attachments are referenced from a [Board_types.post] via the existing
    [meta_json : Yojson.Safe.t option] field — no struct change to the
    post type.  This module owns the JSON shape under the
    ["attachments"] key.

    No I/O.  No Eio.  No network.  Round-trippable JSON.

    See [docs/rfc/RFC-0037-board-multimedia-vision-adapted.md] §4.1 for
    the design rationale.  This is RFC-0037 PR-1.

    Properties enforced:
    - [Id] is opaque + parsed (Parse, don't validate), mirroring the
      discipline used by [Board_types.Post_id] / [Board_types.Comment_id].
    - [of_yojson] is total: an unknown JSON shape returns [Error] rather
      than throwing.
    - [attach_to_post_meta] preserves any keys in [meta_json] other than
      the ["attachments"] slot, so this module can coexist with future
      [meta_json] users. *)

(** {1 Errors} *)

type error =
  | Invalid_id of string
  | Invalid_kind of string
  | Invalid_payload of string
  | Missing_field of string
[@@deriving show]

val error_to_string : error -> string

type attachment_meta_read_error =
  | Meta_not_object of { received : string }
  | Attachments_not_list of { received : string }
  | Attachment_decode_error of { index : int; error : error }

val attachment_meta_read_error_to_string :
  attachment_meta_read_error -> string

(** {1 Attachment kind — closed sum} *)

type kind =
  | Image
  | Video
  | Youtube
  | External_link

val kind_to_string : kind -> string
val kind_of_string : string -> (kind, error) result

(** {1 Attachment id — opaque, parsed} *)

module Id : sig
  type t

  val of_string : string -> (t, error) result
  (** Validates [a-zA-Z0-9_-]+ and length 1..64.  Same character class as
      [Board_types.Post_id]. *)

  val to_string : t -> string

  val generate : unit -> t
  (** Cryptographic random id, prefix ["a-"]. *)

  val equal : t -> t -> bool
end

(** {1 Attachment record} *)

type t = {
  id : Id.t;
  kind : kind;
  origin_url : string;
  origin_name : string;
  origin_size_bytes : int;
  mime_type : string;
  width : int option;
  height : int option;
  created_at : float;
}

(** {1 JSON encoding} *)

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, error) result

(** {1 [meta_json] embedding}

    These helpers pack/unpack a list of attachments under the
    ["attachments"] key of a post's [meta_json] field. *)

val meta_json_key : string
(** ["attachments"] — single-source-of-truth for the JSON key. *)

type attachments_of_post_meta_result = {
  attachments : t list;
  errors : attachment_meta_read_error list;
}

val attachments_of_post_meta_result :
  Yojson.Safe.t option ->
  attachments_of_post_meta_result
(** [attachments_of_post_meta_result meta] returns both successfully
    decoded attachments and typed read errors for malformed [meta_json]
    or malformed attachment items. [None] and a missing [meta_json_key]
    are absence, not errors. *)

val attach_to_post_meta :
  existing:Yojson.Safe.t option ->
  t list ->
  Yojson.Safe.t
(** [attach_to_post_meta ~existing attachments] returns a JSON object
    that:
    - preserves every key in [existing] (when it is a [`Assoc]) other
      than [meta_json_key]
    - sets [meta_json_key] to a JSON array of [attachments]

    If [existing] is [None] or not a [`Assoc], the returned object has
    only the [meta_json_key] entry.  The returned value is suitable to
    drop into [post.meta_json]. *)

val attachments_of_post_meta : Yojson.Safe.t option -> t list
(** [attachments_of_post_meta meta] returns the attachments encoded under
    [meta_json_key]. This is the legacy compatibility projection of
    [attachments_of_post_meta_result]; readers that need failure
    visibility must consume the typed [errors] field from the result API. *)
