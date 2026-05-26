(** Keeper_unified_prompt_format — format helpers and autonomous trigger
    lines extracted from [Keeper_unified_prompt] (616 LoC).
    Board event rendering, mention/goal/scope-message formatting,
    [line_block], and [autonomous_trigger_lines].
    @since Keeper 500-line decomposition *)

open Keeper_types

(** Format a list of (from_agent, content) mentions into a prompt section. *)
let format_mentions (mentions : (string * string) list) : string =
  String.concat "\n"
    (List.map
       (fun (from_agent, content) ->
         Printf.sprintf "- @%s: %s" from_agent
           (Keeper_types.short_preview ~max_len:200 content))
       mentions)

let scope_message_prompt_limit = 12
let scope_message_preview_len = 120

let take_last_with_omitted limit items =
  let len = List.length items in
  if len <= limit then (items, 0)
  else
    let rec drop n xs =
      if n <= 0 then xs
      else
        match xs with
        | [] -> []
        | _ :: rest -> drop (n - 1) rest
    in
    (drop (len - limit) items, len - limit)

(** Format active goals into a prompt section. *)
let format_goals (goal_ids : string list) : string =
  String.concat "\n"
    (List.map (fun gid -> Printf.sprintf "- %s" gid) goal_ids)

let format_scope_messages
    (messages : (string * string) list) : string =
  let shown_messages, omitted =
    take_last_with_omitted scope_message_prompt_limit messages
  in
  let omitted_line =
    if omitted <= 0 then []
    else
      [
        Printf.sprintf
          "- [omitted %d older scope messages; cursor still advances past the full batch]"
          omitted;
      ]
  in
  String.concat "\n"
    (omitted_line
     @ List.map
         (fun (from_agent, content) ->
           Printf.sprintf "- %s: %s"
             from_agent
             (Keeper_types.short_preview ~max_len:scope_message_preview_len content))
         shown_messages)

let format_board_events
    (events : Keeper_world_observation.pending_board_event list) : string =
  String.concat "\n"
    (List.map
       (fun (event : Keeper_world_observation.pending_board_event) ->
         let kind =
           match event.post_kind with
           | Board.Human_post -> "direct"
           | Board.Automation_post -> "automation"
           | Board.System_post -> "system"
         in
         let mention_note =
           if event.explicit_mention then
             let targets =
               match event.matched_targets with
               | [] -> "explicit mention"
               | xs -> "mentions " ^ String.concat ", " xs
             in
             " [" ^ targets ^ "]"
           else ""
         in
         let hearth_note =
           match event.hearth with
           | Some hearth when String.trim hearth <> "" -> " {" ^ hearth ^ "}"
           | _ -> ""
         in
         let self_note =
           if event.self_commented && event.new_external_since > 0 then
             Printf.sprintf " [%d new reply since yours%s]"
               event.new_external_since
               (match event.latest_external_author, event.latest_external_preview with
                | Some a, Some p -> Printf.sprintf ", latest by %s: %s" a p
                | _ -> "")
           else ""
         in
         Printf.sprintf "- [%s] post_id=%s title=%S author=%s%s%s%s preview: %s"
           kind
           event.post_id
           (Keeper_types.short_preview ~max_len:80 event.title)
           event.author
           hearth_note
           mention_note
           self_note
           event.preview)
       events)

let line_block label value =
  if value = "" then ""
  else Printf.sprintf "%s: %s\n" label value

(* --- Autonomous trigger lines (from build_prompt helpers) --- *)

let autonomous_trigger_lines
    ~(decision : Keeper_world_observation.keeper_cycle_decision)
    ~(observation : Keeper_world_observation.world_observation) : string list =
  match decision.channel, decision.should_run with
  | Keeper_world_observation.Scheduled_autonomous, true ->
      let lines =
        [
          Some "- Scheduler: scheduled autonomous keepalive turn.";
          (match Keeper_world_observation.verdict_reasons_to_strings decision.verdict with
           | [] -> None
           | reasons ->
               Some
                 (Printf.sprintf "- Reasons: %s"
                    (String.concat ", " reasons)));
          (match decision.idle_gate_sec with
           | Some idle_gate ->
               Some
                 (Printf.sprintf "- Idle gate: %ds (current idle: %ds)"
                    idle_gate observation.idle_seconds)
           | None -> None);
          (match decision.since_last_scheduled_autonomous, decision.effective_cooldown with
           | Some since_last, Some cooldown ->
               Some
                 (Printf.sprintf
                    "- Since last autonomous turn: %ds, effective cooldown: %ds"
                    since_last cooldown)
           | _ -> None);
          (match decision.task_reactive_cooldown with
           | Some cooldown
             when observation.claimable_task_count > 0
                  || observation.failed_task_count > 0 ->
               Some
                 (Printf.sprintf
                    "- Backlog acceleration cooldown: %ds for claimable/failed tasks"
                    cooldown)
           | _ -> None);
        ]
      in
      List.filter_map Fun.id lines
  | _ -> []
