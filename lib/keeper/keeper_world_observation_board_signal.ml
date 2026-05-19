(** See [keeper_world_observation_board_signal.mli] for the contract. *)

let json_string_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None
;;

let json_string_null_member name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some `Null | None -> None
  | _ -> None
;;

let json_float_null_member name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some `Null | None -> None
  | _ -> None
;;

let board_signal_kind_of_string = function
  | "post_created" | "post" -> Some Board_dispatch.Board_post_created
  | "comment_added" | "comment" -> Some Board_dispatch.Board_comment_added
  | _ -> None
;;

let of_stimulus_payload payload =
  try
    match Yojson.Safe.from_string payload with
    | `Assoc fields
      when Option.equal
             String.equal
             (json_string_member "source" fields)
             (Some "board_signal") ->
      (match
         ( json_string_member "kind" fields
         , json_string_member "post_id" fields
         , json_string_member "author" fields
         , json_string_member "title" fields
         , json_string_member "content" fields )
       with
       | Some kind, Some post_id, Some author, Some title, Some content ->
         Option.map
           (fun kind ->
              { Board_dispatch.kind
              ; post_id
              ; author
              ; title
              ; content
              ; hearth = json_string_null_member "hearth" fields
              ; updated_at = json_float_null_member "updated_at_unix" fields
              })
           (board_signal_kind_of_string kind)
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
;;
