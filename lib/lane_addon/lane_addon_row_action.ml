(* RFC lane-row-offers-actions-filled-from-its-own-fields §2.3: the host judges
   each declared row action once against the action schema a worker advertises.
   The verdict is a projection of that schema; nothing stores it. *)
open Result.Syntax
module P = Lane_addon_presentation

type human_member = { name : string; required : bool }
type refusal =
  | Schema_shape_unsupported
  | No_branch_accepts
  | Several_branches_accept of int list
  | Member_not_in_branch of string
  | Fixed_value_rejected of string
type verdict =
  | Offered of { branch : int option; human : human_member list }
  | Refused of refusal

type branch = { properties : (string * Yojson.Safe.t) list; required : string list }
type shape = Single of branch | Union of branch list

let names = function
  | `List values -> List.fold_right (fun value names -> match value, names with
      | `String name, Some names -> Some (name :: names)
      | _, (Some _ | None) -> None) values (Some [])
  | _ -> None

(* A judged node carries only these keywords besides [title] and
   [description]. Any other keyword on it, such as an object [const] or
   [enum], limits the whole action in a way the members do not show, so the
   node is unsupported. *)
let only keywords fields =
  List.for_all (fun (key, _) -> List.mem key ("title" :: "description" :: keywords)) fields

(* A branch is a closed object: it accepts exactly the members it declares, so
   a member a row action names either belongs to it or refuses it. *)
let closed_object = function
  | `Assoc fields when only [ "type"; "properties"; "required"; "additionalProperties" ] fields ->
      (match List.assoc_opt "type" fields, List.assoc_opt "properties" fields,
             List.assoc_opt "additionalProperties" fields with
       | Some (`String "object"), Some (`Assoc properties), Some (`Bool false) ->
           (match List.assoc_opt "required" fields with
            | None -> Some { properties; required = [] }
            | Some required -> Option.map (fun required -> { properties; required }) (names required))
       | _ -> None)
  | _ -> None

(* Two shapes only: one closed object, or an object node that is nothing but a
   [oneOf] of closed objects. Any other shape could be judged Offered and then
   fail "exactly one alternative" on every send. *)
let shape = function
  | `Assoc fields when List.mem_assoc "oneOf" fields ->
      (match List.assoc_opt "type" fields, List.assoc_opt "oneOf" fields with
       | Some (`String "object"), Some (`List (_ :: _ as alternatives)) when only [ "type"; "oneOf" ] fields ->
           let branches = List.filter_map closed_object alternatives in
           if List.length branches = List.length alternatives then Some (Union branches) else None
       | _ -> None)
  | schema -> Option.map (fun branch -> Single branch) (closed_object schema)

(* The worker advertises the whole lane action tool; the action is its
   [action] property. *)
let action_object = function
  | `Assoc fields -> (match List.assoc_opt "properties" fields with
      | Some (`Assoc properties) -> List.assoc_opt "action" properties
      | _ -> None)
  | _ -> None

(* A fixed value is checked under the action tool's name, as a send checks
   that member, because the checker's rules depend on that name. *)
let accepts ~tool_name branch (action : P.row_action) =
  let member_schema name =
    Option.to_result ~none:(Member_not_in_branch name) (List.assoc_opt name branch.properties) in
  let* _ = Lane_addon_json.traverse (fun (name, _) -> member_schema name) action.P.fixed in
  let* _ = Lane_addon_json.traverse (fun (name, _) -> member_schema name) action.P.from_row in
  let* _ = Lane_addon_json.traverse (fun (name, value) ->
      let* schema = member_schema name in
      Lane_addon_action.validate_input ~schema ~name:tool_name value
      |> Result.map_error (fun _ -> Fixed_value_rejected name)) action.P.fixed in
  let taken name = List.mem_assoc name action.P.fixed || List.mem_assoc name action.P.from_row in
  Ok (List.filter_map (fun (name, _) ->
      if taken name then None else Some { name; required = List.mem name branch.required })
      branch.properties)

let judge ~tool_name ~tool_schema action =
  match Option.bind (action_object tool_schema) shape with
  | None -> Refused Schema_shape_unsupported
  | Some (Single branch) -> (match accepts ~tool_name branch action with
      | Ok human -> Offered { branch = None; human }
      | Error refusal -> Refused refusal)
  | Some (Union branches) ->
      let accepted = List.concat (List.mapi (fun index branch ->
          match accepts ~tool_name branch action with Ok human -> [ (index, human) ] | Error _ -> []) branches) in
      (match accepted with
       | [] -> Refused No_branch_accepts
       | [ (index, human) ] -> Offered { branch = Some index; human }
       | several -> Refused (Several_branches_accept (List.map fst several)))

let refusal_to_json = function
  | Schema_shape_unsupported -> `Assoc [ "reason", `String "schema_shape_unsupported" ]
  | No_branch_accepts -> `Assoc [ "reason", `String "no_branch_accepts" ]
  | Several_branches_accept branches ->
      `Assoc [ "reason", `String "several_branches_accept";
               "branches", `List (List.map (fun index -> `Int index) branches) ]
  | Member_not_in_branch member ->
      `Assoc [ "reason", `String "member_not_in_branch"; "member", `String member ]
  | Fixed_value_rejected member ->
      `Assoc [ "reason", `String "fixed_value_rejected"; "member", `String member ]

let to_json ~index = function
  | Offered { branch; human } ->
      `Assoc [ "index", `Int index;
               "offered", `Assoc [
                 "branch", Option.fold ~none:`Null ~some:(fun index -> `Int index) branch;
                 "human", `List (List.map (fun member ->
                     `Assoc [ "name", `String member.name; "required", `Bool member.required ]) human) ] ]
  | Refused refusal -> `Assoc [ "index", `Int index; "refused", refusal_to_json refusal ]

(* Written only for a package that declares row actions, so every other
   instance snapshot keeps its shape. [null] while no worker advertises an
   action schema: there is nothing to judge against yet. *)
let snapshot_fields ~actions ~tool = match actions with
  | [] -> []
  | actions ->
      [ "row_actions", (match tool with
          | None -> `Null
          | Some (tool_name, tool_schema) -> `List (List.mapi (fun index action ->
              to_json ~index (judge ~tool_name ~tool_schema action)) actions)) ]

(* Readers of what [to_json] writes. Members are compared after sorting, so a
   transport that reorders object members still reads the same verdict. *)
let sorted = function
  | `Assoc fields -> Some (List.sort (fun (left, _) (right, _) -> String.compare left right) fields)
  | _ -> None

let refusal_of_json json = match sorted json with
  | Some [ "reason", `String "schema_shape_unsupported" ] -> Ok Schema_shape_unsupported
  | Some [ "reason", `String "no_branch_accepts" ] -> Ok No_branch_accepts
  | Some [ "branches", `List branches; "reason", `String "several_branches_accept" ] ->
      Lane_addon_json.traverse (function
          | `Int index when index >= 0 -> Ok index
          | _ -> Error "row action refusal branches must be positions") branches
      |> Result.map (fun branches -> Several_branches_accept branches)
  | Some [ "member", `String member; "reason", `String "member_not_in_branch" ] ->
      Ok (Member_not_in_branch member)
  | Some [ "member", `String member; "reason", `String "fixed_value_rejected" ] ->
      Ok (Fixed_value_rejected member)
  | Some _ | None -> Error "row action verdict has an unknown refusal"

let offer_of_json json = match sorted json with
  | Some [ "branch", branch; "human", `List human ] ->
      let* branch = match branch with
        | `Null -> Ok None
        | `Int index when index >= 0 -> Ok (Some index)
        | _ -> Error "row action offer branch must be a position or null" in
      let* human = Lane_addon_json.traverse (fun member -> match sorted member with
          | Some [ "name", `String name; "required", `Bool required ] -> Ok { name; required }
          | Some _ | None -> Error "row action offer has a malformed human member") human in
      Ok (Offered { branch; human })
  | Some _ | None -> Error "row action verdict has a malformed offer"

let verdict_of_json ~index json = match sorted json with
  | Some [ "index", `Int position; "offered", offer ] when position = index -> offer_of_json offer
  | Some [ "index", `Int position; "refused", refusal ] when position = index ->
      Result.map (fun refusal -> Refused refusal) (refusal_of_json refusal)
  | Some [ "index", `Int _; ("offered" | "refused"), _ ] ->
      Error "row action verdicts are not in declaration order"
  | Some _ | None -> Error "row action verdict requires an index and an offer or a refusal"

let snapshot_of_json = function
  | `Null -> Ok None
  | `List values ->
      Lane_addon_json.traverse (fun (index, json) -> verdict_of_json ~index json)
        (List.mapi (fun index json -> index, json) values)
      |> Result.map Option.some
  | _ -> Error "row_actions must be null or a list"

type unfilled =
  | Not_offered of refusal
  | Row_value_absent of { member : string; path : string list }
  | Row_value_wrong_shape of { member : string; path : string list }
  | Row_value_rejected of { member : string; detail : string }
type filled = { branch : int option; locked : (string * Yojson.Safe.t) list }

(* The members of the alternative a verdict offers, read from the same schema
   the verdict was judged against. *)
let offered_members ~tool_schema offered =
  match Option.bind (action_object tool_schema) shape, offered with
  | Some (Single branch), None -> Some branch.properties
  | Some (Union branches), Some index when index >= 0 ->
      Option.map (fun (branch : branch) -> branch.properties) (List.nth_opt branches index)
  | Some (Single _), Some _ | Some (Union _), (Some _ | None) | None, (Some _ | None) -> None

(* Row values are checked under the action tool's name, as a send checks
   them. *)
let fill ~tool_name ~tool_schema verdict (action : P.row_action) fields =
  match verdict with
  | Refused refusal -> Error [ Not_offered refusal ]
  | Offered { branch; _ } ->
      match offered_members ~tool_schema branch with
      | None -> Error [ Not_offered Schema_shape_unsupported ]
      | Some properties ->
          let read (member, path) = match P.row_value path fields with
            | P.Absent -> Error (Row_value_absent { member; path })
            | P.Wrong_shape -> Error (Row_value_wrong_shape { member; path })
            | P.Present value -> (match List.assoc_opt member properties with
                | None -> Error (Not_offered (Member_not_in_branch member))
                | Some schema -> (match Lane_addon_action.validate_input ~schema ~name:tool_name value with
                    | Ok _ -> Ok (member, value)
                    | Error detail -> Error (Row_value_rejected { member; detail }))) in
          let values = List.map read action.P.from_row in
          (match List.filter_map (function Ok _ -> None | Error unfilled -> Some unfilled) values with
           | [] -> Ok { branch; locked = action.P.fixed @ List.filter_map Result.to_option values }
           | unfilled -> Error unfilled)
