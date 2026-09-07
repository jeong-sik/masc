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
      "scope everything · gray · = state/telemetry · composite = Keeper snapshot changed"
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
   [quiet]. Both classes keep their newest and the rest is counted, not
   silently forgotten. Entries arrive newest-first and stay in that order. *)
let retain ~actions ~quiet ~event_of entries =
  let rec walk kept n_actions n_quiet dropped = function
    | [] -> (List.rev kept, dropped)
    | entry :: older ->
        let is_action = visible Actions (event_of entry) in
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
    | Observer.Tool_called ->
        ( Call_started
        , (if is_skill_tool tool then "skill call" else "call")
        , Printf.sprintf "%s%s \xc2\xb7 %s" tool (batch_text e.Observer.batch)
            (turn_text e.Observer.turn) )
    | Observer.Tool_completed ->
        ( Call_returned
        , (if is_skill_tool tool then "skill returned" else "returned")
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
               if skill then "skill \xc2\xb7 " ^ disposition else disposition
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

   Attribution: events that carry a turn number key the chunk directly.
   Ledger events carry none, and the two planes interleave (a settle can
   arrive before the wire's turn-end for the same turn), so a turn-less
   member attaches to the keeper's most recently touched chunk. That can
   misfile a ledger row that lands after the next turn's ready — a display
   blemish, never a stored fact. *)

type chunk_tool = {
  ct_tool : string;
  ct_duration_ms : float option;
}

(* A wire-plane call keeps its start and id so its return can settle the
   duration in place; the tool is on screen from the call, not from the
   return — a running turn names what it is doing right now. *)
type wire_tool = {
  wt_id : string option;
  wt_started : float;
  wt_tool : string;
  wt_duration_ms : float option;
}

type chunk = {
  ck_keeper : string;
  ck_turn : int option;
  ck_session_turn : int option;
  ck_at : float;  (** newest member's arrival — the chunk's feed position *)
  ck_wire_tools : wire_tool list;  (** oldest-first, from the agent-core wire *)
  ck_ledger_tools : chunk_tool list;  (** oldest-first, from the keeper ledger *)
  ck_settled : bool;
  ck_tokens : int option * int option;
  ck_cost_usd : float option;
  ck_calls : int option;
}

type chunk_member =
  | Member_turn_marker of int option
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
      | Observer.Turn_ready | Observer.Turn_started | Observer.Turn_completed
        ->
          Some (Member_turn_marker e.Observer.turn)
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
           })
  | Observer.Keeper_turn_complete t -> Some (Member_settle t)
  | Observer.Keeper_heartbeat _ | Observer.Keeper_composite_changed _
  | Observer.Keeper_chat_appended _ | Observer.Keeper_chat_stream_frame _
  | Observer.Keeper_waiting_inventory_changed _ | Observer.Snapshot _
  | Observer.Fusion_run_status _ | Observer.Other _ ->
      None

let empty_chunk ~keeper ~turn ~at =
  { ck_keeper = keeper
  ; ck_turn = turn
  ; ck_session_turn = turn
  ; ck_at = at
  ; ck_wire_tools = []
  ; ck_ledger_tools = []
  ; ck_settled = false
  ; ck_tokens = (None, None)
  ; ck_cost_usd = None
  ; ck_calls = None
  }

(* Two planes number the same turn. The turn markers, the agent-core wire
   and the keeper ledger all number it from the agent session; only the
   settle numbers it from the keeper's lifetime -- one real turn arrived as
   1157 on the wire and 719 on its settle (live capture 2026-09-07). A chunk
   holds both because a member can only be matched against the plane it was
   written on. [ck_turn] is what a row displays: the settle's number once it
   has one, the session number before that. Both are first-wins. *)
let stamp_session_turn chunk turn =
  let first held = match held with Some _ as t -> t | None -> turn in
  { chunk with
    ck_turn = first chunk.ck_turn
  ; ck_session_turn = first chunk.ck_session_turn
  }

let apply_member chunk ~at member =
  let chunk = { chunk with ck_at = Float.max chunk.ck_at at } in
  match member with
  | Member_quiet -> chunk
  | Member_turn_marker turn -> stamp_session_turn chunk turn
  | Member_wire_call { tool; tool_use_id; turn } ->
      let chunk = stamp_session_turn chunk turn in
      { chunk with
        ck_wire_tools =
          chunk.ck_wire_tools
          @ [ { wt_id = tool_use_id
              ; wt_started = at
              ; wt_tool = tool
              ; wt_duration_ms = None
              }
            ]
      }
  | Member_wire_return { tool; tool_use_id; turn } ->
      let chunk = stamp_session_turn chunk turn in
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
              }
            ]
      in
      { chunk with ck_wire_tools }
  | Member_ledger_tool { tool; duration_ms; turn } ->
      let chunk = stamp_session_turn chunk turn in
      { chunk with
        ck_ledger_tools =
          chunk.ck_ledger_tools
          @ [ { ct_tool = tool; ct_duration_ms = duration_ms } ]
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
  |> List.map (fun { ct_tool; ct_duration_ms } ->
      match ct_duration_ms with
      | Some ms -> ct_tool ^ " " ^ elapsed_text ms
      | None -> ct_tool)
  |> String.concat " \xc2\xb7 "

(* The ledger is the authority when it reported at all; the wire list only
   stands in for runtimes whose ledger plane is silent. *)
let chunk_tools chunk =
  match chunk.ck_ledger_tools with
  | [] ->
      List.map
        (fun wt -> { ct_tool = wt.wt_tool; ct_duration_ms = wt.wt_duration_ms })
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

(* Fold entries (held newest-first) into chunk and pass-through rows, newest
   first by latest activity. [traces] resolves agent-core correlation ids to
   keeper names, exactly as the flat view does. The ring holds up to
   [acting_retained_entries] rows and this runs on every frame, so chunks
   live in a per-keeper table: attaching costs the keeper's own chunk count,
   not the whole screen. *)
let fold_chunks ~traces entries =
  let oldest_first = List.rev entries in
  let chunks : (string, chunk list) Hashtbl.t = Hashtbl.create 16 in
  let plains = ref [] in
  List.iter
    (fun entry ->
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
          (* Which plane this member's number is on decides what it can be
             matched against; see [stamp_session_turn]. *)
          let turn_of_member =
            match member with
            | Member_turn_marker turn -> `Session turn
            | Member_wire_call { turn; _ } | Member_wire_return { turn; _ }
            | Member_ledger_tool { turn; _ } -> `Session turn
            | Member_settle t -> `Keeper t.Observer.tc_turn
            | Member_quiet -> `Session None
          in
          let existing = Option.value ~default:[] (Hashtbl.find_opt chunks keeper) in
          (* The keeper's chunks are held newest first: a turn-less ledger
             row lands on the most recent one, a numbered member skips past
             mismatching turns to its own. *)
          let member_fits chunk =
            let held =
              match turn_of_member with
              | `Session _ -> chunk.ck_session_turn
              | `Keeper _ -> chunk.ck_turn
            in
            match ((match turn_of_member with `Session t | `Keeper t -> t), held) with
            | Some t, Some ct -> t = ct
            | Some _, None | None, (Some _ | None) -> true
          in
          let rec attach acc = function
            | chunk :: rest when member_fits chunk ->
                Some
                  (List.rev_append acc (apply_member chunk ~at member :: rest))
            | chunk :: rest -> attach (chunk :: acc) rest
            | [] -> None
          in
          let updated =
            match attach [] existing with
            | Some chunks -> chunks
            | None -> (
                match member with
                | Member_quiet ->
                    (* A state observation may refresh a turn it can see;
                       it cannot conjure one. A chunk born from telemetry
                       draws as [turn ? | running] for a keeper the scope
                       shows nothing else about (live capture 2026-09-01,
                       #32208). *)
                    existing
                | Member_settle _ when turn_of_member <> `Keeper None ->
                    (* A numbered settle that finds no chunk with its number
                       joins the newest still-open chunk: the wire numbered
                       that turn from the agent session while the settle
                       numbers it from the keeper's lifetime, so one real
                       turn arrived as two numbers and drew as two rows --
                       the open row hoarding the ledger calls, the settled
                       row holding the tokens (live capture 2026-09-06,
                       turn 1740 beside turn 3084). A keeper runs one turn
                       at a time, so the newest open chunk is the turn this
                       settle ends, and [apply_member] stamps it with the
                       keeper's own number. With every chunk settled the
                       settle stands as its own row, as before. *)
                    (match existing with
                     | chunk :: rest when not chunk.ck_settled ->
                         apply_member chunk ~at member :: rest
                     | _ ->
                         apply_member (empty_chunk ~keeper ~turn:None ~at) ~at
                           member
                         :: existing)
                | Member_turn_marker _ | Member_wire_call _
                | Member_wire_return _ | Member_settle _
                | Member_ledger_tool _ ->
                    apply_member (empty_chunk ~keeper ~turn:None ~at) ~at
                      member
                    :: existing)
          in
          Hashtbl.replace chunks keeper updated)
    oldest_first;
  (chunks, !plains)

(* Every keeper's turns as data, newest activity first. The Activity pane
   draws the same fold the [Turns] rows draw, keyed by keeper, so the two
   cannot disagree about which turn is current. *)
let chunks ~traces entries =
  let chunks, _plains = fold_chunks ~traces entries in
  Hashtbl.fold (fun _ keeper_chunks acc -> keeper_chunks @ acc) chunks []
  |> List.stable_sort (fun a b -> Float.compare b.ck_at a.ck_at)

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
          | Observer.Keeper_composite_changed _ | Observer.Keeper_chat_appended _
          | Observer.Keeper_chat_stream_frame _
          | Observer.Keeper_waiting_inventory_changed _
          | Observer.Fusion_run_status _
          | Observer.Snapshot _ | Observer.Other _ ->
              None)
        before
