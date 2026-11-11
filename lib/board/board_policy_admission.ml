open Board_types
open Result.Syntax

let unavailable () = Error (Io_error "Board data is unavailable.")

module String_map = Map.Make (String)

let policy_in_snapshot ~slug (snapshot : Fs_compat.private_jsonl_snapshot) =
  (* Reproduce reload's two indexes in physical file order. *)
  let rec rows by_id by_slug = function
    | [] -> Ok (Option.bind (String_map.find_opt slug by_slug)
        (fun id -> String_map.find_opt id by_id))
    | text :: remaining ->
      if String.equal (String.trim text) "" then rows by_id by_slug remaining
      else match Yojson.Safe.from_string text with
        | json ->
          (match Board_sub_board_json.sub_board_of_yojson json with
           | None -> unavailable ()
           | Some board ->
             let id = Sub_board_id.to_string board.id in
             rows (String_map.add id board by_id)
               (String_map.add board.slug id by_slug) remaining)
        | exception Yojson.Json_error _ -> unavailable () in
  rows String_map.empty String_map.empty (String.split_on_char '\n' snapshot.bytes)

let capture store ~author_id ~hearth =
  match hearth with
  | None -> Ok None
  | Some slug ->
    let* policy = match store.sub_boards_source with
      | Policy_readable observation when
          String.equal observation.policy_path (Board_paths.sub_boards_path store) -> Ok observation
      | Policy_readable _ | Policy_unobserved | Policy_publishing _
      | Policy_refused _ | Policy_unsettled _ -> unavailable () in
    let* board = policy_in_snapshot ~slug policy.policy_snapshot in
    let* () = match board with
      | None -> Ok ()
      | Some board ->
        if Board_access.can_post_in_sub_board ~author_id board then Ok ()
        else Error (Validation_error (Printf.sprintf "Sub-board %S is %s; %s cannot post"
          board.slug (Board_sub_board_json.sub_board_access_to_string board.access)
          (Agent_id.to_string author_id))) in
    Ok (Some policy)
