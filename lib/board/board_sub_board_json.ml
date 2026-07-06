(* Sub-board JSON serializer + member-list parser.

   - Access mode <-> string conversion ([sub_board_access] variant).
   - [sub_board] record <-> Yojson.Safe.t (used by HTTP routes, the
     board tool surface, and the JSONL store rewrite path).
   - Owner-injecting member-list parser (strict + lenient).

   Extracted from [Board_core] (godfile decomp). Pure mapping. *)

open Board_types

let sub_board_access_to_string = function
  | Open -> "open"
  | Members_only -> "members_only"
  | Owner_only -> "owner_only"
;;

let sub_board_access_of_string_opt = function
  | "open" -> Some Open
  | "members_only" -> Some Members_only
  | "owner_only" -> Some Owner_only
  | _ -> None
;;

let sub_board_to_yojson (sb : sub_board) : Yojson.Safe.t =
  `Assoc
    [ "id", `String (Sub_board_id.to_string sb.id)
    ; "slug", `String sb.slug
    ; "name", `String sb.name
    ; "description", `String sb.description
    ; "owner", `String (Agent_id.to_string sb.owner)
    ; "members", `List (List.map (fun id -> `String (Agent_id.to_string id)) sb.members)
    ; "access", `String (sub_board_access_to_string sb.access)
    ; "created_at", `Float sb.created_at
    ; "post_count", `Int sb.post_count
    ]
;;

let dedupe_agent_ids ids =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | id :: rest ->
      let name = Agent_id.to_string id in
      if List.mem name seen
      then loop seen acc rest
      else loop (name :: seen) (id :: acc) rest
  in
  loop [] [] ids
;;

let parse_sub_board_members ~owner members =
  let rec loop acc = function
    | [] -> Ok (dedupe_agent_ids (owner :: List.rev acc))
    | member_name :: rest ->
      (match Agent_id.of_string member_name with
       | Ok member_id -> loop (member_id :: acc) rest
       | Error e -> Error e)
  in
  loop [] members
;;

type sub_board_member_parse_error =
  { member_name : string
  ; error : board_error
  }

type sub_board_members_parse_report =
  { members : Agent_id.t list
  ; errors : sub_board_member_parse_error list
  }

type sub_board_json_report =
  { sub_board : sub_board option
  ; member_errors : sub_board_member_parse_error list
  }

let parse_sub_board_members_lenient_report ~owner members =
  let parsed_rev, errors_rev =
    members
    |> List.fold_left
         (fun (parsed_rev, errors_rev) member_name ->
    match Agent_id.of_string member_name with
    | Ok member_id -> member_id :: parsed_rev, errors_rev
    | Error error ->
      parsed_rev, { member_name; error } :: errors_rev)
         ([], [])
  in
  { members = dedupe_agent_ids (owner :: List.rev parsed_rev)
  ; errors = List.rev errors_rev
  }
;;

let parse_sub_board_members_lenient ~owner members =
  (parse_sub_board_members_lenient_report ~owner members).members
;;

let sub_board_of_yojson_report (json : Yojson.Safe.t) : sub_board_json_report =
  let open Safe_ops in
  match json with
  | `Assoc _ ->
    let id_s = json_string_opt "id" json |> Option.value ~default:"" in
    let slug = json_string_opt "slug" json |> Option.value ~default:"" in
    let name = json_string_opt "name" json |> Option.value ~default:"" in
    let description = json_string_opt "description" json |> Option.value ~default:"" in
    let owner_s = json_string_opt "owner" json |> Option.value ~default:"" in
    let access_s = json_string_opt "access" json |> Option.value ~default:"open" in
    let created_at = json_float_opt "created_at" json |> Option.value ~default:0.0 in
    let post_count = json_int_opt "post_count" json |> Option.value ~default:0 in
    let member_names = json_string_list "members" json in
    (match
       ( Sub_board_id.of_string id_s
       , Agent_id.of_string owner_s
       , sub_board_access_of_string_opt access_s )
     with
     | Ok id, Ok owner, Some access when slug <> "" ->
       let report = parse_sub_board_members_lenient_report ~owner member_names in
       { sub_board =
           Some
             { id
             ; slug
             ; name
             ; description
             ; owner
             ; members = report.members
             ; access
             ; created_at
             ; post_count
             }
       ; member_errors = report.errors
       }
     | _ -> { sub_board = None; member_errors = [] })
  | _ -> { sub_board = None; member_errors = [] }
;;

let sub_board_of_yojson (json : Yojson.Safe.t) : sub_board option =
  (sub_board_of_yojson_report json).sub_board
;;
