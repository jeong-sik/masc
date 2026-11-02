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
