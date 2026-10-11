(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
  | Active_goals
  | Current_task
  | Approval_authority
  | Connected_surfaces
  | Namespace_state
  | Workspace_memory
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
  | Lane_updates -> 6
  | Repository_freshness -> 7
  | Autonomous_trigger -> 8
  | Scheduled_automation -> 9
  | Completion_authority -> 10
  | Task_cancellations -> 11
  | Pending_mentions -> 12
  | Scope_messages -> 13
  | Own_board_posts -> 14
  | Board_activity -> 15
  | Own_recent_actions -> 16
  | Recent_work -> 17
  | Fleet_messages -> 18
;;

type unattributed = World_frame | Host_workspace_recall | Direct_turn | Unprojected_input
type source = Layer of layer_id | Unattributed of unattributed
type span = { source : source; offset : int; bytes : int; sha256 : string }
type rendered = { text : string; spans : span list }

let hash text = Digestif.SHA256.(digest_string text |> to_hex)
let text rendered = rendered.text
let make_span source offset text =
  { source; offset; bytes = String.length text; sha256 = hash text }
let unattributed reason text =
  { text; spans = [make_span (Unattributed reason) 0 text] }
let append_unattributed rendered reason suffix =
  { text = rendered.text ^ suffix;
    spans = rendered.spans @ [make_span (Unattributed reason) (String.length rendered.text) suffix] }
let prepend_unattributed reason prefix rendered =
  { text = prefix ^ rendered.text;
    spans = make_span (Unattributed reason) 0 prefix ::
      List.map (fun span -> {span with offset = span.offset + String.length prefix}) rendered.spans }
let assemble ~content_of =
  let buffer = Buffer.create 256 in
  let spans = List.filter_map (fun layer ->
    match content_of layer with
    | None -> None
    | Some text ->
      let span = make_span (Layer layer) (Buffer.length buffer) text in
      Buffer.add_string buffer text;
      Some span) ordered in
  { text = Buffer.contents buffer; spans }

let layer_name = function
  | Active_goals -> "active_goals"
  | Current_task -> "current_task"
  | Approval_authority -> "approval_authority"
  | Connected_surfaces -> "connected_surfaces"
  | Namespace_state -> "namespace_state"
  | Workspace_memory -> "workspace_memory"
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

let receipt_to_json rendered =
  let source_json = function
    | Layer layer -> `Assoc ["kind", `String "layer"; "layer", `String (layer_name layer)]
    | Unattributed reason -> `Assoc ["kind", `String "unattributed"; "reason", `String
        (match reason with World_frame -> "world_frame" | Host_workspace_recall -> "host_workspace_recall"
         | Direct_turn -> "direct_turn" | Unprojected_input -> "unprojected_input")] in
  `Assoc ["schema", `String "masc.dynamic-context-partition.v1";
    "scope", `String "renderer_raw_utf8_not_delivery";
    "bytes", `Int (String.length rendered.text); "sha256", `String (hash rendered.text);
    "spans", `List (List.map (fun span -> `Assoc ["source", source_json span.source;
      "offset", `Int span.offset; "bytes", `Int span.bytes; "sha256", `String span.sha256]) rendered.spans)]
