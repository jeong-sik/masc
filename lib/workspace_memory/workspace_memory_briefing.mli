(** Durable shared semantic briefing, independent of the classification ledger.
    One serialized Curator owner prepares and accepts batches. Keepers only
    observe the last completely published summary. *)

type kind = Claim | Conflict
type source = { id : string; kind : kind; text : string }
type summary = { source_ids : string list; text : string }
type t
type observation = Missing | Current of summary | Stale of summary

val empty : t
val path : directory:string -> string
val load : directory:string -> (t, string) result
val save : directory:string -> t -> (unit, string) result
(** Missing file is [empty]; malformed state and I/O failures are errors.
    Writes use strict atomic replacement. Eio cancellation propagates. *)

val observe : sources:source list -> t -> observation
(** Freshness compares the exact set of (id, kind, text) identities, independent
    of source order. Reusing an id with changed content makes the summary stale.
    No published summary means [Missing]. The empty source set is the exception:
    it is always [Current {source_ids = []; text = ""}], where empty text means
    there is no workspace evidence to summarize, not a failed model response.
    This read does not depend on the worker's prompt contract. *)

val needs_refresh : sources:source list -> contract:string -> t -> bool
(** False for empty evidence or an identical published source/contract set.
    The worker may skip provider admission entirely in that case. *)

type batch
val input : batch -> Yojson.Safe.t
val rendered_prompt : batch -> string
val selected_count : batch -> int
val remaining_count : batch -> int
val prepared_state : batch -> t
(** Save this state before calling the model to retain the fixed pass target.
    New additions wait for the next pass; removal or modification of a target
    source resets the pass on the next [prepare]. *)

val prepare
  : sources:source list
  -> contract:string
  -> max_input_bytes:int
  -> render:(Yojson.Safe.t -> (string, string) result)
  -> t
  -> (batch option, string) result
(** [contract] identifies the effective prompt and output schema. A changed
    contract rebuilds from current entries, without reusing the old summary.
    Additions alone reuse the previous summary and send only new entries.
    Deletions or changed source contents rebuild without old summary prose.
    Model input contains only [previous_summary] and selected [entries].
    Selects a nonempty prefix that fits the actual rendered provider input
    bound; an entry that cannot fit is an explicit error. Sources must have
    unique, nonblank ids and nonblank text. No new evidence (or no sources)
    returns [Ok None] without rendering or model work. *)

val output_schema : Yojson.Safe.t
val decode_output : Yojson.Safe.t -> (string, string) result
(** Exactly [{"briefing": <nonblank string>}], with no additional fields. *)

val accept : batch -> text:string -> (t, string) result
(** Reject blank output. A successful chunk advances only its fixed pass;
    the previous publication survives until the entire pass completes.
    Save the returned state before scheduling the next wake. If inference or
    saving fails, reload the last successful save rather than consuming work. *)
