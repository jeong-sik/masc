(** Keeper_social_model — keeper-side social routing for unified turns. *)

open Keeper_types

type speech_act =
  | Stay_silent
  | Inform
  | Request_help
  | Claim_task
  | Comment_board
  | Post_board
  | Broadcast
  | Defer

type delivery_surface =
  | Silent
  | Visible_reply
  | Board_post
  | Board_comment
  | Task_claim_surface
  | Broadcast_surface

type social_state = {
  social_model : string;
  belief_summary : string;
  active_desire : string option;
  current_intention : string option;
  blocker : string option;
  need : string option;
  speech_act : speech_act;
  delivery_surface : delivery_surface;
}

let speech_act_to_string = function
  | Stay_silent -> "stay_silent"
  | Inform -> "inform"
  | Request_help -> "request_help"
  | Claim_task -> "claim_task"
  | Comment_board -> "comment_board"
  | Post_board -> "post_board"
  | Broadcast -> "broadcast"
  | Defer -> "defer"

let delivery_surface_to_string = function
  | Silent -> "silent"
  | Visible_reply -> "visible_reply"
  | Board_post -> "board_post"
  | Board_comment -> "board_comment"
  | Task_claim_surface -> "task_claim"
  | Broadcast_surface -> "broadcast"

let speech_act_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "stay_silent" -> Some Stay_silent
  | "inform" -> Some Inform
  | "request_help" -> Some Request_help
  | "claim_task" -> Some Claim_task
  | "comment_board" -> Some Comment_board
  | "post_board" -> Some Post_board
  | "broadcast" -> Some Broadcast
  | "defer" -> Some Defer
  | _ -> None

let delivery_surface_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "silent" -> Some Silent
  | "visible_reply" -> Some Visible_reply
  | "board_post" -> Some Board_post
  | "board_comment" -> Some Board_comment
  | "task_claim" -> Some Task_claim_surface
  | "broadcast" -> Some Broadcast_surface
  | _ -> None

let parse_header_line line =
  match String.index_opt line ':' with
  | None -> None
  | Some idx ->
      let key = String.sub line 0 idx |> String.trim in
      let value =
        String.sub line (idx + 1) (String.length line - idx - 1) |> String.trim
      in
      if key = "" then None else Some (key, value)

let is_social_header_key = function
  | "SOCIAL_MODEL"
  | "BELIEF_SUMMARY"
  | "ACTIVE_DESIRE"
  | "CURRENT_INTENTION"
  | "BLOCKER"
  | "NEED"
  | "SPEECH_ACT"
  | "DELIVERY_SURFACE" ->
      true
  | _ -> false

let parse_header_block raw =
  let lines = String.split_on_char '\n' raw in
  let rec consume acc = function
    | line :: rest -> (
        match parse_header_line line with
        | Some (key, value) when is_social_header_key key ->
            consume ((key, value) :: acc) rest
        | _ -> (List.rev acc, line :: rest))
    | [] -> (List.rev acc, [])
  in
  let headers, body_lines = consume [] lines in
  (headers, String.concat "\n" body_lines |> String.trim)

let header_assoc_opt headers key =
  headers
  |> List.find_map (fun (header_key, value) ->
         if String.equal header_key key then Some value else None)

let nonempty_header_opt headers key =
  match header_assoc_opt headers key with
  | Some value -> (
      match String.lowercase_ascii (String.trim value) with
      | "" | "none" | "null" -> None
      | _ -> Some (String.trim value))
  | None -> None

let belief_summary_of_observation
    (observation : Keeper_world_observation.world_observation) : string =
  let parts =
    List.filter_map Fun.id [
      (if observation.pending_mentions <> [] then
         Some (Printf.sprintf "mentions=%d" (List.length observation.pending_mentions))
       else None);
      (if observation.pending_board_events <> [] then
         Some (Printf.sprintf "board_events=%d"
                 (List.length observation.pending_board_events))
       else None);
      (if observation.pending_scope_messages <> [] then
         Some
           (Printf.sprintf "scope_messages=%d"
              (List.length observation.pending_scope_messages))
       else None);
      (if observation.unclaimed_task_count > 0 then
         Some (Printf.sprintf "unclaimed_tasks=%d" observation.unclaimed_task_count)
       else None);
      (if observation.failed_task_count > 0 then
         Some (Printf.sprintf "failed_tasks=%d" observation.failed_task_count)
       else None);
      (if observation.active_goals <> [] then
         Some (Printf.sprintf "active_goals=%d" (List.length observation.active_goals))
       else None);
      (if observation.idle_seconds > 0 then
         Some (Printf.sprintf "idle=%ds" observation.idle_seconds)
       else None);
      (if Option.is_some observation.worktree_change_summary then
         Some "worktree_delta"
       else None);
    ]
  in
  match parts with
  | [] -> "quiet_room"
  | _ -> String.concat "; " parts

let protocol_violation_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation) ~(reason : string)
    =
  {
    social_model = meta.social_model;
    belief_summary = belief_summary_of_observation observation;
    active_desire = None;
    current_intention = None;
    blocker = Some reason;
    need = None;
    speech_act = Defer;
    delivery_surface = Silent;
  }

let inferred_text_reply_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation) =
  {
    social_model = meta.social_model;
    belief_summary = belief_summary_of_observation observation;
    active_desire = None;
    current_intention = None;
    blocker = None;
    need = None;
    speech_act = Inform;
    delivery_surface = Visible_reply;
  }

let inferred_tool_surface tools =
  if tools = [ "keeper_stay_silent" ] then
    Some (Stay_silent, Silent)
  else if List.mem "keeper_board_comment" tools then
    Some (Comment_board, Board_comment)
  else if List.mem "keeper_board_post" tools then
    Some (Post_board, Board_post)
  else if List.mem "keeper_broadcast" tools then
    Some (Broadcast, Broadcast_surface)
  else if List.mem "keeper_task_claim" tools || List.mem "masc_claim_next" tools then
    Some (Claim_task, Task_claim_surface)
  else
    None

let tool_only_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(result : Keeper_agent_run.run_result) =
  let speech_act, delivery_surface =
    match inferred_tool_surface result.tools_used with
    | Some routed -> routed
    | None ->
        if String.trim result.response_text <> "" then (Inform, Visible_reply)
        else (Defer, Silent)
  in
  {
    social_model = meta.social_model;
    belief_summary = belief_summary_of_observation observation;
    active_desire = None;
    current_intention = None;
    blocker = None;
    need = None;
    speech_act;
    delivery_surface;
  }

let social_state_of_headers ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation) headers =
  match nonempty_header_opt headers "SPEECH_ACT", header_assoc_opt headers "DELIVERY_SURFACE" with
  | Some speech_raw, Some delivery_raw -> (
      match
        speech_act_of_string speech_raw,
        delivery_surface_of_string delivery_raw
      with
      | Some speech_act, Some delivery_surface ->
          {
            social_model =
              Option.value
                ~default:meta.social_model
                (nonempty_header_opt headers "SOCIAL_MODEL");
            belief_summary =
              (let max_len = 200 in
               let raw = Option.value
                ~default:(belief_summary_of_observation observation)
                (nonempty_header_opt headers "BELIEF_SUMMARY") in
               if String.length raw <= max_len then raw
               else
                 (* Truncate at last space before limit to avoid splitting
                    multi-byte UTF-8 characters or mid-word cuts. *)
                 let truncated = String.sub raw 0 max_len in
                 match String.rindex_opt truncated ' ' with
                 | Some i when i > max_len / 2 -> String.sub raw 0 i
                 | _ -> truncated);
            active_desire = nonempty_header_opt headers "ACTIVE_DESIRE";
            current_intention = nonempty_header_opt headers "CURRENT_INTENTION";
            blocker = nonempty_header_opt headers "BLOCKER";
            need = nonempty_header_opt headers "NEED";
            speech_act;
            delivery_surface;
          }
      | _ ->
          protocol_violation_state ~meta ~observation
            ~reason:"invalid social headers")
  | _ ->
      protocol_violation_state ~meta ~observation
        ~reason:"missing social headers"

let should_dedupe_request_help ~(meta : keeper_meta) ~(blocker : string option) =
  match blocker with
  | None -> false
  | Some blocker ->
      String.equal blocker (String.trim meta.runtime.last_blocker)
      && String.equal meta.runtime.last_speech_act "request_help"
      && meta.runtime.proactive_rt.last_ts > 0.0
      && Time_compat.now () -. meta.runtime.proactive_rt.last_ts
         < float_of_int meta.proactive.cooldown_sec

let request_help_post_body ~(meta : keeper_meta) ~(state : social_state) blocker =
  String.concat "\n"
    [
      Printf.sprintf "keeper `%s` is blocked." meta.name;
      Printf.sprintf "goal: %s" meta.goal;
      Printf.sprintf "beliefs: %s" state.belief_summary;
      (match state.current_intention with
      | Some value -> "intended action: " ^ value
      | None -> "intended action: unspecified");
      "blocker: " ^ blocker;
      (match state.need with
      | Some value -> "need: " ^ value
      | None -> "need: guidance");
      "retry condition: external capability or operator guidance becomes available";
    ]

type request_help_delivery =
  | Request_help_posted
  | Request_help_deduped
  | Request_help_failed

let deliver_request_help_post ~(meta : keeper_meta) ~(state : social_state) =
  match state.blocker with
  | None -> Request_help_failed
  | Some blocker when should_dedupe_request_help ~meta ~blocker:(Some blocker) ->
      Request_help_deduped
  | Some blocker ->
      let title = Printf.sprintf "[keeper-blocked] %s needs help" meta.name in
      let body = request_help_post_body ~meta ~state blocker in
      let meta_json =
        Some
          (`Assoc
            [
              ("source", `String "keeper_board_post");
              ("social_model", `String state.social_model);
              ("speech_act", `String (speech_act_to_string state.speech_act));
              ("keeper_name", `String meta.name);
              ("agent_name", `String meta.agent_name);
              ("belief_summary", `String state.belief_summary);
              ("blocker", `String blocker);
              ( "need",
                match state.need with
                | Some value -> `String value
                | None -> `Null );
            ])
      in
      match
        Board_dispatch.create_post ~author:meta.name ~title ~body ~content:body
          ~post_kind:Board.Automation_post ?meta_json ~visibility:Board.Internal
          ~ttl_hours:24 ~hearth:"keepers" ()
      with
      | Ok _ -> Request_help_posted
      | Error _ -> Request_help_failed

let apply_to_result ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    (result : Keeper_agent_run.run_result) =
  let headers, response_body = parse_header_block result.response_text in
  let has_text_reply = String.trim response_body <> "" in
  let state =
    (* Tool calls are the authoritative record of action.
       When tools are present, infer social state from tool calls regardless
       of whether BDI headers were also emitted. This ensures deterministic
       observation: the system reads what the agent DID (tool calls), not what
       it DECLARED (text headers). *)
    if result.tools_used <> [] then
      tool_only_state ~meta ~observation ~result
    else if headers <> [] then
      let state = social_state_of_headers ~meta ~observation headers in
      if has_text_reply
         &&
         match state.blocker with
         | Some "missing social headers" | Some "invalid social headers" -> true
         | _ -> false
      then
        inferred_text_reply_state ~meta ~observation
      else
        state
    else if has_text_reply then
      inferred_text_reply_state ~meta ~observation
    else
      protocol_violation_state ~meta ~observation
        ~reason:"no tool calls and no social headers"
  in
  match state.speech_act, state.delivery_surface with
  | Request_help, Board_post when result.tools_used = [] ->
      (match deliver_request_help_post ~meta ~state with
      | Request_help_posted ->
          let tools_used =
            dedupe_keep_order ("keeper_board_post" :: result.tools_used)
          in
          ( { result with
              response_text = "";
              tools_used;
              tool_calls_made = List.length tools_used;
            },
            state )
      | Request_help_deduped | Request_help_failed ->
          ({ result with response_text = "" }, state))
  | Defer, Silent ->
      ({ result with response_text = "" }, state)
  | Stay_silent, Silent when result.tools_used = [] ->
      ({ result with response_text = "" }, state)
  | _ ->
      ({ result with response_text = response_body }, state)

let derive_failure_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(reason : string) =
  {
    social_model = meta.social_model;
    belief_summary = belief_summary_of_observation observation;
    active_desire = None;
    current_intention = None;
    blocker =
      (match String.trim reason with
      | "" -> None
      | value -> Some (short_preview value));
    need = None;
    speech_act = Defer;
    delivery_surface = Silent;
  }
