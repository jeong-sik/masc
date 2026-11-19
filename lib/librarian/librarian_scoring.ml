open Keeper_memory_os_types
module Effects = Librarian_effects

type case =
  { name : string
  ; question : Librarian_question_id.t
  ; shown : Librarian_plan.shown
  ; facts : fact list
  ; planted : string list
  ; must_keep : (string * string list) list
  }

type reading =
  { ops : int
  ; not_applied : Effects.why_not list
  ; changed : bool
  ; recovered : int
  ; merge_expected : int
  ; merge_kept : int
  }

type scored =
  | Thrown_away of Librarian_answer.rejection
  | Read of reading

type tally =
  { answers : int
  ; thrown_away : (string * int) list
  ; ops : int
  ; not_applied : (string * int) list
  ; changed : int
  ; planted : int
  ; recovered : int
  ; merge_expected : int
  ; merge_kept : int
  }

let count predicate items = List.length (List.filter predicate items)
let said_in claim token = String_util.string_contains_substring ~needle:token claim

(* A score does not depend on when it is taken: the plan stamps new facts
   with this time and the scorer reads no time back. *)
let scoring_time = 0.0
let scoring_trace = "scoring"

let score case text =
  match Librarian_answer.of_string ~asked:case.question text with
  | Error rejection -> Thrown_away rejection
  | Ok answer ->
    let plan =
      Librarian_plan.of_answer ~shown:case.shown ~facts:case.facts ~removed_since:[]
        ~at:scoring_time ~trace_id:scoring_trace answer
    in
    let held_after token = List.exists (fun (fact : fact) -> said_in fact.claim token) plan.facts in
    let claim_of id =
      List.find_map
        (fun (fact : fact) -> if String.equal (memory_id fact) id then Some fact.claim else None)
        plan.facts
    in
    let merge_expected, merge_kept =
      List.fold_left
        (fun (expected, kept) ((fact : fact), (removal : Effects.removal)) ->
           match removal with
           | Merged_into successor ->
             let tokens =
               Option.value (List.assoc_opt (memory_id fact) case.must_keep) ~default:[]
             in
             let successor_claim = Option.value (claim_of successor) ~default:"" in
             ( expected + List.length tokens
             , kept + count (said_in successor_claim) tokens )
           | Dropped _ | Revised_into _ | Support_lost _ -> expected, kept)
        (0, 0)
        plan.effects.removed
    in
    Read
      { ops = List.length answer.ops
      ; not_applied =
          List.map
            (fun ((_ : int), why, (_ : Librarian_answer.new_fact option)) -> why)
            plan.effects.not_applied
      ; changed =
          (match plan.effects.added, plan.effects.removed with
           | [], [] -> false
           | _ :: _, _ | _, _ :: _ -> true)
      ; recovered = count held_after case.planted
      ; merge_expected
      ; merge_kept
      }
;;

let add_to label counts =
  let previous = Option.value (List.assoc_opt label counts) ~default:0 in
  (label, previous + 1) :: List.remove_assoc label counts
;;

let sorted counts =
  List.sort (fun (left, (_ : int)) (right, (_ : int)) -> String.compare left right) counts
;;

let tally scored =
  let total =
    List.fold_left
      (fun total ((case : case), scored) ->
         let total =
           { total with
             answers = total.answers + 1
           ; planted = total.planted + List.length case.planted
           }
         in
         match scored with
         | Thrown_away rejection ->
           { total with
             thrown_away = add_to (Librarian_answer.rejection_kind rejection) total.thrown_away
           }
         | Read { ops; not_applied; changed; recovered; merge_expected; merge_kept } ->
           { total with
             ops = total.ops + ops
           ; not_applied =
               List.fold_left
                 (fun counts why -> add_to (Effects.why_not_kind why) counts)
                 total.not_applied
                 not_applied
           ; changed = (total.changed + if changed then 1 else 0)
           ; recovered = total.recovered + recovered
           ; merge_expected = total.merge_expected + merge_expected
           ; merge_kept = total.merge_kept + merge_kept
           })
      { answers = 0
      ; thrown_away = []
      ; ops = 0
      ; not_applied = []
      ; changed = 0
      ; planted = 0
      ; recovered = 0
      ; merge_expected = 0
      ; merge_kept = 0
      }
      scored
  in
  { total with thrown_away = sorted total.thrown_away; not_applied = sorted total.not_applied }
;;

let tally_to_text tally =
  let sum counts = List.fold_left (fun total ((_ : string), n) -> total + n) 0 counts in
  let by_reason counts =
    List.map (fun (reason, n) -> Printf.sprintf "  %s %d" reason n) counts
  in
  String.concat "\n"
    ([ Printf.sprintf "answers %d" tally.answers
     ; Printf.sprintf "thrown away %d" (sum tally.thrown_away)
     ]
     @ by_reason tally.thrown_away
     @ [ Printf.sprintf "ops %d" tally.ops
       ; Printf.sprintf "ops left out %d" (sum tally.not_applied)
       ]
     @ by_reason tally.not_applied
     @ [ Printf.sprintf "answers that changed Memory %d" tally.changed
       ; Printf.sprintf "planted %d, in Memory afterwards %d" tally.planted tally.recovered
       ; Printf.sprintf "merged away %d, kept by the merge %d" tally.merge_expected
           tally.merge_kept
       ])
  ^ "\n"
;;
