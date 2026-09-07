(** Keyset cursor for [keeper_tasks_list] pages.

    A page is the first [limit] rows ordered by [(priority, created_at, id)],
    strictly after the cursor's key. A row inserted or removed between two
    calls neither shifts nor duplicates the rows a later page returns, which
    an offset would do. The cursor also carries the filter it was issued
    under; a cursor handed to a call with a different filter would page
    through a different ordered set, so it is refused rather than reinterpreted.

    The string form is opaque to the caller: base64url of canonical JSON. A
    string this module did not issue decodes to [Cursor_unparseable]; nothing
    falls back to the first page. *)

type page_key =
  { priority : int
  ; created_at : string
  ; id : string
  }

type filter =
  { status : string option
  ; include_done : bool
  ; projection : string
  }

type t =
  { after : page_key
  ; filter : filter
  }

type error =
  | Cursor_unparseable
  | Cursor_filter_mismatch of
      { cursor : filter
      ; call : filter
      }

val compare_key : page_key -> page_key -> int
(** Total order: priority ascending, then created_at, then id. *)

val to_string : t -> string
val of_string : call:filter -> string -> (t, error) result

val to_yojson : t -> Yojson.Safe.t
(** The canonical JSON the string form encodes; also what the revision hash
    covers so a later page never answers [unchanged] for an earlier one. *)

val rejection_json : error -> Yojson.Safe.t
(** The typed rejection a caller reads: [ok=false], [field="cursor"],
    [error_kind], and both filters when they disagree. *)
