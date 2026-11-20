(** The facts that left a Keeper's Memory, as [keeper_memory_search] shows
    them for [source=absorbed], [source=dropped] and [source=all]
    (RFC librarian-call-only-proposes §11.5).

    Every reading scans the Keeper's commit log ({!Librarian_archive}). A
    fact the log last saw leaving is here; a fact added again after it left,
    or one current Memory holds, is not. The log starts at the cut, so a fact
    removed before it is not here either. Nothing here writes. *)

(** How another fact took a fact's place. *)
type how =
  | Merged (** An answer merged it into another fact. *)
  | Revised (** An answer revised it into another fact. *)
  | Superseded (** A write superseded it with another claim. *)

(** A fact another fact now says ([source=absorbed]). *)
type absorbed =
  { left : Librarian_archive.left
  ; how : how
  ; into : string
  (** Where the fact went. The memory id its removal names, followed while
      that fact left for another fact too. The walk stops at a current fact,
      at a fact that left with nothing in its place or that the log never
      removed, and before a fact it already passed. *)
  ; into_current : bool (** [into] is a fact current Memory holds. *)
  }

(** Why a fact left with nothing in its place. *)
type why =
  | Dropped of { reason : string } (** An answer dropped it. *)
  | Retracted of
      { by : Librarian_effects.actor
      ; reason : string
      }
  | Support_lost of { missing : string list }
  (** A derived fact whose premises left. [missing] names them. *)

(** A fact that left with nothing in its place ([source=dropped]). *)
type dropped =
  { left : Librarian_archive.left
  ; why : why
  }

type t =
  { absorbed : absorbed list
  ; dropped : dropped list
  (** Both in the order of the lines that removed them. *)
  ; unreadable : int
  (** Commit log lines that do not decode. What they removed is not known,
      so an absence here is not proof when this is not 0. *)
  }

(** [current] is what the snapshot holds now. A missing log is a log with no
    line. The error is the scan's, already a sentence. *)
val read
  :  keepers_dir:string
  -> keeper_id:string
  -> current:Keeper_memory_os_types.fact list
  -> (t, string) result

val absorbed_to_json : absorbed -> Yojson.Safe.t
val dropped_to_json : dropped -> Yojson.Safe.t
