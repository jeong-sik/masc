open Board_types

let direction_to_string = function Up -> "up" | Down -> "down"

let to_yojson (vote, direction, ts) =
  `Assoc
    [ "target", `String (Board_vote_key.to_string vote)
    ; "voter", `String (Agent_id.to_string (Board_vote_key.voter vote))
    ; "direction", `String (direction_to_string direction)
    ; "ts", `Float ts
    ]

let persisted_vote_direction_of_string_opt = function
  | "up" -> Some Up
  | "down" -> Some Down
  | _ -> None

let of_yojson = function
  | `Assoc fields ->
    let has_exact_fields =
      let allowed = [ "target"; "voter"; "direction"; "ts" ] in
      let rec loop seen = function
        | [] -> true
        | (name, _) :: rest ->
          if List.mem name seen || not (List.mem name allowed)
          then false
          else loop (name :: seen) rest
      in
      loop [] fields
    in
    if not has_exact_fields
    then None
    else
      (match
         ( List.assoc_opt "target" fields
         , List.assoc_opt "voter" fields
         , List.assoc_opt "direction" fields
         , List.assoc_opt "ts" fields )
       with
       | ( Some (`String target)
         , Some (`String voter)
         , Some (`String direction_raw)
         , Some (`Float ts) )
         when Float.is_finite ts && Float.compare ts 0.0 > 0 ->
         (match
            Board_vote_key.of_string target,
            persisted_vote_direction_of_string_opt direction_raw
          with
          | Some vote, Some direction
            when String.equal voter (Agent_id.to_string (Board_vote_key.voter vote)) ->
            Some (vote, direction, ts)
          | Some _, Some _ | Some _, None | None, _ -> None)
       | _ -> None)
  | _ -> None
