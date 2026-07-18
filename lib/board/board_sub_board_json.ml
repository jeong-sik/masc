(* Sub-board JSON serializer + member-list parser.

   - Access mode <-> string conversion ([sub_board_access] variant).
   - [sub_board] record <-> Yojson.Safe.t (used by HTTP routes, the
     board tool surface, and the JSONL store rewrite path).
   - Owner-injecting member-list parser.

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

let sub_board_of_yojson (json : Yojson.Safe.t) : sub_board option =
  let open Safe_ops in
  match json with
  | `Assoc _ ->
    (match
       ( json_string_opt "id" json
       , json_string_opt "slug" json
       , json_string_opt "name" json
       , json_string_opt "description" json
       , json_string_opt "owner" json
       , json_member_opt "members" json
       , json_string_opt "access" json
       , json_float_opt "created_at" json
       , json_int_opt "post_count" json )
     with
     | ( Some id_s
       , Some slug
       , Some name
       , Some description
       , Some owner_s
       , Some (`List member_json)
       , Some access_s
       , Some created_at
       , Some post_count ) ->
       let member_names =
         List.fold_right
           (fun value names ->
              match value, names with
              | `String name, Some names -> Some (name :: names)
              | _, _ -> None)
           member_json
           (Some [])
       in
       (match
          ( Sub_board_id.of_string id_s
          , Agent_id.of_string owner_s
          , sub_board_access_of_string_opt access_s
          , member_names )
        with
        | Ok id, Ok owner, Some access, Some member_names
          when not (String.equal slug "") ->
          (match parse_sub_board_members ~owner member_names with
           | Error _ -> None
           | Ok members ->
             let canonical_member_names =
               List.map Agent_id.to_string members
             in
             if
               not
                 (String.equal id_s (Sub_board_id.to_string id)
                  && String.equal owner_s (Agent_id.to_string owner)
                  && member_names = canonical_member_names)
             then None
             else
               Some
                 { id
                 ; slug
                 ; name
                 ; description
                 ; owner
                 ; members
                 ; access
                 ; created_at
                 ; post_count
                 })
        | _ -> None)
     | _ -> None)
  | _ -> None
;;
