module Proposal = Keeper_plan_proposal

type error =
  | Request_not_object
  | Duplicate_field of string
  | Unknown_field of string
  | Missing_field of string
  | Empty_assembler_run_id
  | Invalid_proposal_id of string
  | Approval_tools_not_array
  | Empty_approval_tools
  | Approval_tool_not_string of { index : int }
  | Empty_approval_tool of { index : int }

type assembler_run_id = string

module Assembler_run_id = struct
  type t = assembler_run_id

  let of_string = function
    | "" -> Error Empty_assembler_run_id
    | value -> Ok value
  ;;

  let to_string value = value
end

type t =
  { assembler_run_id : Assembler_run_id.t
  ; proposal_id : Proposal.Proposal_id.t
  ; approval_tools : string list
  }

let ( let* ) = Result.bind

let first_duplicate fields =
  let rec loop seen = function
    | [] -> None
    | (field, _) :: rest ->
      if List.mem field seen then Some field else loop (field :: seen) rest
  in
  loop [] fields
;;

let required fields field =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field field)
;;

let parse_proposal_id = function
  | `String value ->
    Proposal.Proposal_id.of_string value
    |> Result.map_error (fun Proposal.Proposal_id.Not_lowercase_sha256 ->
      Invalid_proposal_id value)
  | value -> Error (Invalid_proposal_id (Yojson.Safe.to_string value))
;;

let parse_assembler_run_id = function
  | `String value -> Assembler_run_id.of_string value
  | _ -> Error Empty_assembler_run_id
;;

let parse_approval_tools = function
  | `List [] -> Error Empty_approval_tools
  | `List values ->
    let rec loop index tools = function
      | [] -> Ok (List.rev tools)
      | `String "" :: _ -> Error (Empty_approval_tool { index })
      | `String value :: rest -> loop (index + 1) (value :: tools) rest
      | _ :: _ -> Error (Approval_tool_not_string { index })
    in
    loop 0 [] values
  | _ -> Error Approval_tools_not_array
;;

let of_yojson = function
  | `Assoc fields ->
    (match first_duplicate fields with
     | Some field -> Error (Duplicate_field field)
     | None ->
       (match
          List.find_opt
            (fun (field, _) ->
               not
                 (String.equal field "assembler_run_id"
                  || String.equal field "proposal_id"
                  || String.equal field "approval_tools"))
            fields
        with
        | Some (field, _) -> Error (Unknown_field field)
        | None ->
          let* assembler_run_id_json = required fields "assembler_run_id" in
          let* assembler_run_id = parse_assembler_run_id assembler_run_id_json in
          let* proposal_id_json = required fields "proposal_id" in
          let* proposal_id = parse_proposal_id proposal_id_json in
          let* approval_tools_json = required fields "approval_tools" in
          let* approval_tools = parse_approval_tools approval_tools_json in
          Ok { assembler_run_id; proposal_id; approval_tools }))
  | _ -> Error Request_not_object
;;

let assembler_run_id request = request.assembler_run_id
let proposal_id request = request.proposal_id
let approval_tools request = request.approval_tools

let error_to_yojson = function
  | Request_not_object -> `Assoc [ "kind", `String "request_not_object" ]
  | Duplicate_field field ->
    `Assoc [ "kind", `String "duplicate_field"; "field", `String field ]
  | Unknown_field field ->
    `Assoc [ "kind", `String "unknown_field"; "field", `String field ]
  | Missing_field field ->
    `Assoc [ "kind", `String "missing_field"; "field", `String field ]
  | Empty_assembler_run_id ->
    `Assoc [ "kind", `String "empty_assembler_run_id" ]
  | Invalid_proposal_id value ->
    `Assoc
      [ "kind", `String "invalid_proposal_id"; "value", `String value ]
  | Approval_tools_not_array ->
    `Assoc [ "kind", `String "approval_tools_not_array" ]
  | Empty_approval_tools ->
    `Assoc [ "kind", `String "empty_approval_tools" ]
  | Approval_tool_not_string { index } ->
    `Assoc
      [ "kind", `String "approval_tool_not_string"; "index", `Int index ]
  | Empty_approval_tool { index } ->
    `Assoc
      [ "kind", `String "empty_approval_tool"; "index", `Int index ]
;;
