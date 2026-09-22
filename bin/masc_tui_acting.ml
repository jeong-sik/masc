module Observer = Masc_tui_observer

type filter =
  | Turns
  | Actions
  | Everything

let next_filter = function
  | Turns -> Actions
  | Actions -> Everything
  | Everything -> Turns

let filter_label = function
  | Turns -> "turns"
  | Actions -> "actions"
  | Everything -> "everything"

let filter_explanation = function
  | Turns ->
      "scope turns · one row per Keeper turn · agent start/done = internal run"
  | Actions ->
      "scope actions · flat calls/returns/turn/chat · state pushes hidden"
  | Everything ->
      (* The middle dot left this line with the mark it named. #33691 took the
         dot off a quiet row -- it read as the roster's idle glyph -- so
         [glyph_text Quiet] draws a blank cell and gray is the only cue a
         quiet row still carries. The legend went on naming the dot, on a row
         whose own separator is that same dot, so the reader could not tell
         which of the three was being explained. *)
      "scope everything · gray = state/telemetry · composite = Keeper snapshot changed"
;;

(* One feed event as the screen holds it. The arrival time is here rather than
   read back off the event because the screen is a feed: rows are held and
   drawn in the order they arrived, and two event kinds carry no clock at all
   ([Snapshot], [Other]) -- those rows used to draw --:--:--, on 925 of the
   927 rows on the screen that prompted this. *)
type entry = {
  ae_at : float;  (** when the TUI received it *)
  ae_event : Observer.event;
}

let visible filter (event : Observer.event) =
  match filter with
  | Everything -> true
  | Turns | Actions -> (
      match event with
      | Observer.Agent_core { Observer.kind = Observer.Telemetry; _ } -> false
      | Observer.Agent_core _ -> true
      | Observer.Keeper_heartbeat _ | Observer.Keeper_composite_changed _
      | Observer.Snapshot _
      (* A reply sends one stream frame per token, and a queue-size change is
         state rather than something a keeper did. Both belong with the
         heartbeat: shown under [Everything], never counted as an action. *)
      | Observer.Keeper_chat_stream_frame _
      | Observer.Keeper_waiting_inventory_changed _
      (* A provider-call observation is identity the fold reads, not
         something a keeper did. *)
      | Observer.Keeper_turn_observation _
      (* Server push, same verdict as the whole-projection snapshots: a
         deliberation changing stage is something the server reports, not
         something a keeper did. *)
      | Observer.Fusion_run_status _ ->
          false
      | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
      | Observer.Keeper_chat_appended _ | Observer.Other _ ->
          true)

(* Trimming the ring by arrival alone let one class of event evict every
   other. [acting_retained_entries] was sized against a feed of about four
   events a second, and a chat stream sends one frame per token: a single
   thousand-token reply fills the whole ring, and the calls and settlements
   an operator opened this screen for are gone before they can read them.

   So the budget is per class, using the same predicate the screen filters
   with -- what [Actions] shows gets [actions] slots, everything else gets
   [quiet]. Every class keeps its newest and the rest is counted, not
   silently forgotten. Entries arrive newest-first and stay in that order.

   A turn observation spends an action slot although no scope but
   [Everything] draws it. The Turns fold reads it to number the calls it
   reports, so it has to leave the ring with those calls, neither before nor
   after them. Among the quiet class, token-sized stream frames trim it
   before its calls and the turn splits back into unnumbered rows. Held past
   its calls, it still answers for its ordinal when a session created
   without a checkpoint reaches that ordinal again, and the new call in
   flight opens a row under the old keeper turn. In the action budget it
   leaves in arrival order with the frames around it. *)
let retained_as_action (event : Observer.event) =
  match event with
  | Observer.Keeper_turn_observation _ -> true
  | Observer.Agent_core _ | Observer.Keeper_heartbeat _
  | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
  | Observer.Keeper_composite_changed _ | Observer.Keeper_chat_appended _
  | Observer.Keeper_chat_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _
  | Observer.Fusion_run_status _ | Observer.Snapshot _ | Observer.Other _ ->
      visible Actions event

let retain ~actions ~quiet ~event_of entries =
  let rec walk kept n_actions n_quiet dropped = function
    | [] -> (List.rev kept, dropped)
    | entry :: older ->
        let is_action = retained_as_action (event_of entry) in
        let used = if is_action then n_actions else n_quiet in
        let budget = if is_action then actions else quiet in
        if used >= budget then walk kept n_actions n_quiet (dropped + 1) older
        else
          walk (entry :: kept)
            (if is_action then n_actions + 1 else n_actions)
            (if is_action then n_quiet else n_quiet + 1)
            dropped older
  in
  walk [] 0 0 0 entries

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
  (* A quiet row claims no state, so it draws no mark: a blank first cell.
     [\xc2\xb6] here read as the roster's idle glyph -- the same character
     saying two things in one line (#33691). The label beside the cell
     names the row. *)
  | Quiet -> " "

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

(* The keeper turn a provider call belongs to, as the keeper's hook reports
   it: [total_turns] keeper turns had completed when the call ran, so the
   call is inside turn [total_turns + 1] -- the registry's own definition of
   a turn id and the number the turn's settle carries. *)
let keeper_turn_of_observation (o : Observer.keeper_turn_observation) =
  Option.map succ o.Observer.to_total_turns

let batch_text = function
  | Some (index, size) -> Printf.sprintf " [%d/%d]" (index + 1) size
  | None -> ""

(* Mirrors Keeper_tool_composition_catalog.{skill_tool_name,tool_name_prefix}.
   Those tool names are a stable wire contract (RFC skills-as-tools keeps
   them identical across migrations); this projection library deliberately
   depends only on the observer, so it names them instead of linking the
   keeper catalog. Display tagging only — never a dispatch decision. *)
let skill_read_tool_name = "keeper_skill"
let composition_tool_name_prefix = "keeper_compose_"

let is_skill_tool tool =
  String.equal tool skill_read_tool_name
  || String.starts_with ~prefix:composition_tool_name_prefix tool

let agent_core_row ~at ~duration_ms (e : Observer.agent_core) =
  let tool = Option.value ~default:"?" e.Observer.tool in
  let glyph, label, detail =
    match e.Observer.kind with
    (* The wire's [turn] is the agent session's ordinal for the provider
       call, not the keeper's turn number that [turn N] means everywhere else
       on this surface, so a flat row does not print it; the event evidence
       shows it under its own name. *)
    | Observer.Tool_called ->
        ( Call_started
        , (if is_skill_tool tool then "skill call" else "call")
        , Printf.sprintf "%s%s" tool (batch_text e.Observer.batch) )
    | Observer.Tool_completed ->
        ( Call_returned
        , (if is_skill_tool tool then "skill returned" else "returned")
        , Printf.sprintf "%s%s%s" tool
            (match duration_ms with
             | Some ms -> " \xc2\xb7 " ^ elapsed_text ms
             | None -> "")
            (batch_text e.Observer.batch) )
    | Observer.Turn_started -> (Turn_boundary, "turn start", "")
    | Observer.Turn_ready -> (Turn_boundary, "turn ready", "")
    | Observer.Turn_completed -> (Turn_boundary, "turn end", "")
    | Observer.Agent_started -> (Turn_boundary, "agent start", "")
    | Observer.Agent_completed -> (Turn_settled, "agent done", "")
    | Observer.Agent_failed -> (Failure, "agent failed", "")
    | Observer.Agent_yielded -> (Quiet, "agent yielded", "")
    (* Where the tool name is the whole detail, an event that carries none
       leaves the cell empty rather than printing the [?] the default stands
       for. A lone [?] in the Detail column reads as a failure marker and says
       nothing; [masc:audit_event] drew one. The arms above spell the tool
       into a longer sentence, where the placeholder still marks its slot. *)
    | Observer.Tool_approval_completed ->
        (Attention, "approval settled", Option.value ~default:"" e.Observer.tool)
    | Observer.Telemetry -> (Quiet, "telemetry", "")
    | Observer.Agent_core_other name ->
        (Attention, name, Option.value ~default:"" e.Observer.tool)
  in
  let detail =
    match e.Observer.task with
    | Some task when detail = "" -> task
    | Some task -> detail ^ " \xc2\xb7 " ^ task
    | None -> detail
  in
  { at
  ; keeper = Option.value ~default:"-" e.Observer.agent
  ; glyph
  ; label
  ; detail
  }

let keeper_of_event ~traces (event : Observer.event) =
  match event with
  | Observer.Agent_core e -> (
      let by_agent = Option.value ~default:"-" e.Observer.agent in
      match e.Observer.correlation with
      | None -> by_agent
      | Some correlation -> (
          match
            List.find_opt
              (fun (_, trace) -> String.equal trace correlation)
              traces
          with
          | Some (keeper, _) -> keeper
          | None -> by_agent))
  | Observer.Keeper_heartbeat h -> h.Observer.hb_keeper
  | Observer.Keeper_tool_call c -> c.Observer.kt_keeper
  | Observer.Keeper_turn_complete t -> t.Observer.tc_keeper
  | Observer.Keeper_turn_observation o -> o.Observer.to_keeper
  | Observer.Keeper_composite_changed { keeper; _ }
  | Observer.Keeper_chat_appended { keeper; _ }
  | Observer.Keeper_chat_stream_frame { keeper; _ }
  | Observer.Keeper_waiting_inventory_changed { keeper; _ }
  | Observer.Fusion_run_status { keeper; _ } ->
      keeper
  | Observer.Snapshot _ | Observer.Other _ -> "server"

let row_of_event ~at ~duration_ms (event : Observer.event) =
  match event with
  | Observer.Agent_core e -> agent_core_row ~at ~duration_ms e
  | Observer.Keeper_heartbeat h ->
      { at
      ; keeper = h.Observer.hb_keeper
      ; glyph = Quiet
      ; label = "heartbeat"
      ; detail =
          (let phase = Option.value ~default:"" h.Observer.hb_phase in
           match (h.Observer.hb_in_turn, h.Observer.hb_in_flight_ms) with
           | Some true, Some ms ->
               Printf.sprintf "%s \xc2\xb7 in turn for %s" phase (elapsed_text ms)
           | (Some true | Some false | None), (Some _ | None) -> phase)
      }
  | Observer.Keeper_tool_call c ->
      let skill = is_skill_tool c.Observer.kt_tool in
      { at
      ; keeper = c.Observer.kt_keeper
      ; glyph = Call_returned
      ; label =
          (match c.Observer.kt_disposition with
           | Some disposition ->
               let word =
                 match disposition with
                 | Ok disposition ->
                     Masc.Tui_decode.keeper_call_disposition_to_string disposition
                 | Error _ -> "unknown disposition"
               in
               if skill then "skill \xc2\xb7 " ^ word else word
           | None -> if skill then "skill call" else "tool call")
      ; detail =
          (match c.Observer.kt_duration_ms with
           | Some ms -> c.Observer.kt_tool ^ " \xc2\xb7 " ^ elapsed_text ms
           | None -> c.Observer.kt_tool)
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
      { at
      ; keeper = t.Observer.tc_keeper
      ; glyph = Turn_settled
      ; label = "turn settled"
      ; detail = turn_text t.Observer.tc_turn ^ tokens ^ cost ^ calls
      }
  | Observer.Keeper_composite_changed { keeper; _ } ->
      { at; keeper; glyph = Quiet; label = "composite"; detail = "" }
  | Observer.Keeper_turn_observation o ->
      { at
      ; keeper = o.Observer.to_keeper
      ; glyph = Quiet
      ; label = "call"
      ; detail = turn_text (keeper_turn_of_observation o)
      }
  | Observer.Keeper_chat_appended { keeper; connector; _ } ->
      { at
      ; keeper
      ; glyph = Turn_boundary
      ; label = "chat"
      ; detail = Option.value ~default:"" connector
      }
  | Observer.Keeper_chat_stream_frame { keeper; frame; _ } ->
      { at
      ; keeper
      ; glyph = Quiet
      ; label = "chat stream"
      ; detail = Option.value ~default:"" frame
      }
  | Observer.Keeper_waiting_inventory_changed { keeper; queue_kind; _ } ->
      { at
      ; keeper
      ; glyph = Quiet
      ; label = "waiting queue"
      ; detail = Option.value ~default:"" queue_kind
      }
  | Observer.Fusion_run_status { keeper; run_id; status } ->
      (* Quiet: the Fusion surface is where a run is read, and it reloads
         itself on this same event. This row is the Everything-feed trace
         that a deliberation moved. The run id keeps its kmsg- prefix --
         it is what Ctrl-] would jump on. *)
      { at
      ; keeper
      ; glyph = Quiet
      ; label = "fusion"
      ; detail = status ^ " \xc2\xb7 " ^ run_id
      }
  | Observer.Snapshot name ->
      { at; keeper = "server"; glyph = Quiet; label = "snapshot"; detail = name }
  | Observer.Other name ->
      { at; keeper = "server"; glyph = Attention; label = name; detail = "" }

(* The screen draws entries, not bare events. Taking the entry means there is
   no clock argument at the call site to hand in the wrong value. *)
let row_of_entry ~duration_ms entry =
  row_of_event ~at:entry.ae_at ~duration_ms entry.ae_event

(* ── Turn chunks ────────────────────────────────────────────────────────
   [Turns] draws one row per keeper turn instead of the up-to-seven
   lifecycle rows a single tool call produces across the two reporting
   planes (agent-core wire: ready / start / call / returned / end; keeper
   ledger: completed / settled). The fold is a display projection only:
   nothing is stored, and events that are not part of a turn's lifecycle
   pass through as the rows they already were -- when [visible Turns]
   shows them at all; what the scope hides stays hidden.

   Attribution: a chunk is one keeper turn. The wire and ledger members state
   the agent session's ordinal for their provider call; a settle states the
   keeper turn; a turn observation names both, and {!fold_chunks} files each
   member through them. A member whose call no retained observation names
   is filed by its ordinal and the keeper's open turn, which can misfile a
   row across a session restart. A member that states no ordinal at all (a
   ledger row from the runtime MCP path) joins the keeper's newest chunk,
   settled or not, so it lands on the turn before its own once that turn has
   settled. Both are display blemishes, never stored facts. *)

type chunk_tool = {
  ct_tool : string;
  ct_duration_ms : float option;
  ct_at : float;
  ct_tool_use_id : string option;
  ct_session_turn : int option;
  ct_disposition : (Masc.Tui_decode.keeper_call_disposition, string) result option;
  ct_schedule : (Agent_core.Tool_contract.schedule, string) result option;
  ct_input : string option;
  ct_output : string option;
}

type call_key =
  | Call_by_id of string
  | Call_by_receipt of { at : float; tool : string }

let call_key tool =
  match tool.ct_tool_use_id with
  | Some id -> Call_by_id id
  | None -> Call_by_receipt { at = tool.ct_at; tool = tool.ct_tool }

let call_key_equal a b =
  match a, b with
  | Call_by_id a, Call_by_id b -> String.equal a b
  | Call_by_receipt a, Call_by_receipt b ->
      Float.equal a.at b.at && String.equal a.tool b.tool
  | Call_by_id _, Call_by_receipt _ | Call_by_receipt _, Call_by_id _ -> false

(* A wire-plane call keeps its start and id so its return can settle the
   duration in place; the tool is on screen from the call, not from the
   return — a running turn names what it is doing right now. *)
type wire_tool = {
  wt_id : string option;
  wt_started : float;
  wt_tool : string;
  wt_duration_ms : float option;
  wt_session_turn : int option;
}

(* The turn marker the agent-core loop last sent for this record: a
   provider call was asked for, started, or came back. The pane reads the
   newest one to say whether the model has the turn right now. *)
type turn_marker =
  | Marker_ready
  | Marker_started
  | Marker_completed

type chunk = {
  ck_keeper : string;
  ck_turn : int option;
  ck_session_turns : int list;
  ck_at : float;  (** newest member's arrival — the chunk's feed position *)
  ck_wire_tools : wire_tool list;  (** oldest-first, from the agent-core wire *)
  ck_ledger_tools : chunk_tool list;  (** oldest-first, from the keeper ledger *)
  ck_settled : bool;
  ck_marker : (turn_marker * float) option;
  ck_tokens : int option * int option;
  ck_cost_usd : float option;
  ck_calls : int option;
}

type chunk_member =
  | Member_turn_marker of { marker : turn_marker; turn : int option }
  | Member_wire_call of {
      tool : string;
      tool_use_id : string option;
      turn : int option;
    }
  | Member_wire_return of {
      tool : string;
      tool_use_id : string option;
      turn : int option;
    }
  | Member_ledger_tool of {
      tool : string;
      duration_ms : float option;
      turn : int option;
      tool_use_id : string option;
      disposition : (Masc.Tui_decode.keeper_call_disposition, string) result option;
      schedule : (Agent_core.Tool_contract.schedule, string) result option;
      input : string option;
      output : string option;
    }
  | Member_settle of Observer.keeper_turn_complete
  | Member_quiet

(* Which events fold into a chunk. Internal agent runs (Agent_started and
   friends) and approvals stay standalone: they are not keeper-turn
   lifecycle, and a reader scanning for them should not find them buried
   inside a turn row. *)
let member_of_event (event : Observer.event) =
  match event with
  | Observer.Agent_core e -> (
      match e.Observer.kind with
      | Observer.Turn_ready ->
          Some (Member_turn_marker { marker = Marker_ready; turn = e.Observer.turn })
      | Observer.Turn_started ->
          Some (Member_turn_marker { marker = Marker_started; turn = e.Observer.turn })
      | Observer.Turn_completed ->
          Some (Member_turn_marker { marker = Marker_completed; turn = e.Observer.turn })
      | Observer.Tool_called ->
          Some
            (Member_wire_call
               { tool = Option.value ~default:"?" e.Observer.tool
               ; tool_use_id = e.Observer.tool_use_id
               ; turn = e.Observer.turn
               })
      | Observer.Tool_completed ->
          Some
            (Member_wire_return
               { tool = Option.value ~default:"?" e.Observer.tool
               ; tool_use_id = e.Observer.tool_use_id
               ; turn = e.Observer.turn
               })
      | Observer.Telemetry -> Some Member_quiet
      | Observer.Agent_started | Observer.Agent_completed
      | Observer.Agent_failed | Observer.Agent_yielded
      | Observer.Tool_approval_completed | Observer.Agent_core_other _ ->
          None)
  | Observer.Keeper_tool_call c ->
      Some
        (Member_ledger_tool
           { tool = c.Observer.kt_tool
           ; duration_ms = c.Observer.kt_duration_ms
           ; turn = c.Observer.kt_turn
           ; tool_use_id = c.Observer.kt_tool_use_id
           ; disposition = c.Observer.kt_disposition
           ; schedule = c.Observer.kt_schedule
           ; input = c.Observer.kt_tool_args_preview
           ; output = c.Observer.kt_tool_output_preview
           })
  | Observer.Keeper_turn_complete t -> Some (Member_settle t)
  (* Identity for the fold's session table, read before members are filed
     ([fold_chunks]); not a member itself. *)
  | Observer.Keeper_turn_observation _
  | Observer.Keeper_heartbeat _ | Observer.Keeper_composite_changed _
  | Observer.Keeper_chat_appended _ | Observer.Keeper_chat_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _ | Observer.Snapshot _
  | Observer.Fusion_run_status _ | Observer.Other _ ->
      None

let empty_chunk ~keeper ~at =
  { ck_keeper = keeper
  ; ck_turn = None
  ; ck_session_turns = []
  ; ck_at = at
  ; ck_wire_tools = []
  ; ck_ledger_tools = []
  ; ck_settled = false
  ; ck_marker = None
  ; ck_tokens = (None, None)
  ; ck_cost_usd = None
  ; ck_calls = None
  }

let apply_member chunk ~at member =
  let chunk = { chunk with ck_at = Float.max chunk.ck_at at } in
  match member with
  | Member_quiet -> chunk
  | Member_turn_marker { marker; turn = _ } -> { chunk with ck_marker = Some (marker, at) }
  | Member_wire_call { tool; tool_use_id; turn } ->
      { chunk with
        ck_wire_tools =
          chunk.ck_wire_tools
          @ [ { wt_id = tool_use_id
              ; wt_started = at
              ; wt_tool = tool
              ; wt_duration_ms = None
              ; wt_session_turn = turn
              }
            ]
      }
  | Member_wire_return { tool; tool_use_id; turn } ->
      (* Settle the newest still-open call with this id in place; a return
         whose call was never held (the feed opened mid-turn) appends with
         no duration rather than being dropped. *)
      let settled = ref false in
      let settle_in_place =
        List.rev_map
          (fun wt ->
            if
              (not !settled)
              && Option.is_none wt.wt_duration_ms
              && Option.equal String.equal wt.wt_id tool_use_id
              && Option.is_some tool_use_id
            then begin
              settled := true;
              { wt with wt_duration_ms = Some ((at -. wt.wt_started) *. 1000.) }
            end
            else wt)
          (List.rev chunk.ck_wire_tools)
      in
      let ck_wire_tools =
        if !settled then settle_in_place
        else
          chunk.ck_wire_tools
          @ [ { wt_id = tool_use_id
              ; wt_started = at
              ; wt_tool = tool
              ; wt_duration_ms = None
              ; wt_session_turn = turn
              }
            ]
      in
      { chunk with ck_wire_tools }
  | Member_ledger_tool
      { tool; duration_ms; turn; tool_use_id; disposition; schedule; input; output } ->
      { chunk with
        ck_ledger_tools =
          chunk.ck_ledger_tools
          @ [ { ct_tool = tool
              ; ct_duration_ms = duration_ms
              ; ct_at = at
              ; ct_tool_use_id = tool_use_id
              ; ct_session_turn = turn
              ; ct_disposition = disposition
              ; ct_schedule = schedule
              ; ct_input = input
              ; ct_output = output
              }
            ]
      }
  | Member_settle t ->
      let ck_turn =
        match t.Observer.tc_turn with Some _ as n -> n | None -> chunk.ck_turn
      in
      { chunk with
        ck_turn
      ; ck_settled = true
      ; ck_tokens = (t.Observer.tc_input_tokens, t.Observer.tc_output_tokens)
      ; ck_cost_usd = t.Observer.tc_cost_usd
      ; ck_calls = t.Observer.tc_tool_calls
      }

let chunk_tools_text tools =
  tools
  |> List.map (fun { ct_tool; ct_duration_ms; _ } ->
      match ct_duration_ms with
      | Some ms -> ct_tool ^ " " ^ elapsed_text ms
      | None -> ct_tool)
  |> String.concat " \xc2\xb7 "

(* The ledger is the authority when it reported at all; the wire list only
   stands in for runtimes whose ledger plane is silent. A wire call has no
   disposition, schedule or I/O to stand in with: those are the ledger's. *)
let chunk_tools chunk =
  match chunk.ck_ledger_tools with
  | [] ->
      List.map
        (fun wt ->
          { ct_tool = wt.wt_tool
          ; ct_duration_ms = wt.wt_duration_ms
          ; ct_at = wt.wt_started
          ; ct_tool_use_id = wt.wt_id
          ; ct_session_turn = wt.wt_session_turn
          ; ct_disposition = None
          ; ct_schedule = None
          ; ct_input = None
          ; ct_output = None
          })
        chunk.ck_wire_tools
  | l -> l

let row_of_chunk chunk =
  let tools = chunk_tools chunk in
  let tools_text = chunk_tools_text tools in
  let tokens =
    match chunk.ck_tokens with
    | Some i, Some o -> Printf.sprintf " \xc2\xb7 in %d out %d" i o
    | Some i, None -> Printf.sprintf " \xc2\xb7 in %d" i
    | None, Some o -> Printf.sprintf " \xc2\xb7 out %d" o
    | None, None -> ""
  in
  let cost =
    match chunk.ck_cost_usd with
    | Some usd -> Printf.sprintf " \xc2\xb7 $%.4f" usd
    | None -> ""
  in
  let calls =
    (* Only when no tool is listed by name: a count next to the list would
       say the same thing twice. *)
    match (tools, chunk.ck_calls) with
    | [], Some n when n > 0 ->
        Printf.sprintf "%d call%s" n (if n = 1 then "" else "s")
    | _, (Some _ | None) -> ""
  in
  let detail =
    if chunk.ck_settled then
      let body = if tools_text = "" then calls else tools_text in
      let body = if body = "" then "no calls" else body in
      body ^ tokens ^ cost
    else if tools_text = "" then "running"
    else tools_text
  in
  { at = chunk.ck_at
  ; keeper = chunk.ck_keeper
  ; glyph = (if chunk.ck_settled then Turn_settled else Call_started)
  ; label = turn_text chunk.ck_turn
  ; detail
  }

(* Only observations feed the session table; every other event is listed
   so a new event kind has to say which side it is on. *)
let observation_of_event (event : Observer.event) =
  match event with
  | Observer.Keeper_turn_observation o -> Some o
  | Observer.Agent_core _ | Observer.Keeper_heartbeat _
  | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
  | Observer.Keeper_composite_changed _ | Observer.Keeper_chat_appended _
  | Observer.Keeper_chat_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _
  | Observer.Fusion_run_status _ | Observer.Snapshot _ | Observer.Other _ ->
      None

(* The agent session's ordinal a member states, if it states one. *)
let session_of_member = function
  | Member_turn_marker { turn; _ } -> turn
  | Member_wire_call { turn; _ } | Member_wire_return { turn; _ }
  | Member_ledger_tool { turn; _ } ->
      turn
  | Member_settle _ | Member_quiet -> None

(* Replace the newest chunk [fits] accepts with [apply] of it. *)
let attach ~fits ~apply chunks =
  let rec go acc = function
    | chunk :: rest when fits chunk ->
        Some (List.rev_append acc (apply chunk :: rest))
    | chunk :: rest -> go (chunk :: acc) rest
    | [] -> None
  in
  go [] chunks

(* File one member into a keeper's chunks, held newest first.

   [keeper_turn] is the member's keeper turn when known -- a settle carries
   it, a session-numbered member gets it from the observation table -- and
   [session] is the agent session's ordinal the member states. The first
   rule that finds a chunk wins; otherwise the member opens one, telemetry
   excepted.

   - A settle joins the chunk with its number, else the newest chunk if that
     one is unsettled; [apply_member] then stamps the settle's number on it.
   - A wire or ledger member with a keeper turn joins the chunk with that
     number, else the newest chunk if it is unsettled and still unnumbered.
   - A wire or ledger member with only an ordinal joins the newest chunk that
     already holds the ordinal; else the newest chunk if it holds no ordinal
     yet, settled or not (a settle that landed before its turn's wire
     replay); else the newest chunk if it is unsettled and numbered -- a
     keeper runs one turn at a time, and the call in flight has no
     observation until its response is collected.
   - A member stating neither lands on the newest chunk.
   - Telemetry only refreshes the newest chunk: a keeper the feed knows
     nothing else about gains no row from it (#32208). *)
let file_member ~existing ~keeper ~at ~session ~keeper_turn member =
  let absorb chunk =
    let chunk = apply_member chunk ~at member in
    let chunk =
      match session with
      | Some ordinal when not (List.mem ordinal chunk.ck_session_turns) ->
          { chunk with ck_session_turns = chunk.ck_session_turns @ [ ordinal ] }
      | Some _ | None -> chunk
    in
    match (chunk.ck_turn, keeper_turn) with
    | None, Some turn -> { chunk with ck_turn = Some turn }
    | Some _, (Some _ | None) | None, None -> chunk
  in
  let by_keeper_turn () =
    match keeper_turn with
    | Some turn -> attach ~fits:(fun c -> c.ck_turn = Some turn) ~apply:absorb existing
    | None -> None
  in
  let by_session () =
    match session with
    | Some ordinal ->
        attach ~fits:(fun c -> List.mem ordinal c.ck_session_turns) ~apply:absorb existing
    | None -> None
  in
  let on_newest fits () =
    match existing with
    | chunk :: rest when fits chunk -> Some (absorb chunk :: rest)
    | _ :: _ | [] -> None
  in
  let opened () = absorb (empty_chunk ~keeper ~at) :: existing in
  let first_of candidates ~otherwise =
    match List.find_map (fun candidate -> candidate ()) candidates with
    | Some chunks -> chunks
    | None -> otherwise ()
  in
  match member with
  | Member_quiet ->
      first_of [ on_newest (fun _ -> true) ] ~otherwise:(fun () -> existing)
  | Member_settle _ ->
      first_of
        [ by_keeper_turn; on_newest (fun c -> not c.ck_settled) ]
        ~otherwise:opened
  | Member_turn_marker _ | Member_wire_call _ | Member_wire_return _
  | Member_ledger_tool _ -> (
      match (keeper_turn, session) with
      | Some _, (Some _ | None) ->
          first_of
            [ by_keeper_turn
            ; on_newest (fun c -> (not c.ck_settled) && c.ck_turn = None)
            ]
            ~otherwise:opened
      | None, Some _ ->
          first_of
            [ by_session
            ; on_newest (fun c -> c.ck_session_turns = [])
            ; on_newest (fun c -> (not c.ck_settled) && Option.is_some c.ck_turn)
            ]
            ~otherwise:opened
      | None, None -> first_of [ on_newest (fun _ -> true) ] ~otherwise:opened)

(* Fold entries (held newest-first) into chunk and pass-through rows.

   One keeper turn is several provider calls. The agent-core wire and the
   keeper ledger number their frames by the call (the agent session's
   ordinal) while a settle numbers the turn from the keeper's lifetime, so
   the two could only meet by guesswork until the hook's per-call
   observation named both. The first pass reads every observation in the
   ring into a (keeper, ordinal) table of (feed position, keeper turn); the
   second files each member through {!file_member}.

   An agent session created without a checkpoint numbers its calls from
   zero again, so one keeper can observe the same ordinal twice in the ring.
   A member takes the observation nearest to it in feed position, which is
   the right one while a call's frames sit nearer their own observation than
   another session's observation of the same ordinal. On the agent-core loop
   they sit right around it: the call's turn markers just before, its tools
   just after. A CLI lane runs a whole keeper turn as one call, so every
   frame of the turn comes before the observation, and a frame from early in
   a long lane turn can sit nearer an older session's observation. A frame
   that lands long after its observation -- a slow tool's return, or one the
   relay held -- can sit nearer the next session's. Either way it is filed
   under the other session's turn.

   [traces] resolves agent-core correlation ids to keeper names, exactly as
   the flat view does. The ring holds up to [acting_retained_entries] +
   [acting_retained_quiet] entries and this runs on every frame, so chunks live in a per-keeper table:
   attaching costs the keeper's own chunk count, not the whole screen. *)
let fold_chunks ~traces entries =
  let oldest_first = List.rev entries in
  let observed : (string * int, (int * int) list) Hashtbl.t = Hashtbl.create 64 in
  List.iteri
    (fun position entry ->
      match observation_of_event entry.ae_event with
      | Some o -> (
          match (o.Observer.to_session_turn, keeper_turn_of_observation o) with
          | Some ordinal, Some turn ->
              let key = (o.Observer.to_keeper, ordinal) in
              let held =
                match Hashtbl.find_opt observed key with
                | Some held -> held
                | None -> []
              in
              Hashtbl.replace observed key ((position, turn) :: held)
          | None, (Some _ | None) | Some _, None -> ())
      | None -> ())
    oldest_first;
  let keeper_turn_near ~keeper ~ordinal ~position =
    match Hashtbl.find_opt observed (keeper, ordinal) with
    | None -> None
    | Some held ->
        List.fold_left
          (fun nearest (at, turn) ->
            let distance = abs (at - position) in
            match nearest with
            | Some (nearest_distance, _) when nearest_distance <= distance -> nearest
            | Some _ | None -> Some (distance, turn))
          None held
        |> Option.map snd
  in
  let chunks : (string, chunk list) Hashtbl.t = Hashtbl.create 16 in
  let plains = ref [] in
  List.iteri
    (fun position entry ->
      let event = entry.ae_event in
      let at = entry.ae_at in
      match member_of_event event with
      | None ->
          (* A non-member passes through as its own row only if the Turns
             scope shows it at all. Without this test the fold readmitted
             everything [visible Turns] hides -- composite pushes, heartbeats,
             stream frames, waiting-queue changes -- and a live screen showed
             them outnumbering the turn rows it promised (2026-09-01, 128
             rows). *)
          if visible Turns event then
            plains :=
              (entry.ae_at, row_of_entry ~duration_ms:None entry) :: !plains
      | Some member ->
          let keeper = keeper_of_event ~traces event in
          let session = session_of_member member in
          let keeper_turn =
            match member with
            | Member_settle t -> t.Observer.tc_turn
            | Member_turn_marker _ | Member_wire_call _ | Member_wire_return _
            | Member_ledger_tool _ | Member_quiet -> (
                match session with
                | Some ordinal -> keeper_turn_near ~keeper ~ordinal ~position
                | None -> None)
          in
          let existing =
            match Hashtbl.find_opt chunks keeper with
            | Some held -> held
            | None -> []
          in
          Hashtbl.replace chunks keeper
            (file_member ~existing ~keeper ~at ~session ~keeper_turn member))
    oldest_first;
  (chunks, !plains)

(* Every keeper's turns as data, newest activity first. The Activity pane
   draws the same fold the [Turns] rows draw, keyed by keeper, so the two
   cannot disagree about which turn is current. *)
let chunks ~traces entries =
  let chunks, _plains = fold_chunks ~traces entries in
  Hashtbl.fold (fun _ keeper_chunks acc -> keeper_chunks @ acc) chunks []
  |> List.stable_sort (fun a b -> Float.compare b.ck_at a.ck_at)

type chunk_projection = {
  source_entries : entry list;
  source_traces : (string * string) list;
  projected_chunks : chunk list;
}

let refresh_projection ~previous ~traces entries =
  let same_trace (keeper, trace) (other_keeper, other_trace) =
    String.equal keeper other_keeper && String.equal trace other_trace
  in
  match previous with
  | Some projection
    when projection.source_entries == entries
      && List.equal same_trace projection.source_traces traces -> projection
  | _ ->
    { source_entries = entries; source_traces = traces;
      projected_chunks = chunks ~traces entries }

let projection_chunks projection = projection.projected_chunks

let chunk_rows ~traces entries =
  let chunks, plains = fold_chunks ~traces entries in
  let chunk_rows =
    Hashtbl.fold
      (fun _ keeper_chunks acc ->
        List.fold_left
          (fun acc chunk -> (chunk.ck_at, row_of_chunk chunk) :: acc)
          acc keeper_chunks)
      chunks []
  in
  (* Latest activity first, so a long-running turn surfaces when it moves. *)
  chunk_rows @ plains
  |> List.stable_sort (fun (a, _) (b, _) -> Float.compare b a)
  |> List.map snd

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
                 && Option.equal String.equal agent completed.Observer.agent ->
              Some ((completed.Observer.at -. at) *. 1000.)
          | Observer.Agent_core _ | Observer.Keeper_heartbeat _
          | Observer.Keeper_tool_call _ | Observer.Keeper_turn_complete _
          | Observer.Keeper_turn_observation _
          | Observer.Keeper_composite_changed _ | Observer.Keeper_chat_appended _
          | Observer.Keeper_chat_stream_frame _
          | Observer.Keeper_waiting_inventory_changed _
          | Observer.Fusion_run_status _
          | Observer.Snapshot _ | Observer.Other _ ->
              None)
        before

let evidence_fields (entry : entry) =
  let field label value = label, value in
  let some label value = field label (Some value) in
  let number label value = field label (Option.map string_of_int value) in
  match entry.ae_event with
  | Observer.Agent_core e ->
      let kind = match e.kind with
        | Tool_called -> "tool_called" | Tool_completed -> "tool_completed"
        | Turn_started -> "turn_started" | Turn_ready -> "turn_ready"
        | Turn_completed -> "turn_completed" | Agent_started -> "agent_started"
        | Agent_completed -> "agent_completed" | Agent_failed -> "agent_failed"
        | Agent_yielded -> "agent_yielded" | Tool_approval_completed -> "tool_approval_completed"
        | Telemetry -> "telemetry_event" | Agent_core_other name -> name in
      [ some "Source" "runtime observer event"
      ; some "Event kind" kind
      ; field "Tool name" e.tool
      ; field "Tool use ID" e.tool_use_id
      ; field "Execution ID" e.execution_id
      ; field "Event ID" e.event_id
      ; field "Run ID" e.run_id
      ; field "Parent event ID" e.parent
      ; field "Caused by" e.caused_by
      ; field "Correlation ID" e.correlation
      ; field "Runtime agent" e.agent
      ; field "Task ID" e.task
      ; number "Agent session turn" e.turn
      ; field "Batch index / size" (Option.map (fun (index, size) -> Printf.sprintf "%d / %d" index size) e.batch)
      ; some "Input/output" "not carried by this observer event"
      ; some "Skill receipt" "not carried by this observer event"
      ]
  | Observer.Keeper_tool_call call ->
      let schedule_fields =
        match call.kt_schedule with
        | None -> [ field "Execution schedule" None ]
        | Some (Error error) -> [ some "Execution schedule error" error ]
        | Some (Ok schedule) ->
            [ some "Execution mode"
                (match schedule.execution_mode with
                 | Agent_core.Tool_contract.Concurrent -> "concurrent"
                 | Agent_core.Tool_contract.Serial -> "serial")
            ; some "Planned index (zero-based)" (string_of_int schedule.planned_index)
            ; some "Batch index (zero-based) / size"
                (Printf.sprintf "%d / %d" schedule.batch_index schedule.batch_size)
            ]
      in
      [ some "Source" "keeper_tool_call observer event"
      ; some "Keeper" call.kt_keeper
      ; some "Tool name" call.kt_tool
      ; number "Agent session turn" call.kt_turn
      ; (match call.kt_disposition with
         | None -> field "Disposition" None
         | Some (Ok disposition) ->
             some "Disposition"
               (Masc.Tui_decode.keeper_call_disposition_to_string disposition)
         | Some (Error error) -> some "Disposition error" error)
      ; field "Tool use ID" call.kt_tool_use_id
      ; some "Input/output" "producer-redacted observations below; full payload not guaranteed"
      ] @ schedule_fields
  | event ->
      let row = row_of_event ~at:entry.ae_at ~duration_ms:None event in
      [ some "Source" "observer event"
      ; some "Event" row.label
      ; some "Detail" row.detail
      ; some "Call evidence" "this event is not an exact tool invocation"
      ]
