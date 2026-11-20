module Lane = Librarian_memory_lane
module Outcome = Librarian_slot_outcome

type which =
  | With_memory
  | Alone

type judged =
  { question : Librarian_question_id.t
  ; facts : (Lane.slot_key * Outcome.size_fact) list
  }

type t =
  { with_memory : judged option
  ; alone : judged option
  }

let empty = { with_memory = None; alone = None }

let held t = function
  | With_memory -> t.with_memory
  | Alone -> t.alone
;;

let known t which question =
  match held t which with
  | Some judged when Librarian_question_id.equal judged.question question -> judged.facts
  | Some (_ : judged) | None -> []
;;

let size_fact : Outcome.unanswered -> Outcome.size_fact option = function
  | Refused (Sized fact) -> Some fact
  | Refused Unsized | Silent (_ : Outcome.silence) -> None
;;

let sized slots =
  List.filter_map
    (fun (key, outcome) -> Option.map (fun fact -> key, fact) (size_fact outcome))
    slots
;;

(* §7.4 「기록은 다른 질문 id 의 크기 사실이 올 때만 갈아 쓴다」. *)
let learn t which question slots =
  match sized slots with
  | [] -> t
  | fresh ->
    let renewed (key, (_ : Outcome.size_fact)) =
      List.exists (fun (fresh_key, (_ : Outcome.size_fact)) -> Lane.equal_slot_key key fresh_key)
        fresh
    in
    let facts =
      match held t which with
      | Some judged when Librarian_question_id.equal judged.question question ->
        fresh @ List.filter (fun fact -> not (renewed fact)) judged.facts
      | Some (_ : judged) | None -> fresh
    in
    (match which with
     | With_memory -> { t with with_memory = Some { question; facts } }
     | Alone -> { t with alone = Some { question; facts } })
;;

type verdict =
  | Input
  | All_not_input
  | Not_all

let fold (lane : Lane.t) slots =
  let fact_of key =
    List.find_map
      (fun (slot, outcome) -> if Lane.equal_slot_key slot key then size_fact outcome else None)
      slots
  in
  let facts = List.map fact_of (lane.http @ lane.cli) in
  let input : Outcome.size_fact option -> bool = function
    | Some Input_too_large -> true
    | Some (Output_over_reserve | Window_reached) | None -> false
  in
  (* A lane value walks one slot or more; one with none says nothing of any
     slot, so it is no verdict. *)
  match lane.unadmitted, facts with
  | _ :: _, (_ : Outcome.size_fact option list) | [], [] -> Not_all
  | [], (_ :: _ as facts) ->
    if List.exists Option.is_none facts
    then Not_all
    else if List.for_all input facts
    then Input
    else All_not_input
;;
