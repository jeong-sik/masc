module Window = Browser_ego_native_window
type unreleased = Receipt_with_dialog | Void_answer | Undeclared_answer | Never_returned
  | Native_window_unconfirmed of Window.unconfirmed | Conflicting_evidence
type resolution = Transient | Permanent
let resolution_to_wire = function Transient -> "transient" | Permanent -> "permanent"
type refusable_gesture = Click | Double_click | Drag_and_drop
type answer = Receipt_without_dialog | Native_window_tail of Window.completion
  | Refused_before_press of resolution | Unreleased of unreleased
type evidence = Receipt_step of int | Window_step of {index:int;completion:Window.completion}
type proof = Released_by_receipts of int list | Completed_by_evidence of evidence list
type settled = No_hold | Released of proof
type unconfirmed =
  | Step_not_released of { index : int; answer : unreleased }
  | Held_by_script_report
type t = Settled of settled | Unconfirmed of unconfirmed
let declared_members = ["popups"; "dialog"]
let popup_members = ["label"; "targetId"]
let popup_required_string_members = ["label"; "targetId"]
let receipt_contract =
  let strings values = `List (List.map (fun value -> `String value) values) in
  `Assoc ["declaredMembers",strings declared_members;"popupMembers",strings popup_members;
    "requiredPopupStringMembers",strings popup_required_string_members]
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
    && List.for_all (fun key -> nonempty_string_member key fields) popup_required_string_members
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
let resolution_error_name = "ElementResolutionError"
let resolution_of_wire = function
  | "transient" -> Some Transient
  | "permanent" -> Some Permanent
  | _ -> None
(* The gesture is matched so that only the three refusable gestures can ask. *)
let answer_of_refusal gesture value =
  match gesture with
  | Click | Double_click | Drag_and_drop ->
    match value with
    | `Assoc fields when distinct_members fields && List.length fields = 2 ->
      (match List.assoc_opt "name" fields, List.assoc_opt "kind" fields with
       | Some (`String name), Some (`String kind) when name = resolution_error_name ->
         (match resolution_of_wire kind with
          | Some resolution -> Refused_before_press resolution
          | None -> Unreleased Never_returned)
       | (None | Some _), (None | Some _) -> Unreleased Never_returned)
    | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Unreleased Never_returned
let answer_of_window ~expected completion =
  if Window.matches completion expected then Ok (Native_window_tail completion)
  else Error "native input completion belongs to another invocation"
let window_bindings = function
  | Released_by_receipts _ -> []
  | Completed_by_evidence evidence -> List.filter_map (function
      | Receipt_step _ -> None | Window_step {completion;_} -> Some (Window.binding completion)) evidence
let one_answer_per_step answers =
  let keep_the_stricter kept later = match kept with
    | Unreleased _ -> kept
    | Receipt_without_dialog -> (match later with
        | Receipt_without_dialog | Unreleased _ -> later
        | Native_window_tail _ | Refused_before_press _ -> Unreleased Conflicting_evidence)
    | Native_window_tail original -> (match later with
        | Unreleased _ -> later
        | Receipt_without_dialog | Refused_before_press _ -> Unreleased Conflicting_evidence
        | Native_window_tail next -> if Window.same_completion original next then kept
          else Unreleased Conflicting_evidence)
    | Refused_before_press _ -> (match later with
        | Unreleased _ -> later
        | Refused_before_press _ -> kept
        | Receipt_without_dialog | Native_window_tail _ -> Unreleased Conflicting_evidence) in
  List.fold_left (fun folded (index, answer) ->
    if List.mem_assoc index folded
    then List.map (fun (step, kept) -> if step = index then (step, keep_the_stricter kept answer) else (step, kept)) folded
    else folded @ [index, answer]) [] answers
let judge answers =
  let rec go first_window proven = function
    | [] ->
      (match List.rev proven with
       | [] -> Settled No_hold
       | _ :: _ as evidence ->
         let proof = match first_window with
           | None -> Released_by_receipts (List.filter_map (function
               | Receipt_step index -> Some index | Window_step _ -> None) evidence)
           | Some _ -> Completed_by_evidence evidence in
         Settled (Released proof))
    | (index, Receipt_without_dialog) :: rest -> go first_window (Receipt_step index :: proven) rest
    | (_, Refused_before_press _) :: rest -> go first_window proven rest
    | (index, Native_window_tail completion) :: rest ->
      let binding = Window.binding completion in
      let compatible = match first_window with
        | None -> true
        | Some (first:Window.binding) -> first.command_id=binding.command_id
          && first.generation=binding.generation && first.source=binding.source in
      if binding.step_index<>index || not compatible then
        Unconfirmed (Step_not_released {index;answer=Conflicting_evidence})
      else go (Some binding) (Window_step {index;completion}::proven) rest
    | (index, Unreleased answer) :: _ -> Unconfirmed (Step_not_released {index; answer}) in
  match one_answer_per_step answers with
  | [] -> Settled No_hold
  | _ :: _ as steps -> go None [] steps
let unreleased_description = function
  | Receipt_with_dialog -> "a dialog that cut it short"
  | Void_answer -> "void"
  | Undeclared_answer -> "a value the SDK does not declare"
  | Never_returned -> "nothing"
  | Native_window_unconfirmed _ -> "an unconfirmed native input window"
  | Conflicting_evidence -> "contradictory input-completion evidence"
let describe = function
  | Step_not_released {index; answer} -> Printf.sprintf "step %d answered %s" index (unreleased_description answer)
  | Held_by_script_report -> "the script reports a held input"
