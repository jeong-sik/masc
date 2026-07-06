let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let assoc_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> trim_nonempty value
  | _ -> None
;;

let payload_fields payload =
  match Schedule_domain.payload_to_yojson payload with
  | `Assoc fields -> Some fields
  | _ -> None
;;

let kind_of_payload payload =
  Option.bind (payload_fields payload) (assoc_string "kind")
;;

let body_fields payload =
  match payload_fields payload with
  | Some fields ->
    (match List.assoc_opt "body" fields with
     | Some (`Assoc body) -> Some body
     | _ -> None)
  | None -> None
;;

let board_target body =
  match assoc_string "thread_id" body, assoc_string "hearth" body with
  | Some thread_id, _ -> Some ("thread:" ^ thread_id)
  | None, Some hearth -> Some ("hearth:" ^ hearth)
  | None, None -> Some "board:default"
;;

let truncate_summary text =
  String.trim text
  |> String_util.utf8_safe ~max_bytes:160 ~suffix:"..."
  |> String_util.to_string
;;

let board_summary body =
  match assoc_string "title" body, assoc_string "content" body with
  | Some title, _ -> Some (truncate_summary title)
  | None, Some content -> Some (truncate_summary content)
  | None, None -> None
;;

let keeper_wake_target body =
  match assoc_string "keeper_name" body with
  | Some keeper_name -> Some ("keeper:" ^ keeper_name)
  | None -> None
;;

let keeper_wake_summary body =
  match assoc_string "title" body, assoc_string "message" body with
  | Some title, _ -> Some (truncate_summary title)
  | None, Some message -> Some (truncate_summary message)
  | None, None -> None
;;

let target_summary_of_payload payload =
  match kind_of_payload payload, body_fields payload with
  | Some kind, Some body when String.equal kind Schedule_supported_kinds.board_post ->
    board_target body, board_summary body
  | Some kind, Some body when String.equal kind Schedule_supported_kinds.keeper_wake ->
    keeper_wake_target body, keeper_wake_summary body
  | _ -> None, None
;;

let kind (request : Schedule_domain.schedule_request) =
  kind_of_payload request.payload
;;

let target_summary (request : Schedule_domain.schedule_request) =
  target_summary_of_payload request.payload
;;
