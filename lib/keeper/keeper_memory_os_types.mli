(** Keeper Memory OS current fact schema.

    The persisted shape is current-only and closed; version or compatibility
    fields reject. *)

(** Canonical JSON wire field names for Memory OS persistence and librarian
    ingestion. The schema module owns these strings so parser, retry prompt,
    persistence codec, and tests share one source. *)
val wire_field_claim : string
val wire_field_category : string
val wire_field_memory_id : string
val wire_field_reason : string

(** Claim-object fields accepted from the librarian and rendered in retry
    prompts. *)
val wire_librarian_claim_fields : string list

(** Dropped-statement object fields accepted from the librarian. *)
val wire_librarian_dropped_fields : string list

(** The librarian's explicit reason for dropping one existing memory.
    [memory_id] names a fact in the current snapshot; [reason] is one
    non-empty sentence. Statements ride the journal line of the commit
    they explain; the snapshot codec never stores them. *)
type dropped_statement =
  { memory_id : string
  ; reason : string
  }

val dropped_statement_to_json : dropped_statement -> Yojson.Safe.t

(** Inverse of {!dropped_statement_to_json}. Field-exact: an object carrying
    anything besides [memory_id] and [reason] is [None] rather than being
    read past, so a journal line written by a build with a wider statement
    shape does not decode as this one. *)
val dropped_statement_of_json : Yojson.Safe.t -> dropped_statement option

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

(** Row-level provenance. [Authored]: explicit keeper memory_write.
    [Injected]: librarian extraction (a copy of what the keeper already
    saw — the feed the self-referential reinjection loop runs on).
    [Legacy]: rows written before this field existed; provenance unknown,
    never back-filled with a guess. *)
type origin_kind =
  | Authored
  | Injected
  | Legacy

type origin =
  { kind : origin_kind
  ; trace_id : string
  }

(** Canonical lowercase token for an origin kind. Category tokens only —
    this never renders a unique identity into a prompt (masc#29558). *)
val origin_kind_to_string : origin_kind -> string

(** A single semantic claim extracted from conversation history.
    [first_seen] insertion (authoritative, preserved across re-upsert);
    [last_seen] most recent re-observation of the same claim bytes —
    the eviction ordering key; [reinforcement] re-observation count of the
    exact claim bytes, the measurable damper on byte-identical reinjection. *)
type fact =
  { claim : string
  ; category : category
  ; first_seen : float
  ; last_seen : float
  ; reinforcement : int
  ; origin : origin
  }

(** SHA-256 of the exact claim bytes. This derived identifier is used only for
    retention, duplicate rejection, and observability. *)
val memory_id : fact -> string

val fact_to_json : fact -> Yojson.Safe.t

(** Inverse of {!fact_to_json}. Accepts both the current six-field row and
    the legacy three-field row; a legacy row decodes with [Legacy] origin,
    [last_seen = first_seen], [reinforcement = 0]. A row mixing the two
    vocabularies rejects rather than being read past. *)
val fact_of_json : Yojson.Safe.t -> fact option
