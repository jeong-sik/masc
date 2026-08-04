(* Sub-board JSON serializer + member-list parser.

   - Access mode <-> string conversion ([sub_board_access] variant).
   - [sub_board] record <-> Yojson.Safe.t (used by HTTP routes, the
     board tool surface, and the JSONL store rewrite path).
   - Owner-injecting strict member-list parser.

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

let valid_sub_board_slug_pattern =
  Re.Pcre.re {|^[a-z0-9][a-z0-9_-]*$|} |> Re.compile
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
  match json with
  | `Assoc fields ->
    let allowed =
      [ "id"
      ; "slug"
      ; "name"
      ; "description"
      ; "owner"
      ; "members"
      ; "access"
      ; "created_at"
      ; "post_count"
      ]
    in
    let rec has_exact_fields seen = function
      | [] -> true
      | (name, _) :: rest ->
        if List.mem name seen || not (List.mem name allowed)
        then false
        else has_exact_fields (name :: seen) rest
    in
    if not (has_exact_fields [] fields)
    then None
    else
      (match
         ( List.assoc_opt "id" fields
         , List.assoc_opt "slug" fields
         , List.assoc_opt "name" fields
         , List.assoc_opt "description" fields
         , List.assoc_opt "owner" fields
         , List.assoc_opt "members" fields
         , List.assoc_opt "access" fields
         , List.assoc_opt "created_at" fields
         , List.assoc_opt "post_count" fields )
       with
       | ( Some (`String id_raw)
         , Some (`String slug)
         , Some (`String name)
         , Some (`String description)
         , Some (`String owner_raw)
         , Some (`List member_json)
         , Some (`String access_raw)
         , Some (`Float created_at)
         , Some (`Int 0) )
         when Float.is_finite created_at && Float.compare created_at 0.0 > 0 ->
         let member_names =
           let rec loop acc = function
             | [] -> Some (List.rev acc)
             | `String member :: rest -> loop (member :: acc) rest
             | _ -> None
           in
           loop [] member_json
         in
         (match
            ( Sub_board_id.of_string id_raw
            , Agent_id.of_string owner_raw
            , sub_board_access_of_string_opt access_raw
            , member_names )
          with
          | Ok id, Ok owner, Some access, Some member_names
            when String.equal id_raw (Sub_board_id.to_string id)
                 && String.equal owner_raw (Agent_id.to_string owner)
                 && String.length slug >= 1
                 && String.length slug <= 64
                 && Re.execp valid_sub_board_slug_pattern slug ->
            (match parse_sub_board_members ~owner member_names with
             | Ok members
               when List.equal
                      String.equal
                      member_names
                      (List.map Agent_id.to_string members) ->
               Some
                 { id
                 ; slug
                 ; name
                 ; description
                 ; owner
                 ; members
                 ; access
                 ; created_at
                 ; post_count = 0
                 }
             | Ok _ | Error _ -> None)
          | _ -> None)
       | _ -> None)
  | _ -> None
;;
