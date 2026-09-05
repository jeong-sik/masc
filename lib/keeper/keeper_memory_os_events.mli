(** Memory use events (RFC-0418).

    A memory strengthens when it is used, not when the same bytes are seen
    again. This module records the three uses masc can observe as typed events
    in a per-keeper append-only sidecar, [<keeper>.memory-events.jsonl], and
    projects them at read time. It stores no strength, score, or threshold;
    every number a consumer shows is computed from the events it reads.

    The sidecar is separate from the memory journal on purpose: the journal
    holds one line per librarian pass and is not read on the turn path, while
    [Retrieved] is written on the turn path by [keeper_memory_search]. Events
    outlive the fact they name; a dropped fact keeps its events and a reader
    attaches them only to facts that still exist. *)

(** What happened to the memory. A closed set: a new kind of use is a new
    constructor, and the compiler names every consumer that has to learn it. *)
type event_kind =
  | Retrieved of { query : string }
  (** The fact was among the results [keeper_memory_search] returned for
      [query]. *)
  | Cited of { tool : string }
  (** The fact's [memory_id] was a typed argument of a tool call to [tool].
      Ids found by scanning free text do not count. *)
  | Revised of { superseded_by : string }
  (** The librarian wrote a new claim that continues this fact and dropped this
      one; [superseded_by] is the new fact's [memory_id]. The producer is
      responsible for pairing this with the drop and for never letting a fact
      supersede itself. *)

type event =
  { recorded_at : float (** Unix seconds, the producer's clock. *)
  ; memory_id : string (** The fact this happened to. *)
  ; trace_id : string (** The turn it happened in; empty when there is none. *)
  ; kind : event_kind
  }

val suffix : string
val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

(** {1 Codec}

    One JSON object per line. [recorded_at], [memory_id], [trace_id], [kind]
    and exactly one payload field named by the kind ([query], [tool] or
    [superseded_by]); nothing else. The decoder rejects a missing, extra or
    duplicate field, an unknown kind token, a non-finite time, a string that is
    not a memory id where one is required, and a blank [query] or [tool]. *)

val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, Keeper_memory_os_types.wire_error) result

(** {1 Sidecar} *)

type append_error =
  | Invalid_event of Keeper_memory_os_types.wire_error
  (** The event fails the same checks the decoder applies; nothing was
      written. *)
  | Write_failed of
      { path : string
      ; message : string
      }

val append_error_to_string : append_error -> string

(** Validate, then append one line. The caller decides what a failure means on
    its path: a search that could not record its [Retrieved] still returns its
    results, and says so in its log. *)
val append : keepers_dir:string -> keeper_id:string -> event -> (unit, append_error) result

type read_error =
  | Not_json of string
  | Malformed of Keeper_memory_os_types.wire_error

val read_error_to_string : read_error -> string

(** Every non-blank line of the sidecar in file order, paired with its
    zero-based index among non-blank lines. A line this module cannot read
    stays in the list as an [Error] so a reader can count and name it instead
    of losing it. A missing file reads as no events. *)
val read : keepers_dir:string -> keeper_id:string -> (int * (event, read_error) result) list

(** {1 Projection} *)

type summary =
  { retrieved_count : int
  ; retrieved_distinct_days : int
  (** Distinct UTC calendar days on which the fact was retrieved. Spacing is
      shown as a count of days, not turned into a score. *)
  ; last_retrieved_at : float option
  ; cited_count : int
  ; revised_from : string list
  (** Memory ids of facts whose [Revised] event names this fact as their
      successor, sorted, without repeats. *)
  }

(** What the events say about one fact. Events about other facts are ignored
    except [Revised] events that point at [memory_id]. *)
val summary_for : memory_id:string -> event list -> summary
