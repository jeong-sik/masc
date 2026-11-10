type row =
  | Blank
  | Accepted of {
      post : Board_types.post;
      diagnostics : Board_content_json.diagnostic list;
    }
  | Rejected of {
      error : Board_types.posts_row_error;
      diagnostics : Board_content_json.diagnostic list;
    }

let decode ~line text =
  if String.equal (String.trim text) "" then Blank
  else
    match Yojson.Safe.from_string text with
    | json ->
      let decoded = Board_content_json.post_of_yojson json in
      (match decoded.value with
       | Some post -> Accepted { post; diagnostics = decoded.diagnostics }
       | None -> Rejected {
           error = Board_types.Invalid_posts_row { line };
           diagnostics = decoded.diagnostics;
         })
    | exception Yojson.Json_error detail ->
      Rejected {
        error = Board_types.Invalid_posts_json { line; detail };
        diagnostics = [];
      }

let latest ~post_id (snapshot : Fs_compat.private_jsonl_snapshot) =
  let rec rows line parent = function
    | [] -> (match parent with
        | Some post -> Ok post
        | None -> Error (Board_types.Post_not_found post_id))
    | text :: remaining ->
      match decode ~line text with
      | Blank -> rows (line + 1) parent remaining
      | Rejected _ -> Error (Board_types.Io_error "Board data is unavailable.")
      | Accepted { post; _ } ->
        let parent = if String.equal post_id (Board_types.Post_id.to_string post.id)
          then Some post else parent in
        rows (line + 1) parent remaining in
  rows 1 None (String.split_on_char '\n' snapshot.bytes)
