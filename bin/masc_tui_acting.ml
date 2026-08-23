module Observer = Masc_tui_observer

type filter =
  | Actions
  | Everything

let next_filter = function Actions -> Everything | Everything -> Actions
let filter_label = function Actions -> "actions" | Everything -> "everything"

let visible filter (event : Observer.event) =
  match filter with
  | Everything -> true
  | Actions -> (
      match event with
      | Observer.Agent_core { Observer.kind = Observer.Telemetry; _ } -> false
      | Observer.Agent_core _ -> true
      | Observer.Keeper_heartbeat _ | Observer.Keeper_composite_changed _
      | Observer.Snapshot _ ->
          false
      | Observer.Keeper_turn_complete _ | Observer.Keeper_chat_appended _
      | Observer.Other _ ->
          true)

type glyph =
  | Call_started
  | Call_returned
  | Turn_boundary
  | Turn_settled
  | Failure
  | Attention
  | Quiet

let glyph_text = function
  | Call_started -> "\xe2\x96\xb6"
  | Call_returned -> "\xe2\x9c\x93"
  | Turn_boundary -> "\xe2\x97\x8f"
  | Turn_settled -> "\xe2\x96\xa0"
  | Failure -> "\xe2\x9c\x97"
  | Attention -> "?"
  | Quiet -> "\xc2\xb7"

type row = {
  at : float;
  keeper : string;
  glyph : glyph;
  label : string;
  detail : string;
}

let elapsed_text ms =
  if ms < 1000. then Printf.sprintf "%.0fms" ms
  else if ms < 60_000. then Printf.sprintf "%.1fs" (ms /. 1000.)
  else
    let seconds = int_of_float (ms /. 1000.) in
    Printf.sprintf "%dm%02ds" (seconds / 60) (seconds mod 60)

let turn_text = function
  | Some turn -> Printf.sprintf "turn %d" turn
  | None -> "turn ?"

let batch_text = function
  | Some (index, size) -> Printf.sprintf " [%d/%d]" (index + 1) size
  | None -> ""

let agent_core_row ~duration_ms (e : Observer.agent_core) =
  let tool = Option.value ~default:"?" e.Observer.tool in
  let glyph, label, detail =
    match e.Observer.kind with
    | Observer.Tool_called ->
        ( Call_started
        , "call"
        , Printf.sprintf "%s%s \xc2\xb7 %s" tool (batch_text e.Observer.batch)
            (turn_text e.Observer.turn) )
    | Observer.Tool_completed ->
        ( Call_returned
        , "returned"
        , Printf.sprintf "%s%s%s" tool
            (match duration_ms with
             | Some ms -> " \xc2\xb7 " ^ elapsed_text ms
             | None -> "")
            (batch_text e.Observer.batch) )
    | Observer.Turn_started -> (Turn_boundary, "turn start", turn_text e.Observer.turn)
    | Observer.Turn_ready -> (Turn_boundary, "turn ready", turn_text e.Observer.turn)
    | Observer.Turn_completed ->
        (Turn_boundary, "turn end", turn_text e.Observer.turn)
    | Observer.Agent_started -> (Turn_boundary, "agent start", "")
    | Observer.Agent_completed -> (Turn_settled, "agent done", "")
    | Observer.Agent_failed -> (Failure, "agent failed", "")
    | Observer.Agent_yielded -> (Quiet, "agent yielded", "")
    | Observer.Tool_approval_completed -> (Attention, "approval settled", tool)
    | Observer.Telemetry -> (Quiet, "telemetry", "")
    | Observer.Agent_core_other name -> (Attention, name, tool)
  in
  let detail =
    match e.Observer.task with
    | Some task when detail = "" -> task
    | Some task -> detail ^ " \xc2\xb7 " ^ task
    | None -> detail
  in
  { at = e.Observer.at; keeper = e.Observer.agent; glyph; label; detail }

let row_of_event ~duration_ms (event : Observer.event) =
  match event with
  | Observer.Agent_core e -> agent_core_row ~duration_ms e
  | Observer.Keeper_heartbeat h ->
      { at = h.Observer.hb_at
      ; keeper = h.Observer.hb_keeper
      ; glyph = Quiet
      ; label = "heartbeat"
      ; detail =
          (match h.Observer.hb_in_flight_ms with
           | Some ms when h.Observer.hb_in_turn ->
               Printf.sprintf "%s \xc2\xb7 in turn for %s" h.Observer.hb_phase
                 (elapsed_text ms)
           | Some _ | None -> h.Observer.hb_phase)
      }
  | Observer.Keeper_turn_complete t ->
      let tokens =
        match (t.Observer.tc_input_tokens, t.Observer.tc_output_tokens) with
        | Some i, Some o -> Printf.sprintf " \xc2\xb7 in %d out %d" i o
        | Some i, None -> Printf.sprintf " \xc2\xb7 in %d" i
        | None, Some o -> Printf.sprintf " \xc2\xb7 out %d" o
        | None, None -> ""
      in
      let cost =
        match t.Observer.tc_cost_usd with
        | Some usd -> Printf.sprintf " \xc2\xb7 $%.4f" usd
        | None -> ""
      in
      let calls =
        match t.Observer.tc_tool_calls with
        | Some n -> Printf.sprintf " \xc2\xb7 %d call%s" n (if n = 1 then "" else "s")
        | None -> ""
      in
      { at = t.Observer.tc_at
      ; keeper = t.Observer.tc_keeper
      ; glyph = Turn_settled
      ; label = "turn settled"
      ; detail = turn_text t.Observer.tc_turn ^ tokens ^ cost ^ calls
      }
  | Observer.Keeper_composite_changed { keeper; at } ->
      { at; keeper; glyph = Quiet; label = "composite"; detail = "" }
  | Observer.Keeper_chat_appended { keeper; connector; at } ->
      { at
      ; keeper
      ; glyph = Turn_boundary
      ; label = "chat"
      ; detail = Option.value ~default:"" connector
      }
  | Observer.Snapshot name ->
      { at = 0.; keeper = "server"; glyph = Quiet; label = "snapshot"; detail = name }
  | Observer.Other name ->
      { at = 0.; keeper = "server"; glyph = Attention; label = name; detail = "" }

let duration_of_completion ~before (completed : Observer.agent_core) =
  match completed.Observer.tool_use_id with
  | None -> None
  | Some id ->
      List.find_map
        (fun (event : Observer.event) ->
          match event with
          | Observer.Agent_core
              { Observer.kind = Observer.Tool_called
              ; tool_use_id = Some started_id
              ; agent
              ; at
              ; _
              }
            when String.equal started_id id
                 && String.equal agent completed.Observer.agent ->
              Some ((completed.Observer.at -. at) *. 1000.)
          | Observer.Agent_core _ | Observer.Keeper_heartbeat _
          | Observer.Keeper_turn_complete _ | Observer.Keeper_composite_changed _
          | Observer.Keeper_chat_appended _ | Observer.Snapshot _ | Observer.Other _
            ->
              None)
        before
