(* What one event does to a Keeper's writer (RFC librarian-call-only-proposes
   §9.2, §9.3): each row of the writer's table and of the current ask's
   result, a late answer, a direct write while an ask is out, and an
   operator's act. No model is called: each ask's result is made here. *)

open Alcotest
module Machine = Masc.Librarian_machine
module Store = Masc.Librarian_store
module Log = Masc.Librarian_log
module Log_store = Masc.Librarian_log_store
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Envelope = Masc.Librarian_envelope
module Answer = Masc.Librarian_answer
module Lane = Masc.Librarian_memory_lane
module Read_result = Masc.Librarian_read_result
module Unread = Masc.Librarian_unread
module Snapshot_codec = Masc.Keeper_memory_os_snapshot_codec
module Types = Masc.Keeper_memory_os_types
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Registry = Runtime_exact_output_registry
module Backpressure = Runtime_candidate_backpressure
module EO = Agent_core.Exact_output
module Digest = Agent_core.Checkpoint_objects

let keeper_id = "keeper-a"

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

(* Every store where the log started but the chat, so a unit's range is
   its chat bytes. *)
let mark chat : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 4
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = chat
  ; external_rows = 0
  }
;;

let new_place () : Machine.place =
  { memory_dir = Filename.temp_dir "memory" ""
  ; turns_dir = Filename.temp_dir "turns" ""
  ; keeper_id
  }
;;

let turns_path (place : Machine.place) =
  Turn_store.path_for_keepers_dir ~keepers_dir:place.turns_dir ~keeper_id
;;

let length place =
  match Fs_compat.file_size (turns_path place) with
  | Some length -> length
  | None -> fail "the turn log of the fixture is not there"
;;

(* Appends one line where the turn log ends and gives the offset it starts at. *)
let append place ~at_end line =
  match Turn_store.append ~path:(turns_path place) ~at_end (line, []) with
  | Ok { new_end = (_ : int); last_at } -> last_at
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

(* A place whose Keeper has a turn log and nothing else. *)
let started_place () =
  let place = new_place () in
  let (_ : int) =
    append place ~at_end:0 (Turn_log.Log_started { id = turn_log; at = 50.0; mark = mark 0 })
  in
  place
;;

(* One turn whose chat grew from [from] to [until]: a unit with items. *)
let close_turn place ~from ~until =
  let turn =
    append place ~at_end:(length place)
      (Turn_log.Opened
         { at = 101.0
         ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:7
         ; runtime = "glm-main"
         ; task = No_task
         ; stimuli = []
         ; baseline = mark from
         })
  in
  let (_ : int) =
    append place ~at_end:(length place)
      (Turn_log.Closed
         { turn; at = 102.0; outcome = Completed; after = mark until; unattributed = []; own = [] })
  in
  ()
;;

let snapshot_path (place : Machine.place) =
  Masc.Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:place.memory_dir
    ~keeper_id
;;

let log_path (place : Machine.place) =
  Log_store.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id
;;

let file_bytes path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

let hex (digest : Digest.digest) = (digest :> string)
let other_snapshot () = Snapshot_codec.snapshot_bytes (Envelope.empty ~at:999.0 ~turn_log)

(* {1 Lane values} *)

let slot id : Lane.slot_key =
  { id; target = Cli { runtime_id = id; api_name = "claude-sonnet-5" }; window = 200_000 }
;;

let fast = slot "claude_code.fast"
let wide = slot "claude_code.wide"
let not_held : Registry.resolved_lane = { selected_slots = []; cli_slots = [] }

let declared ?(prompt = "memory prompt") ?(resolved = not_held) ?(unadmitted = []) cli
  : Machine.declared
  =
  { value =
      { question =
          { prompt
          ; answer_schemas =
              { Lane.range = `Assoc [ "type", `String "object" ]
              ; item_alone = `Assoc [ "type", `String "object" ]
              ; room = `Assoc [ "type", `String "object" ]
              }
          ; max_output_tokens = 4096
          ; thinking = None
          }
      ; http = []
      ; cli
      ; unadmitted
      }
  ; resolved
  }
;;

(* An admitted HTTP target, so a slot can carry a rate limit. *)
let admitted_target () =
  let target : EO.declared_target =
    { target_ref = "openrouter.probe"
    ; binding =
        Llm_provider.Provider_config.make ~kind:Llm_provider.Provider_config.OpenAI_compat
          ~provider_id:"openrouter" ~model_id:"z-ai/glm-5.3-flash"
          ~base_url:"https://openrouter.ai/api/v1" ~request_path:"/chat/completions" ()
    ; credential = EO.Credential_not_declared
    ; body_timeout_s = None
    ; model_declaration = EO.No_model_declaration
    }
  in
  match EO.load_resolver_snapshot ~catalog:(EO.Embedded_with_targets [ target ]) () with
  | Error (_ : EO.resolver_snapshot_error) -> fail "the fixture's resolver did not load"
  | Ok snapshot ->
    (match EO.admit_target_ref snapshot target.target_ref with
     | Ok admitted -> admitted
     | Error (_ : EO.target_catalog_admission_error) -> fail "the fixture's target was refused")
;;

(* A lane whose one slot its provider holds for 30 seconds from now. *)
let held_lane () : Registry.resolved_lane =
  let candidate =
    Backpressure.create_candidate ~binding:(Http_binding_unavailable "the machine test's slot")
  in
  Backpressure.note_rate_limit ~candidate ~retry_after:(Some 30.0);
  { selected_slots =
      [ { slot_id = "openrouter.probe"
        ; admitted_target = admitted_target ()
        ; runtime_observation =
            Some
              { candidate
              ; quota_scope =
                  Runtime_quota_window.scope_of_credential ~provider_id:"machine-test" None
              ; window = Some 128_000
              }
        }
      ]
  ; cli_slots = []
  }
;;

let held_slots (value : Machine.t) =
  match value.lane with
  | Some declared ->
    List.map (fun (key : Lane.slot_key) -> key.id) (declared.value.http @ declared.value.cli)
  | None -> []
;;

(* {1 Texts} *)

let stop_text : Store.stop -> string = function
  | Log_diverged { expected; observed } ->
    Printf.sprintf "diverged: the log names %s and the file is %s" (hex expected) (hex observed)
  | Memory_unreadable -> "memory unreadable"
  | Log_unreadable -> "log unreadable"
  | Store_unwritable -> "store unwritable"
  | Raised { detail } -> "raised: " ^ detail
;;

let claims store =
  String.concat "; "
    (List.map (fun (fact : Types.fact) -> fact.claim) (Store.memory store).facts)
;;

let state_text (value : Machine.t) =
  match value.state with
  | Idle { store; seen_length = (_ : int option) } -> "idle, holding: " ^ claims store
  | Asking { store; asking } -> Printf.sprintf "asking #%d, holding: %s" asking.ask (claims store)
  | Resting store -> "resting, holding: " ^ claims store
  | Refused_at_bottom store -> "refused at the bottom, holding: " ^ claims store
  | Stopped stop -> "stopped: " ^ stop_text stop
;;

let fiber_text : Machine.fiber_change -> string = function
  | Keep -> "keep"
  | Start asking -> Printf.sprintf "start #%d" asking.ask
  | Cancel -> "cancel"
  | Cancel_then_start asking -> Printf.sprintf "cancel, then start #%d" asking.ask
;;

let unavailable_text : Machine.unavailable -> string = function
  | Store_stopped stop -> "the store is stopped: " ^ stop_text stop
  | Keeper_retired -> "the keeper is retired"
;;

let write_text : Machine.write_answer -> string = function
  | Written line -> Printf.sprintf "written as commit %d" line.seq
  | Already_held -> "already held"
  | Already_done -> "already done"
  | Already_absent -> "already absent"
  | Refused refusal -> "refused: " ^ Direct.refusal_kind refusal
  | Not_a_snapshot (_ : Envelope.refusal) -> "not a snapshot"
  | Unavailable why -> unavailable_text why
;;

let act_text : Machine.act_answer -> string = function
  | Done -> "done"
  | Not_done Nothing_to_resume -> "nothing to resume"
  | Not_done Not_stopped -> "not stopped"
  | Not_done Snapshot_mismatch -> "snapshot mismatch"
  | Not_done Snapshot_unreadable -> "snapshot unreadable"
  | Not_done (Act_unavailable why) -> unavailable_text why
;;

let cause_text : Log.cause -> string = function
  | Direct _ -> "a direct write"
  | Adopt _ -> "an adoption"
  | Read { slot; _ } -> "read by " ^ slot
  | Make_room { slot; _ } -> "made room by " ^ slot
  | Skip { hole = Content_missing _ } -> "skip: content missing"
  | Skip { hole = Unknown_span { before; after } } ->
    Printf.sprintf "skip: an unknown span from chat %d to %d" before.chat_bytes after.chat_bytes
  | Skip { hole = Item_exceeds_window _ } -> "skip: the item fits no slot"
;;

let not_applied_text (number, (why : Effects.why_not), (_ : Answer.new_fact option)) =
  match why with
  | Removed_during_flight { seq } -> Printf.sprintf "op %d: removed by commit %d" number seq
  | Unknown_ref | Ref_used_twice | Source_outside_question | Not_valid_alone | Not_valid_in_room
  | Successor_unsupported -> Printf.sprintf "op %d: another reason" number
;;

(* {1 Steps} *)

let booted ?lane ?(last_ask = 0) place ~at =
  Machine.booted place ~at ~lane ~last_ask (Machine.boot place ~at)
;;

(* One event, checked as the state it leaves and what it does to the ask's
   fiber. *)
let step ?(at = 300.0) label place value event ~state ~fiber =
  let next = Machine.decide place value ~at event in
  check string (label ^ ": the state") state (state_text next);
  check string (label ^ ": the ask's fiber") fiber
    (fiber_text (Machine.fiber_change ~before:value ~after:next));
  next
;;

(* How the fiber of [value]'s reading ask ends, with what it was asked for,
   as the writer posts it. A late answer is read as one whatever it was
   asked for, so with no reading ask out it says the width the narrowing
   gives now. *)
let ended (value : Machine.t) ask (result : Read_result.t) =
  let asked : Read_result.asked =
    match value.state with
    | Asking { asking = { asked = Read asked; _ }; _ } -> asked
    | Asking { asking = { asked = Room (_ : Masc.Librarian_room_result.asked); _ }; _ }
    | Idle _ | Resting _ | Refused_at_bottom _ | Stopped _ ->
      Read_range (Masc.Librarian_width.next value.narrowing)
  in
  Machine.Ask_ended { ask; result = Read_ended { asked; result } }
;;

let write ?(trace = "turn") place value ~at w =
  Machine.write place value ~at ~by:Effects.Keeper ~trace w
;;

let resume place value ~at =
  Machine.resume place ~boot:(fun () -> Machine.boot place ~at) value ~at
;;

let open_store (value : Machine.t) =
  match value.state with
  | Idle { store; _ } | Asking { store; _ } | Resting store | Refused_at_bottom store -> store
  | Stopped stop -> fail ("the store is stopped: " ^ stop_text stop)
;;

let last_commit (value : Machine.t) =
  match Store.tail (open_store value) with
  | Committed line -> line
  | Started _ -> fail "nothing was committed"
;;

let late_answers () =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string LibrarianLateAnswers)
    ~labels:[ "keeper", keeper_id ]
    ()
;;

let question_id =
  match
    Masc.Librarian_question_id.of_halves ~front:(String.make 32 'c') ~back:(String.make 32 'd')
  with
  | Some id -> id
  | None -> fail "the test question halves are not 32 hexadecimal characters"
;;

(* The question of the ask that is out: the first unread unit, read whole,
   and Memory as it is, its facts named m1, m2 and on. *)
let question place (value : Machine.t) : Read_result.question =
  let store = open_store value in
  let span =
    match
      Unread.read ~turns_path:(turns_path place) ~until:(First_with_items 1) (Store.tail store)
    with
    | Ok { spans; stop = (_ : Unread.stop); bytes = (_ : int) } ->
      (match List.rev spans with
       | last :: _ -> last
       | [] -> fail "nothing is unread")
    | Error (_ : Unread.read_error) -> fail "the turn log of the fixture was not read"
  in
  { id = question_id
  ; shown =
      Range
        { memory =
            List.mapi
              (fun index fact -> Printf.sprintf "m%d" (index + 1), Types.memory_id fact)
              (Store.memory store).facts
        ; units = [ "u1", span.line ]
        }
  ; basis = Log.snapshot_after (Store.tail store)
  ; reach = Unread.reach span Whole
  ; trace = "trace-1"
  ; missing = []
  ; offered = { units = 1; head_items = 1 }
  }
;;

let stated claim : Answer.new_fact =
  { claim; category = Types.Fact; observation = Types.Transcript; from_units = [ "u1" ] }
;;

let answered ?(working_state = Answer.Keep) (question : Read_result.question) ops : Read_result.t =
  Answered { question; answer = { question = question.id; ops; working_state }; slot = fast.id }
;;

let transcript = Types.Observed Types.Transcript

let remember ?(category = Types.Constraint) claim =
  Direct.Remember { claim; category; basis = transcript }
;;

let port = "the port is 8935"
let owner = "the owner is the release team"

(* A place with one unread turn and a writer asking about it. *)
let asking_place () =
  let place = started_place () in
  close_turn place ~from:0 ~until:64;
  place, booted ~lane:(declared [ fast ]) place ~at:100.0
;;

(* A writer whose ask failed with the turn still unread. *)
let resting ?(lane = declared [ fast ]) place =
  close_turn place ~from:0 ~until:64;
  let value = booted ~lane place ~at:100.0 in
  Machine.decide place value ~at:200.0 (ended value 1 (Ask_failed Raised))
;;

(* {1 Boot} *)

let test_boot () =
  check string "a Keeper with a turn log" "idle, holding: "
    (state_text (booted (started_place ()) ~at:100.0));
  check string "a Keeper without one" "stopped: store unwritable"
    (state_text (booted (new_place ()) ~at:100.0));
  let place = started_place () in
  close_turn place ~from:0 ~until:64;
  check string "a turn to read and no lane value" "idle, holding: "
    (state_text (booted place ~at:100.0));
  check string "with a lane value, the first ask" "asking #1, holding: "
    (state_text (booted ~lane:(declared [ fast ]) place ~at:100.0))
;;

(* {1 The table} *)

let test_idle_turn_closed () =
  let place = started_place () in
  let value = booted ~lane:(declared [ fast ]) place ~at:100.0 in
  close_turn place ~from:0 ~until:64;
  let (_ : Machine.t) =
    step "a closed turn" place value Turn_closed ~state:"asking #1, holding: " ~fiber:"start #1"
  in
  ()
;;

let test_idle_pulse () =
  let place = started_place () in
  let value = booted ~lane:(declared [ fast ]) place ~at:100.0 in
  (match value.state with
   | Idle { seen_length; store = (_ : Store.t) } ->
     check (option int) "the length it saw" (Some (length place)) seen_length
   | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _ -> fail "the writer is not idle");
  let value =
    step "the same length" place value Pulse ~state:"idle, holding: " ~fiber:"keep"
  in
  close_turn place ~from:0 ~until:64;
  let (_ : Machine.t) =
    step "a turn whose hint did not come" place value Pulse ~state:"asking #1, holding: "
      ~fiber:"start #1"
  in
  ()
;;

let test_idle_declaration_changed () =
  let place = started_place () in
  close_turn place ~from:0 ~until:64;
  let value = booted place ~at:100.0 in
  let value =
    step "a lane value" place value (Declaration_changed (Some (declared [ fast ])))
      ~state:"asking #1, holding: " ~fiber:"start #1"
  in
  check (list string) "is held" [ fast.id ] (held_slots value)
;;

let test_asking_turn_closed_and_pulse () =
  let place, value = asking_place () in
  close_turn place ~from:64 ~until:128;
  let value =
    step "another closed turn" place value Turn_closed ~state:"asking #1, holding: "
      ~fiber:"keep"
  in
  let (_ : Machine.t) =
    step "the pulse" place value Pulse ~state:"asking #1, holding: " ~fiber:"keep"
  in
  ()
;;

let test_asking_declaration_with_another_question () =
  let place, value = asking_place () in
  let value =
    step "another prompt" place value
      (Declaration_changed (Some (declared ~prompt:"another prompt" [ fast ])))
      ~state:"asking #2, holding: " ~fiber:"cancel, then start #2"
  in
  let (_ : Machine.t) =
    step "no lane value" place value (Declaration_changed None) ~state:"idle, holding: "
      ~fiber:"cancel"
  in
  ()
;;

let test_asking_declaration_with_other_slots () =
  let place, value = asking_place () in
  let value =
    step "other slots" place value (Declaration_changed (Some (declared [ fast; wide ])))
      ~state:"asking #1, holding: " ~fiber:"keep"
  in
  check (list string) "are held" [ fast.id; wide.id ] (held_slots value);
  let (_ : Machine.t) =
    step "the answer" place value
      (ended value 1 (answered (question place value) [ Add (stated owner) ]))
      ~state:("idle, holding: " ^ owner) ~fiber:"cancel"
  in
  ()
;;

let test_resting_turn_closed () =
  let place = started_place () in
  let value = resting place in
  close_turn place ~from:64 ~until:128;
  let (_ : Machine.t) =
    step "a closed turn" place value Turn_closed ~state:"resting, holding: " ~fiber:"keep"
  in
  ()
;;

let test_resting_pulse () =
  let place = started_place () in
  let value = resting ~lane:(declared ~resolved:(held_lane ()) [ fast ]) place in
  let (_ : Machine.t) =
    step ~at:(Unix.gettimeofday () +. 1.0) "every slot held" place value Pulse
      ~state:"resting, holding: " ~fiber:"keep"
  in
  let place = started_place () in
  let (_ : Machine.t) =
    step "a slot that may be called" place (resting place) Pulse ~state:"asking #2, holding: "
      ~fiber:"start #2"
  in
  ()
;;

let test_resting_declaration_changed () =
  let place = started_place () in
  let value = resting place in
  let value =
    step "the value held, published again" place value
      (Declaration_changed (Some (declared [ fast ])))
      ~state:"resting, holding: " ~fiber:"keep"
  in
  let (_ : Machine.t) =
    step "another value" place value (Declaration_changed (Some (declared [ wide ])))
      ~state:"asking #2, holding: " ~fiber:"start #2"
  in
  ()
;;

(* A key or body timeout changed in the registry comes with the same lane
   value. The rest reads the new resolution: here no slot of it is held, so
   the next pulse asks. *)
let test_resting_same_value_new_resolution () =
  let place = started_place () in
  let at = Unix.gettimeofday () +. 1.0 in
  let value = resting ~lane:(declared ~resolved:(held_lane ()) [ fast ]) place in
  let value =
    step ~at "the value held, its resolution published again" place value
      (Declaration_changed (Some (declared [ fast ])))
      ~state:"resting, holding: " ~fiber:"keep"
  in
  let (_ : Machine.t) =
    step ~at "the pulse reads the new resolution" place value Pulse ~state:"asking #2, holding: "
      ~fiber:"start #2"
  in
  ()
;;

let test_stopped () =
  let place = new_place () in
  let value = booted place ~at:100.0 in
  let value =
    step "a closed turn" place value Turn_closed ~state:"stopped: store unwritable" ~fiber:"keep"
  in
  let value = step "the pulse" place value Pulse ~state:"stopped: store unwritable" ~fiber:"keep" in
  let value =
    step "a lane value" place value (Declaration_changed (Some (declared [ fast ])))
      ~state:"stopped: store unwritable" ~fiber:"keep"
  in
  check (list string) "is held for the boot" [ fast.id ] (held_slots value)
;;

(* An answer to an ask that is not out is not committed in any state, and
   only one that carried an answer is counted. *)
let test_late_answers () =
  let place, asking = asking_place () in
  let answer = answered (question place asking) [ Add (stated owner) ] in
  let idle = Machine.decide place asking ~at:200.0 (Declaration_changed None) in
  let resting_place = started_place () in
  let rested = resting resting_place in
  let stopped_place = new_place () in
  let stopped = booted stopped_place ~at:100.0 in
  let logs () = [ file_bytes (log_path place); file_bytes (log_path resting_place) ] in
  let before = logs () in
  let counted = late_answers () in
  let late label place value result ~state =
    let (_ : Machine.t) = step label place value (ended value 1 result) ~state ~fiber:"keep" in
    ()
  in
  late "an answer when idle" place idle answer ~state:"idle, holding: ";
  late "an answer when resting" resting_place rested answer ~state:"resting, holding: ";
  late "an answer when stopped" stopped_place stopped answer ~state:"stopped: store unwritable";
  late "a failed ask when idle" place idle (Ask_failed Raised) ~state:"idle, holding: ";
  check (list string) "nothing is committed" before (logs ());
  check (float 0.0) "the answers are counted" (counted +. 3.0) (late_answers ())
;;

(* {1 The current ask's result} *)

let test_an_answer () =
  let place, value = asking_place () in
  let question = question place value in
  close_turn place ~from:64 ~until:128;
  let value =
    step "the answer" place value
      (ended value 1 (answered question [ Add (stated owner) ]))
      ~state:("asking #2, holding: " ^ owner) ~fiber:"cancel, then start #2"
  in
  let line = last_commit value in
  check string "is committed" ("read by " ^ fast.id) (cause_text line.cause);
  check int "and reading stands past the unit" question.reach.turn_log_offset line.turn_log_offset
;;

let test_nothing_to_ask () =
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "the ask found nothing, the turn log still has the unit" place value
      (ended value 1 Nothing_to_ask) ~state:"asking #2, holding: " ~fiber:"cancel, then start #2"
  in
  ()
;;

let test_no_answer () =
  let place, value = asking_place () in
  let question = question place value in
  let (_ : Machine.t) =
    step "the lane the ask started with" place value
      (ended value 1 (No_answer { question; slots = [ fast, Refused Unsized ] }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  let moved =
    Machine.decide place value ~at:200.0 (Declaration_changed (Some (declared [ wide ])))
  in
  let (_ : Machine.t) =
    step "a new lane value with no slot in the result" place moved
      (ended moved 1 (No_answer { question; slots = [ fast, Silent Busy ] }))
      ~state:"asking #2, holding: " ~fiber:"cancel, then start #2"
  in
  let grown =
    Machine.decide place value ~at:200.0 (Declaration_changed (Some (declared [ fast; wide ])))
  in
  let (_ : Machine.t) =
    step "a new lane value with a slot in the result" place grown
      (ended grown 1 (No_answer { question; slots = [ fast, Silent Busy ] }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  ()
;;

(* §7.6: a refusal of a question wider than one item narrows by what it
   carried and asks again at once, units first and then the head unit's
   items. Silence says nothing of size, so it does not narrow: the writer
   rests. *)
let test_a_refusal_narrows () =
  let asked_text (value : Machine.t) =
    match value.state with
    | Asking { asking = { asked = Read (Read_range width); _ }; _ } -> (
      match width with
      | All -> "all"
      | Units count -> Printf.sprintf "%d units" (count :> int)
      | Items count -> Printf.sprintf "%d items" (count :> int))
    | Asking { asking = { asked = Read Read_item_alone; _ }; _ } -> "the item alone"
    | Asking { asking = { asked = Room (_ : Masc.Librarian_room_result.asked); _ }; _ } ->
      "making room"
    | Idle _ | Resting _ | Refused_at_bottom _ | Stopped _ -> "no ask out"
  in
  let place, value = asking_place () in
  check string "the first ask reads every unit" "all" (asked_text value);
  let refused value ask offered =
    let question = { (question place value) with offered } in
    Machine.decide place value ~at:300.0
      (ended value ask (No_answer { question; slots = [ fast, Refused (Sized Input_too_large) ] }))
  in
  let units = refused value 1 { units = 4; head_items = 2 } in
  check string "four units refused: two" "2 units" (asked_text units);
  let fewer = refused units 2 { units = 2; head_items = 2 } in
  check string "two refused: one" "1 units" (asked_text fewer);
  let items = refused fewer 3 { units = 1; head_items = 6 } in
  check string "one unit refused: half its items" "3 items" (asked_text items);
  let (_ : Machine.t) =
    step "a busy lane says nothing of size" place items
      (ended items 4 (No_answer { question = question place items; slots = [ fast, Silent Busy ] }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  ()
;;

(* {1 The bottom (§7.4)} *)

(* The same question shown alone: the writer reads [shown] for what an
   answer may do, and the test question's id stands for either. *)
let alone_of (question : Read_result.question) : Read_result.question =
  match question.shown with
  | Range { units; _ } | Item_alone { units } -> { question with shown = Item_alone { units } }
;;

let asked_of (value : Machine.t) =
  match value.state with
  | Asking { asking = { asked = Read (Read_range (_ : Masc.Librarian_width.width)); _ }; _ } ->
    "the item with Memory"
  | Asking { asking = { asked = Read Read_item_alone; _ }; _ } -> "the item alone"
  | Asking { asking = { asked = Room (_ : Masc.Librarian_room_result.asked); _ }; _ } ->
    "making room"
  | Idle _ | Resting _ | Refused_at_bottom _ | Stopped _ -> "no ask out"
;;

let facts_held (value : Machine.t) which =
  List.length (Masc.Librarian_bottom.known value.bottom which question_id)
;;

let sized fact : (Lane.slot_key * Masc.Librarian_slot_outcome.unanswered) list =
  [ fast, Refused (Sized fact) ]
;;

(* Every slot refused the head item with Memory for the input's size: the
   item alone is asked at once, and its ask holds the fact, so it will not
   call that slot for the item with Memory again. *)
let test_the_item_with_memory_gives_way_to_the_item_alone () =
  let place, value = asking_place () in
  let question = question place value in
  let alone =
    step "every slot sized for the input" place value
      (ended value 1 (No_answer { question; slots = sized Input_too_large }))
      ~state:"asking #2, holding: " ~fiber:"cancel, then start #2"
  in
  check string "what is asked" "the item alone" (asked_of alone);
  check int "the fact is held" 1 (facts_held alone With_memory);
  match alone.state with
  | Asking { asking; _ } ->
    check int "and the ask starts with it" 1
      (List.length (Masc.Librarian_bottom.known asking.bottom With_memory question.id))
  | Idle _ | Resting _ | Refused_at_bottom _ | Stopped _ -> fail "no ask is out"
;;

(* The item alone fits no slot either: it is skipped for its size, reading
   moves past it and the facts about it go. *)
let test_an_item_that_fits_no_slot_alone_is_skipped () =
  let place, value = asking_place () in
  let question = question place value in
  let alone =
    Machine.decide place value ~at:300.0
      (ended value 1 (No_answer { question; slots = sized Input_too_large }))
  in
  let passed =
    step "every slot sized the item alone for the input" place alone
      (ended alone 2 (No_answer { question = alone_of question; slots = sized Input_too_large }))
      ~state:"idle, holding: " ~fiber:"cancel"
  in
  let line = last_commit passed in
  check string "is passed" "skip: the item fits no slot" (cause_text line.cause);
  check int "reading stands past it" question.reach.turn_log_offset line.turn_log_offset;
  check int "no fact is left" 0 (facts_held passed With_memory + facts_held passed Alone)
;;

(* An item read alone adds and keeps the working state the question did not
   show, and the line says the answer tried to replace it. *)
let test_the_item_alone_keeps_the_working_state () =
  let place, value = asking_place () in
  let question = question place value in
  let alone =
    Machine.decide place value ~at:300.0
      (ended value 1 (No_answer { question; slots = sized Input_too_large }))
  in
  let read =
    step "the item alone answered" place alone
      (ended alone 2
         (answered ~working_state:(Answer.Set "a plan it never saw") (alone_of question)
            [ Add (stated owner) ]))
      ~state:("asking #3, holding: " ^ owner) ~fiber:"cancel, then start #3"
  in
  let line = last_commit read in
  (match line.cause with
   | Read { shown = Item_alone Not_valid_alone; _ } -> ()
   | Read { shown = With_memory | Item_alone Untouched; _ } | Make_room _ | Direct _ | Adopt _ | Skip _ ->
     fail "the line does not say the working state was kept");
  check (option string) "the working state is as it was" None line.working_state;
  check int "no fact is left" 0 (facts_held read With_memory + facts_held read Alone)
;;

(* Every slot sized and not all for the input: nothing is asked or read
   until an event can change the question. A direct write changes Memory,
   so the item with Memory is another question. *)
let test_a_bottom_sized_otherwise_waits_for_an_event () =
  let place, value = asking_place () in
  let question = question place value in
  let waiting =
    step "every slot sized, not all for the input" place value
      (ended value 1 (No_answer { question; slots = sized Output_over_reserve }))
      ~state:"refused at the bottom, holding: " ~fiber:"cancel"
  in
  let waiting =
    step "the pulse" place waiting Pulse ~state:"refused at the bottom, holding: " ~fiber:"keep"
  in
  let waiting =
    step "a closed turn" place waiting Turn_closed ~state:"refused at the bottom, holding: "
      ~fiber:"keep"
  in
  let written, answer = write place waiting ~at:301.0 (remember port) in
  check string "a direct write" "written as commit 1" (write_text answer);
  check string "asks again" ("asking #2, holding: " ^ port) (state_text written);
  check string "its fiber" "start #2" (fiber_text (Machine.fiber_change ~before:waiting ~after:written))
;;

(* A [Resume] at the bottom forgets the facts, so every slot is called again. *)
let test_resume_at_the_bottom_forgets_the_facts () =
  let place, value = asking_place () in
  let question = question place value in
  let waiting =
    Machine.decide place value ~at:300.0
      (ended value 1 (No_answer { question; slots = sized Window_reached }))
  in
  check int "the fact is held" 1 (facts_held waiting With_memory);
  let resumed, answer = resume place waiting ~at:301.0 in
  check string "the operator's resume" "done" (act_text answer);
  check string "asks again" "asking #2, holding: " (state_text resumed);
  check int "with no fact held" 0 (facts_held resumed With_memory)
;;

(* A verdict about a snapshot other than the one now is not used: the item
   with Memory is asked again, and the fact stays learnt. *)
let test_a_verdict_on_another_memory_asks_again () =
  let place, value = asking_place () in
  let question =
    { (question place value) with
      basis = Agent_core.Checkpoint_objects.digest_of_bytes "an older snapshot"
    }
  in
  let again =
    step "sized for the input, against an older snapshot" place value
      (ended value 1 (No_answer { question; slots = sized Input_too_large }))
      ~state:"asking #2, holding: " ~fiber:"cancel, then start #2"
  in
  check string "what is asked" "the item with Memory" (asked_of again);
  check int "the fact is learnt" 1 (facts_held again With_memory)
;;

(* A slot that gives no size keeps the writer above the item: a refusal
   without one, and a declared slot admission left out. *)
let test_a_slot_without_a_size_keeps_the_writer_above () =
  let place = started_place () in
  close_turn place ~from:0 ~until:64;
  let value = booted ~lane:(declared [ fast; wide ]) place ~at:100.0 in
  let (_ : Machine.t) =
    step "one slot sized for the input, one refused without a size" place value
      (ended value 1
         (No_answer
            { question = question place value
            ; slots = [ fast, Refused (Sized Input_too_large); wide, Refused Unsized ]
            }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  let place = started_place () in
  close_turn place ~from:0 ~until:64;
  let value = booted ~lane:(declared ~unadmitted:[ "openrouter.down" ] [ fast ]) place ~at:100.0 in
  let (_ : Machine.t) =
    step "every walked slot sized for the input, one declared slot not admitted" place value
      (ended value 1 (No_answer { question = question place value; slots = sized Input_too_large }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  ()
;;

let test_nothing_readable () =
  let place, value = asking_place () in
  let ({ reach; offered; _ } : Read_result.question) = question place value in
  let value =
    step "a unit with nothing to read" place value
      (ended value 1
         (Nothing_readable
            { reach
            ; missing = [ { line = reach.line; parts = [ Chat_bytes { from = 0; until = 64 } ] } ]
            ; offered
            }))
      ~state:"idle, holding: " ~fiber:"cancel"
  in
  let line = last_commit value in
  check string "is passed" "skip: content missing" (cause_text line.cause);
  check int "and reading stands past it" reach.turn_log_offset line.turn_log_offset
;;

let test_span_unknown () =
  let place, value = asking_place () in
  let reach = (question place value).reach in
  let value =
    step "a span no unit holds" place value
      (ended value 1 (Span_unknown { before = mark 32; reach }))
      ~state:"idle, holding: " ~fiber:"cancel"
  in
  let line = last_commit value in
  check string "is passed up to where the reach covers" "skip: an unknown span from chat 32 to 64"
    (cause_text line.cause);
  check int "and reading stands past it" reach.turn_log_offset line.turn_log_offset
;;

let test_memory_diverged () =
  let place, value = asking_place () in
  let expected = Digest.digest_of_bytes "named" in
  let observed = Digest.digest_of_bytes "held" in
  let (_ : Machine.t) =
    step "Memory that is not the log's" place value
      (ended value 1 (Memory_diverged { expected; observed }))
      ~state:("stopped: " ^ stop_text (Log_diverged { expected; observed }))
      ~fiber:"cancel"
  in
  ()
;;

(* A snapshot the store does not open stops the store, as boot does for the
   same file; the writer does not rest and ask again on every pulse. *)
let test_snapshot_fault () =
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "no snapshot file" place value (ended value 1 (Snapshot_fault Absent))
      ~state:"stopped: memory unreadable" ~fiber:"cancel"
  in
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "a snapshot read that failed" place value (ended value 1 (Snapshot_fault Not_read))
      ~state:"stopped: store unwritable" ~fiber:"cancel"
  in
  ()
;;

let test_input_fault () =
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "a line that cannot be read" place value
      (ended value 1 (Input_fault (Line_unreadable { offset = 0 })))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  ()
;;

let test_ask_failed () =
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "an ask that raised" place value (ended value 1 (Ask_failed Raised))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  ()
;;

(* §13 F14: an answer whose question started where reading no longer stands
   is not committed. Only a commit of the current ask moves reading, and the
   ask after it has another number, so the old answer is late. *)
let test_an_answer_from_before_reading_moved () =
  let place, value = asking_place () in
  close_turn place ~from:64 ~until:128;
  let first = question place value in
  let value =
    Machine.decide place value ~at:200.0
      (ended value 1 (Nothing_readable { reach = first.reach; missing = []; offered = first.offered }))
  in
  let log = file_bytes (log_path place) in
  let counted = late_answers () in
  let (_ : Machine.t) =
    step "the answer to the first question" place value
      (ended value 1 (answered first [ Add (stated owner) ]))
      ~state:"asking #2, holding: " ~fiber:"keep"
  in
  check string "is not committed" log (file_bytes (log_path place));
  check (float 0.0) "and is counted" (counted +. 1.0) (late_answers ())
;;

(* {1 Making room (§7.4)} *)

let room_question (value : Machine.t) : Masc.Librarian_room_result.question =
  let store = open_store value in
  { id = question_id
  ; memory =
      List.mapi
        (fun index fact -> Printf.sprintf "m%d" (index + 1), Types.memory_id fact)
        (Store.memory store).facts
  ; basis = Log.snapshot_after (Store.tail store)
  ; trace = "trace-1"
  }
;;

let room_outcomes outcome =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string LibrarianRoomOutcomes)
    ~labels:[ "keeper", keeper_id; "outcome", outcome ]
    ()
;;

let room_ended ask (result : Masc.Librarian_room_result.t) =
  Machine.Ask_ended { ask; result = Room_ended result }
;;

let room_answered ?(working_state = Answer.Keep) question ops : Masc.Librarian_room_result.t =
  Room_answered
    { question
    ; answer = { question = question.Masc.Librarian_room_result.id; ops; working_state }
    ; slot = fast.id
    }
;;

(* The item read alone and committed with [owner], [before] written first
   while it was asked, and what follows it. *)
let after_the_item_alone ?(before = fun (_ : Machine.place) value -> value) ~state ~fiber () =
  let place, value = asking_place () in
  let question = question place value in
  let alone =
    before place
      (Machine.decide place value ~at:300.0
         (ended value 1 (No_answer { question; slots = sized Input_too_large })))
  in
  ( place
  , step "the item alone answered" place alone
      (ended alone 2 (answered (alone_of question) [ Add (stated owner) ]))
      ~state ~fiber )
;;

let making_room () =
  let place, room =
    after_the_item_alone ~state:("asking #3, holding: " ^ owner)
      ~fiber:"cancel, then start #3" ()
  in
  check string "is followed by" "making room" (asked_of room);
  place, room
;;

(* An answer is committed only when it changes something, on a line that
   does not move reading. One about a fact removed while it was asked is
   not committed. Either way the next ask follows. *)
let test_making_room () =
  let counted = List.map room_outcomes [ "made"; "left_out"; "stale" ] in
  let place, room = making_room () in
  let read = last_commit room in
  let made =
    step "an answer that drops a fact" place room
      (room_ended 3
         (room_answered (room_question room) [ Drop { ref_ = "m1"; reason = "held elsewhere" } ]))
      ~state:"idle, holding: " ~fiber:"cancel"
  in
  let line = last_commit made in
  check string "is a line" ("made room by " ^ fast.id) (cause_text line.cause);
  check int "after the item's" (read.seq + 1) line.seq;
  check bool "that leaves reading where the item ended" true
    (line.covers_through = read.covers_through && line.turn_log_offset = read.turn_log_offset);
  let place, room = making_room () in
  let unchanged =
    step "an answer that changes nothing" place room
      (room_ended 3
         (room_answered ~working_state:(Answer.Set "") (room_question room) [ Add (stated port) ]))
      ~state:("idle, holding: " ^ owner) ~fiber:"cancel"
  in
  check int "writes no line" read.seq (last_commit unchanged).seq;
  let place, room = making_room () in
  let shown = room_question room in
  let retracted, (_ : Machine.write_answer) =
    write place room ~at:310.0
      (Direct.Retract { id = Types.memory_id_of_claim owner; reason = "moved" })
  in
  let stale =
    step "an answer about a fact retracted while it was asked" place retracted
      (room_ended 3
         (room_answered shown [ Revise { ref_ = "m1"; into = stated "the owner is the platform team" } ]))
      ~state:"idle, holding: " ~fiber:"cancel"
  in
  check int "is not committed" (last_commit retracted).seq (last_commit stale).seq;
  check (list (float 0.0)) "each end is counted once, under its outcome"
    (List.map (fun count -> count +. 1.0) counted)
    (List.map room_outcomes [ "made"; "left_out"; "stale" ])
;;

(* Making room is asked only about what the item was asked under, and it
   never holds reading up; a snapshot that is not the log's stops the store
   as for any ask. *)
let test_making_room_follows_the_item () =
  let (_ : Machine.place), (_ : Machine.t) =
    after_the_item_alone
      ~before:(fun place value ->
        let held, (_ : Machine.write_answer) = write place value ~at:310.0 (remember port) in
        fst
          (write place held ~at:320.0
             (Direct.Retract { id = Types.memory_id_of_claim port; reason = "moved" })))
      ~state:("idle, holding: " ^ owner) ~fiber:"cancel" ()
  in
  let place, room = making_room () in
  let (_ : Machine.t) =
    step "no slot answers" place room
      (room_ended 3
         (Room_not_answered { question = room_question room; slots = [ fast, Silent Busy ] }))
      ~state:("idle, holding: " ^ owner) ~fiber:"cancel"
  in
  let place, room = making_room () in
  let expected = Log.snapshot_after (Store.tail (open_store room)) in
  let observed = Digest.digest_of_bytes "held" in
  let (_ : Machine.t) =
    step "Memory that is not the log's" place room
      (room_ended 3 (Room_memory_diverged { expected; observed }))
      ~state:("stopped: " ^ stop_text (Log_diverged { expected; observed }))
      ~fiber:"cancel"
  in
  (* The snapshot is replaced after the question was made: the line is not
     written, so the answer is not made. *)
  let place, room = making_room () in
  let shown = room_question room in
  let named = Digest.digest_of_bytes (file_bytes (snapshot_path place)) in
  let other = other_snapshot () in
  write_file (snapshot_path place) other;
  let stop : Store.stop =
    Log_diverged { expected = named; observed = Digest.digest_of_bytes other }
  in
  let made = room_outcomes "made" in
  let stopped = room_outcomes "store_stopped" in
  let (_ : Machine.t) =
    step "an answer whose line finds another snapshot" place room
      (room_ended 3 (room_answered shown [ Drop { ref_ = "m1"; reason = "held elsewhere" } ]))
      ~state:("stopped: " ^ stop_text stop) ~fiber:"cancel"
  in
  check (pair (float 0.0) (float 0.0)) "is counted as the store's stop, not as made"
    (made, stopped +. 1.0)
    (room_outcomes "made", room_outcomes "store_stopped")
;;

(* {1 Direct writes} *)

(* An open store that holds [port]. *)
let holding_port () =
  let place = started_place () in
  let value, answer = write place (booted place ~at:100.0) ~at:201.0 (remember port) in
  check string "the fixture's write" "written as commit 1" (write_text answer);
  place, value
;;

(* The same store after its snapshot was replaced from outside. The first
   write finds it and stops the store. *)
let diverged () =
  let place, value = holding_port () in
  let named = Digest.digest_of_bytes (file_bytes (snapshot_path place)) in
  let other = other_snapshot () in
  write_file (snapshot_path place) other;
  let stop : Store.stop =
    Log_diverged { expected = named; observed = Digest.digest_of_bytes other }
  in
  let value, answer = write place value ~at:202.0 (remember owner) in
  check string "the write that finds the other snapshot"
    ("the store is stopped: " ^ stop_text stop)
    (write_text answer);
  check string "stops the store" ("stopped: " ^ stop_text stop) (state_text value);
  place, value, stop, other
;;

let test_write_when_idle () =
  let place, value = holding_port () in
  check string "the store holds the claim" ("idle, holding: " ^ port) (state_text value);
  let value, again = write place value ~at:202.0 (remember port) in
  check string "the same claim again moves its last_seen, so it is a commit"
    "written as commit 2" (write_text again);
  let log = file_bytes (log_path place) in
  let unchanged label w expected =
    let next, answer = write place value ~at:203.0 w in
    check string label expected (write_text answer);
    check string (label ^ ": the state is as it was") (state_text value) (state_text next);
    check string (label ^ ": no line is written") log (file_bytes (log_path place))
  in
  unchanged "the claim said another way" (remember ~category:Types.Lesson port) "already held";
  unchanged "a fact that is not held"
    (Direct.Retract { id = Types.memory_id_of_claim "never written"; reason = "wrong" })
    "already absent";
  unchanged "a claim that replaces a fact that is not held"
    (Direct.Supersede
       { old = Types.memory_id_of_claim "never written"
       ; claim = "the port is 9000"
       ; category = Types.Constraint
       ; basis = transcript
       })
    "refused: unknown_fact";
  let next, answer = write ~trace:" " place value ~at:203.0 (remember owner) in
  check string "a write on no trace" "refused: blank_trace" (write_text answer);
  check string "leaves the state" (state_text value) (state_text next)
;;

(* The write is committed while the ask is out, and the answer that comes
   after it cannot bring back the fact it removed. *)
let test_write_while_asking () =
  let place, value = holding_port () in
  close_turn place ~from:0 ~until:64;
  let value =
    Machine.decide place value ~at:205.0 (Declaration_changed (Some (declared [ fast ])))
  in
  let question = question place value in
  let next, answer =
    write place value ~at:210.0 (Direct.Retract { id = Types.memory_id_of_claim port; reason = "moved" })
  in
  check string "a retraction while an ask is out" "written as commit 2" (write_text answer);
  check string "is committed at once" "asking #1, holding: " (state_text next);
  check string "and the ask goes on" "keep"
    (fiber_text (Machine.fiber_change ~before:value ~after:next));
  let value =
    Machine.decide place next ~at:300.0
      (ended next 1
         (answered question
            [ Revise { ref_ = "m1"; into = stated "the port is 9000" }; Add (stated port) ]))
  in
  check string "the answer is committed without the fact" "idle, holding: " (state_text value);
  check (list string) "its ops on that fact are left out"
    [ "op 0: removed by commit 2"; "op 1: removed by commit 2" ]
    (List.map not_applied_text (last_commit value).effects.not_applied)
;;

let test_write_when_stopped () =
  let place, value, stop, (_ : string) = diverged () in
  let log = file_bytes (log_path place) in
  let next, answer = write place value ~at:203.0 (remember owner) in
  check string "a write to a stopped store"
    ("the store is stopped: " ^ stop_text stop)
    (write_text answer);
  check string "leaves it stopped" (state_text value) (state_text next);
  check string "and writes no line" log (file_bytes (log_path place))
;;

(* {1 Operator acts} *)

let test_resume () =
  let place, idle = holding_port () in
  let held = file_bytes (snapshot_path place) in
  let same, answer = resume place idle ~at:300.0 in
  check string "a store that is open" "nothing to resume" (act_text answer);
  check string "stays as it was" (state_text idle) (state_text same);
  write_file (snapshot_path place) (other_snapshot ());
  let stopped, (_ : Machine.write_answer) = write place idle ~at:202.0 (remember owner) in
  let still, answer = resume place stopped ~at:300.0 in
  check string "the boot ran" "done" (act_text answer);
  check string "and stopped the same way" (state_text stopped) (state_text still);
  write_file (snapshot_path place) held;
  let opened, answer = resume place still ~at:301.0 in
  check string "the boot ran again" "done" (act_text answer);
  check string "with the snapshot back, the store opens" ("idle, holding: " ^ port)
    (state_text opened);
  let resting_place = started_place () in
  let asked, answer = resume resting_place (resting resting_place) ~at:300.0 in
  check string "a resting writer" "done" (act_text answer);
  check string "asks again" "asking #2, holding: " (state_text asked)
;;

(* A write stops the store while ask 1 is out, and its answer is still in
   the mailbox after the resume. The resumed writer keeps the lane value and
   numbers its next ask 2, so that answer is late. *)
let test_resume_keeps_the_lane_and_the_last_number () =
  let place, value = asking_place () in
  let question = question place value in
  let held = file_bytes (snapshot_path place) in
  write_file (snapshot_path place) (other_snapshot ());
  let stopped, (_ : Machine.write_answer) = write place value ~at:201.0 (remember owner) in
  write_file (snapshot_path place) held;
  let resumed, answer = resume place stopped ~at:300.0 in
  check string "the boot ran" "done" (act_text answer);
  check string "and the next ask has the number after the last" "asking #2, holding: "
    (state_text resumed);
  let log = file_bytes (log_path place) in
  let (_ : Machine.t) =
    step "the answer to the ask before the stop" place resumed
      (ended resumed 1 (answered question [ Add (stated owner) ]))
      ~state:"asking #2, holding: " ~fiber:"keep"
  in
  check string "is not committed" log (file_bytes (log_path place))
;;

let test_adopt () =
  let place, stopped, (_ : Store.stop), other = diverged () in
  let log = file_bytes (log_path place) in
  let adopt value observed = Machine.adopt place value ~at:400.0 ~by:"operator-1" ~observed in
  let refused, answer = adopt stopped (Digest.digest_of_bytes "another snapshot") in
  check string "bytes the file does not hold" "snapshot mismatch" (act_text answer);
  check string "leave the store stopped" (state_text stopped) (state_text refused);
  check string "and the log as it was" log (file_bytes (log_path place));
  let opened, answer = adopt stopped (Digest.digest_of_bytes other) in
  check string "the bytes the file holds" "done" (act_text answer);
  check string "open the store with them" "idle, holding: " (state_text opened);
  let again, answer = adopt opened (Digest.digest_of_bytes other) in
  check string "a store that is open" "not stopped" (act_text answer);
  check string "stays as it was" (state_text opened) (state_text again);
  let value, answer = write place opened ~at:401.0 (remember owner) in
  check string "the next write follows the adoption" "written as commit 3" (write_text answer);
  check string "and is held" ("idle, holding: " ^ owner) (state_text value)
;;

let test_adopt_is_not_the_way_out_of_every_stop () =
  let place, (_ : Machine.t) = holding_port () in
  Sys.remove (snapshot_path place);
  let stopped = booted place ~at:300.0 in
  check string "a store without its snapshot" "stopped: memory unreadable" (state_text stopped);
  let same, answer =
    Machine.adopt place stopped ~at:400.0 ~by:"operator-1"
      ~observed:(Digest.digest_of_bytes "anything")
  in
  check string "is not adopted" "the store is stopped: memory unreadable" (act_text answer);
  check string "and stays stopped" (state_text stopped) (state_text same)
;;

(* {1 What the row reads}

   The writer keeps how its last asks ended for the operator's row (§12.2),
   as the model's [SetLast] and [SetRoom] set them. *)

let last_read_text (value : Machine.t) =
  match value.last_read with
  | None -> "none"
  | Some Committed -> "committed"
  | Some (Lane { one_item; silent; basis = (_ : Digest.digest); slots = _ }) ->
    Printf.sprintf "lane, %s, %s"
      (if one_item then "one item" else "wider")
      (if silent then "a slot silent" else "none silent")
  | Some Input_fault -> "input fault"
  | Some (Ask_failed Raised) -> "failed: raised"
  | Some (Ask_failed Flow_stopped) -> "failed: flow stopped"
  | Some (Ask_failed Read_failed) -> "failed: read failed"
;;

let last_room_text (value : Machine.t) =
  match value.last_room with
  | None -> "none"
  | Some Made -> "made"
  | Some Unchanged -> "unchanged"
  | Some Stale -> "stale"
  | Some Not_judged -> "not judged"
  | Some (Fits_none { memory = (_ : Digest.digest); lane = (_ : Lane.t) }) -> "fits none"
;;

let last_basis (value : Machine.t) =
  match value.last_read with
  | Some (Lane { basis; _ }) -> hex basis
  | Some (Committed | Input_fault | Ask_failed _) | None -> fail "the last read is not the lane's"
;;

(* A boot holds none; a failed ask and an input fault are kept as they
   ended, and an ask with nothing to read keeps what the last one left. *)
let test_the_row_starts_empty_and_keeps_each_failure () =
  let place, value = asking_place () in
  check string "a boot holds no read" "none" (last_read_text value);
  check string "and no room" "none" (last_room_text value);
  check bool "and no read alone" false value.read_alone;
  let faulted =
    Machine.decide place value ~at:300.0
      (ended value 1 (Input_fault (Line_unreadable { offset = 0 })))
  in
  check string "an input fault" "input fault" (last_read_text faulted);
  let failed = resting (started_place ()) in
  check string "a failed ask" "failed: raised" (last_read_text failed)
;;

(* At one item the row says whether a slot declared now was silent: one not
   in the walk is, one that refused without a size is not. The basis is the
   snapshot the question was made against. *)
let test_a_one_item_rest_says_whether_a_slot_was_silent () =
  let place = started_place () in
  close_turn place ~from:0 ~until:64;
  let value = booted ~lane:(declared [ fast; wide ]) place ~at:100.0 in
  let question = question place value in
  let rested =
    step "one slot sized, the other not in the walk" place value
      (ended value 1 (No_answer { question; slots = sized Output_over_reserve }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  check string "is a silent one-item rest" "lane, one item, a slot silent" (last_read_text rested);
  let place, value = asking_place () in
  let question = question place value in
  let rested =
    step "the one slot refused without a size" place value
      (ended value 1 (No_answer { question; slots = [ fast, Refused Unsized ] }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  check string "is not silent" "lane, one item, none silent" (last_read_text rested);
  check string "about the snapshot it was asked against" (hex question.basis) (last_basis rested)
;;

(* The item read alone marks the read, and the room ask after it that every
   slot refused for its input says so with the Memory and the lane value it
   was asked with. A range read after it is one with Memory again and
   empties the room's verdict. *)
let test_an_item_read_alone_and_a_room_that_fits_no_slot () =
  let place, room = making_room () in
  check string "the item alone was committed" "committed" (last_read_text room);
  check bool "and read without Memory" true room.read_alone;
  let shown = room_question room in
  let fits_none =
    step "every slot refused the room for its input" place room
      (room_ended 3 (Room_not_answered { question = shown; slots = sized Input_too_large }))
      ~state:("idle, holding: " ^ owner) ~fiber:"cancel"
  in
  check string "fits none" "fits none" (last_room_text fits_none);
  (match fits_none.last_room with
   | Some (Fits_none { memory; lane }) ->
     check string "with the Memory it showed" (hex shown.basis) (hex memory);
     check bool "and the lane value it was asked with" true
       (Lane.equal (declared [ fast ]).value lane)
   | Some (Made | Unchanged | Stale | Not_judged) | None -> fail "the room does not fit none");
  close_turn place ~from:64 ~until:128;
  let asking = Machine.decide place fits_none ~at:400.0 Turn_closed in
  let read =
    Machine.decide place asking ~at:410.0
      (ended asking 4 (answered (question place asking) [ Add (stated port) ]))
  in
  check string "a range read" "committed" (last_read_text read);
  check bool "is not alone" false read.read_alone;
  check string "and empties the room" "none" (last_room_text read)
;;

(* Each other end of a room ask is kept as it ended. *)
let test_each_room_end_is_kept () =
  let place, room = making_room () in
  let made =
    Machine.decide place room ~at:320.0
      (room_ended 3
         (room_answered (room_question room) [ Drop { ref_ = "m1"; reason = "held elsewhere" } ]))
  in
  check string "an answer committed" "made" (last_room_text made);
  let place, room = making_room () in
  let unchanged =
    Machine.decide place room ~at:320.0 (room_ended 3 (room_answered (room_question room) []))
  in
  check string "an answer that changes nothing" "unchanged" (last_room_text unchanged);
  let place, room = making_room () in
  let shown = room_question room in
  let retracted, (_ : Machine.write_answer) =
    write place room ~at:310.0
      (Direct.Retract { id = Types.memory_id_of_claim owner; reason = "moved" })
  in
  let stale =
    Machine.decide place retracted ~at:320.0
      (room_ended 3 (room_answered shown [ Drop { ref_ = "m1"; reason = "held elsewhere" } ]))
  in
  check string "an answer about a fact gone" "stale" (last_room_text stale);
  let place, room = making_room () in
  let failed = Machine.decide place room ~at:320.0 (room_ended 3 (Room_failed Raised)) in
  check string "a failed ask" "not judged" (last_room_text failed)
;;

let () =
  run "librarian_machine"
    [ "boot", [ test_case "opens or stops, and asks" `Quick test_boot ]
    ; ( "table"
      , [ test_case "idle, a closed turn" `Quick test_idle_turn_closed
        ; test_case "idle, the pulse" `Quick test_idle_pulse
        ; test_case "idle, a new declaration" `Quick test_idle_declaration_changed
        ; test_case "asking, a closed turn and the pulse" `Quick test_asking_turn_closed_and_pulse
        ; test_case "asking, another question side" `Quick
            test_asking_declaration_with_another_question
        ; test_case "asking, other slots" `Quick test_asking_declaration_with_other_slots
        ; test_case "resting, a closed turn" `Quick test_resting_turn_closed
        ; test_case "resting, the pulse" `Quick test_resting_pulse
        ; test_case "resting, a new declaration" `Quick test_resting_declaration_changed
        ; test_case "resting, the same value with a new resolution" `Quick
            test_resting_same_value_new_resolution
        ; test_case "stopped" `Quick test_stopped
        ; test_case "late answers" `Quick test_late_answers
        ] )
    ; ( "result"
      , [ test_case "an answer" `Quick test_an_answer
        ; test_case "nothing to ask" `Quick test_nothing_to_ask
        ; test_case "no answer" `Quick test_no_answer
        ; test_case "a refusal narrows" `Quick test_a_refusal_narrows
        ; test_case "nothing readable" `Quick test_nothing_readable
        ; test_case "a span unknown" `Quick test_span_unknown
        ; test_case "Memory diverged" `Quick test_memory_diverged
        ; test_case "a snapshot fault" `Quick test_snapshot_fault
        ; test_case "an input fault" `Quick test_input_fault
        ; test_case "a failed ask" `Quick test_ask_failed
        ; test_case "an answer from before reading moved" `Quick
            test_an_answer_from_before_reading_moved
        ] )
    ; ( "bottom"
      , [ test_case "the item with Memory gives way to the item alone" `Quick
            test_the_item_with_memory_gives_way_to_the_item_alone
        ; test_case "an item that fits no slot alone is skipped" `Quick
            test_an_item_that_fits_no_slot_alone_is_skipped
        ; test_case "the item alone keeps the working state" `Quick
            test_the_item_alone_keeps_the_working_state
        ; test_case "a bottom sized otherwise waits for an event" `Quick
            test_a_bottom_sized_otherwise_waits_for_an_event
        ; test_case "resume at the bottom forgets the facts" `Quick
            test_resume_at_the_bottom_forgets_the_facts
        ; test_case "a verdict on another Memory asks again" `Quick
            test_a_verdict_on_another_memory_asks_again
        ; test_case "a slot without a size keeps the writer above" `Quick
            test_a_slot_without_a_size_keeps_the_writer_above
        ] )
    ; ( "making room"
      , [ test_case "an answer that changes something" `Quick test_making_room
        ; test_case "follows the item it was asked under" `Quick test_making_room_follows_the_item
        ] )
    ; ( "row"
      , [ test_case "starts empty and keeps each failure" `Quick
            test_the_row_starts_empty_and_keeps_each_failure
        ; test_case "a one-item rest says whether a slot was silent" `Quick
            test_a_one_item_rest_says_whether_a_slot_was_silent
        ; test_case "an item read alone and a room that fits no slot" `Quick
            test_an_item_read_alone_and_a_room_that_fits_no_slot
        ; test_case "each room end is kept" `Quick test_each_room_end_is_kept
        ] )
    ; ( "write"
      , [ test_case "when idle" `Quick test_write_when_idle
        ; test_case "while asking" `Quick test_write_while_asking
        ; test_case "when stopped" `Quick test_write_when_stopped
        ] )
    ; ( "operator"
      , [ test_case "resume" `Quick test_resume
        ; test_case "resume keeps the lane and the last number" `Quick
            test_resume_keeps_the_lane_and_the_last_number
        ; test_case "adopt" `Quick test_adopt
        ; test_case "adopt is not the way out of every stop" `Quick
            test_adopt_is_not_the_way_out_of_every_stop
        ] )
    ]
;;
