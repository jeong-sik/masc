(** A Keeper the operator snapshot listed by name but could not turn into a
    row.

    The snapshot builds one row per Keeper name. When a row cannot be built,
    the Keeper still exists -- its name was listed -- so the snapshot reports
    it here instead of leaving it out of [items]. Readers count these next to
    the rows: a Keeper that vanished from the list reads the same as one that
    was never there (RFC-0462). *)

type reason =
  | Meta_read_failed of string
      (** The stored metadata did not read; the payload is the store's error. *)
  | Row_raised of string
      (** Building the row raised; the payload is the exception text. *)

type t = {
  name : string;
  reason : reason;
}

(** [{"name", "reason", "detail"}], [reason] one of [meta_read_failed],
    [row_raised]. *)
val to_json : t -> Yojson.Safe.t

(** Strict inverse of {!to_json}: a missing field, a non-string field, or a
    [reason] word outside the pair is an [Error]. *)
val of_json : Yojson.Safe.t -> (t, string) result

(** The key the operator snapshot's [keepers] section carries the list under. *)
val section_field : string

(** Reads [section_field] off a [keepers] section object. The section always
    carries it, so an absent or non-list value is an [Error], not an empty
    list. *)
val of_section : Yojson.Safe.t -> (t list, string) result

(** Reads a JSON list of {!to_json} values. *)
val list_of_json : Yojson.Safe.t -> (t list, string) result

(** Reads the list off a whole operator snapshot. A snapshot with no
    [keepers] section -- [`Null] before a snapshot function is registered, or
    a view that does not read Keepers -- listed no Keeper name, so none went
    unread and the result is [Ok []]. A [keepers] section without the list
    is an [Error]. *)
val of_snapshot : Yojson.Safe.t -> (t list, string) result
