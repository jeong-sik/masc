module Transcript = Masc_tui_keeper_chat_transcript

type kind =
  | Said_by_operator
  | Said_by_keeper
  | Delivery_failed
  | Tool_calls of string list

type row =
  { at : float
  ; kind : kind
  ; text : string
  }

type decoded =
  { rows : row list
  ; dropped : int
  }

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let float_field fields name =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some _ | None -> None

(* What one server row is, before consecutive tool rows are folded. Parsed once
   so the fold below matches on a closed sum rather than re-reading strings. *)
type parsed =
  | Utterance of row
  | Tool_call of
      { at : float
      ; tool_name : string
      ; args : string
      }

let parse_row = function
  | `Assoc fields -> (
      let at = Option.value ~default:0.0 (float_field fields "ts") in
      let content = Option.value ~default:"" (string_field fields "content") in
      match string_field fields "role" with
      | Some "user" -> Some (Utterance { at; kind = Said_by_operator; text = content })
      | Some "assistant" ->
          let kind =
            match string_field fields "kind" with
            | Some "transport_failure" -> Delivery_failed
            | Some _ | None -> Said_by_keeper
          in
          Some (Utterance { at; kind; text = content })
      | Some "tool" ->
          (* A row with no tool name would draw as a marker and nothing else,
             which says less than no row -- the same call the connector trail
             makes. *)
          Option.map
            (fun tool_name -> Tool_call { at; tool_name; args = content })
            (string_field fields "tool_call_name")
      | Some _ | None -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _
  | `Tuple _ | `Variant _ ->
      None

(* Fold consecutive tool calls into one block, the way a live turn draws its
   calls, and keep every other row where it was. Order is the server's: it
   appends in order and its own note asks a client not to re-sort rows that
   carry no [ts]. *)
let fold_tool_blocks parsed_rows =
  let flush pending acc =
    match List.rev pending with
    | [] -> acc
    | (at, _, _) :: _ as calls ->
        let rows =
          Transcript.completed_tool_rows
            (List.map (fun (_, tool_name, args) -> (tool_name, args)) calls)
        in
        { at; kind = Tool_calls rows; text = "" } :: acc
  in
  let rec loop pending acc = function
    | [] -> List.rev (flush pending acc)
    | Tool_call { at; tool_name; args } :: rest ->
        loop ((at, tool_name, args) :: pending) acc rest
    | Utterance row :: rest -> loop [] (row :: flush pending acc) rest
  in
  loop [] [] parsed_rows

let rows_of_json = function
  | `List entries ->
      let parsed = List.map parse_row entries in
      let dropped = List.length (List.filter Option.is_none parsed) in
      Ok
        { rows = fold_tool_blocks (List.filter_map (fun row -> row) parsed)
        ; dropped
        }
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _
  | `Tuple _ | `Variant _ ->
      Error "keeper chat history did not come back as an array of rows"
