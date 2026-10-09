open Result.Syntax

let config_error ~field detail =
  Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })
;;

type image_block =
  { media_type : string
  ; base64_data : string
  }

(* Split a goal into the text the CLI receives and the images that ride with it.
   [text_of_blocks] rejects every non-text block; this admits [Image] for the
   transports that carry one, and keeps rejecting the rest so a block nobody
   projects cannot slip through as silence. Only [Base64] images are carried:
   a [Url] or [File_id] source names bytes this process never read, and the CLI
   has no way to fetch them. *)
let text_and_images_of_blocks ~runtime_label ~field blocks =
  let rec loop texts images = function
    | [] -> Ok (String.concat "\n" (List.rev texts), List.rev images)
    | Agent_core.Types.Text text :: rest -> loop (text :: texts) images rest
    | Agent_core.Types.Image { media_type; data; source_type } :: rest ->
      (match source_type with
       | Agent_core.Types.Base64 ->
         loop texts ({ media_type; base64_data = data } :: images) rest
       | Agent_core.Types.Url | Agent_core.Types.File_id ->
         Error
           (config_error
              ~field
              (runtime_label ^ " image projection admits base64 sources only")))
    | _ :: _ ->
      Error
        (config_error
           ~field
           (runtime_label ^ " projection admits text and image blocks only"))
  in
  loop [] [] blocks
;;

let text_of_blocks ~runtime_label ~field blocks =
  let rec loop texts = function
    | [] -> Ok (String.concat "\n" (List.rev texts))
    | Agent_core.Types.Text text :: rest -> loop (text :: texts) rest
    | _ :: _ ->
      Error
        (config_error
           ~field
           (runtime_label ^ " official-client projection admits text blocks only"))
  in
  loop [] blocks
;;

let encode_history_message = Keeper_official_client_context_codec.encode

let user_message text : Agent_core.Types.message =
  { role = User
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

(* Official-client adapters own their provider instruction projection. Keep
   dynamic context on that System path rather than copying Agent Core's
   synthetic User-message encoding, while retaining the shared typed identity
   used by prompt attribution and input-window projection.

   The Librarian's working state rides the same System path, so it reaches
   the client the way each adapter delivers System text: Claude Code joins it
   into [--system-prompt] on every turn, a resume included
   ([Keeper_claude_code_runtime]); Antigravity renders it as a [SYSTEM:]
   section ahead of the history ([Keeper_antigravity_runtime]). The Agent
   Core lane sends the same text as a [User] message, which only that lane's
   wire has. The text names itself a summary to use as context, not as new
   instructions ([Keeper_turn_driver_try_provider.working_state_text]).

   The two carry different tags. The composition check over a request expects
   exactly one per-turn carrier; a working state stamped with the carrier's
   tag made every request that carried both fail it as a repeated carrier.
   The working state carries {!Runtime_model_input_tail_window.working_state_metadata},
   as on the Agent Core lane, and the adapters select both through
   [is_composed_system_context]. *)
let system_context_message ~metadata text : Agent_core.Types.message =
  { role = System
  ; content = [ Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata
  }
;;

let extra_system_context_message text =
  system_context_message
    ~metadata:Agent_core.Types.Extra_system_context_provenance.metadata
    text
;;

let working_state_message text =
  system_context_message
    ~metadata:Runtime_model_input_tail_window.working_state_metadata
    text
;;

let is_composed_system_context (message : Agent_core.Types.message) =
  (match Agent_core.Types.Extra_system_context_provenance.classify message.metadata with
   | Agent_core.Types.Extra_system_context_provenance.Present -> true
   | Agent_core.Types.Extra_system_context_provenance.Absent
   | Agent_core.Types.Extra_system_context_provenance.Invalid
   | Agent_core.Types.Extra_system_context_provenance.Duplicate -> false)
  || Runtime_model_input_tail_window.is_working_state message
;;

let history_role_label = function
  | Agent_core.Types.System -> "SYSTEM:\n"
  | Agent_core.Types.User -> "USER:\n"
  | Agent_core.Types.Assistant -> "ASSISTANT:\n"
  | Agent_core.Types.Tool -> "TOOL:\n"
;;

(* A blank line between rendered messages and before the goal. *)
let resume_section_separator = "\n\n"

let is_carried_on_resume message =
  is_composed_system_context message || Keeper_official_task_reference.is_reference message
;;

module Session_store = Keeper_official_client_session_store

type composed_context = Keeper_context_assembly.t

type resume_delivery =
  { prompt : string
  ; held_context : Session_store.held_context list
  }

let sha256_hex text = Digestif.SHA256.(digest_string text |> to_hex)

(* One carried context a turn composes: its name and digest, whether a resume
   sends it again when the session holds the same bytes, and the message a
   resume renders for it. *)
type carried =
  { held : Session_store.held_context
  ; resent_when_held : bool
  ; message : Agent_core.Types.message
  }

let carried_message context message =
  { held = { Session_store.context; sha256 = sha256_hex (encode_history_message message) }
  ; resent_when_held = false
  ; message
  }
;;

(* The context carrier splits into its typed blocks only when it is the exact
   renderer-issued assembly [composed_context] names, without an existing
   prefix. Otherwise the whole carrier is one carried context.
   A block's digest is the one its turn record keeps, the sha256 of its raw
   text. *)
let carried_of_message ~composed_context (message : Agent_core.Types.message) =
  if Keeper_official_task_reference.is_reference message
  then [ carried_message Session_store.Historical_task_reference message ]
  else if Runtime_model_input_tail_window.is_working_state message
  then [ carried_message Session_store.Librarian_working_state message ]
  else if is_composed_system_context message
  then (
    let blocks =
      match composed_context, message.content with
      | Some assembly, [ Agent_core.Types.Text text ] ->
        Keeper_context_assembly.blocks_for_carrier assembly text
      | Some _, _ | None, _ -> None
    in
    match blocks with
    | Some blocks ->
      List.map
        (fun (block, text) ->
           { held =
               { Session_store.context = Session_store.Context_block block
               ; sha256 = sha256_hex text
               }
           ; resent_when_held = Prompt_block_id.resent_when_held block
           ; message = extra_system_context_message text
           })
        blocks
    | None -> [ carried_message Session_store.Context_carrier message ])
  else []
;;

let carried_context ~composed_context messages =
  List.concat_map (carried_of_message ~composed_context) messages
;;

let held_of_carried carried =
  carried
  |> List.filter (fun item -> not item.resent_when_held)
  |> List.map (fun item -> item.held)
;;

type carried_summary =
  { label : string
  ; bytes : int
  ; sha256_prefix : string
  ; resent_every_resume : bool
  }

let carried_label = function
  | Session_store.Context_block block -> "block:" ^ Prompt_block_id.to_string block
  | Session_store.Context_carrier -> "carrier"
  | Session_store.Librarian_working_state -> "librarian_working_state"
  | Session_store.Historical_task_reference -> "historical_task_reference"
;;

let carried_sha256_prefix_length = 12

let carried_summaries ?composed_context messages =
  carried_context ~composed_context messages
  |> List.map (fun item ->
    { label = carried_label item.held.Session_store.context
    ; bytes = String.length (encode_history_message item.message)
    ; sha256_prefix =
        String.sub item.held.Session_store.sha256 0 carried_sha256_prefix_length
    ; resent_every_resume = item.resent_when_held
    })
;;

let start_held_context ?composed_context messages =
  held_of_carried (carried_context ~composed_context messages)
;;

(* Blocks sent together read as one carrier, as they do on a start. *)
let is_block item =
  match item.held.Session_store.context with
  | Session_store.Context_block _ -> true
  | Session_store.Context_carrier
  | Session_store.Librarian_working_state
  | Session_store.Historical_task_reference -> false
;;

let block_text item =
  match item.message.Agent_core.Types.content with
  | [ Agent_core.Types.Text text ] -> Some text
  | _ -> None
;;

let rec rendered_messages = function
  | [] -> []
  | item :: rest when is_block item ->
    let rec take_blocks texts = function
      | next :: rest when is_block next ->
        (match block_text next with
         | Some text -> take_blocks (text :: texts) rest
         | None -> List.rev texts, next :: rest)
      | rest -> List.rev texts, rest
    in
    (match block_text item with
     | Some text ->
       let texts, rest = take_blocks [ text ] rest in
       extra_system_context_message (String.concat resume_section_separator texts)
       :: rendered_messages rest
     | None -> item.message :: rendered_messages rest)
  | item :: rest -> item.message :: rendered_messages rest
;;

let resume_prompt ~goal ~held ?composed_context messages =
  let carried = carried_context ~composed_context messages in
  let already_held item =
    (not item.resent_when_held) && List.mem item.held held
  in
  let context =
    carried
    |> List.filter (fun item -> not (already_held item))
    |> rendered_messages
    |> List.map (fun (message : Agent_core.Types.message) ->
      history_role_label message.role ^ encode_history_message message)
    |> String.concat resume_section_separator
  in
  let composed = held_of_carried carried in
  (* A context composed this turn supersedes what the session held under the
     same name. A whole carrier and the typed blocks name the same text, so
     each supersedes the other: after a turn that sent the whole carrier, the
     session's latest copy of every block is inside that carrier, not in an
     earlier block digest. *)
  let supersedes (current : Session_store.held_context)
      (previous : Session_store.held_context) =
    match current.context, previous.context with
    | Session_store.Context_carrier, Session_store.Context_block _
    | Session_store.Context_block _, Session_store.Context_carrier ->
      true
    | current_context, previous_context -> current_context = previous_context
  in
  let held_context =
    composed
    @ List.filter
        (fun previous ->
           not (List.exists (fun current -> supersedes current previous) composed))
        held
  in
  let prompt =
    match String_util.trim_nonempty context with
    | None -> goal
    | Some context -> context ^ resume_section_separator ^ goal
  in
  { prompt; held_context }
;;

let last_tool_results messages =
  messages
  |> List.rev
  |> List.find_map (fun (message : Agent_core.Types.message) ->
    match message.role with
    | Tool ->
      Some
        (List.filter_map
           (function
             | Agent_core.Types.ToolResult { content; content_blocks; outcome; _ } ->
               Some (Agent_core.Types.tool_result_of_outcome ?content_blocks ~content outcome)
             | _ -> None)
           message.content)
    | System | User | Assistant -> None)
  |> Option.value ~default:[]
;;
