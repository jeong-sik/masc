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

(* A branch is a closed object: it accepts exactly the members it declares, so
   a member a row action names either belongs to it or refuses it. *)
let closed_object = function
  | `Assoc fields when not (List.mem_assoc "oneOf" fields) ->
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
      (match List.assoc_opt "type" fields, List.assoc_opt "properties" fields,
             List.assoc_opt "oneOf" fields with
       | Some (`String "object"), None, Some (`List (_ :: _ as alternatives)) ->
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

let accepts branch (action : P.row_action) =
  let member_schema name =
    Option.to_result ~none:(Member_not_in_branch name) (List.assoc_opt name branch.properties) in
  let* _ = Lane_addon_json.traverse (fun (name, _) -> member_schema name) action.P.fixed in
  let* _ = Lane_addon_json.traverse (fun (name, _) -> member_schema name) action.P.from_row in
  let* _ = Lane_addon_json.traverse (fun (name, value) ->
      let* schema = member_schema name in
      Lane_addon_action.validate_input ~schema ~name value
      |> Result.map_error (fun _ -> Fixed_value_rejected name)) action.P.fixed in
  let taken name = List.mem_assoc name action.P.fixed || List.mem_assoc name action.P.from_row in
  Ok (List.filter_map (fun (name, _) ->
      if taken name then None else Some { name; required = List.mem name branch.required })
      branch.properties)

let judge ~tool_schema action =
  match Option.bind (action_object tool_schema) shape with
  | None -> Refused Schema_shape_unsupported
  | Some (Single branch) -> (match accepts branch action with
      | Ok human -> Offered { branch = None; human }
      | Error refusal -> Refused refusal)
  | Some (Union branches) ->
      let accepted = List.concat (List.mapi (fun index branch ->
          match accepts branch action with Ok human -> [ (index, human) ] | Error _ -> []) branches) in
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
let snapshot_fields ~actions ~tool_schema = match actions with
  | [] -> []
  | actions ->
      [ "row_actions", (match tool_schema with
          | None -> `Null
          | Some tool_schema -> `List (List.mapi (fun index action ->
              to_json ~index (judge ~tool_schema action)) actions)) ]
