(** Keeper Memory OS current fact schema. The persisted shape is closed and
    unknown fields reject. *)

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

(** {1 Decode rejections}

    A decoder that answers [None] tells its caller only that something is
    wrong. Reading a snapshot the runtime had refused meant re-deriving this
    decoder by hand to find out which row and field it was (#32239 recovery),
    so every rejection now carries a path and a named reason. *)

(** One step of the path to a rejected node, outermost first. *)
type wire_step =
  | Wire_field of string
  | Wire_index of int

(** Why one node did not decode. Closed, so a new rejection has to name itself
    here before a decoder can make it. [Not_ascending] and [Not_positive] are
    produced only by the snapshot codec in {!Keeper_memory_os_current}, which
    shares this vocabulary rather than keeping a parallel one. *)
type wire_reason =
  | Expected_object
  | Expected_array
  | Expected_string
  | Expected_int
  | Expected_number
  | Duplicate_field of string
  | Field_set_mismatch of
      { missing : string list
      ; unexpected : string list
      }
  | Unknown_token of string
  | Blank_string
  | Not_a_memory_id of string
  | Not_a_board_post_id of string
  | Not_a_board_comment_id of string
  | Not_finite
  | Negative
  | Not_positive
  | Empty_list
  | Not_ascending
  | Duplicate_entry of string

type wire_error =
  { path : wire_step list
  ; reason : wire_reason
  }

(** One line naming the path and the reason, for a log or an operator surface.
    [<root>] is the document itself. *)
val wire_error_to_string : wire_error -> string

(** Reject at [path] relative to the decoder that calls it. *)
val wire_fail : wire_step list -> wire_reason -> ('a, wire_error) result

(** {!wire_fail} at the node itself. *)
val wire_here : wire_reason -> ('a, wire_error) result

(** Prefix [step] onto a nested decoder's path, so each decoder reports
    relative to itself and its caller places the result. *)
val wire_at : wire_step -> ('a, wire_error) result -> ('a, wire_error) result

(** {!wire_at} for the [index]th element of the array field [field]. *)
val wire_at_element
  :  string
  -> int
  -> ('a, wire_error) result
  -> ('a, wire_error) result

(** [Ok ()] only when the object's fields are exactly [names]: no duplicate,
    nothing missing, nothing extra. The rejection names which side is wrong. *)
val exact_field_names_result
  :  string list
  -> (string * Yojson.Safe.t) list
  -> (unit, wire_error) result

(** Typed readers for a field the caller has already proven present. An absent
    field is reported as missing rather than raised: the two checks disagreeing
    is a rejection like any other. *)
val wire_string_field
  :  string
  -> (string * Yojson.Safe.t) list
  -> (string, wire_error) result

val wire_int_field
  :  string
  -> (string * Yojson.Safe.t) list
  -> (int, wire_error) result

(** Accepts a JSON integer as well as a float, because a whole-numbered
    timestamp serializes without a decimal point. *)
val wire_number_field
  :  string
  -> (string * Yojson.Safe.t) list
  -> (float, wire_error) result

val wire_list_field
  :  string
  -> (string * Yojson.Safe.t) list
  -> (Yojson.Safe.t list, wire_error) result

(** The raw value, for a field whose own decoder reports its shape. *)
val wire_json_field
  :  string
  -> (string * Yojson.Safe.t) list
  -> (Yojson.Safe.t, wire_error) result

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
    anything besides [memory_id] and [reason] is rejected rather than being
    read past, so a journal line written by a build with a wider statement
    shape does not decode as this one. *)
val dropped_statement_of_json
  :  Yojson.Safe.t
  -> (dropped_statement, wire_error) result

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
    saw — the feed the self-referential reinjection loop runs on). *)
type origin_kind =
  | Authored
  | Injected

type origin =
  { kind : origin_kind
  ; trace_id : string
  }

(** One independently sufficient proof of a derived fact. Every [premise_id]
    is the exact {!memory_id} of another current fact. [rule_id] is an opaque
    producer-owned identity used for explanation and rule evolution; Memory OS
    never branches on its spelling. *)
type derivation =
  { rule_id : string
  ; premise_ids : string list
  }

(** Where an observed fact was read from. [Transcript] is the keeper's own
    turn history, which was the only source before Board provenance existed.
    [Board] names the post, and optionally the comment, the claim was taken
    from, so a later turn can open the source with the Board tools and a
    measurement can count how much Board knowledge reaches a store instead of
    guessing from a post id that happens to appear in the claim text. The ids
    are the Board's own parsed identities, so a reference that fails the Board
    grammar cannot be built. Whether the post still exists is not checked by
    any reader today; RFC-0401 piece 2 revalidates at recall the way a
    source-bound fact is revalidated against its file. *)
type board_ref =
  { post_id : Board_types.Post_id.t
  ; comment_id : Board_types.Comment_id.t option
  }

type observation =
  | Transcript
  | Board of board_ref

(** Why a fact belongs to maintained current knowledge. [Observed] facts are
    base facts selected from evidence, and carry where that evidence was read.
    [Derived] facts stay current while at least one derivation has all of its
    premises current. The non-empty derivation and premise invariants are
    enforced at construction and decode boundaries. *)
type basis =
  | Observed of observation
  | Derived of derivation list

(** A Board reference whose ids satisfy the Board id grammar. The error names
    the field that failed. *)
val board_ref_of_ids
  :  post_id:string
  -> comment_id:string option
  -> (board_ref, wire_error) result

val wire_field_board : string
val wire_field_post_id : string
val wire_field_comment_id : string

(** Optional librarian claim fields naming a Board source. *)
val wire_field_board_post_id : string
val wire_field_board_comment_id : string

val basis_to_json : basis -> Yojson.Safe.t

(** Decode a basis; the exact field set of each shape is enforced. *)
val basis_of_json : Yojson.Safe.t -> (basis, wire_error) result

val wire_field_kind : string

(** Canonical lowercase token for an origin kind. Category tokens only —
    this never renders a unique identity into a prompt (masc#29558). *)
val origin_kind_to_string : origin_kind -> string

(** A single semantic claim extracted from conversation history.
    [first_seen] insertion (authoritative, preserved across re-upsert);
    [last_seen] most recent re-observation of the same claim bytes;
    [reinforcement] re-observation count of the
    exact claim bytes, the measurable damper on byte-identical reinjection. *)
type fact =
  { claim : string
  ; category : category
  ; first_seen : float
  ; last_seen : float
  ; reinforcement : int
  ; origin : origin
  ; basis : basis
  }

(** A claim observed for the first time. [first_seen] and [last_seen] are both
    [now] and [reinforcement] is zero, because a row seen once has been seen
    once.

    The three identity fields move together, and this is the one place that
    says how. Spelled at each construction site instead, the invariant would
    live in as many copies as there are fixtures. *)
val observed
  :  claim:string
  -> category:category
  -> now:float
  -> origin:origin
  -> fact

(** A derived claim with one or more independently sufficient proof paths.
    Empty derivation lists, empty premise lists, duplicate premise ids, and
    blank or duplicate rule ids are rejected. Premise ids are canonicalized as
    a set in lexical order. *)
val derived
  :  claim:string
  -> category:category
  -> now:float
  -> origin:origin
  -> derivations:derivation list
  -> (fact, string) result

(** True only for the canonical [sha256:] prefix followed by exactly 64
    lowercase hexadecimal characters. *)
val is_memory_id : string -> bool

(** SHA-256 of the exact claim bytes. This derived identifier is used only for
    retention, duplicate rejection, and observability. *)
val memory_id : fact -> string

val fact_to_json : fact -> Yojson.Safe.t

(** Inverse of {!fact_to_json}. The current shape is closed and field-exact.
    A rejection names the field it failed on, which is how a refused snapshot
    row is read without re-deriving this decoder. *)
val fact_of_json : Yojson.Safe.t -> (fact, wire_error) result
