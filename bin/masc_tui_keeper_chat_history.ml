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
  | Reasoning of string list

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

let int_field fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | Some _ | None -> None

let bool_field fields name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> value
  | Some _ | None -> false

let non_blank_lines text =
  String.split_on_char '\n' text
  |> List.filter (fun line -> String.trim line <> "")

(* What an autonomous turn's trace block adds up to, in the order the turn
   made it: the reasoning the server carried, the tool steps, and the counts
   of what it did not carry. Kept as data until the end so one row of output
   is built from the whole block rather than a row per step -- 917 withheld
   reasoning steps on one live keeper would otherwise draw as 917 rows that
   each say nothing. *)
type trace_summary =
  { reasoning : string list  (** non-blank lines, in order *)
  ; withheld : int  (** reasoning steps the server scrubbed *)
  ; tools :
      (Transcript.persisted_tool_outcome * string * string * string option) list
  ; omitted : int  (** steps the server dropped from this surface *)
  }

let empty_trace = { reasoning = []; withheld = 0; tools = []; omitted = 0 }

let persisted_outcome fields : Transcript.persisted_tool_outcome =
  match string_field fields "status" with
  | Some "ok" -> Transcript.Returned
  | Some "err" -> Transcript.Failed
  | Some "pending" -> Transcript.Never_returned
  | Some _ | None -> Transcript.Outcome_unrecorded

(* The wire step kinds are [think], [reason], and [tool]. A kind this build
   was not taught is counted as omitted rather than dropped without a trace:
   the turn did something here, and a shorter block would read as a shorter
   turn. Steps are folded in wire order and the lists reversed once at the
   end. *)
let add_trace_step summary (step : Yojson.Safe.t) =
  match step with
  | `Assoc fields -> (
      match string_field fields "kind" with
      | Some "think" ->
          if bool_field fields "content_withheld" then
            { summary with withheld = summary.withheld + 1 }
          else
            let text = Option.value ~default:"" (string_field fields "text") in
            { summary with
              reasoning = List.rev_append (non_blank_lines text) summary.reasoning
            }
      | Some "reason" ->
          let text = Option.value ~default:"" (string_field fields "text") in
          let detail =
            Option.value ~default:"" (string_field fields "detail")
          in
          { summary with
            reasoning =
              List.rev_append
                (non_blank_lines text @ non_blank_lines detail)
                summary.reasoning
          }
      | Some "tool" -> (
          match string_field fields "name" with
          | None -> { summary with omitted = summary.omitted + 1 }
          | Some tool_name ->
              let args =
                match List.assoc_opt "args" fields with
                | None | Some `Null -> ""
                | Some json -> Yojson.Safe.to_string json
              in
              { summary with
                tools =
                  ( persisted_outcome fields
                  , tool_name
                  , args
                  , string_field fields "dur" )
                  :: summary.tools
              })
      | Some _ | None -> { summary with omitted = summary.omitted + 1 })
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      { summary with omitted = summary.omitted + 1 }

let add_trace_block summary (block : Yojson.Safe.t) =
  match block with
  | `Assoc fields -> (
      match string_field fields "t" with
      | Some "trace" ->
          let steps =
            match List.assoc_opt "trace" fields with
            | Some (`List steps) -> steps
            | Some _ | None -> []
          in
          let summary = List.fold_left add_trace_step summary steps in
          { summary with
            omitted =
              summary.omitted + Option.value ~default:0 (int_field fields "omitted")
          }
      | Some "thinking" ->
          if bool_field fields "redacted" then
            { summary with withheld = summary.withheld + 1 }
          else
            let text =
              Option.value ~default:"" (string_field fields "content")
            in
            { summary with
              reasoning = List.rev_append (non_blank_lines text) summary.reasoning
            }
      (* Every other block kind is prose the row's [content] already carries
         as text; reading it again would draw the reply twice. *)
      | Some _ | None -> summary)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      summary

let trace_summary_of fields =
  match List.assoc_opt "blocks" fields with
  | Some (`List blocks) ->
      let summary = List.fold_left add_trace_block empty_trace blocks in
      { summary with
        reasoning = List.rev summary.reasoning
      ; tools = List.rev summary.tools
      }
  | Some _ | None -> empty_trace

let plural count noun =
  Printf.sprintf "%d %s%s" count noun (if count = 1 then "" else "s")

(* The rows an assistant row's blocks become: one reasoning block, one
   tool block, then what the turn said. The trace interleaves think and
   tool steps; they are gathered into one block each, the way the live pane
   draws a turn, rather than drawn as one row per step. A withheld count
   rides the reasoning block and an omitted count the tool block -- omitted
   steps are steps the turn took, so a block that has nothing but that count
   is still a block of steps. *)
let rows_of_trace at summary =
  let omitted_note =
    if summary.omitted = 0 then []
    else
      [ Printf.sprintf "(%s not carried by the transcript)"
          (plural summary.omitted "step")
      ]
  in
  let withheld_note =
    if summary.withheld = 0 then []
    else
      [ Printf.sprintf "(%s, content withheld)"
          (plural summary.withheld "reasoning step")
      ]
  in
  let tool_rows = Transcript.persisted_tool_rows summary.tools in
  match summary.reasoning @ withheld_note, tool_rows with
  | [], [] ->
      (* No reasoning and no calls: the omitted count, if any, is the only
         thing the block said, and it counts steps. *)
      List.map
        (fun line -> Utterance { at; kind = Tool_calls [ line ]; text = "" })
        omitted_note
  | reasoning, [] ->
      [ Utterance { at; kind = Reasoning (reasoning @ omitted_note); text = "" } ]
  | [], tools ->
      [ Utterance { at; kind = Tool_calls (tools @ omitted_note); text = "" } ]
  | reasoning, tools ->
      [ Utterance { at; kind = Reasoning reasoning; text = "" }
      ; Utterance { at; kind = Tool_calls (tools @ omitted_note); text = "" }
      ]

(* Annotated rather than inferred: an inferred parameter widens to an open
   variant and accepts tags Yojson does not have, which leaves the match below
   exhaustive over nothing. yojson 3 has no `Tuple or `Variant. *)
let parse_row (entry : Yojson.Safe.t) : parsed list =
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
          [ Utterance
              { at; kind = Addressed_to_keeper { speaker; surface }; text = content }
          ]
      | Some "assistant" -> (
          match string_field fields "kind" with
          | Some "transport_failure" ->
              [ Utterance { at; kind = Delivery_failed; text = content } ]
          | Some _ | None ->
              (* An autonomous turn persists what it did as a trace block and
                 often says nothing in [content]: on one live keeper 32 of
                 183 assistant rows were blank that way, and each drew as a
                 timestamp over an empty line. The trace rows come first
                 because the turn ran them first; the text, when there is
                 any, is what it said afterwards. A row with neither keeps
                 its empty line -- that is what the server holds for it.

                 Only a row the server marks [autonomous_turn] is read this
                 way. A direct-conversation turn can carry a trace block too
                 -- the server joins the raw trace onto rows with a turn ref
                 -- but its calls are already in the transcript as
                 [role: "tool"] rows, and reading both drew every call twice. *)
              let trace_rows =
                match List.assoc_opt "autonomous_turn" fields with
                | Some (`Assoc _) -> rows_of_trace at (trace_summary_of fields)
                | Some _ | None -> []
              in
              let said =
                if String.equal content "" && trace_rows <> [] then []
                else [ Utterance { at; kind = Said_by_keeper; text = content } ]
              in
              trace_rows @ said)
      | Some "tool" -> (
          (* A row with no tool name would draw as a marker and nothing else,
             which says less than no row -- the same call the connector trail
             makes. *)
          match string_field fields "tool_call_name" with
          | Some tool_name -> [ Tool_call { at; tool_name; args = content } ]
          | None -> [])
      | Some _ | None -> [])
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> []

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
      let dropped = List.length (List.filter (fun rows -> rows = []) parsed) in
      Ok { rows = fold_tool_blocks (List.concat parsed); dropped }
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ ->
      Error "keeper chat history did not come back as an array of rows"

type page =
  { decoded : decoded
  ; has_more : bool
  ; next_before : float option
  }

let page_of_json (payload : Yojson.Safe.t) =
  match payload with
  | `Assoc fields -> (
      match List.assoc_opt "messages" fields with
      | Some (`List _ as messages) -> (
          match rows_of_json messages with
          | Error _ as error -> error
          | Ok decoded ->
              Ok
                { decoded
                ; (* A missing flag reads as "no more". Guessing true would
                     leave the pane offering a page the server never promised,
                     and every request for it would come back empty. *)
                  has_more =
                    (match List.assoc_opt "has_more" fields with
                     | Some (`Bool value) -> value
                     | Some _ | None -> false)
                ; next_before =
                    (match List.assoc_opt "next_before" fields with
                     | Some (`Float value) -> Some value
                     | Some (`Int value) -> Some (float_of_int value)
                     | Some _ | None -> None)
                })
      | Some _ | None ->
          Error "keeper chat page has no messages array")
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "keeper chat page did not come back as an object"
