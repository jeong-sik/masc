(* One ask of a reading question (RFC librarian-call-only-proposes §7.1, §7.2,
   §13 G4) against a fake provider on loopback: a slot answers, refuses for
   the input's size, or says nothing; Memory bytes other than the log names
   end the ask before any call; a direct write that commits while the ask
   reads Memory is read again, not named diverged; and however long the ask
   waits for a seat, the body deadline is not shorter. *)

open Alcotest
open Masc
module Ask = Librarian_ask
module Machine = Librarian_machine
module Store = Librarian_store
module Read_result = Librarian_read_result
module Registry = Runtime_exact_output_registry
module Fixture = Exact_output_fixture
module Turn_log = Keeper_turn_log
module Turn_store = Keeper_turn_log_store
module Digest = Agent_core.Checkpoint_objects

let keeper_id = "keeper-a"
let session = "session-1"
let slot_id = "openrouter.fast"
let prompt = "You keep one Keeper's Memory."
let schema = `Assoc [ "type", `String "object" ]
let chat_text = "the release train leaves on Friday"
let claim = "the port is 8935"

(* The deadline every request of the fixture's provider carries, from its
   dispatch. *)
let body_deadline_s = 60.0

(* How many body deadlines pass on the ask's clock while its seat is held. *)
let waited_deadlines = 10.0

(* How often the test looks at the seat's queue. *)
let poll_s = 0.001

let boot_at = 100.0
let write_at = 101.0

let runtime_toml ~endpoint ~binding =
  Printf.sprintf
    {|[runtime]
default = "openrouter.fast"
[runtime.exact_output_lanes.librarian_memory]
slots = ["openrouter.fast"]
max_output_tokens = 1024
[runtime.exact_output_lanes.board_attention_exact]
slots = ["openrouter.fast"]
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["openrouter.fast"]
[providers.openrouter]
protocol = "openai-compatible-http"
endpoint = "%s"
connect-timeout-s = %.1f
exact-body-timeout-s = %.1f
[providers.openrouter.credentials]
type = "env"
key = "OPENROUTER_API_KEY"
[models.fast]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
max-context = 128000
[openrouter.fast]
%s
|}
    endpoint
    body_deadline_s
    body_deadline_s
    binding
;;

let log_id =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark ~chat_bytes : Turn_log.mark =
  { trace = session
  ; closed_messages = 0
  ; session
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes
  ; external_rows = 0
  }
;;

let append path at_end line =
  match Turn_store.append ~path ~at_end (line, []) with
  | Ok appended -> appended
  | Error (_ : Turn_store.append_error) -> fail "the fixture's turn log was not written"
;;

(* One closed turn whose own items are one chat row. *)
let write_turn ~turns_dir ~base_dir =
  let speaker : Keeper_chat_store.speaker =
    { speaker_id = Some "owner"; speaker_name = Some "Owner"; speaker_authority = Owner }
  in
  Keeper_chat_store.append_user_message ~base_dir ~keeper_name:keeper_id ~content:chat_text ~speaker ();
  let chat_bytes = (Unix.stat (Keeper_chat_store.chat_path ~base_dir ~keeper_name:keeper_id)).st_size in
  let path = Turn_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id in
  let started = append path 0 (Log_started { id = log_id; at = 50.0; mark = mark ~chat_bytes:0 }) in
  let opened =
    append path started.new_end
      (Opened
         { at = 51.0
         ; turn_ref = Ids.Turn_ref.make ~trace_id:session ~absolute_turn:1
         ; runtime = slot_id
         ; task = No_task
         ; stimuli = []
         ; baseline = mark ~chat_bytes:0
         })
  in
  ignore
    (append path opened.new_end
       (Closed
          { turn = opened.last_at
          ; at = 52.0
          ; outcome = Completed
          ; after = mark ~chat_bytes
          ; unattributed = []
          ; own = []
          })
     : Turn_store.appended)
;;

type fixture =
  { env : Ask.env
  ; place : Machine.place
  ; stores : Librarian_unit_content.stores
  ; lane : Librarian_memory_lane.t
  ; resolved : Registry.resolved_lane
  ; server : Fixture.test_server
  ; clock : float Eio.Time.clock_ty Eio.Resource.t (** The real clock. *)
  }

(* A Keeper with one unread turn, and a registry whose one Librarian slot is
   a fake provider that answers with [reply]. *)
let with_fixture ?(binding = "") reply f =
  Eio_main.run
  @@ fun stdenv ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs stdenv);
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-loopback") @@ fun () ->
  let root = Filename.temp_dir "librarian-ask-" "" in
  let previous_runtime = Runtime.For_testing.snapshot () in
  let previous_startup = Runtime_startup_state.get () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  Fun.protect
    ~finally:(fun () ->
      (match Registry.unpublish () with
       | Ok () -> ()
       | Error (_ : Registry.publication_error) -> fail "the fixture registry was not unpublished");
      Runtime.For_testing.restore previous_runtime;
      Runtime_startup_state.set previous_startup;
      Llm_provider.Catalog_snapshot.publish previous_catalog;
      Fs_compat.remove_tree root)
  @@ fun () ->
  Llm_provider.Catalog_snapshot.reset ();
  let server = Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with reply) in
  let config_path = Filename.concat root "runtime.toml" in
  Fs_compat.save_file config_path (runtime_toml ~endpoint:server.base_url ~binding);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> failf "runtime initialization: %s" detail);
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:root ();
  let registry =
    match Registry.current () with
    | Ok registry -> registry
    | Error (_ : Registry.publication_error) -> fail "no registry was published"
  in
  let lane, resolved =
    match Librarian_memory_lane.resolve ~prompt ~answer_schema:schema registry with
    | Ok declared -> declared
    | Error why -> failf "the Librarian lane: %s" (Librarian_memory_lane.show_unavailable why)
  in
  let directory name =
    let path = Filename.concat root name in
    Fs_compat.mkdir_p path;
    path
  in
  let base_dir = directory "base" in
  let session_dir = directory "session" in
  let place : Machine.place =
    { memory_dir = directory "memory"; turns_dir = directory "turns"; keeper_id }
  in
  write_turn ~turns_dir:place.turns_dir ~base_dir;
  f
    { env = { net; clock; base_dir }
    ; place
    ; stores = { session_dir = (fun ~session:_ -> session_dir); base_path = base_dir; keeper_name = keeper_id }
    ; lane
    ; resolved
    ; server
    ; clock
    }
;;

let input fixture tail : Ask.input =
  { place = fixture.place
  ; stores = fixture.stores
  ; tail
  ; lane = fixture.lane
  ; resolved = fixture.resolved
  ; asked = Read_range All
  ; bottom = Librarian_bottom.empty
  }
;;

(* A writer that holds no lane value, so its boot asks nothing. *)
let boot fixture =
  ref
    (Machine.booted fixture.place ~at:boot_at ~lane:None ~last_ask:0
       (Machine.boot fixture.place ~at:boot_at))
;;

(* The tail an open writer shows, as [Librarian_writer.status] does. *)
let tail_of (state : Machine.t ref) () : Librarian_log.line option =
  let value = !state in
  match value.state with
  | Idle { store; seen_length = (_ : int option) }
  | Asking { store; asking = (_ : Machine.asking) }
  | Resting store
  | Refused_at_bottom store -> Some (Store.tail store)
  | Stopped (_ : Store.stop) -> None
;;

let snapshot_path (place : Machine.place) =
  Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:place.memory_dir ~keeper_id
;;

(* --- The fake provider --- *)

(* Each message of an OpenAI chat request: its role and its text. *)
let messages body =
  let open Yojson.Safe.Util in
  Yojson.Safe.from_string body
  |> member "messages"
  |> to_list
  |> List.map (fun message ->
    let text =
      match member "content" message with
      | `String text -> text
      | `List parts -> String.concat "" (List.map (fun part -> member "text" part |> to_string) parts)
      | _ -> fail "a message carries no text"
    in
    member "role" message |> to_string, text)
;;

(* What follows [label] on the question's line that starts with it. *)
let labelled label text =
  let prefix = label ^ ": " in
  match List.find_opt (String.starts_with ~prefix) (String.split_on_char '\n' text) with
  | Some line -> String.sub line (String.length prefix) (String.length line - String.length prefix)
  | None -> failf "the question has no %s line" label
;;

(* A model that reads the question and writes back its two halves, changing
   nothing. *)
let echo (_ : int) body =
  let text = String.concat "\n" (List.map snd (messages body)) in
  match Librarian_question_id.of_halves ~front:(labelled "question" text) ~back:(labelled "question-end" text) with
  | Some question ->
    `OK, Fixture.openai_response (Librarian_answer.to_json { question; ops = []; working_state = Keep })
  | None -> fail "the question's halves are not an id"
;;

let refuse status (_ : int) (_ : string) =
  status, {|{"error":{"message":"refused by the fixture","type":"invalid_request_error"}}|}
;;

(* --- What an ask ended with --- *)

let outcome_text : Librarian_slot_outcome.unanswered -> string = function
  | Refused (Sized Input_too_large) -> "Refused (Sized Input_too_large)"
  | Refused (Sized Output_over_reserve) -> "Refused (Sized Output_over_reserve)"
  | Refused (Sized Window_reached) -> "Refused (Sized Window_reached)"
  | Refused Unsized -> "Refused Unsized"
  | Silent Not_called -> "Silent Not_called"
  | Silent Unavailable -> "Silent Unavailable"
  | Silent Busy -> "Silent Busy"
  | Silent Lost -> "Silent Lost"
  | Silent (Unusable rejection) -> "Silent (Unusable " ^ Librarian_answer.rejection_kind rejection ^ ")"
;;

let failed_text : Read_result.failed -> string = function
  | Raised -> "raised"
  | Flow_stopped -> "flow stopped"
  | Read_failed -> "read failed"
;;

let hex (digest : Digest.digest) = (digest :> string)

let fault_text : Librarian_snapshot_fault.t -> string = function
  | Absent -> "absent"
  | Not_a_snapshot_file -> "not a snapshot file"
  | Not_read -> "not read"
;;

let result_text : Read_result.t -> string = function
  | Answered { slot; answer; question = _ } ->
    Printf.sprintf "answered by %s with %d ops" slot (List.length answer.ops)
  | Nothing_to_ask -> "nothing to ask"
  | No_answer { slots; question = _ } ->
    "no answer: "
    ^ String.concat "; "
        (List.map
           (fun ((key : Librarian_memory_lane.slot_key), outcome) -> key.id ^ " " ^ outcome_text outcome)
           slots)
  | Nothing_readable _ -> "nothing readable"
  | Span_unknown _ -> "span unknown"
  | Memory_diverged { expected; observed } ->
    Printf.sprintf "memory diverged: the log names %s, the file is %s" (hex expected) (hex observed)
  | Snapshot_fault fault -> "snapshot fault: " ^ fault_text fault
  | Input_fault _ -> "input fault"
  | Ask_failed failed -> "ask failed: " ^ failed_text failed
;;

let question_of : Read_result.t -> Read_result.question = function
  | Answered { question; _ } -> question
  | ( Nothing_to_ask | No_answer _ | Nothing_readable _ | Span_unknown _ | Memory_diverged _
    | Snapshot_fault _ | Input_fault _ | Ask_failed _ ) as result ->
    failf "no question was answered: %s" (result_text result)
;;

let answered = Printf.sprintf "answered by %s with 0 ops" slot_id

(* --- The cases --- *)

let test_a_slot_answers () =
  with_fixture echo
  @@ fun fixture ->
  let state = boot fixture in
  let result = Ask.run fixture.env (input fixture (tail_of state)) in
  check string "the slot answers" answered (result_text result);
  check int "one unit was asked about" 1 (List.length (question_of result).shown.units);
  check int "one request" 1 (Fixture.post_count fixture.server);
  match Fixture.request_bodies fixture.server with
  | [ body ] ->
    let sent = messages body in
    check bool "no message is a system prompt" false
      (List.exists (fun (role, _) -> String.equal role "system") sent);
    (match sent with
     | (role, text) :: _ ->
       check string "the question is a user message" "user" role;
       check bool "the question's text starts with the lane's prompt" true
         (String.starts_with ~prefix:prompt text)
     | [] -> fail "the request carries no message")
  | bodies -> failf "%d requests reached the provider" (List.length bodies)
;;

let test_a_size_refusal_is_the_slots_outcome () =
  with_fixture (refuse `Request_entity_too_large)
  @@ fun fixture ->
  let state = boot fixture in
  check string "the slot refused for the input's size"
    ("no answer: " ^ slot_id ^ " Refused (Sized Input_too_large)")
    (result_text (Ask.run fixture.env (input fixture (tail_of state))))
;;

(* §7.4 「묻기는 bottom 을 받는다」: a slot with a size fact under the
   question's id is not called, and its fact is its outcome. *)
let test_a_slot_with_a_fact_is_not_called () =
  with_fixture (refuse `Request_entity_too_large)
  @@ fun fixture ->
  let state = boot fixture in
  let refused = "no answer: " ^ slot_id ^ " Refused (Sized Input_too_large)" in
  let first = Ask.run fixture.env (input fixture (tail_of state)) in
  check string "the first ask" refused (result_text first);
  check int "calls the slot" 1 (Fixture.post_count fixture.server);
  let bottom =
    match first with
    | No_answer { question; slots } ->
      Librarian_bottom.learn Librarian_bottom.empty With_memory question.id slots
    | Answered _ | Nothing_to_ask | Nothing_readable _ | Span_unknown _ | Memory_diverged _
    | Snapshot_fault _ | Input_fault _ | Ask_failed _ -> fail "the first ask had an answer"
  in
  let again = Ask.run fixture.env { (input fixture (tail_of state)) with bottom } in
  check string "the same question again" refused (result_text again);
  check int "calls nothing" 1 (Fixture.post_count fixture.server)
;;

(* §7.4 「항목만 읽기」: the question shows the head item and neither Memory
   nor the working state. *)
let test_the_item_alone_is_sent_without_memory () =
  with_fixture echo
  @@ fun fixture ->
  let state = boot fixture in
  let result =
    Ask.run fixture.env { (input fixture (tail_of state)) with asked = Read_item_alone }
  in
  check string "the slot answers" answered (result_text result);
  check bool "no fact is named" true (Option.is_none (question_of result).shown.memory);
  match Fixture.request_bodies fixture.server with
  | [ body ] ->
    let lines = String.split_on_char '\n' (String.concat "\n" (List.map snd (messages body))) in
    let labelled label = List.exists (String.starts_with ~prefix:label) lines in
    check bool "no memory line" false (labelled "memory:");
    check bool "no working state line" false (labelled "working_state:");
    check bool "the units line" true (labelled "units:")
  | bodies -> failf "%d requests reached the provider" (List.length bodies)
;;

let test_a_slot_says_nothing () =
  with_fixture (refuse `Internal_server_error)
  @@ fun fixture ->
  let state = boot fixture in
  check string "the slot said nothing about the question"
    ("no answer: " ^ slot_id ^ " Silent Busy")
    (result_text (Ask.run fixture.env (input fixture (tail_of state))))
;;

let test_other_bytes_end_the_ask_before_a_call () =
  with_fixture echo
  @@ fun fixture ->
  let state = boot fixture in
  let named =
    match tail_of state () with
    | Some (Started { snapshot; _ }) -> snapshot
    | Some (Committed _) | None -> fail "a first boot leaves a Started line"
  in
  let path = snapshot_path fixture.place in
  let other = In_channel.with_open_bin path In_channel.input_all ^ "\n" in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel other);
  check string "Memory diverged"
    (Printf.sprintf "memory diverged: the log names %s, the file is %s" (hex named)
       (hex (Digest.digest_of_bytes other)))
    (result_text (Ask.run fixture.env (input fixture (tail_of state))));
  check int "no request" 0 (Fixture.post_count fixture.server)
;;

(* A snapshot the store would not open ends the ask with the store's fault
   and before a call. The writer stops for it as boot does (§8.6); it does
   not rest and ask again on every pulse. *)
let test_a_snapshot_the_store_would_not_open () =
  with_fixture echo
  @@ fun fixture ->
  let state = boot fixture in
  let path = snapshot_path fixture.place in
  let ask () = result_text (Ask.run fixture.env (input fixture (tail_of state))) in
  Sys.remove path;
  check string "no file" "snapshot fault: absent" (ask ());
  Sys.mkdir path 0o700;
  check string "a directory" "snapshot fault: not a snapshot file" (ask ());
  Sys.rmdir path;
  check int "no request" 0 (Fixture.post_count fixture.server)
;;

(* The writer commits a direct write right after the ask's first read of the
   tail, so the ask reads the new snapshot's bytes under the old line. *)
let test_a_direct_write_during_the_read_is_read_again () =
  with_fixture echo
  @@ fun fixture ->
  let state = boot fixture in
  let reads = ref 0 in
  (* Kept and read after the ask: a failure raised inside it would be its
     [Ask_failed Raised]. *)
  let written : Machine.write_answer option ref = ref None in
  let tail () =
    let line = tail_of state () in
    incr reads;
    if Int.equal !reads 1
    then (
      let next, answer =
        Machine.write fixture.place !state ~at:write_at ~by:Librarian_effects.Keeper ~trace:session
          (Librarian_direct.Remember
             { claim
             ; category = Keeper_memory_os_types.Constraint
             ; basis = Keeper_memory_os_types.(Observed Transcript)
             })
      in
      state := next;
      written := Some answer);
    line
  in
  let result = Ask.run fixture.env (input fixture tail) in
  (match !written with
   | Some (Written (_ : Librarian_log.commit)) -> ()
   | Some
       ( Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _
       | Unavailable _ )
   | None -> fail "the direct write was not committed");
  check string "the slot answers" answered (result_text result);
  check int "two rounds of tail, bytes and tail" 4 !reads;
  check (option int) "the question shows the written fact" (Some 1)
    (Option.map List.length (question_of result).shown.memory)
;;

(* G4. Ten body deadlines pass on the ask's clock while another request
   holds the slot's one seat. The request sent once the seat frees still has
   its whole deadline, so it answers. *)
let test_a_seat_wait_does_not_shorten_the_body_deadline () =
  with_fixture ~binding:"max-concurrent = 1" echo
  @@ fun fixture ->
  let config =
    match Runtime_agent_core_runner.resolve_runtime_providers_for_turn ~runtime_id:slot_id () with
    | Ok [ config ] -> config
    | Ok (_ : Llm_provider.Provider_config.t list) | Error (_ : string) ->
      fail "the slot's binding did not resolve to one config"
  in
  check (option int) "the binding declares one seat" (Some 1) config.max_concurrent_requests;
  let ask_clock = Eio_mock.Clock.make () in
  let env : Ask.env =
    { fixture.env with clock = (ask_clock :> float Eio.Time.clock_ty Eio.Resource.t) }
  in
  let state = boot fixture in
  let occupied, set_occupied = Eio.Promise.create () in
  let freed, set_freed = Eio.Promise.create () in
  let result = ref None in
  let await_queued () =
    let deadline = Eio.Time.now fixture.clock +. Fixture.fixture_wait_seconds in
    let rec look () =
      match Llm_provider.Provider_admission.snapshot_for ~config with
      | Some snapshot when snapshot.queue_length >= 1 -> ()
      | Some (_ : Llm_provider.Slot_scheduler.snapshot) | None ->
        if Eio.Time.now fixture.clock > deadline then fail "the ask never waited for the seat";
        Eio.Time.sleep fixture.clock poll_s;
        look ()
    in
    look ()
  in
  Eio.Fiber.all
    [ (fun () ->
        Llm_provider.Provider_admission.with_admission ~config (fun () ->
          Eio.Promise.resolve set_occupied ();
          Eio.Promise.await freed))
    ; (fun () ->
        Eio.Promise.await occupied;
        result := Some (Ask.run env (input fixture (tail_of state))))
    ; (fun () ->
        Eio.Promise.await occupied;
        await_queued ();
        Eio_mock.Clock.set_time ask_clock (waited_deadlines *. body_deadline_s);
        Eio.Promise.resolve set_freed ())
    ];
  (match !result with
   | Some result -> check string "the slot answers after the wait" answered (result_text result)
   | None -> fail "the ask did not end");
  check int "one request, after the seat freed" 1 (Fixture.post_count fixture.server)
;;

let () =
  run "librarian_ask"
    [ ( "slots"
      , [ test_case "a slot answers" `Quick test_a_slot_answers
        ; test_case "a size refusal is the slot's outcome" `Quick test_a_size_refusal_is_the_slots_outcome
        ; test_case "a slot with a fact is not called" `Quick test_a_slot_with_a_fact_is_not_called
        ; test_case "the item alone is sent without Memory" `Quick
            test_the_item_alone_is_sent_without_memory
        ; test_case "a slot says nothing" `Quick test_a_slot_says_nothing
        ] )
    ; ( "memory"
      , [ test_case "other bytes end the ask before a call" `Quick test_other_bytes_end_the_ask_before_a_call
        ; test_case "a snapshot the store would not open" `Quick
            test_a_snapshot_the_store_would_not_open
        ; test_case "a direct write during the read is read again" `Quick
            test_a_direct_write_during_the_read_is_read_again
        ] )
    ; ( "deadline"
      , [ test_case "a seat wait does not shorten the body deadline" `Quick
            test_a_seat_wait_does_not_shorten_the_body_deadline
        ] )
    ]
;;
