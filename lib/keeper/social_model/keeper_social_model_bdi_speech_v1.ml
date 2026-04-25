(** First concrete social-model implementation for the active baseline.

    This module owns the BDI-flavored transition logic; the registry decides
    when it is selected. *)

open Keeper_types

module Types = Keeper_social_model_types
module Protocol = Keeper_social_model_protocol

type input = {
  meta : keeper_meta;
  observation : Keeper_world_observation.world_observation;
  result : Keeper_agent_run.run_result;
  headers : (string * string) list;
  has_text_reply : bool;
}

type state = {
  social_model : string;
  belief_summary : string;
  active_desire : string option;
  current_intention : string option;
  blocker : string option;
  need : string option;
}

type output = {
  speech_act : Types.speech_act;
  delivery_surface : Types.delivery_surface;
}

type request_help_delivery =
  | Request_help_posted
  | Request_help_deduped
  | Request_help_failed

let state_of_social_state (state : Types.social_state) : state =
  {
    social_model = state.social_model;
    belief_summary = state.belief_summary;
    active_desire = state.active_desire;
    current_intention = state.current_intention;
    blocker = state.blocker;
    need = state.need;
  }

let to_social_state (state : state) (output : output) : Types.social_state =
  (* Gen8: cap narrative fields so previous_state on the next turn does
     not keep growing when speech_act=Stay_silent preserves state across
     turns. See Types.cap_social_state doc. *)
  Types.cap_social_state
    {
      social_model = state.social_model;
      belief_summary = state.belief_summary;
      active_desire = state.active_desire;
      current_intention = state.current_intention;
      blocker = state.blocker;
      need = state.need;
      speech_act = output.speech_act;
      delivery_surface = output.delivery_surface;
    }

let belief_summary_of_observation
    (observation : Keeper_world_observation.world_observation) : string =
  let parts =
    List.filter_map Fun.id
      [
        (if observation.pending_mentions <> [] then
           Some
             (Printf.sprintf "mentions=%d"
                (List.length observation.pending_mentions))
         else None);
        (if observation.pending_board_events <> [] then
           Some
             (Printf.sprintf "board_events=%d"
                (List.length observation.pending_board_events))
         else None);
        (if observation.pending_scope_messages <> [] then
           Some
             (Printf.sprintf "scope_messages=%d"
                (List.length observation.pending_scope_messages))
         else None);
        (if observation.unclaimed_task_count > 0 then
           Some
             (Printf.sprintf "unclaimed_tasks=%d" observation.unclaimed_task_count)
         else None);
        (if observation.claimable_task_count > 0 then
           Some
             (Printf.sprintf "claimable_tasks=%d" observation.claimable_task_count)
         else None);
        (if observation.failed_task_count > 0 then
           Some (Printf.sprintf "failed_tasks=%d" observation.failed_task_count)
         else None);
        (if observation.active_goals <> [] then
           Some
             (Printf.sprintf "active_goals=%d"
                (List.length observation.active_goals))
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

let make_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ?previous_state
    ?active_desire ?current_intention ?blocker ?need ?social_model
    ?belief_summary () =
  let carry explicit selector =
    match explicit with
    | Some _ -> explicit
    | None -> Option.bind previous_state selector
  in
  {
    social_model =
      Option.value
        ~default:(Types.normalize_social_model meta.social_model)
        social_model;
    belief_summary =
      Option.value ~default:(belief_summary_of_observation observation)
        belief_summary;
    active_desire = carry active_desire (fun state -> state.active_desire);
    current_intention =
      carry current_intention (fun state -> state.current_intention);
    blocker;
    need = carry need (fun state -> state.need);
  }

let protocol_violation_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation) ~(reason : string)
=
  ( make_state ~meta ~observation ?previous_state:None ?blocker:(Some reason)
      (),
    { speech_act = Types.Defer; delivery_surface = Types.Silent } )

let inferred_text_reply_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ?previous_state () =
  ( make_state ~meta ~observation ?previous_state (),
    { speech_act = Types.Inform; delivery_surface = Types.Visible_reply } )

let inferred_tool_surface tools =
  if tools = [ Tool_name.Keeper.to_string Tool_name.Keeper.Stay_silent ] then
    Some
      ( { speech_act = Types.Stay_silent; delivery_surface = Types.Silent }
      , Types.Tool_only_stay_silent )
  else if List.mem "keeper_board_comment" tools then
    Some
      ( {
          speech_act = Types.Comment_board;
          delivery_surface = Types.Board_comment;
        }
      , Types.Tool_only_comment_board )
  else if List.mem "keeper_board_post" tools then
    Some
      ( { speech_act = Types.Post_board; delivery_surface = Types.Board_post }
      , Types.Tool_only_post_board )
  else if List.mem "keeper_broadcast" tools then
    Some
      ( {
          speech_act = Types.Broadcast;
          delivery_surface = Types.Broadcast_surface;
        }
      , Types.Tool_only_broadcast )
  else if List.exists Keeper_tool_disclosure.is_claim_tool_name tools then
    Some
      ( {
          speech_act = Types.Claim_task;
          delivery_surface = Types.Task_claim_surface;
        }
      , Types.Tool_only_claim_task )
  else
    None

let tool_only_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(previous_state : state option)
    ~(result : Keeper_agent_run.run_result) =
  let output, transition_reason =
    match inferred_tool_surface result.tools_used with
    | Some routed -> routed
    | None ->
        ( {
            speech_act = Types.Inform;
            delivery_surface = Types.Visible_reply;
          }
        , Types.Tool_only_visible_reply )
  in
  (make_state ~meta ~observation ?previous_state (), output, transition_reason)

let social_state_of_headers ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(previous_state : state option) headers =
  match
    Protocol.nonempty_header_opt headers "SPEECH_ACT",
    Protocol.header_assoc_opt headers "DELIVERY_SURFACE"
  with
  | Some speech_raw, Some delivery_raw -> (
      match
        Types.speech_act_of_string speech_raw,
        Types.delivery_surface_of_string delivery_raw
      with
      | Some speech_act, Some delivery_surface ->
          let belief_summary =
            let max_len = 200 in
            let raw =
              Option.value
                ~default:(belief_summary_of_observation observation)
                (Protocol.nonempty_header_opt headers "BELIEF_SUMMARY")
            in
            if String.length raw <= max_len then raw
            else
              let truncated = String.sub raw 0 max_len in
              match String.rindex_opt truncated ' ' with
              | Some i when i > max_len / 2 -> String.sub raw 0 i
              | _ -> truncated
          in
          ( make_state ~meta ~observation
              ?previous_state
              ~social_model:
                (Types.normalize_social_model
                   (Option.value
                      ~default:meta.social_model
                      (Protocol.nonempty_header_opt headers "SOCIAL_MODEL")))
              ~belief_summary
              ?active_desire:
                (Protocol.nonempty_header_opt headers "ACTIVE_DESIRE")
              ?current_intention:
                (Protocol.nonempty_header_opt headers "CURRENT_INTENTION")
              ?blocker:(Protocol.nonempty_header_opt headers "BLOCKER")
              ?need:(Protocol.nonempty_header_opt headers "NEED")
              (),
            { speech_act; delivery_surface },
            Types.Explicit_social_headers )
      | _ ->
          let state, output =
            protocol_violation_state ~meta ~observation
              ~reason:"invalid social headers"
          in
          (state, output, Types.Protocol_violation_invalid_social_headers))
  | _ ->
      let state, output =
        protocol_violation_state ~meta ~observation
          ~reason:"missing social headers"
      in
      (state, output, Types.Protocol_violation_missing_social_headers)

let should_dedupe_request_help ~(meta : keeper_meta) ~(blocker : string option) =
  match blocker with
  | None -> false
  | Some blocker ->
      String.equal blocker (String.trim meta.runtime.last_blocker)
      && String.equal meta.runtime.last_speech_act "request_help"
      && meta.runtime.proactive_rt.last_ts > 0.0
      && Time_compat.now () -. meta.runtime.proactive_rt.last_ts
         < float_of_int meta.proactive.cooldown_sec

let request_help_post_body ~(meta : keeper_meta)
    ~(state : Types.social_state) blocker =
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

let deliver_request_help_post ~(meta : keeper_meta)
    ~(state : Types.social_state) =
  match state.blocker with
  | None -> Request_help_failed
  | Some blocker when should_dedupe_request_help ~meta ~blocker:(Some blocker)
    ->
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
              ( "speech_act",
                `String (Types.speech_act_to_string state.speech_act) );
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
          ~post_kind:Board.Automation_post ?meta_json
          ~visibility:Board.Internal ~ttl_hours:24 ~hearth:"keepers" ()
      with
      | Ok _ -> Request_help_posted
      | Error _ -> Request_help_failed

let transition (previous_state : state option) (input : input) =
  let meta = input.meta in
  let observation = input.observation in
  let result = input.result in
  if result.tools_used <> [] then
    tool_only_state ~meta ~observation ~previous_state ~result
  else if input.headers <> [] then
    let state, output, transition_reason =
      social_state_of_headers ~meta ~observation ~previous_state input.headers
    in
    if input.has_text_reply
       &&
       match state.blocker with
       | Some "missing social headers" | Some "invalid social headers" -> true
       | _ -> false
    then
      let state, output =
        inferred_text_reply_state ~meta ~observation ?previous_state ()
      in
      let fallback_reason =
        match transition_reason with
        | Types.Protocol_violation_missing_social_headers ->
            Types.Missing_headers_fallback_visible_reply
        | Types.Protocol_violation_invalid_social_headers ->
            Types.Invalid_headers_fallback_visible_reply
        | _ ->
            Types.Inferred_visible_reply
      in
      (state, output, fallback_reason)
    else
      (state, output, transition_reason)
  else if input.has_text_reply then
    let state, output =
      inferred_text_reply_state ~meta ~observation ?previous_state ()
    in
    (state, output, Types.Inferred_visible_reply)
  else
    let state, output =
      protocol_violation_state ~meta ~observation
        ~reason:"no tool calls and no social headers"
    in
    (state, output, Types.Protocol_violation_no_tools_no_social_headers)

let apply_output_to_result ~(meta : keeper_meta)
    ~(result : Keeper_agent_run.run_result)
    ~(visible_response_body : string) (state : Types.social_state) =
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
      let response_text =
        match
          Keeper_tool_disclosure.normalize_response_text
            ~text:visible_response_body
            ~tool_names:result.tools_used ()
        with
        | Ok normalized -> normalized
        | Error _ -> visible_response_body
      in
      ({ result with response_text }, state)

let apply_to_result ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(previous_state : Types.social_state option)
    (result : Keeper_agent_run.run_result) =
  let headers, response_body =
    Protocol.parse_header_block result.response_text
  in
  let visible_response_body =
    Keeper_text_processing.strip_internal_reply_markup response_body
  in
  let input =
    {
      meta;
      observation;
      result;
      headers;
      has_text_reply = String.trim visible_response_body <> "";
    }
  in
  let prior_state = Option.map state_of_social_state previous_state in
  let state, output, transition_reason = transition prior_state input in
  let social_state = to_social_state state output in
  let result, social_state =
    apply_output_to_result ~meta ~result ~visible_response_body social_state
  in
  (result, social_state, transition_reason)

let derive_failure_state ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(previous_state : Types.social_state option)
    ~(is_auto_recoverable : bool)
    ~(reason : string) =
  let previous_state = Option.map state_of_social_state previous_state in
  let blocker =
    match String.trim reason with
    | "" -> None
    | value -> Some (short_preview value)
  in
  let state =
    if is_auto_recoverable && observation.claimable_task_count > 0 then
      make_state ~meta ~observation ?previous_state
        ~active_desire:"recover_tool_route"
        ~current_intention:"retry_claim_after_recovery"
        ?blocker
        ~need:"provider_recovery_or_operator_guidance"
        ()
    else
      make_state ~meta ~observation ?previous_state ?blocker ()
  in
  let output =
    { speech_act = Types.Defer; delivery_surface = Types.Silent }
  in
  (to_social_state state output, Types.Failure_run_error)
