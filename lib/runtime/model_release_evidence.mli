(** Release recency is recommendation metadata, never account availability or a
    runtime admission gate. Provider listing timestamps are not release dates. *)
type date

val date_of_string : string -> (date, string) result
val date_to_string : date -> string
val three_month_cutoff : date -> date

type release_kind =
  | General_availability
  | Limited_release
  | Preview

type release =
  | Unknown (** Identity is not in the evidence file. *)
  | Evidence_unavailable of string
  (** The evidence file could not be read or decoded; carries the reason. *)
  | Official of
      { released_on : date
      ; kind : release_kind
      ; source_url : string
      ; checked_on : date
      }

(** Recommendation window in calendar months. Basis: a model released within
    the last three calendar months is presented as a recent release in the
    setup picker; older releases are still selectable. [three_month_cutoff]
    subtracts this many calendar months and the wire label
    [within_three_calendar_months] spells the same number in words. *)
val recency_window_months : int

type recency =
  | Unknown_release
  | Future_release
  | Within_three_months
  | Older_release

val recency : as_of:date -> release -> recency

type t

val of_json : Yojson.Safe.t -> (t, string) result

val of_string : string -> (t, string) result
(** Decodes one evidence file's contents; malformed JSON is an [Error]. *)

val load_default : unit -> (t, string) result

(** Exact publisher and complete model identity only; no prefix/alias inference.
    A failed load projects as [Evidence_unavailable] with its reason, never as
    [Unknown]. *)
val lookup : (t, string) result -> publisher:string -> model_id:string -> release

val to_json : as_of:date -> release -> Yojson.Safe.t

val catalog_to_json : as_of:date -> (t, string) result -> Yojson.Safe.t
(** Exact identities and their release evidence for a read-only picker. A failed
    load is [status: unavailable] with its [reason] and no models. *)

val current_date : unit -> date
(** UTC calendar date; never a model listing timestamp. *)

val default_catalog_json : unit -> Yojson.Safe.t
(** Unavailable embedded evidence is explicit and does not block model discovery. *)

val default_model_json : publisher:string -> model_id:string -> Yojson.Safe.t
