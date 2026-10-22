module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request

let ( let* ) = Result.bind

let text_schema = `Assoc ["type", `String "string"; "minLength", `Int 1]
let output_schema =
  `Assoc ["type", `String "object";
          "properties", `Assoc ["decisions", `Assoc
            ["type", `String "array"; "items", `Assoc
              ["type", `String "object";
               "properties", `Assoc
                 ["fact_id", text_schema;
                  "kind", `Assoc ["type", `String "string";
                     "enum", `List (List.map (fun kind -> `String kind)
                       ["join_claim"; "create_claim"; "join_conflict";
                        "create_conflict"; "exclude"])];
                  "value", text_schema];
               "required", `List [`String "fact_id"; `String "kind"; `String "value"];
               "additionalProperties", `Bool false]]];
          "required", `List [`String "decisions"];
          "additionalProperties", `Bool false]

let exact_fields what expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
                       = List.sort String.compare expected -> Ok fields
  | _ -> Error (what ^ " has unknown, missing, or repeated fields")

let field_text fields name =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error ("workspace curator decision " ^ name ^ " must be nonblank text")

let rec traverse f = function
  | [] -> Ok []
  | first :: rest ->
    let* value = f first in
    let* remaining = traverse f rest in
    Ok (value :: remaining)

module String_map = Map.Make (String)

let local_map pairs =
  List.fold_left (fun map (local, value) -> String_map.add local value map) String_map.empty pairs

let decode ~batch json =
  let* fields = exact_fields "workspace curator output" ["decisions"] json in
  let* rows = match List.assoc "decisions" fields with
    | `List rows -> Ok rows
    | _ -> Error "workspace curator decisions must be an array" in
  let selected = Request.selected_ids batch in
  let facts = local_map (List.map (fun (id, (pending : Ledger.pending_fact)) -> id, pending.fact) selected) in
  let claims = local_map (Request.claim_ids batch) in
  let conflicts = local_map (Request.conflict_ids batch) in
  let parse row =
    let* fields = exact_fields "workspace curator decision"
        ["fact_id"; "kind"; "value"] row in
    let* id = field_text fields "fact_id" in
    let* kind = field_text fields "kind" in
    let* value = field_text fields "value" in
    let* fact = match String_map.find_opt id facts with
      | Some fact -> Ok fact
      | None -> Error ("workspace curator named a fact outside the selected batch: " ^ id) in
    let shown what entries = match String_map.find_opt value entries with
      | Some ledger_id -> Ok ledger_id
      | None -> Error ("workspace curator named a " ^ what ^ " this request does not show: " ^ value) in
    let* decision = match kind with
      | "join_claim" -> let* claim_id = shown "claim" claims in Ok (Ledger.Join_claim claim_id)
      | "create_claim" -> Ok (Ledger.Create_claim value)
      | "join_conflict" -> let* conflict_id = shown "conflict" conflicts in Ok (Ledger.Join_conflict conflict_id)
      | "create_conflict" -> Ok (Ledger.Create_conflict value)
      | "exclude" -> Ok (Ledger.Exclude value)
      | _ -> Error ("unknown workspace curator decision kind: " ^ kind) in
    Ok ({ fact; decision } : Ledger.assignment) in
  let* assignments = traverse parse rows in
  if List.length assignments <> List.length selected
  then Error "workspace curator answer must classify every selected fact once"
  else
    let seen = List.map (fun (assignment : Ledger.assignment) -> assignment.fact) assignments in
    if List.length seen <> List.length (List.sort_uniq Stdlib.compare seen)
    then Error "workspace curator answer repeats a fact"
    else Ok assignments
