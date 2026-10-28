type unreleased = Receipt_with_dialog | Void_answer | Undeclared_answer | Never_returned
type answer = Receipt_without_dialog | Unreleased of unreleased
type proof = Released_by_receipts of int list
type settled = No_hold | Released of proof
type unconfirmed =
  | Step_not_released of { index : int; answer : unreleased }
  | Held_by_script_report
type t = Settled of settled | Unconfirmed of unconfirmed
let declared_members = ["popups"; "dialog"]
let popup_members = ["label"; "targetId"]
let distinct_members fields =
  let names = List.map fst fields in
  List.length (List.sort_uniq String.compare names) = List.length names
let nonempty_string_member key fields = match List.assoc_opt key fields with
  | Some (`String text) -> text <> ""
  | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) -> false
let popup_declared = function
  | `Assoc fields ->
    distinct_members fields
    && List.for_all (fun (member, _) -> List.mem member popup_members) fields
    && nonempty_string_member "label" fields && nonempty_string_member "targetId" fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
let popups_declared fields = match List.assoc_opt "popups" fields with
  | None -> true
  | Some (`List popups) -> List.for_all popup_declared popups
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) -> false
let answer_of_json = function
  | `Assoc fields ->
    if not (distinct_members fields
            && List.for_all (fun (member, _) -> List.mem member declared_members) fields
            && popups_declared fields)
    then Unreleased Undeclared_answer
    else (match List.assoc_opt "dialog" fields with
      | None -> Receipt_without_dialog
      | Some (`Assoc _) -> Unreleased Receipt_with_dialog
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) -> Unreleased Undeclared_answer)
  | `Null -> Unreleased Void_answer
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Unreleased Undeclared_answer
let of_unreleased answer = Unreleased answer
let one_answer_per_step answers =
  let keep_the_stricter kept later = match kept with
    | Unreleased _ -> kept
    | Receipt_without_dialog -> later in
  List.fold_left (fun folded (index, answer) ->
    if List.mem_assoc index folded
    then List.map (fun (step, kept) -> if step = index then (step, keep_the_stricter kept answer) else (step, kept)) folded
    else folded @ [index, answer]) [] answers
let judge answers =
  let rec go proven = function
    | [] -> Settled (Released (Released_by_receipts (List.rev proven)))
    | (index, Receipt_without_dialog) :: rest -> go (index :: proven) rest
    | (index, Unreleased answer) :: _ -> Unconfirmed (Step_not_released {index; answer}) in
  match one_answer_per_step answers with
  | [] -> Settled No_hold
  | _ :: _ as steps -> go [] steps
let unreleased_description = function
  | Receipt_with_dialog -> "a dialog that cut it short"
  | Void_answer -> "void"
  | Undeclared_answer -> "a value the SDK does not declare"
  | Never_returned -> "nothing"
let describe = function
  | Step_not_released {index; answer} -> Printf.sprintf "step %d answered %s" index (unreleased_description answer)
  | Held_by_script_report -> "the script reports a held input"
