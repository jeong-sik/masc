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
    | Agent_core.Types.(
        Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
        | ToolResult _ | Document _ | Audio _)
      :: _ ->
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
    | Agent_core.Types.(
        Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
        | ToolResult _ | Document _ | Image _ | Audio _)
      :: _ ->
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
   | Agent_core.Types.Extra_system_context_provenance.Historical
   | Agent_core.Types.Extra_system_context_provenance.Invalid
   | Agent_core.Types.Extra_system_context_provenance.Duplicate -> false)
  || Runtime_model_input_tail_window.is_working_state message
  || Runtime_model_input_tail_window.is_unread_context message
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
  ; context_projection : Keeper_context_submission_link.t
  ; held_context : Session_store.held_context list
  ; unchanged_sections : Keeper_context_layers.source list
  }

let sha256_hex text = Digestif.SHA256.(digest_string text |> to_hex)

(* One World State section of a [Dynamic_context] block whose renderer
   partition the assembly kept: what rendered it, its exact text, and the name
   and digest a session holds it under. *)
type world_state_section =
  { section : Keeper_context_layers.source
  ; section_text : string
  ; section_held : Session_store.held_context
  }

(* What a resume compares with what the session holds: the carried context as
   one text, or the World State sections of its [Dynamic_context] block. *)
type carried_body =
  | Whole_text
  | World_state_sections of world_state_section list

(* One carried context a turn composes: its name and digest, whether a resume
   sends it again when the session holds the same bytes, the message a
   resume renders for it, and what a resume compares. *)
type carried =
  { held : Session_store.held_context
  ; resent_when_held : bool
  ; message : Agent_core.Types.message
  ; body : carried_body
  }

let carried_message context message =
  { held = { Session_store.context; sha256 = sha256_hex (encode_history_message message) }
  ; resent_when_held = false
  ; message
  ; body = Whole_text
  }
;;

let world_state_section (section, section_text) =
  { section
  ; section_text
  ; section_held =
      { Session_store.context = Session_store.Context_section section
      ; sha256 = sha256_hex section_text
      }
  }
;;

(* A block is compared section by section only when it is the
   [Dynamic_context] block and the assembly kept the renderer's partition of
   its exact text with every section named apart. Fleet messages and recent
   actions change on nearly every turn, so compared as one block the World
   State went out whole on every resume, and the unchanged wiki contents,
   memory ledger and own Board posts piled up in the session with it. *)
let block_body assembly = function
  | Prompt_block_id.Dynamic_context ->
    (match Keeper_context_assembly.dynamic_context_sections assembly with
     | Some sections -> World_state_sections (List.map world_state_section sections)
     | None -> Whole_text)
  | Prompt_block_id.(
      Keeper_instructions | Temporal_summary | Memory_os_recall
      | Librarian_working_context | Operator_note | Skill_compositions) -> Whole_text
;;

(* The context carrier splits into its typed blocks only when it is the exact
   renderer-issued assembly [composed_context] names, without an existing
   prefix. Otherwise the whole carrier is one carried context.
   A block's digest is the one its turn record keeps, the sha256 of its raw
   text. *)
let carried_of_message ~composed_context (message : Agent_core.Types.message) =
  if Keeper_official_task_reference.is_reference message
  then [ carried_message Session_store.Historical_task_reference message ]
  else if Runtime_model_input_tail_window.is_unread_context message
  then [ carried_message Session_store.Librarian_unread message ]
  else if Runtime_model_input_tail_window.is_working_state message
  then [ carried_message Session_store.Librarian_working_state message ]
  else if is_composed_system_context message
  then (
    let blocks =
      match composed_context, message.content with
      | Some assembly, [ Agent_core.Types.Text text ] ->
        Keeper_context_assembly.blocks_for_carrier assembly text
        |> Option.map (fun blocks -> assembly, blocks)
      | Some _,
        ( []
        | [ Agent_core.Types.(
              Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
              | ToolResult _ | Document _ | Image _ | Audio _) ]
        | _ :: _ :: _ )
      | None, _ -> None
    in
    match blocks with
    | Some (assembly, blocks) ->
      List.map
        (fun (block, text) ->
           { held =
               { Session_store.context = Session_store.Context_block block
               ; sha256 = sha256_hex text
               }
           ; resent_when_held = Prompt_block_id.resent_when_held block
           ; message = extra_system_context_message text
           ; body = block_body assembly block
           })
        blocks
    | None -> [ carried_message Session_store.Context_carrier message ])
  else []
;;

let carried_context ~composed_context messages =
  List.concat_map (carried_of_message ~composed_context) messages
;;

(* What the session holds once it has this carried context: the context under
   its name, or each World State section a resume may leave out. What is sent
   on every resume is never left out, so it is not recorded. *)
let held_of_item item =
  match item.body with
  | Whole_text -> if item.resent_when_held then [] else [ item.held ]
  | World_state_sections sections ->
    List.filter_map
      (fun section ->
         match Keeper_context_layers.resend_on_resume section.section with
         | Keeper_context_layers.Sent_every_resume -> None
         | Keeper_context_layers.(Sent_when_changed | Sent_with_other_sections) ->
           Some section.section_held)
      sections
;;

let held_of_carried carried = List.concat_map held_of_item carried

type carried_summary =
  { label : string
  ; bytes : int
  ; sha256_prefix : string
  ; resent_every_resume : bool
  }

let carried_label = function
  | Session_store.Context_block block -> "block:" ^ Prompt_block_id.to_string block
  | Session_store.Context_section section ->
    "section:" ^ Keeper_context_layers.source_name section
  | Session_store.Context_carrier -> "carrier"
  | Session_store.Librarian_working_state -> "librarian_working_state"
  | Session_store.Librarian_unread -> "librarian_unread"
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
  | Session_store.Context_section _
  | Session_store.Context_carrier
  | Session_store.Librarian_working_state
  | Session_store.Librarian_unread
  | Session_store.Historical_task_reference -> false
;;

let block_text item =
  match item.message.Agent_core.Types.content with
  | [ Agent_core.Types.Text text ] -> Some text
  | []
  | [ Agent_core.Types.(
        Thinking _ | ReasoningDetails _ | RedactedThinking _ | ToolUse _
        | ToolResult _ | Document _ | Image _ | Audio _) ]
  | _ :: _ :: _ -> None
;;

let block_id item = match item.held.Session_store.context with
  | Session_store.Context_block id -> Some id
  | Session_store.Context_section _ | Session_store.Context_carrier
  | Session_store.Librarian_working_state | Session_store.Librarian_unread
  | Session_store.Historical_task_reference -> None

let unchanged_sections_notice sections =
  Prompt_registry.render_prompt_template
    Prompt_names.keeper_world_frame_unchanged_sections
    [ "sections", String.concat ", " (List.map Keeper_context_layers.source_name sections) ]
;;

(* What a resume sends for one carried context: all of it, or the World State
   sections the session does not hold unchanged with the line naming the ones
   it does. [unchanged] is never empty. *)
type sent =
  | Sent_whole of carried
  | Sent_changed_sections of
      { item : carried
      ; sections : world_state_section list
      ; unchanged : world_state_section list
      ; notice : string
      }

type carried_delivery =
  | Already_held
  | Sent of sent

let carried_delivery ~held item =
  let holds entry = List.mem entry held in
  match item.body with
  | Whole_text ->
    if (not item.resent_when_held) && holds item.held then Already_held
    else Sent (Sent_whole item)
  | World_state_sections sections ->
    let resend section = Keeper_context_layers.resend_on_resume section.section in
    let section_held section =
      match resend section with
      | Keeper_context_layers.Sent_every_resume -> false
      | Keeper_context_layers.(Sent_when_changed | Sent_with_other_sections) ->
        holds section.section_held
    in
    let left_out section =
      match resend section with
      | Keeper_context_layers.Sent_when_changed -> section_held section
      | Keeper_context_layers.(Sent_every_resume | Sent_with_other_sections) -> false
    in
    if List.for_all section_held sections
    then Already_held
    else (
      match List.partition (fun section -> not (left_out section)) sections with
      | _, [] -> Sent (Sent_whole item)
      | sent, (_ :: _ as unchanged) ->
        (match unchanged_sections_notice (List.map (fun section -> section.section) unchanged) with
         | Ok notice -> Sent (Sent_changed_sections { item; sections = sent; unchanged; notice })
         | Error detail ->
           (* Leaving a section out is sound only beside the line that names
              it, so without that line every section goes out. *)
           Log.Keeper.warn
             "World State unchanged-sections line did not render; sending every section: %s"
             detail;
           Sent (Sent_whole item)))
;;

let sent_item = function
  | Sent_whole item | Sent_changed_sections { item; _ } -> item
;;

let sent_text = function
  | Sent_whole item -> block_text item
  | Sent_changed_sections { sections; _ } ->
    Some (String.concat "" (List.map (fun section -> section.section_text) sections))
;;

let sent_unchanged = function
  | Sent_whole _ -> []
  | Sent_changed_sections { unchanged; _ } ->
    List.map (fun section -> section.section) unchanged
;;

let sent_notice = function
  | Sent_whole _ -> None
  | Sent_changed_sections { notice; _ } -> Some notice
;;

(* The line goes out as its own System message after the carrier it speaks
   for. It is host text, not issuer bytes, so it claims no context
   provenance. *)
let unchanged_sections_message notice =
  system_context_message ~metadata:[] notice
;;

let rec rendered_messages = function
  | [] -> []
  | sent :: rest when is_block (sent_item sent) ->
    let rec take_blocks texts ids unchanged notices = function
      | next :: rest when is_block (sent_item next) ->
        (match sent_text next, block_id (sent_item next) with
         | Some text, Some id ->
           take_blocks (text :: texts) (id :: ids)
             (List.rev_append (sent_unchanged next) unchanged)
             (Option.fold ~none:notices ~some:(fun notice -> notice :: notices)
                (sent_notice next))
             rest
         | _ -> (texts, ids, unchanged, notices), next :: rest)
      | rest -> (texts, ids, unchanged, notices), rest in
    (match sent_text sent, block_id (sent_item sent) with
     | Some text, Some id ->
       let (texts, ids, unchanged, notices), rest =
         take_blocks [text] [id] (List.rev (sent_unchanged sent))
           (Option.to_list (sent_notice sent)) rest in
       (extra_system_context_message (String.concat resume_section_separator (List.rev texts)),
        Some (List.rev ids, List.rev unchanged))
       :: List.rev_map (fun notice -> unchanged_sections_message notice, None) notices
       @ rendered_messages rest
     | _ -> ((sent_item sent).message,None) :: rendered_messages rest)
  | sent :: rest -> ((sent_item sent).message,None) :: rendered_messages rest
;;

let resume_prompt ~goal ~held ?composed_context messages =
  let carried = carried_context ~composed_context messages in
  let deliveries = List.map (fun item -> item, carried_delivery ~held item) carried in
  let sent = List.filter_map (fun (_, delivery) -> match delivery with
    | Sent sent -> Some sent
    | Already_held -> None) deliveries in
  let omitted = List.filter_map (fun (item, delivery) -> match delivery with
    | Already_held -> Some item
    | Sent _ -> None) deliveries in
  let context_projection =
    sent |> rendered_messages
    |> List.map (fun ((message : Agent_core.Types.message),selection) ->
      Keeper_context_submission_link.concat ~separator:""
        [Keeper_context_submission_link.literal (history_role_label message.role);
         Keeper_context_submission_link.encoded_carrier ~assembly:composed_context
           ~selected_blocks:(Option.map fst selection)
           ?omitted_sections:(Option.map snd selection) message])
    |> Keeper_context_submission_link.concat ~separator:resume_section_separator
    |> Keeper_context_submission_link.trim in
  let composed = held_of_carried carried in
  (* A context composed this turn supersedes what the session held under the
     same name. A whole carrier and the typed blocks name the same text, so
     each supersedes the other: after a turn that sent the whole carrier, the
     session's latest copy of every block is inside that carrier, not in an
     earlier block digest. World State sections and their whole
     [Dynamic_context] block stand in for each other the same way. A World
     State also replaces the previous one as a whole: after a turn that
     composed its sections, the sections the session holds as current are
     exactly those, so a section absent this turn goes out again when it
     returns. *)
  let supersedes item (previous : Session_store.held_context) =
    match item.body, previous.context with
    | World_state_sections _,
      ( Session_store.Context_section _
      | Session_store.Context_block Prompt_block_id.Dynamic_context
      | Session_store.Context_carrier ) -> true
    | World_state_sections _,
      ( Session_store.Context_block
          Prompt_block_id.(
            Keeper_instructions | Temporal_summary | Memory_os_recall
            | Librarian_working_context | Operator_note | Skill_compositions)
      | Session_store.Librarian_working_state
      | Session_store.Librarian_unread
      | Session_store.Historical_task_reference ) -> false
    | Whole_text, previous_context ->
      (not item.resent_when_held)
      && (match item.held.context, previous_context with
          | Session_store.Context_carrier,
            (Session_store.Context_block _ | Session_store.Context_section _)
          | Session_store.Context_block _, Session_store.Context_carrier -> true
          | Session_store.Context_block block, Session_store.Context_section _ ->
            Prompt_block_id.equal block Prompt_block_id.Dynamic_context
          | ( (( Session_store.Context_block _
               | Session_store.Context_section _
               | Session_store.Context_carrier
               | Session_store.Librarian_working_state
               | Session_store.Librarian_unread
               | Session_store.Historical_task_reference ) as current_context)
            , (( Session_store.Context_block _
               | Session_store.Context_section _
               | Session_store.Context_carrier
               | Session_store.Librarian_working_state
               | Session_store.Librarian_unread
               | Session_store.Historical_task_reference ) as previous_context) ) ->
            current_context = previous_context)
  in
  let held_context =
    composed
    @ List.filter
        (fun previous ->
           not (List.exists (fun item -> supersedes item previous) carried))
        held
  in
  let context_projection =
    if Keeper_context_submission_link.text context_projection = "" then
      Keeper_context_submission_link.literal goal
    else Keeper_context_submission_link.concat ~separator:resume_section_separator
      [context_projection;Keeper_context_submission_link.literal goal] in
  let context_projection = List.fold_left (fun projection item ->
    Keeper_context_submission_link.omit_held ~assembly:composed_context
      ~blocks:(Option.map (fun id -> [id]) (block_id item)) item.message projection)
    context_projection omitted in
  { prompt = Keeper_context_submission_link.text context_projection; held_context; context_projection
  ; unchanged_sections = List.concat_map sent_unchanged sent }

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
             | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
             | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
             | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _ | Agent_core.Types.Document _
             | Agent_core.Types.Audio _ -> None)
           message.content)
    | System | User | Assistant -> None)
  |> Option.value ~default:[]
;;
