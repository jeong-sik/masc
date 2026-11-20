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

type why_not =
  | Unknown_ref
  | Ref_used_twice
  | Source_outside_question
  | Removed_during_flight of { seq : int }
  | Not_valid_alone
  | Not_valid_in_room
  | Successor_unsupported

type t =
  { added : fact list
  ; touched : string list
  ; removed : (fact * removal) list
  ; not_applied : (int * why_not * Librarian_answer.new_fact option) list
  ; sources : (string * int list) list
  }

let empty = { added = []; touched = []; removed = []; not_applied = []; sources = [] }

let why_not_kind = function
  | Unknown_ref -> "unknown_ref"
  | Ref_used_twice -> "ref_used_twice"
  | Source_outside_question -> "source_outside_question"
  | Removed_during_flight _ -> "removed_during_flight"
  | Not_valid_alone -> "not_valid_alone"
  | Not_valid_in_room -> "not_valid_in_room"
  | Successor_unsupported -> "successor_unsupported"
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
  kept @ effects.added
;;
