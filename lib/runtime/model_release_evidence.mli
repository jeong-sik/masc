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
  | Unknown
  | Official of
      { released_on : date
      ; kind : release_kind
      ; source_url : string
      ; checked_on : date
      }

type recency =
  | Unknown_release
  | Future_release
  | Within_three_months
  | Older_release

val recency : as_of:date -> release -> recency

type t

val of_json : Yojson.Safe.t -> (t, string) result
val load_default : unit -> (t, string) result

(** Exact publisher and complete model identity only; no prefix/alias inference. *)
val lookup : t -> publisher:string -> model_id:string -> release

val to_json : as_of:date -> release -> Yojson.Safe.t

val catalog_to_json : as_of:date -> t -> Yojson.Safe.t
(** Exact identities and their release evidence for a read-only picker. *)

val current_date : unit -> date
(** UTC calendar date; never a model listing timestamp. *)

val default_catalog_json : unit -> Yojson.Safe.t
(** Unavailable embedded evidence is explicit and does not block model discovery. *)

val default_model_json : publisher:string -> model_id:string -> Yojson.Safe.t
