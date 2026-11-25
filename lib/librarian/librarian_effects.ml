open Keeper_memory_os_types
module Ids = Set_util.StringSet

type actor =
  | Keeper
  | Operator of string

type removal =
  | Dropped of { reason : string }
  | Merged_into of string
  | Revised_into of string
  | Superseded_by of string
  | Retracted of
      { by : actor
      ; reason : string
      }
  | Support_lost of { missing : string list }
  | Molted of { reason : string }

type why_not =
  | Unknown_ref
  | Ref_used_twice
  | Source_outside_question
  | Source_reserved_for_personal_memory
  | Removed_during_flight of { seq : int }
  | Not_valid_alone
  | Not_valid_in_room
  | Successor_unsupported
  | Promotion_refused

type t =
  { added : fact list
  ; touched : string list
  ; removed : (fact * removal) list
  ; not_applied : (int * why_not * Librarian_answer.new_fact option) list
  ; sources : (string * int list) list
  ; promotions : Librarian_lifecycle.world_promotion list
  }

let empty =
  { added = []
  ; touched = []
  ; removed = []
  ; not_applied = []
  ; sources = []
  ; promotions = []
  }
;;

let ordinary_projection effects =
  { effects with
    added = List.filter is_ordinary effects.added
  ; removed = List.filter (fun (fact, _) -> is_ordinary fact) effects.removed
  ; touched = List.filter is_ordinary_memory_id effects.touched
  ; sources = List.filter (fun (id, _) -> is_ordinary_memory_id id) effects.sources
  }
;;

let why_not_kind = function
  | Unknown_ref -> "unknown_ref"
  | Ref_used_twice -> "ref_used_twice"
  | Source_outside_question -> "source_outside_question"
  | Source_reserved_for_personal_memory -> "source_reserved_for_personal_memory"
  | Removed_during_flight _ -> "removed_during_flight"
  | Not_valid_alone -> "not_valid_alone"
  | Not_valid_in_room -> "not_valid_in_room"
  | Successor_unsupported -> "successor_unsupported"
  | Promotion_refused -> "promotion_refused"
;;

let add_facts kept added =
  let ordinary, personal = List.partition is_ordinary added in
  List.fold_left Keeper_memory_os_support_core.insert_or_reobserve (kept @ ordinary) personal
;;

let apply ~at facts effects =
  let removed =
    List.fold_left
      (fun ids (fact, (_ : removal)) -> Ids.add (memory_id fact) ids)
      Ids.empty
      effects.removed
  in
  let touched = Ids.of_list effects.touched in
  let kept =
    List.filter_map
      (fun fact ->
         let id = memory_id fact in
         if Ids.mem id removed
         then None
         else if Ids.mem id touched
         then Some { fact with last_seen = Float.max fact.last_seen at }
         else Some fact)
      facts
  in
  add_facts kept effects.added
;;
