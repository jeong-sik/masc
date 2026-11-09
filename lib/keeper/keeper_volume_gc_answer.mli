(** The [masc_sandbox_volume_gc] answer: the {!Keeper_volume_gc.report} as
    the tool writes it, and as a reader such as the TUI reads it back.

    Each keeper carries a closed [outcome_kind] next to the sentence
    {!Keeper_volume_gc.keeper_outcome_to_string} writes for the operator. A
    reader decides from the kind and only shows the sentence, so no reader
    matches on the words of a sentence. The tool and the reader use this one
    module, so the two sides cannot disagree on a field. *)

type outcome_kind =
  | Kept
  | Reclaim_candidate
  | Reclaimed
  | Reclaim_failed

type verdict =
  { keeper_name : string
  ; work_volume : string option
  ; build_volume : string option
  ; kind : outcome_kind
  ; outcome : string  (** The operator's sentence for the outcome. *)
  }

type t =
  { executed : bool
        (** The call asked to reclaim the keepers it named ([execute]). *)
  ; image_given : bool
        (** A claims image was given. Without one no marker is read, and an
            unowned keeper is kept as unverified. *)
  ; foreign_volumes : string list
  ; keepers : verdict list
  ; unlisted_keepers : string list
        (** Named keepers the volume listing did not show; nothing was
            deleted for them. Empty when [executed] is false. *)
  }

type summary =
  { kept : int
  ; reclaim_candidates : int
  ; reclaimed : int
  ; reclaim_failed : int
  }

val of_report : executed:bool -> image_given:bool -> Keeper_volume_gc.report -> t

(** Counted from the keepers. *)
val summary : t -> summary

(** The names of the keepers judged reclaim candidates, in answer order. *)
val reclaim_candidates : t -> string list

(** The object the tool answers with. The summary is written too, counted
    from the keepers. *)
val to_json : t -> Yojson.Safe.t

(** Refuses a missing, duplicate or unknown field, an unknown
    [outcome_kind], a blank keeper name or volume name, an unlisted keeper on
    an answer that did not execute, and a summary that does not match the
    keepers. *)
val of_json : Yojson.Safe.t -> (t, string) result
