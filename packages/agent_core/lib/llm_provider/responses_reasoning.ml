type t =
  | Absent
  | Plaintext of string
  | Opaque of Yojson.Safe.t

let field key = function `Assoc fields -> List.assoc_opt key fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
let nonblank text = not (Api_common.string_is_blank text)
let summary item =
  match field "summary" item with
  | Some (`List parts) ->
    List.filter_map (fun part -> match field "type" part,field "text" part with
      | Some (`String ("summary_text" | "text")),Some (`String text) -> Some text
      | _,_ -> None) parts |> String.concat "\n"
  | Some (`String text) -> text
  | Some (`Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None -> ""
let full_text item =
  match field "content" item with
  | None | Some `Null -> Ok ""
  | Some (`List parts) ->
    let rec collect texts = function
      | [] -> Ok (String.concat "\n" (List.rev texts))
      | part :: rest ->
        (match field "type" part,field "text" part with
         | Some (`String "reasoning_text"),Some (`String text) -> collect (text::texts) rest
         | Some (`String "reasoning_text"),_ -> Error "malformed_responses_reasoning:text"
         | _,_ -> collect texts rest)
    in collect [] parts
  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error "malformed_responses_reasoning:content"
let decode item =
  match field "encrypted_content" item with
  | Some (`String encrypted) when nonblank encrypted -> Ok (Opaque item)
  | Some (`String _ | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
  | None ->
    Result.map (fun full ->
      let text = if nonblank full then full else summary item in
      if nonblank text then Plaintext text else Absent) (full_text item)
