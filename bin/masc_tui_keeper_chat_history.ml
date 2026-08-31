module Transcript = Masc_tui_keeper_chat_transcript
module Delivery_identity = Keeper_chat_delivery_identity

(* The surface vocabulary, mirrored from [Surface_ref.t]. This library decodes
   the chat history and nothing else — it carries no [masc] dependency, so it
   cannot name that type. [test_tui_chat_surface_mirror] compares the kinds
   decoded here against [Surface_ref]'s own JSON, so a variant added there
   fails a test instead of quietly drawing rows with no origin. Only the parts
   a label needs are kept: which surface, and the name a webhook or gate goes
   by. *)
module Surface = struct
  (* Slack and Discord carry which channel the row came in on. A Keeper can be
     bound to several -- one keeper has five Discord channels -- and without it
     every one of them reads as the same place.

     A reference, not a name: the store has only the platform's id today, and
     naming it would mean the label lied about what it knows. When the id is
     resolved to a name the field carries that instead and nothing here
     changes. *)
  (* Which room, and which kind of answer that is. A name and an id are cut
     from opposite ends: Discord ids are snowflakes that share a long prefix,
     so the tail is what tells two channels apart, while a name differs at the
     front and loses its meaning from the back -- [#kinossam-dev] cut to a
     tail reads [...ssam-dev].

     A variant rather than a marker on the string: "does it start with #" is a
     guess about text, and this is a fact the decoder already knows. *)
  type channel =
    | Channel_name of string
    | Channel_id of string

  type t =
    | Dashboard
    | Discord of { channel : channel option }
    | Slack of { channel : channel option }
    | Webhook of string
    | Agent
    | Broadcast
    | Gate of string
end

type speaker =
  | Operator
  | Named of string
  (* The row named an author the producer could not resolve: [speaker_name] was
     absent, or it repeated [speaker_id]. Both are the store saying "someone,
     and I do not know who".

     Kept apart from [Operator] because that one means "the person reading this
     pane wrote it". Folding an unknown author into it turned 272 messages from
     Slack and Discord into the operator's own words. *)
  | Unresolved of { id : string option }

type kind =
  | Addressed_to_keeper of
      { speaker : speaker
      ; surface : Surface.t option
      }
  | Said_by_keeper
  | Autonomous_reply
  | Delivery_failed of
      { origin_request_id : string option
      ; recovered_at : float option
      }
  | Tool_calls of Transcript.tool_block
  | Reasoning of string list
  | Memory_activity

let tool_rows block =
  let projection = Transcript.project_tool_block Transcript.Full block in
  projection.rows

(* The surface half of the label. An operator's own surfaces say nothing extra:
   a dashboard row from a named person is that person, and the pane the
   operator is looking at needs no badge to say so. Every other surface is
   where the row came in from, which is the fact the label exists to carry. *)
(* What a row carries besides its words. The store has held these since the
   composer learned to stage a file; this reader never looked, so a message
   that arrived with a 70 KB image read as the sentence beside it and nothing
   else. The bytes stay in the store -- the pane needs to know a file is
   there, not to hold it. *)
type attachment_note =
  { att_name : string
  ; att_mime : string
  ; att_bytes : int
  }

type row =
  { at : float
  ; turn_id : string option
  ; kind : kind
  ; text : string
  ; attachments : attachment_note list
  }

type decoded =
  { rows : row list
  ; dropped : int
  }

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let find_substring ~needle text =
  let needle_len = String.length needle in
  let text_len = String.length text in
  let rec loop offset =
    if offset + needle_len > text_len then None
    else if String.sub text offset needle_len = needle then Some offset
    else loop (offset + 1)
  in
  if needle_len = 0 then Some 0 else loop 0
;;

type interruption_cause =
  | Host_shutdown
  | Provider_connection_closed

let interruption_of_failure text =
  let direct_cause () =
    if
      Option.is_some
        (find_substring
           ~needle:"MASC runtime shutdown interrupted the active Codex turn"
           text)
    then Some (Host_shutdown, false)
    else if
      Option.is_some
        (find_substring
           ~needle:"Provider 'codex_app_server' unavailable: stdout closed"
           text)
    then Some (Provider_connection_closed, false)
    else None
  in
  let marker = "[masc_agent_core_error]" in
  match find_substring ~needle:marker text with
  | None -> direct_cause ()
  | Some marker_at ->
    let after_marker = marker_at + String.length marker in
    (match String.index_from_opt text after_marker '{' with
     | None -> direct_cause ()
     | Some json_at ->
       let json = String.sub text json_at (String.length text - json_at) in
       (match Yojson.Safe.from_string json with
        | exception Yojson.Json_error _ -> direct_cause ()
        | `Assoc fields
          when string_field fields "kind" = Some "provider_attempt_effect_fenced" ->
          let diagnostic = Option.value ~default:"" (string_field fields "diagnostic") in
          let cause =
            if
              Option.is_some
                (find_substring ~needle:"runtime shutdown interrupted" diagnostic)
            then Some Host_shutdown
            else if
              Option.is_some
                (find_substring
                   ~needle:"Provider 'codex_app_server' unavailable: stdout closed"
                   diagnostic)
            then Some Provider_connection_closed
            else None
          in
          Option.map
            (fun cause ->
               ( cause
               , string_field fields "effect_disposition" = Some "effect_attempted" ))
            cause
        | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _
        | `Null | `String _ -> direct_cause ()))
;;

let present_delivery_failure ?recovered_at text =
  match interruption_of_failure text with
  | None -> None
  | Some (cause, effect_attempted) ->
    let subject =
      match cause with
      | Host_shutdown -> "Runtime shutdown interrupted this turn"
      | Provider_connection_closed ->
        "Provider connection closed during this turn"
    in
    let lifecycle, recovered =
      match recovered_at with
      | Some _ -> "lane recovered in a later Keeper reply", true
      | None -> "recovery pending", false
    in
    let replay =
      if effect_attempted then
        " · same-turn replay blocked to avoid duplicate tool calls"
      else ""
    in
    Some (Printf.sprintf "%s · %s%s · details in Logs" subject lifecycle replay, recovered)
;;

let float_field fields name =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some _ | None -> None

(* A channel reference, cut to its tail rather than its head. Discord ids are
   snowflakes: consecutive channels share a long prefix, so [1356818755795157113]
   and [1356818756755525815] are the same string for the first eleven digits.
   Cutting the head is what tells them apart. *)
let channel_reference_cells = 8

let short_channel reference =
  let length = String.length reference in
  if length <= channel_reference_cells then reference
  else
    "\xe2\x80\xa6"
    ^ String.sub reference (length - channel_reference_cells) channel_reference_cells

let connector_label name channel =
  match channel with
  | None -> Some name
  (* A room name is left whole. The label is fitted to the speaker column
     further down, and that cut keeps the head -- which is the half of a name
     that carries it. Cutting again here would only cut it shorter. *)
  | Some (Surface.Channel_name room) -> Some (name ^ " #" ^ String.trim room)
  (* An id is cut here because the fit above keeps the wrong half of one. *)
  | Some (Surface.Channel_id reference) ->
      Some (name ^ " " ^ short_channel (String.trim reference))

let surface_label : Surface.t -> string option = function
  | Surface.Dashboard -> None
  | Surface.Agent -> Some "agent"
  | Surface.Broadcast -> Some "broadcast"
  | Surface.Slack { channel } -> connector_label "slack" channel
  | Surface.Discord { channel } -> connector_label "discord" channel
  | Surface.Webhook source -> Some source
  | Surface.Gate label -> Some label
;;

(* Unknown kinds decode to [None]: a build that meets a surface it was not
   taught draws the row unlabelled rather than inventing a name for it. *)
let channel_reference_of fields =
  match string_field fields "channel_name" with
  | Some name when String.trim name <> "" ->
      Some (Surface.Channel_name (String.trim name))
  | Some _ | None -> (
    (* A blank name is the absence the resolver reports, not a room called
       "". The id still says which room. *)
    match string_field fields "channel_id" with
    | Some id when String.trim id <> "" -> Some (Surface.Channel_id id)
    | Some _ | None -> None)

let surface_of_json : Yojson.Safe.t -> Surface.t option = function
  | `Assoc fields ->
      (match string_field fields "kind" with
       | Some "dashboard" -> Some Surface.Dashboard
       (* The name where the workspace let us ask, the id where it did not.
          Both answer "which room", and the id was always better than the bare
          connector badge -- five channels of one Keeper read as one place
          before either. *)
       | Some "discord" ->
           Some
             (Surface.Discord
                { channel = channel_reference_of fields })
       | Some "slack" ->
           Some (Surface.Slack { channel = channel_reference_of fields })
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
  let name =
    match speaker with
    | Operator -> "you"
    | Named name -> name
    (* Named by its id where there is one: an unresolved author is still a
       particular author, and two of them in a channel are two people. *)
    | Unresolved { id = Some id } -> short_channel id
    | Unresolved { id = None } -> "someone"
  in
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
      ; turn_id : string option
      ; call_id : string option
      ; execution_id : string option
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

let bool_field_opt fields name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Some value
  | Some _ | None -> None

(* The transcript carries an exact operation key for direct turns and a
   [turn_ref] for autonomous turns. Keep whichever authority the producer
   supplied; timestamps and row adjacency are not turn identity. *)
let turn_id_of_fields fields =
  match Delivery_identity.delivery_provenance_of_fields fields with
  | Ok (Some provenance) ->
      let request_id =
        match provenance.Delivery_identity.delivery_key with
        | Delivery_identity.Operation request_id
        | Delivery_identity.Fusion_run request_id
        | Delivery_identity.Workspace_message request_id
        | Delivery_identity.Approval_lifecycle request_id ->
            request_id
      in
      Some (Delivery_identity.Request_id.to_string request_id)
  | Ok None | Error _ -> string_field fields "turn_ref"

(* The row's text with one line per file under it.

   A file posted with no caption arrives with [text] empty, and joining on it
   anyway put a blank line above the file — the reader sees a gap where a
   sentence would be (task-552). The connector side makes the same choice when
   it composes an inbound message; the two have to agree or the same message
   reads differently depending on which path wrote it. *)
let text_with_attachments ~format_bytes ~text ~notes =
  match notes with
  | [] -> text
  | notes ->
    let line (n : attachment_note) =
      Printf.sprintf "\xe2\x8e\x98 %s%s%s" n.att_name
        (if n.att_bytes > 0 then
           Printf.sprintf " \xc2\xb7 %s" (format_bytes n.att_bytes)
         else "")
        (if n.att_mime = "" then "" else " \xc2\xb7 " ^ n.att_mime)
    in
    let body = String.trim text in
    String.concat "\n"
      (if body = "" then List.map line notes else body :: List.map line notes)

let attachment_notes_of fields =
  match List.assoc_opt "attachments" fields with
  | Some (`List items) ->
      List.filter_map
        (function
          | `Assoc item ->
              (* A row that names a file without naming it is not an
                 attachment this pane can say anything about. *)
              (match string_field item "name" with
               | None -> None
               | Some name ->
                   Some
                     { att_name = name
                     ; att_mime =
                         Option.value (string_field item "mime_type")
                           ~default:""
                     ; att_bytes =
                         Option.value (int_field item "size") ~default:0
                     })
          | _ -> None)
        items
  | Some _ | None -> []

let list_field (fields : (string * Yojson.Safe.t) list) name =
  match List.assoc_opt name fields with
  | Some (`List values) -> Some values
  | Some _ | None -> None

let memory_fact_line marker (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      (match string_field fields "category", string_field fields "claim" with
       | Some category, Some claim ->
           Some (Printf.sprintf "%s [%s] %s" marker category claim)
       | Some _, None | None, Some _ | None, None -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None

let memory_drop_line (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
      (match string_field fields "memory_id", string_field fields "reason" with
       | Some memory_id, Some reason ->
           Some (Printf.sprintf "drop %s \xe2\x80\x94 %s" memory_id reason)
       | Some _, None | None, Some _ | None, None -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None

let memory_source_label (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt "source" fields with
  | Some (`Assoc source) ->
      (match string_field source "kind" with
       | Some "librarian" -> "Librarian"
       | Some "explicit_write" -> "Memory write"
       | Some value -> "Memory " ^ value
       | None -> "Memory")
  | Some _ | None -> "Memory"

let memory_committed_row (fields : (string * Yojson.Safe.t) list) =
  match
    float_field fields "recorded_at",
    int_field fields "revision",
    List.assoc_opt "change" fields
  with
  | Some at, Some revision, Some (`Assoc change) ->
      (match
         list_field change "added",
         list_field change "removed",
         int_field change "retained"
       with
       | Some added, Some removed, Some retained ->
           let added_lines = List.map (memory_fact_line "+") added in
           let removed_lines = List.map (memory_fact_line "-") removed in
           let dropped_lines =
             match list_field fields "dropped" with
             | None -> Some []
             | Some dropped ->
                 let lines = List.map memory_drop_line dropped in
                 if List.exists Option.is_none lines
                 then None
                 else Some (List.filter_map Fun.id lines)
           in
           if List.exists Option.is_none (added_lines @ removed_lines)
           then None
           else
             Option.map
               (fun dropped_lines ->
                  (* One header line, then the change as a diff fence. The
                     per-fact wording used to repeat "now in current memory" on
                     every line; the header says once what the state is now,
                     and inside the fence a [+] or [-] says which way each fact
                     went. The fence also takes these lines out of markdown's
                     list grammar -- the reason the renderer used to escape a
                     leading [+], an escape nothing ever consumed, so readers
                     saw a literal backslash. *)
                  let summary =
                    Printf.sprintf
                      "%s committed current memory revision %d \xc2\xb7 now %d added, %d removed, %d retained"
                      (memory_source_label fields)
                      revision
                      (List.length added)
                      (List.length removed)
                      retained
                  in
                  { at
                  ; turn_id = None
                  ; kind = Memory_activity
                  ; attachments = []
                  ; text =
                      (let change_lines =
                         List.filter_map Fun.id added_lines
                         @ List.filter_map Fun.id removed_lines
                         @ dropped_lines
                       in
                       String.concat "\n"
                         (match change_lines with
                          | [] -> [ summary ]
                          | lines ->
                            (summary :: "```memory" :: lines) @ [ "```" ]))
                  })
               dropped_lines
       | Some _, Some _, None | Some _, None, _ | None, _, _ -> None)
  | Some _, Some _, Some _
  | Some _, Some _, None
  | Some _, None, _
  | None, _, _ -> None

let memory_failed_row (fields : (string * Yojson.Safe.t) list) =
  match
    float_field fields "recorded_at",
    string_field fields "kind",
    string_field fields "detail",
    bool_field_opt fields "snapshot_present",
    bool_field_opt fields "cadence_deferred"
  with
  | Some at, Some kind, Some detail, Some snapshot_present, Some cadence_deferred ->
      Some
        { at
        ; turn_id = None
        ; kind = Memory_activity
        ; attachments = []
        ; text =
            Printf.sprintf
              "Librarian failed \xc2\xb7 %s\n%s\nsnapshot present: %s \xc2\xb7 cadence deferred: %s"
              kind
              detail
              (if snapshot_present then "yes" else "no")
              (if cadence_deferred then "yes" else "no")
        }
  | Some _, Some _, Some _, Some _, None
  | Some _, Some _, Some _, None, _
  | Some _, Some _, None, _, _
  | Some _, None, _, _, _
  | None, _, _, _, _ -> None

let memory_row_of_json = function
  | `Assoc fields ->
      (match bool_field_opt fields "ok" with
       | Some false ->
           Option.map
             (fun error ->
                { at = 0.0
                ; turn_id = None
                ; kind = Memory_activity
                ; text = "Memory journal unreadable: " ^ error
                ; attachments = []
                })
             (string_field fields "error")
       | Some true ->
           (match string_field fields "outcome" with
            | Some "committed" -> memory_committed_row fields
            | Some "failed" -> memory_failed_row fields
            | Some _ | None -> None)
       | None -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None

let memory_rows_of_json = function
  | `Assoc fields ->
      (match List.assoc_opt "entries" fields with
       | Some (`List entries) ->
           let rows = List.map memory_row_of_json entries in
           Ok
             { rows = List.filter_map Fun.id rows
             ; dropped = List.length (List.filter Option.is_none rows)
             }
       | Some _ | None -> Error "memory journal response has no entries array")
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "memory journal response is not an object"

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
  ; tools : Transcript.tool_activity list
  ; omitted : int  (** steps the server dropped from this surface *)
  }

let empty_trace = { reasoning = []; withheld = 0; tools = []; omitted = 0 }

let persisted_outcome fields : Transcript.tool_outcome =
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
                  Transcript.make_tool_activity
                    ?execution_id:(string_field fields "execution_id")
                    ~call_id:(string_field fields "tool_call_id") ~tool_name
                    ~args ~outcome:(persisted_outcome fields)
                    ~duration:(string_field fields "dur") ()
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
let rows_of_trace ~turn_id at summary =
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
  let reasoning = summary.reasoning @ withheld_note in
  let tool_block =
    Transcript.tool_block ~omitted_steps:summary.omitted summary.tools
  in
  match reasoning, summary.tools, summary.omitted with
  | [], [], 0 -> []
  | [], [], _ ->
      (* No reasoning and no calls: the omitted count is the only thing the
         block said, and remains a typed transcript omission rather than a
         synthetic tool call. *)
      [ Utterance { at; turn_id; kind = Tool_calls tool_block; text = "" ; attachments = [] } ]
  | reasoning, [], _ ->
      [ Utterance
          { at; turn_id; kind = Reasoning (reasoning @ omitted_note); text = "" ; attachments = [] }
      ]
  | [], _ :: _, _ ->
      [ Utterance { at; turn_id; kind = Tool_calls tool_block; text = "" ; attachments = [] } ]
  | reasoning, _ :: _, _ ->
      [ Utterance { at; turn_id; kind = Reasoning reasoning; text = "" ; attachments = [] }
      ; Utterance { at; turn_id; kind = Tool_calls tool_block; text = "" ; attachments = [] }
      ]

(* Annotated rather than inferred: an inferred parameter widens to an open
   variant and accepts tags Yojson does not have, which leaves the match below
   exhaustive over nothing. yojson 3 has no `Tuple or `Variant. *)
let parse_row (entry : Yojson.Safe.t) : parsed list =
  match entry with
  | `Assoc fields -> (
      let at = Option.value ~default:0.0 (float_field fields "ts") in
      let content = Option.value ~default:"" (string_field fields "content") in
      let turn_id = turn_id_of_fields fields in
      match string_field fields "role" with
      | Some "user" ->
          (* [speaker_name] and [surface] are what the server already sends;
             reading them is the whole difference between "you" and the 23
             other authors that share this role. A surface this build cannot
             decode is dropped to [None] rather than guessed at. *)
          let speaker_id = string_field fields "speaker_id" in
          let speaker =
            match string_field fields "speaker_name" with
            (* The producer repeating the id in the name field is the store
               saying it had no name, not a person called [U09L0RHPW7P]. *)
            | Some name
              when String.trim name <> ""
                   && not (Option.equal String.equal (Some name) speaker_id) ->
                Named name
            | Some _ | None ->
                (* The producer wrote down whose row this is; reading that
                   beats inferring it. The surface says where a row came from,
                   not who spoke — a dashboard row can carry an external
                   author, and an operator can write from a connector.

                   Absent or unrecognised authority stays unresolved rather
                   than defaulting to the reader: calling someone else "you"
                   is the one wrong answer with no way back. *)
                (match List.assoc_opt "speaker_authority" fields with
                 | Some (`String "owner") -> Operator
                 | Some (`String _) | Some _ | None ->
                     Unresolved { id = speaker_id })
          in
          let surface =
            match List.assoc_opt "surface" fields with
            | None | Some `Null -> None
            | Some json -> surface_of_json json
          in
          [ Utterance
              { at
              ; turn_id
              ; kind = Addressed_to_keeper { speaker; surface }
              ; text = content
              ; attachments = attachment_notes_of fields
              }
          ]
      | Some "assistant" -> (
          match string_field fields "kind" with
          | Some "transport_failure" ->
              (* The server already sends the append-once identity it stored
                 the row under. Only an operation key names a turn this client
                 dispatched; the other producers get [None] rather than a
                 borrowed id. *)
              let origin_request_id =
                match List.assoc_opt "delivery_key" fields with
                | Some (`Assoc key_fields) -> (
                    match string_field key_fields "kind" with
                    | Some "operation" -> string_field key_fields "operation_id"
                    | Some _ | None -> None)
                | Some _ | None -> None
              in
              [ Utterance
                  { at
                  ; turn_id
                  ; kind = Delivery_failed { origin_request_id; recovered_at = None }
                  ; text = content
                  ; attachments = []
                  }
              ]
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
              let autonomous =
                match List.assoc_opt "autonomous_turn" fields with
                | Some (`Assoc _) -> true
                | Some _ | None -> false
              in
              let trace_rows =
                if autonomous then
                  rows_of_trace ~turn_id at (trace_summary_of fields)
                else []
              in
              let said =
                if String.equal content "" && trace_rows <> [] then []
                else
                  [ Utterance
                      { at
                      ; turn_id
                      ; kind = if autonomous then Autonomous_reply else Said_by_keeper
                      ; text = content
                      ; attachments = []
                      }
                  ]
              in
              trace_rows @ said)
      | Some "system" ->
          (* Durable approval lifecycle rows are server-owned status, never
             Keeper speech. The TUI's existing [Memory_activity] presentation
             is the neutral system lane: it renders the typed row without
             advancing reply/recovery semantics. *)
          [ Utterance
              { at
              ; turn_id
              ; kind = Memory_activity
              ; text = content
              ; attachments = []
              }
          ]
      | Some "tool" -> (
          (* A row with no tool name would draw as a marker and nothing else,
             which says less than no row -- the same call the connector trail
             makes. *)
          match string_field fields "tool_call_name" with
          | Some tool_name ->
              [ Tool_call
                  { at
                  ; turn_id
                  ; call_id = string_field fields "tool_call_id"
                  ; execution_id = string_field fields "execution_id"
                  ; tool_name
                  ; args = content
                  }
              ]
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
    | (at, turn_id, _, _, _, _) :: _ as calls ->
        let activities =
          List.map
            (fun (_, _, call_id, execution_id, tool_name, args) ->
              let outcome =
                match execution_id with
                | Some _ -> Transcript.Returned
                | None -> Transcript.Outcome_unrecorded
              in
              Transcript.make_tool_activity ?execution_id ~call_id ~tool_name ~args
                ~outcome ~duration:None ())
            calls
        in
        { at
        ; turn_id
        ; kind = Tool_calls (Transcript.tool_block activities)
        ; text = ""
        ; attachments = []
        }
        :: acc
  in
  let rec loop pending acc = function
    | [] -> List.rev (flush pending acc)
    | Tool_call { at; turn_id; call_id; execution_id; tool_name; args } :: rest ->
        let next = (at, turn_id, call_id, execution_id, tool_name, args) in
        (match pending with
         | (_, pending_turn, _, _, _, _) :: _ when pending_turn <> turn_id ->
             loop [ next ] (flush pending acc) rest
         | _ -> loop (next :: pending) acc rest)
    | Utterance row :: rest -> loop [] (row :: flush pending acc) rest
  in
  loop [] [] parsed_rows

(* A delivery failure remains a failure record, but a later real keeper
   utterance answers the operator's practical question: the lane recovered.
   Scan the append order backwards so the evidence comes from a row after the
   interruption, never merely from a healthy badge or a newer timestamp.

   Only failures this reader can classify are annotated. A later reply must
   not turn an unrelated timeout/auth/config error into a recovered restart. *)
let annotate_recovered_interruptions rows =
  let rec loop later_reply_at acc = function
    | [] -> acc
    | row :: rest ->
      let row, later_reply_at =
        match row.kind with
        | Said_by_keeper | Autonomous_reply
          when String.trim row.text <> "" ->
          row, Some row.at
        | Delivery_failed failure ->
          let recognized = Option.is_some (present_delivery_failure row.text) in
          let recovered_at = if recognized then later_reply_at else None in
          { row with
            kind =
              Delivery_failed
                { origin_request_id = failure.origin_request_id; recovered_at }
          }, later_reply_at
        | Addressed_to_keeper _ | Said_by_keeper | Autonomous_reply
        | Tool_calls _ | Reasoning _ | Memory_activity ->
          row, later_reply_at
      in
      loop later_reply_at (row :: acc) rest
  in
  loop None [] (List.rev rows)
;;

let rows_of_json (payload : Yojson.Safe.t) =
  match payload with
  | `List entries ->
      let parsed = List.map parse_row entries in
      let dropped = List.length (List.filter (fun rows -> rows = []) parsed) in
      let rows =
        fold_tool_blocks (List.concat parsed) |> annotate_recovered_interruptions
      in
      Ok { rows; dropped }
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
