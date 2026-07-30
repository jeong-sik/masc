(** Keeper Memory OS current fact schema.

    The persisted shape is current-only and closed; version or compatibility
    fields reject. *)

(** Canonical JSON wire field names for Memory OS persistence and librarian
    ingestion. The schema module owns these strings so parser, retry prompt,
    persistence codec, and tests share one source. *)
val wire_field_trace_id : string
val wire_field_turn : string
val wire_field_tool_call_id : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_source : string
val wire_field_first_seen : string
val wire_field_last_verified_at : string
val wire_field_claim_id : string

val wire_field_source_turn : string
val wire_field_source_tool_call_id : string
val wire_field_open_items : string
val wire_field_constraints : string
val wire_field_preserved_tool_refs : string

(** Claim-object fields accepted from the librarian and rendered in retry
    prompts. *)
val wire_librarian_claim_fields : string list

(** Source attribution for a single extracted fact. *)
type provenance_event =
  { trace_id : string
  ; turn : int
  ; tool_call_id : string option
  }

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

(** A single semantic claim extracted from conversation history.

    RFC-0247 (purge): the fact carries only structure — claim, typed category,
    provenance, and producer timestamps. The
    deleted fields (confidence, access_count, last_accessed, stale_factor,
    expected_lifetime_cycles) fed the removed composite score; a fact's value is
    the librarian's judgment, not a number on the row. *)
type fact =
  { claim : string
  ; category : category
  ; source : provenance_event
  ; first_seen : float
  ; last_verified_at : float option
  ; claim_id : string option
    (** Optional producer-emitted stable conclusion id. It is preserved exactly;
        absent ids use exact observation identity, never normalized prose. *)
  }

(** Presentation timestamp: [last_verified_at] if set, else [first_seen]. Recall
    and dashboard share it for ordering, but it is not an expiry or truth
    boundary. *)
val reference_time : fact -> float

(** Producer identity SSOT. A non-empty [claim_id] is preserved exactly. When it
    is absent, identity uses the exact source event plus exact claim payload, so
    code never semantically normalizes or classifies prose. *)
val claim_identity : fact -> string

(** {1 JSON codecs} *)

val provenance_event_to_json : provenance_event -> Yojson.Safe.t
val provenance_event_of_json : Yojson.Safe.t -> provenance_event option

val fact_to_json : fact -> Yojson.Safe.t
val fact_of_json : Yojson.Safe.t -> fact option
