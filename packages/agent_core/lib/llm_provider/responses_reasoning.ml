type channel = Summary | Full
type plaintext = { summary : (int * string) list option; full : (int * string) list option }
type t = Plaintext of plaintext | Opaque of Yojson.Safe.t
let field key = function `Assoc fields -> List.assoc_opt key fields
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
let nonblank text = not (Api_common.string_is_blank text)
let selected channels =
  let choose channel = function
    | None -> None
    | Some parts ->
      let text=List.map snd parts |> String.concat "\n" in
      if nonblank text then Some(channel,text) else None in
  match choose Full channels.full with Some _ as full -> full | None -> choose Summary channels.summary
let summary item =
  match field "summary" item with
  | Some (`List parts) -> Some(List.mapi(fun i part->i,part)parts |> List.filter_map(fun(i,part)->
      match field "type" part,field "text" part with
      | Some (`String ("summary_text" | "text")),Some (`String text) -> Some(i,text)
      | _,_ -> None))
  | Some (`String text) -> Some[0,text]
  | Some (`Assoc _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) | None -> None
let full_text item =
  match field "content" item with
  | None | Some `Null -> Ok None
  | Some (`List parts) ->
    let rec collect index texts = function
      | [] -> Ok(Some(List.rev texts))
      | part :: rest ->
        (match field "type" part,field "text" part with
         | Some (`String "reasoning_text"),Some (`String text) -> collect (index+1) ((index,text)::texts) rest
         | Some (`String "reasoning_text"),_ -> Error "malformed_responses_reasoning:text"
         | _,_ -> collect (index+1) texts rest)
    in collect 0 [] parts
  | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _) ->
    Error "malformed_responses_reasoning:content"
let decode item =
  match field "encrypted_content" item with
  | Some (`String encrypted) when nonblank encrypted -> Ok(Opaque item)
  | Some (`String _ | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
  | None -> Result.map(fun full->Plaintext {full;summary=summary item}) (full_text item)
