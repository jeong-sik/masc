module Transcript = Masc_tui_keeper_chat_transcript

(* The surface vocabulary, mirrored from [Surface_ref.t]. This library decodes
   the chat history and nothing else — it carries no [masc] dependency, so it
   cannot name that type. [test_tui_chat_surface_mirror] compares the kinds
   decoded here against [Surface_ref]'s own JSON, so a variant added there
   fails a test instead of quietly drawing rows with no origin. Only the parts
   a label needs are kept: which surface, and the name a webhook or gate goes
   by. *)
module Surface = struct
  type t =
    | Dashboard
    | Discord
    | Slack
    | Webhook of string
    | Agent
    | Broadcast
    | Gate of string
end

type speaker =
  | Operator
  | Named of string

type kind =
  | Addressed_to_keeper of
      { speaker : speaker
      ; surface : Surface.t option
      }
  | Said_by_keeper
  | Delivery_failed
  | Tool_calls of string list

(* The surface half of the label. An operator's own surfaces say nothing extra:
   a dashboard row from a named person is that person, and the pane the
   operator is looking at needs no badge to say so. Every other surface is
   where the row came in from, which is the fact the label exists to carry. *)
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

let surface_label : Surface.t -> string option = function
  | Surface.Dashboard -> None
  | Surface.Agent -> Some "agent"
  | Surface.Broadcast -> Some "broadcast"
  | Surface.Slack -> Some "slack"
  | Surface.Discord -> Some "discord"
  | Surface.Webhook source -> Some source
  | Surface.Gate label -> Some label
;;

(* Unknown kinds decode to [None]: a build that meets a surface it was not
   taught draws the row unlabelled rather than inventing a name for it. *)
let surface_of_json : Yojson.Safe.t -> Surface.t option = function
  | `Assoc fields ->
      (match string_field fields "kind" with
       | Some "dashboard" -> Some Surface.Dashboard
       | Some "discord" -> Some Surface.Discord
       | Some "slack" -> Some Surface.Slack
       | Some "webhook" ->
           Some
             (Surface.Webhook
                (Option.value ~default:"webhook" (string_field fields "source")))
       | Some "agent" -> Some Surface.Agent
       | Some "broadcast" -> Some Surface.Broadcast
       | Some "gate" ->
           Some
             (Surface.Gate
                (Option.value ~default:"gate" (string_field fields "label")))
       | Some _ | None -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let addressed_label speaker surface =
  let name = match speaker with Operator -> "you" | Named name -> name in
  match Option.bind surface surface_label with
  | None -> name
  | Some surface -> name ^ " \xc2\xb7 " ^ surface
;;

(* What one server row is, before consecutive tool rows are folded. Parsed once
   so the fold below matches on a closed sum rather than re-reading strings. *)
type parsed =
  | Utterance of row
  | Tool_call of
      { at : float
      ; tool_name : string
      ; args : string
      }

(* Annotated rather than inferred: an inferred parameter widens to an open
   variant and accepts tags Yojson does not have, which leaves the match below
   exhaustive over nothing. yojson 3 has no `Tuple or `Variant. *)
let parse_row (entry : Yojson.Safe.t) =
  match entry with
  | `Assoc fields -> (
      let at = Option.value ~default:0.0 (float_field fields "ts") in
      let content = Option.value ~default:"" (string_field fields "content") in
      match string_field fields "role" with
      | Some "user" ->
          (* [speaker_name] and [surface] are what the server already sends;
             reading them is the whole difference between "you" and the 23
             other authors that share this role. A surface this build cannot
             decode is dropped to [None] rather than guessed at. *)
          let speaker =
            match string_field fields "speaker_name" with
            | Some name when String.trim name <> "" -> Named name
            | Some _ | None -> Operator
          in
          let surface =
            match List.assoc_opt "surface" fields with
            | None | Some `Null -> None
            | Some json -> surface_of_json json
          in
          Some
            (Utterance
               { at; kind = Addressed_to_keeper { speaker; surface }; text = content })
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
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
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

let rows_of_json (payload : Yojson.Safe.t) =
  match payload with
  | `List entries ->
      let parsed = List.map parse_row entries in
      let dropped = List.length (List.filter Option.is_none parsed) in
      Ok
        { rows = fold_tool_blocks (List.filter_map (fun row -> row) parsed)
        ; dropped
        }
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ ->
      Error "keeper chat history did not come back as an array of rows"
