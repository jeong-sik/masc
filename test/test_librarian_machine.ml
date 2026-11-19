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

let declared ?(prompt = "memory prompt") ?(resolved = not_held) cli : Machine.declared =
  { value =
      { question =
          { prompt
          ; answer_schema = `Assoc [ "type", `String "object" ]
          ; max_output_tokens = 4096
          ; thinking = None
          }
      ; http = []
      ; cli
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
  | Skip { hole = Content_missing _ } -> "skip: content missing"
  | Skip { hole = Unknown_span { before; after } } ->
    Printf.sprintf "skip: an unknown span from chat %d to %d" before.chat_bytes after.chat_bytes
;;

let not_applied_text (number, (why : Effects.why_not), (_ : Answer.new_fact option)) =
  match why with
  | Removed_during_flight { seq } -> Printf.sprintf "op %d: removed by commit %d" number seq
  | Unknown_ref | Ref_used_twice | Source_outside_question | Not_valid_alone
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

let ended ask (result : Read_result.t) = Machine.Ask_ended { ask; result = Read_ended result }

let write ?(trace = "turn") value ~at w = Machine.write value ~at ~by:Effects.Keeper ~trace w

let resume place value ~at =
  Machine.resume place ~boot:(fun () -> Machine.boot place ~at) value ~at
;;

let open_store (value : Machine.t) =
  match value.state with
  | Idle { store; _ } | Asking { store; _ } | Resting store -> store
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
      { memory =
          Some
            (List.mapi
               (fun index fact -> Printf.sprintf "m%d" (index + 1), Types.memory_id fact)
               (Store.memory store).facts)
      ; units = [ "u1", span.line ]
      }
  ; reach = Unread.reach_whole span
  ; trace = "trace-1"
  ; missing = []
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
  Machine.decide place (booted ~lane place ~at:100.0) ~at:200.0
    (ended 1 (Ask_failed Raised))
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
   | Asking _ | Resting _ | Stopped _ -> fail "the writer is not idle");
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
      (ended 1 (answered (question place value) [ Add (stated owner) ]))
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
    let (_ : Machine.t) = step label place value (ended 1 result) ~state ~fiber:"keep" in
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
      (ended 1 (answered question [ Add (stated owner) ]))
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
      (ended 1 Nothing_to_ask) ~state:"asking #2, holding: " ~fiber:"cancel, then start #2"
  in
  ()
;;

let test_no_answer () =
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "the lane the ask started with" place value
      (ended 1 (No_answer { slots = [ fast, Refused Unsized ] }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  let moved =
    Machine.decide place value ~at:200.0 (Declaration_changed (Some (declared [ wide ])))
  in
  let (_ : Machine.t) =
    step "a new lane value with no slot in the result" place moved
      (ended 1 (No_answer { slots = [ fast, Silent Busy ] }))
      ~state:"asking #2, holding: " ~fiber:"cancel, then start #2"
  in
  let grown =
    Machine.decide place value ~at:200.0 (Declaration_changed (Some (declared [ fast; wide ])))
  in
  let (_ : Machine.t) =
    step "a new lane value with a slot in the result" place grown
      (ended 1 (No_answer { slots = [ fast, Silent Busy ] }))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  ()
;;

let test_nothing_readable () =
  let place, value = asking_place () in
  let reach = (question place value).reach in
  let value =
    step "a unit with nothing to read" place value
      (ended 1
         (Nothing_readable
            { reach
            ; missing = [ { line = reach.line; parts = [ Chat_bytes { from = 0; until = 64 } ] } ]
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
      (ended 1 (Span_unknown { before = mark 32; reach }))
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
      (ended 1 (Memory_diverged { expected; observed }))
      ~state:("stopped: " ^ stop_text (Log_diverged { expected; observed }))
      ~fiber:"cancel"
  in
  ()
;;

let test_input_fault () =
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "a line that cannot be read" place value
      (ended 1 (Input_fault (Line_unreadable { offset = 0 })))
      ~state:"resting, holding: " ~fiber:"cancel"
  in
  ()
;;

let test_ask_failed () =
  let place, value = asking_place () in
  let (_ : Machine.t) =
    step "an ask that raised" place value (ended 1 (Ask_failed Raised))
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
      (ended 1 (Nothing_readable { reach = first.reach; missing = [] }))
  in
  let log = file_bytes (log_path place) in
  let counted = late_answers () in
  let (_ : Machine.t) =
    step "the answer to the first question" place value
      (ended 1 (answered first [ Add (stated owner) ]))
      ~state:"asking #2, holding: " ~fiber:"keep"
  in
  check string "is not committed" log (file_bytes (log_path place));
  check (float 0.0) "and is counted" (counted +. 1.0) (late_answers ())
;;

(* {1 Direct writes} *)

(* An open store that holds [port]. *)
let holding_port () =
  let place = started_place () in
  let value, answer = write (booted place ~at:100.0) ~at:201.0 (remember port) in
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
  let value, answer = write value ~at:202.0 (remember owner) in
  check string "the write that finds the other snapshot"
    ("the store is stopped: " ^ stop_text stop)
    (write_text answer);
  check string "stops the store" ("stopped: " ^ stop_text stop) (state_text value);
  place, value, stop, other
;;

let test_write_when_idle () =
  let place, value = holding_port () in
  check string "the store holds the claim" ("idle, holding: " ^ port) (state_text value);
  let value, again = write value ~at:202.0 (remember port) in
  check string "the same claim again moves its last_seen, so it is a commit"
    "written as commit 2" (write_text again);
  let log = file_bytes (log_path place) in
  let unchanged label w expected =
    let next, answer = write value ~at:203.0 w in
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
  let next, answer = write ~trace:" " value ~at:203.0 (remember owner) in
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
    write value ~at:210.0 (Direct.Retract { id = Types.memory_id_of_claim port; reason = "moved" })
  in
  check string "a retraction while an ask is out" "written as commit 2" (write_text answer);
  check string "is committed at once" "asking #1, holding: " (state_text next);
  check string "and the ask goes on" "keep"
    (fiber_text (Machine.fiber_change ~before:value ~after:next));
  let value =
    Machine.decide place next ~at:300.0
      (ended 1
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
  let next, answer = write value ~at:203.0 (remember owner) in
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
  let stopped, (_ : Machine.write_answer) = write idle ~at:202.0 (remember owner) in
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
  let stopped, (_ : Machine.write_answer) = write value ~at:201.0 (remember owner) in
  write_file (snapshot_path place) held;
  let resumed, answer = resume place stopped ~at:300.0 in
  check string "the boot ran" "done" (act_text answer);
  check string "and the next ask has the number after the last" "asking #2, holding: "
    (state_text resumed);
  let log = file_bytes (log_path place) in
  let (_ : Machine.t) =
    step "the answer to the ask before the stop" place resumed
      (ended 1 (answered question [ Add (stated owner) ]))
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
  let value, answer = write opened ~at:401.0 (remember owner) in
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
        ; test_case "stopped" `Quick test_stopped
        ; test_case "late answers" `Quick test_late_answers
        ] )
    ; ( "result"
      , [ test_case "an answer" `Quick test_an_answer
        ; test_case "nothing to ask" `Quick test_nothing_to_ask
        ; test_case "no answer" `Quick test_no_answer
        ; test_case "nothing readable" `Quick test_nothing_readable
        ; test_case "a span unknown" `Quick test_span_unknown
        ; test_case "Memory diverged" `Quick test_memory_diverged
        ; test_case "an input fault" `Quick test_input_fault
        ; test_case "a failed ask" `Quick test_ask_failed
        ; test_case "an answer from before reading moved" `Quick
            test_an_answer_from_before_reading_moved
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
