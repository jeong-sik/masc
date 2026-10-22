(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
  | Active_goals
  | Current_task
  | Approval_authority
  | Connected_surfaces
  | Namespace_state
  | Workspace_memory
  | Wiki
  | Lane_updates
  | Repository_freshness
  | Autonomous_trigger
  | Scheduled_automation
  | Completion_authority
  | Task_cancellations
  | Pending_mentions
  | Scope_messages
  | Own_board_posts
  | Board_activity
  | Own_recent_actions
  | Recent_work
  | Fleet_messages

(* Prefix-cache ordering: emit larger, more stable sections first so providers
   can reuse a longer shared prefix across cycles; highly volatile reactive
   signals stay later in the same user message. [Current_task] sits directly
   after [Active_goals]: the claimed task is standing context that changes on
   claim/release, not per cycle. [Own_board_posts] changes only when the
   keeper itself publishes, so it sits just ahead of the per-cycle reactive
   [Board_activity]. [Own_recent_actions] is a window that advances with recorded tool-call turns,
   so it cannot hold a stable prefix and sits behind the sections that can.
   [Fleet_messages] carries any keeper's broadcast, so it is the most
   fleet-volatile section and sits last. *)
let ordered =
  [ Active_goals
  ; Current_task
  ; Approval_authority
  ; Connected_surfaces
  ; Namespace_state
  ; Workspace_memory
  ; Wiki
  ; Lane_updates
  ; Repository_freshness
  ; Autonomous_trigger
  ; Scheduled_automation
  ; Completion_authority
  ; Task_cancellations
  ; Pending_mentions
  ; Scope_messages
  ; Own_board_posts
  ; Board_activity
  ; Own_recent_actions
  ; Recent_work
  ; Fleet_messages
  ]
;;

(* Exhaustive over [layer_id]: adding a variant breaks this match at compile
   time, forcing both a position here and (via the [content_of] match at the
   call site) a rendering for the new layer. *)
let order_index = function
  | Active_goals -> 0
  | Current_task -> 1
  | Approval_authority -> 2
  | Connected_surfaces -> 3
  | Namespace_state -> 4
  | Workspace_memory -> 5
  | Wiki -> 6
  | Lane_updates -> 7
  | Repository_freshness -> 8
  | Autonomous_trigger -> 9
  | Scheduled_automation -> 10
  | Completion_authority -> 11
  | Task_cancellations -> 12
  | Pending_mentions -> 13
  | Scope_messages -> 14
  | Own_board_posts -> 15
  | Board_activity -> 16
  | Own_recent_actions -> 17
  | Recent_work -> 18
  | Fleet_messages -> 19
;;

type unattributed = World_frame | Host_workspace_recall | Direct_turn | Unprojected_input
type source = Layer of layer_id | Unattributed of unattributed
type resend_on_resume = Sent_when_changed | Sent_every_resume | Sent_with_other_sections
type section_rows =
  | Whole_section
  | Head_and_rows of { head : string; rows : string list; tail : string }
type span = { source : source; offset : int; bytes : int; sha256 : string; span_rows : section_rows }
type rendered = { text : string; spans : span list }
type prepared_content = { content_text : string; content_sha256 : string; content_rows : section_rows }
type section = { section_source : source; section_text : string; section_rows : section_rows }

let hash text = Digestif.SHA256.(digest_string text |> to_hex)
let prepare_content text = {content_text=text;content_sha256=hash text;content_rows=Whole_section}
let prepare_rows ~head ~rows ~tail =
  let content_text = head ^ String.concat "" rows ^ tail in
  let content_rows = match rows with
    | [] -> Whole_section
    | _ :: _ -> Head_and_rows { head; rows; tail } in
  {content_text;content_sha256=hash content_text;content_rows}
let text rendered = rendered.text
let prepared_span source offset content =
  {source;offset;bytes=String.length content.content_text;sha256=content.content_sha256;
   span_rows=content.content_rows}
let make_span source offset text =
  prepared_span source offset (prepare_content text)
let unattributed reason text =
  { text; spans = [make_span (Unattributed reason) 0 text] }
let append_unattributed rendered reason suffix =
  { text = rendered.text ^ suffix;
    spans = rendered.spans @ [make_span (Unattributed reason) (String.length rendered.text) suffix] }
let prepend_prepared_unattributed reason prefix rendered =
  { text = prefix.content_text ^ rendered.text;
    spans = prepared_span (Unattributed reason) 0 prefix ::
      List.map (fun span -> {span with offset = span.offset + String.length prefix.content_text}) rendered.spans }
let prepend_unattributed reason prefix rendered =
  prepend_prepared_unattributed reason (prepare_content prefix) rendered
let assemble_prepared ~content_of =
  let buffer = Buffer.create 256 in
  let spans = List.filter_map (fun layer ->
    match content_of layer with
    | None -> None
    | Some content ->
      let span = prepared_span (Layer layer) (Buffer.length buffer) content in
      Buffer.add_string buffer content.content_text;
      Some span) ordered in
  { text = Buffer.contents buffer; spans }
let assemble ~content_of =
  assemble_prepared ~content_of:(fun layer -> Option.map prepare_content (content_of layer))

let layer_name = function
  | Active_goals -> "active_goals"
  | Current_task -> "current_task"
  | Approval_authority -> "approval_authority"
  | Connected_surfaces -> "connected_surfaces"
  | Namespace_state -> "namespace_state"
  | Workspace_memory -> "workspace_memory"
  | Wiki -> "wiki"
  | Lane_updates -> "lane_updates"
  | Repository_freshness -> "repository_freshness"
  | Autonomous_trigger -> "autonomous_trigger"
  | Scheduled_automation -> "scheduled_automation"
  | Completion_authority -> "completion_authority"
  | Task_cancellations -> "task_cancellations"
  | Pending_mentions -> "pending_mentions"
  | Scope_messages -> "scope_messages"
  | Own_board_posts -> "own_board_posts"
  | Board_activity -> "board_activity"
  | Own_recent_actions -> "own_recent_actions"
  | Recent_work -> "recent_work"
  | Fleet_messages -> "fleet_messages"

let unattributed_name = function
  | World_frame -> "world_frame"
  | Host_workspace_recall -> "host_workspace_recall"
  | Direct_turn -> "direct_turn"
  | Unprojected_input -> "unprojected_input"

let source_name = function
  | Layer layer -> layer_name layer
  | Unattributed reason -> unattributed_name reason

let all_unattributed = [ World_frame; Host_workspace_recall; Direct_turn; Unprojected_input ]

let source_of_name name =
  List.map (fun layer -> Layer layer) ordered
  @ List.map (fun reason -> Unattributed reason) all_unattributed
  |> List.find_opt (fun source -> String.equal (source_name source) name)

(* See the mli. The inbox layers carry rows delivered for this turn (pending
   messages, Board and authority events, the consumed schedule wake) and the
   trigger says why this turn ran, so a repeat of their bytes is a new arrival.
   Every other layer projects state that holds until it changes. A whole
   dynamic context the renderer did not partition into layers
   ([Direct_turn], [Unprojected_input]) keeps the class the whole
   [Dynamic_context] block has ({!Prompt_block_id.resent_when_held}). *)
let resend_on_resume = function
  | Layer
      ( Active_goals | Current_task | Approval_authority | Connected_surfaces
      | Namespace_state | Workspace_memory | Wiki | Lane_updates | Repository_freshness
      | Own_board_posts | Own_recent_actions | Recent_work | Fleet_messages )
  | Unattributed (Host_workspace_recall | Direct_turn | Unprojected_input) ->
    Sent_when_changed
  | Layer
      ( Autonomous_trigger | Scheduled_automation | Completion_authority
      | Task_cancellations | Pending_mentions | Scope_messages | Board_activity ) ->
    Sent_every_resume
  | Unattributed World_frame -> Sent_with_other_sections

let sections rendered =
  List.map
    (fun span ->
       { section_source = span.source
       ; section_text = String.sub rendered.text span.offset span.bytes
       ; section_rows = span.span_rows
       })
    rendered.spans

let receipt_to_json rendered =
  let source_json = function
    | Layer layer -> `Assoc ["kind", `String "layer"; "layer", `String (layer_name layer)]
    | Unattributed reason ->
      `Assoc ["kind", `String "unattributed"; "reason", `String (unattributed_name reason)] in
  `Assoc ["schema", `String "masc.dynamic-context-partition.v1";
    "scope", `String "renderer_raw_utf8_not_delivery";
    "bytes", `Int (String.length rendered.text); "sha256", `String (hash rendered.text);
    "spans", `List (List.map (fun span -> `Assoc ["source", source_json span.source;
      "offset", `Int span.offset; "bytes", `Int span.bytes; "sha256", `String span.sha256]) rendered.spans)]
