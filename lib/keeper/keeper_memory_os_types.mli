(** Keeper Memory OS current fact schema.

    The persisted shape is current-only and closed; version or compatibility
    fields reject. *)

(** Canonical JSON wire field names for Memory OS persistence and librarian
    ingestion. The schema module owns these strings so parser, retry prompt,
    persistence codec, and tests share one source. *)
val wire_field_claim : string
val wire_field_category : string
val wire_field_first_seen : string

(** Claim-object fields accepted from the librarian and rendered in retry
    prompts. *)
val wire_librarian_claim_fields : string list

(** Librarian taxonomy as a closed sum. Labels outside the current vocabulary
    reject at the producer and persistence boundaries. Categories are model
    context only and do not grant retention, expiry, or promotion authority. *)
type category =
  | Code_change
  | Fact
  | Preference
  | Blocker
  | Goal
  | Constraint
  | Validated_approach
  | Lesson

(** Canonical lowercase token for a category. *)
val category_to_string : category -> string

(** All closed taxonomy categories that can be emitted by the librarian prompt. *)
val all_categories : category list

(** Parse an exact category token. Unknown or non-canonical tokens reject. *)
val category_of_string : string -> category option

(** A single semantic claim extracted from conversation history. *)
type fact =
  { claim : string
  ; category : category
  ; first_seen : float
  }

(** SHA-256 of the exact claim bytes. This derived identifier is used only for
    retention, duplicate rejection, and observability. *)
val memory_id : fact -> string

val fact_to_json : fact -> Yojson.Safe.t
val fact_of_json : Yojson.Safe.t -> fact option
