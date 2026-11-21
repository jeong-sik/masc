(* A writer that asks (RFC librarian-call-only-proposes §9.2 to §9.5, §13,
   §16, §20 L6). Closed turns in a Keeper's turn log become questions to a
   fake provider on loopback, through the writers table the server runs and
   the real ask, and what the provider answers is committed. A table gets
   its declaration as the server's watcher sends it, and the watcher itself
   follows a runtime publication. *)

open Alcotest
open Masc
module Ask = Librarian_ask
module Writer = Librarian_writer
module Writers = Librarian_writers
module Machine = Librarian_machine
module Store = Librarian_store
module Log_line = Librarian_log
module Log_store = Librarian_log_store
module Lane = Librarian_memory_lane
module Effects = Librarian_effects
module Direct = Librarian_direct
module Registry = Runtime_exact_output_registry
module Fixture = Exact_output_fixture
module Turn_log = Keeper_turn_log
module Turn_store = Keeper_turn_log_store
module Types = Keeper_memory_os_types

let keeper_id = "keeper-a"
let session = "session-1"
let fast = "openrouter.fast"
let wide = "openrouter.wide"
let prompt = "You keep one Keeper's Memory."
let other_prompt = "Keep this Keeper's Memory, with a date on every event."
let schema = `Assoc [ "type", `String "object" ]
let schemas = { Lane.range = schema; item_alone = schema; room = schema }
let max_output_tokens = 1024
let chat_text = "the release train leaves on Friday"

(* How long a case waits for the writer, and how often it looks. *)
let wait_s = 30.0
let poll_s = 0.001

(* F7: the fake call lasts ten minutes on the provider's clock. *)
let call_s = 600.0

(* F10 *)
let ticks = 1_000
let few_lines = 10
let many_lines = 100_000

(* HITL and board attention are declared because bootstrap refuses a
   runtime table without both. [lane] is the Librarian lane's slots, and
   [None] declares no Librarian lane. *)
let runtime_toml ~endpoint lane =
  let librarian =
    match lane with
    | None -> ""
    | Some slots ->
      Printf.sprintf
        "[runtime.exact_output_lanes.librarian_memory]\nslots = [%s]\nmax_output_tokens = %d\n"
        (String.concat ", " (List.map (Printf.sprintf "%S") slots))
        max_output_tokens
  in
  Printf.sprintf
    {|[runtime]
default = "openrouter.fast"
%s[runtime.exact_output_lanes.board_attention_exact]
slots = ["openrouter.fast"]
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["openrouter.fast"]
[providers.openrouter]
protocol = "openai-compatible-http"
endpoint = "%s"
connect-timeout-s = 60.0
exact-body-timeout-s = 60.0
[providers.openrouter.credentials]
type = "env"
key = "OPENROUTER_API_KEY"
[models.fast]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
max-context = 128000
[models.wide]
api-name = "deepseek/deepseek-v4-flash"
tools-support = true
max-context = 400000
[openrouter.fast]
[openrouter.wide]
|}
    librarian
    endpoint
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

type fixture =
  { env : Ask.env
  ; place : Machine.place
  ; stores : Librarian_unit_content.stores
  ; base_dir : string
  ; root : string
  ; server : Fixture.test_server
  ; clock : float Eio.Time.clock_ty Eio.Resource.t (** The real clock. *)
  ; sw : Eio.Switch.t
  }

(* {1 The runtime table and the lane value} *)

let publish fixture lane =
  let path = Filename.concat fixture.root "runtime.toml" in
  Fs_compat.save_file path (runtime_toml ~endpoint:fixture.server.base_url lane);
  (match Runtime.init_default ~config_path:path with
   | Ok () -> ()
   | Error detail -> failf "runtime initialization: %s" detail);
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root:fixture.root ()
;;

(* The lane value under the registry published now, as the server's watcher
   reads it. *)
let declared ?(prompt = prompt) () : Machine.declared =
  match Registry.current () with
  | Error error -> failf "no registry: %s" (Registry.publication_error_to_string error)
  | Ok registry ->
    (match Lane.resolve ~prompt ~answer_schemas:schemas registry with
     | Ok (value, resolved) -> { value; resolved }
     | Error why -> failf "the Librarian lane: %s" (Lane.show_unavailable why))
;;

(* {1 The turn log} *)

let size path =
  match (Unix.stat path).st_size with
  | size -> size
  | exception Unix.Unix_error (Unix.ENOENT, (_ : string), (_ : string)) -> 0
;;

let turn_log_path fixture =
  Turn_store.path_for_keepers_dir ~keepers_dir:fixture.place.turns_dir ~keeper_id
;;

let append fixture lines : Turn_store.appended =
  let path = turn_log_path fixture in
  match lines with
  | [] -> fail "no line to append"
  | first :: rest ->
    (match Turn_store.append ~path ~at_end:(size path) (first, rest) with
     | Ok appended -> appended
     | Error (_ : Turn_store.append_error) -> fail "the fixture's turn log was not written")
;;

let chat_path fixture = Keeper_chat_store.chat_path ~base_dir:fixture.base_dir ~keeper_name:keeper_id

let speaker : Keeper_chat_store.speaker =
  { speaker_id = Some "owner"; speaker_name = Some "Owner"; speaker_authority = Owner }
;;

(* Turn [n], closed, whose own item is one chat row saying [text]. The
   answer is the byte offset of its [Closed] line. *)
let close_turn fixture n text =
  let before = size (chat_path fixture) in
  Keeper_chat_store.append_user_message ~base_dir:fixture.base_dir ~keeper_name:keeper_id
    ~content:text ~speaker ();
  let after = size (chat_path fixture) in
  let at = 50.0 +. Float.of_int n in
  let opened =
    append fixture
      [ Opened
          { at
          ; turn_ref = Ids.Turn_ref.make ~trace_id:session ~absolute_turn:n
          ; runtime = fast
          ; task = No_task
          ; stimuli = []
          ; baseline = mark ~chat_bytes:before
          }
      ]
  in
  let closed =
    append fixture
      [ Closed
          { turn = opened.last_at
          ; at
          ; outcome = Completed
          ; after = mark ~chat_bytes:after
          ; unattributed = []
          ; own = []
          }
      ]
  in
  closed.last_at
;;

(* [count] lines a store has already read: resets that moved nothing, all
   passed by one Skip commit, which the store makes as a writer would. *)
let pass_lines fixture count =
  let still = mark ~chat_bytes:0 in
  let reset : Turn_log.line =
    Reset { at = 50.5; cause = Announced Cleared; before = still; after = still; closed_before = [] }
  in
  let passed = append fixture (List.init count (fun (_ : int) -> reset)) in
  match
    Store.boot ~memory_dir:fixture.place.memory_dir ~turns_dir:fixture.place.turns_dir ~keeper_id
      ~at:60.0
  with
  | Error (_ : Store.stop) -> fail "the fixture's store did not open"
  | Ok store ->
    (match
       Store.commit_skip store ~at:61.0 ~hole:(Content_missing [])
         { line = passed.last_at; within = Whole; covered = still; turn_log_offset = passed.new_end }
     with
     | Ok { store = (_ : Store.t); line = (_ : Log_line.commit) } -> ()
     | Error (_ : Store.stop) -> fail "the fixture's lines were not passed")
;;

(* {1 The fake provider} *)

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

let text_of body = String.concat "\n" (List.map snd (messages body))

(* What follows [label] on the question's line that starts with it. *)
let labelled label text =
  let prefix = label ^ ": " in
  match List.find_opt (String.starts_with ~prefix) (String.split_on_char '\n' text) with
  | Some line -> String.sub line (String.length prefix) (String.length line - String.length prefix)
  | None -> failf "the question has no %s line" label
;;

(* A model that answers every question with [ops], naming the question it
   read. *)
let answering ops (_ : int) body =
  let text = text_of body in
  match
    Librarian_question_id.of_halves ~front:(labelled "question" text)
      ~back:(labelled "question-end" text)
  with
  | Some question ->
    `OK, Fixture.openai_response (Librarian_answer.to_json { question; ops; working_state = Keep })
  | None -> fail "the question's halves are not an id"
;;

let echo = answering []

(* How many units a request's question showed. *)
let units_shown body =
  labelled "units" (text_of body) |> Yojson.Safe.from_string |> Yojson.Safe.Util.to_list |> List.length
;;

(* A Keeper with the turn log started and nothing in it, and a runtime table
   whose Librarian lane is one slot of a fake provider that answers with
   [reply]. [on_request] runs before the provider answers each request. *)
let with_fixture ?on_request ~reply f =
  Eio_main.run
  @@ fun stdenv ->
  Fs_compat.set_fs (Eio.Stdenv.fs stdenv);
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None @@ fun () ->
  Masc_test_deps.with_process_env "OPENROUTER_API_KEY" (Some "synthetic-loopback") @@ fun () ->
  let root = Filename.temp_dir "librarian-writer-asks-" "" in
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
  let server =
    Fixture.start_server ?on_request_before_reply:on_request ~sw ~net ~clock (Fixture.Reply_with reply)
  in
  let directory name =
    let path = Filename.concat root name in
    Fs_compat.mkdir_p path;
    path
  in
  let base_dir = directory "base" in
  let session_dir = directory "session" in
  let fixture =
    { env = { net; clock; base_dir }
    ; place = { memory_dir = directory "memory"; turns_dir = directory "turns"; keeper_id }
    ; stores =
        { session_dir = (fun ~session:(_ : string) -> session_dir); base_path = base_dir; keeper_name = keeper_id }
    ; base_dir
    ; root
    ; server
    ; clock
    ; sw
    }
  in
  publish fixture (Some [ fast ]);
  ignore (append fixture [ Log_started { id = log_id; at = 50.0; mark = mark ~chat_bytes:0 } ] : Turn_store.appended);
  f fixture
;;

(* {1 The table} *)

(* The server's ask, with the number of times the table called it. *)
let counted fixture =
  let calls = Atomic.make 0 in
  ( (fun input ->
      Atomic.incr calls;
      Ask.run fixture.env input)
  , calls )
;;

(* The table the server runs, for the fixture's one Keeper. *)
let table ?sw fixture ask =
  Writers.create
    ~sw:(Option.value sw ~default:fixture.sw)
    ~now:Unix.gettimeofday
    ~registered:(String.equal keeper_id)
    ~place:(fun (_ : string) -> fixture.place)
    ~stores:(fun (_ : string) -> fixture.stores)
    ~ask
    ~ask_room:(Ask.run_room fixture.env)
    ~start_turn_log:(fun (_ : string) -> Ok ())
;;

let tail writers =
  match List.assoc_opt keeper_id (Writers.statuses writers) with
  | Some (Writer.Open line) -> Some line
  | Some (Booting | Stopped (_ : Store.stop) | Retired) | None -> None
;;

let until fixture label check =
  let deadline = Eio.Time.now fixture.clock +. wait_s in
  let rec look () =
    match check () with
    | Some value -> value
    | None ->
      if Eio.Time.now fixture.clock > deadline then failf "%s: not reached in %.0f s" label wait_s;
      Eio.Time.sleep fixture.clock poll_s;
      look ()
  in
  look ()
;;

(* Waits until the writer's tail is commit [seq] or a later one. *)
let await_commit fixture writers seq =
  until fixture (Printf.sprintf "commit %d" seq) (fun () ->
    match tail writers with
    | Some (Committed commit) when commit.seq >= seq -> Some ()
    | Some (Committed (_ : Log_line.commit) | Started _) | None -> None)
;;

(* The writer has taken every event sent to it before this: its mailbox is
   one queue, and a writer that is idle or asking has nothing to resume. *)
let settled writers =
  match Writers.resume writers keeper_id with
  | Not_done Nothing_to_resume -> ()
  | Done
  | Not_done
      ( Not_stopped | Snapshot_mismatch | Snapshot_unreadable | Not_replaced | Turn_log_unread
      | Not_the_head _ | Content_unread | Act_unavailable _ ) ->
    fail "the writer was not idle or asking"
;;

let remember claim =
  Direct.Remember { claim; category = Types.Fact; basis = Types.Observed Types.Transcript }
;;

let write writers claim =
  match Writers.write writers keeper_id ~by:Effects.Keeper ~trace:session (remember claim) with
  | Written (_ : Log_line.commit) -> ()
  | Already_held | Already_done | Already_absent
  | Refused (_ : Direct.refusal)
  | Not_a_snapshot (_ : Librarian_envelope.refusal)
  | Unavailable (_ : Machine.unavailable) -> failf "the write of %S was not committed" claim
;;

(* {1 What the writer left} *)

let commits fixture =
  match
    Log_store.fold
      (Log_store.path_for_keepers_dir ~keepers_dir:fixture.place.memory_dir ~keeper_id)
      ~init:[]
      ~f:(fun commits (scanned : Log_store.scanned) ->
        match scanned.line with
        | Ok (Committed commit) -> commit :: commits
        | Ok (Started _) -> commits
        | Error (_ : Log_store.undecodable) -> fail "a commit line does not decode")
  with
  | Ok commits -> List.rev commits
  | Error (_ : Private_jsonl_scan.error) -> fail "the commit log was not read"
;;

let cause_text : Log_line.cause -> string = function
  | Direct _ -> "direct"
  | Adopt _ -> "adopt"
  | Read _ -> "read"
  | Make_room _ -> "make_room"
  | Skip _ -> "skip"
;;

let causes fixture = List.map (fun (commit : Log_line.commit) -> cause_text commit.cause) (commits fixture)

let position_text : Log_line.position -> string = function
  | Before_first -> "before the first unit"
  | Through { line; within = Whole } -> Printf.sprintf "through the unit at %d" line
  | Through { line; within = Item { at; store = (_ : Librarian_unit.store) } } ->
    Printf.sprintf "through the item at %d of the unit at %d" at line
;;

let snapshot_bytes fixture =
  In_channel.with_open_bin
    (Keeper_memory_os_current_layout.path_for_keepers_dir ~keepers_dir:fixture.place.memory_dir
       ~keeper_id)
    In_channel.input_all
;;

let late_answers () =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string LibrarianLateAnswers)
    ~labels:[ "keeper", keeper_id ]
    ()
;;

let requests fixture = Fixture.request_bodies fixture.server

(* {1 The cases} *)

(* §20 L6: three turns that closed before the writer asks are one question,
   and its answer is one commit. *)
let test_three_closed_turns_are_one_question_and_one_commit () =
  with_fixture ~reply:echo
  @@ fun fixture ->
  let third =
    List.fold_left
      (fun (_ : int) n -> close_turn fixture n (Printf.sprintf "turn %d moved the port" n))
      0 [ 1; 2; 3 ]
  in
  let ask, calls = counted fixture in
  let writers = table fixture ask in
  Writers.declaration_changed writers (Some (declared ()));
  Writers.pulse writers [ keeper_id ];
  await_commit fixture writers 1;
  for _tick = 1 to 3 do
    Writers.pulse writers [ keeper_id ]
  done;
  settled writers;
  check int "one ask" 1 (Atomic.get calls);
  check (list int) "one call, and its question shows the three turns" [ 3 ]
    (List.map units_shown (requests fixture));
  check (list string) "one commit: the answer" [ "read" ] (causes fixture);
  check (list string) "it reads through the third turn"
    [ position_text (Through { line = third; within = Whole }) ]
    (List.map (fun (commit : Log_line.commit) -> position_text commit.covers_through) (commits fixture))
;;

(* F2: an answer whose four ops hold and whose fifth names a fact the
   question did not give commits the four and leaves the fifth on the line
   as [Unknown_ref]. *)
let test_one_unknown_name_leaves_one_op_out () =
  let observed claim : Librarian_answer.new_fact =
    { claim; category = Types.Fact; observation = Types.Transcript; from_units = [ "u1" ] }
  in
  let ops : Librarian_answer.op list =
    [ Add (observed "the release train leaves on Friday")
    ; Add (observed "the build runs every night")
    ; Revise { ref_ = "m1"; into = observed "the port is 8936" }
    ; Drop { ref_ = "m2"; reason = "the turn says the mirror is gone" }
    ; Drop { ref_ = "m9"; reason = "a name the question did not give" }
    ]
  in
  with_fixture ~reply:(answering ops)
  @@ fun fixture ->
  let ask, (_ : int Atomic.t) = counted fixture in
  let writers = table fixture ask in
  Writers.declaration_changed writers (Some (declared ()));
  write writers "the port is 8935";
  write writers "a mirror serves the docs";
  ignore (close_turn fixture 1 "the train leaves on Friday, the build runs nightly, the mirror is gone" : int);
  Writers.turn_closed writers keeper_id;
  await_commit fixture writers 3;
  settled writers;
  match List.rev (commits fixture) with
  | [] -> fail "nothing was committed"
  | read :: (_ : Log_line.commit list) ->
    check string "the last commit is the answer" "read" (cause_text read.cause);
    check (list string) "two adds and the revision's claim are new"
      [ "the build runs every night"; "the port is 8936"; "the release train leaves on Friday" ]
      (List.sort String.compare (List.map (fun (fact : Types.fact) -> fact.claim) read.effects.added));
    check (list string) "the revision and the drop removed one fact each"
      [ "a mirror serves the docs"; "the port is 8935" ]
      (List.sort String.compare
         (List.map (fun ((fact : Types.fact), (_ : Effects.removal)) -> fact.claim) read.effects.removed));
    check (list string) "the fifth op is left out as a name the question did not give"
      [ "op 4: " ^ Effects.why_not_kind Unknown_ref ]
      (List.map
         (fun (index, why, (_ : Librarian_answer.new_fact option)) ->
            Printf.sprintf "op %d: %s" index (Effects.why_not_kind why))
         read.effects.not_applied)
;;

(* F7: a direct write is answered while the call is out, and the call lasts
   ten minutes on the provider's clock. The answer that comes after the
   write is committed after it. *)
let test_a_write_does_not_wait_for_a_ten_minute_call () =
  let provider_clock = Eio_mock.Clock.make () in
  let held = Atomic.make 0 in
  let hold () = if Atomic.fetch_and_add held 1 = 0 then Eio.Time.sleep provider_clock call_s in
  with_fixture ~on_request:hold ~reply:echo
  @@ fun fixture ->
  ignore (close_turn fixture 1 chat_text : int);
  let ask, (_ : int Atomic.t) = counted fixture in
  let writers = table fixture ask in
  Writers.declaration_changed writers (Some (declared ()));
  Writers.pulse writers [ keeper_id ];
  Fixture.await_first_request fixture.server;
  (match Eio.Time.with_timeout fixture.clock wait_s (fun () -> Ok (write writers "the port is 8935")) with
   | Ok () -> ()
   | Error `Timeout -> fail "the write waited for the call");
  check (float 0.0) "the call has not ended" 0.0 (Eio.Time.now provider_clock);
  check (list string) "the write is committed" [ "direct" ] (causes fixture);
  Eio_mock.Clock.set_time provider_clock call_s;
  await_commit fixture writers 2;
  check (list string) "and the answer after it" [ "direct"; "read" ] (causes fixture)
;;

(* F9: a writer that ends while its call is out commits nothing. The writer
   that starts after it reads the same tail and asks once more. *)
let test_a_restart_during_the_call_asks_once_more () =
  let release, released = Eio.Promise.create () in
  let held = Atomic.make 0 in
  let hold () = if Atomic.fetch_and_add held 1 = 0 then Eio.Promise.await release in
  with_fixture ~on_request:hold ~reply:echo
  @@ fun fixture ->
  ignore (close_turn fixture 1 chat_text : int);
  let lane = declared () in
  let first_ask, first_calls = counted fixture in
  Eio.Fiber.first
    (fun () ->
       Eio.Switch.run (fun sw ->
         let first = table ~sw fixture first_ask in
         Writers.declaration_changed first (Some lane);
         Writers.pulse first [ keeper_id ];
         Eio.Fiber.await_cancel ()))
    (fun () -> Fixture.await_first_request fixture.server);
  check int "the first writer asked" 1 (Atomic.get first_calls);
  check (list string) "and committed nothing" [] (causes fixture);
  let second_ask, second_calls = counted fixture in
  let second = table fixture second_ask in
  Writers.declaration_changed second (Some lane);
  Writers.pulse second [ keeper_id ];
  await_commit fixture second 1;
  for _tick = 1 to 3 do
    Writers.pulse second [ keeper_id ]
  done;
  settled second;
  Eio.Promise.resolve released ();
  check int "the next writer asks once" 1 (Atomic.get second_calls);
  check int "two calls in all" 2 (Fixture.post_count fixture.server);
  check (list string) "one commit: the second answer" [ "read" ] (causes fixture)
;;

(* §12.4: an operator's skip of the head is read from the disk while a call
   is out. A target that is not the head is refused, the refusal names the
   head now, and the call goes on. That name passes the head: the call is
   cancelled, and the next question carries the turn after it. With nothing
   unread there is no head to skip. *)
let test_a_skip_during_the_call_passes_the_head () =
  let release, released = Eio.Promise.create () in
  let held = Atomic.make 0 in
  let hold () = if Atomic.fetch_and_add held 1 = 0 then Eio.Promise.await release in
  with_fixture ~on_request:hold ~reply:echo
  @@ fun fixture ->
  let first = close_turn fixture 1 chat_text in
  let ask, (_ : int Atomic.t) = counted fixture in
  let writers = table fixture ask in
  Writers.declaration_changed writers (Some (declared ()));
  Writers.pulse writers [ keeper_id ];
  Fixture.await_first_request fixture.server;
  ignore (close_turn fixture 2 "the port moved to 8936" : int);
  let skip target = Writers.skip_item writers keeper_id ~by:"operator-1" ~target in
  let head =
    match skip (Unreadable_unit { turn_log = log_id; line = first }) with
    | Not_done (Not_the_head { now = Some (Head_item { line; _ } as head) }) when Int.equal line first ->
      head
    | (_ : Machine.act_answer) -> fail "the refusal does not name the first turn's item"
  in
  check int "the refusal leaves the call out" 1 (Fixture.post_count fixture.server);
  check (list string) "and commits nothing" [] (causes fixture);
  (match skip head with
   | Done -> ()
   | (_ : Machine.act_answer) -> fail "the head's name was refused");
  await_commit fixture writers 2;
  settled writers;
  check (list string) "the skip, then the next turn's answer" [ "skip"; "read" ] (causes fixture);
  (match commits fixture with
   | skipped :: (_ : Log_line.commit list) ->
     (match skipped.cause with
      | Skip { hole = Operator_skipped { by; missing } } ->
        check string "the line names the operator" "operator-1" by;
        check int "and no missing part" 0 (List.length missing)
      | Direct _ | Read _ | Make_room _ | Adopt _ | Skip _ -> fail "the first commit is not the operator's skip");
     check string "it passes the first turn"
       (position_text (Through { line = first; within = Whole }))
       (position_text skipped.covers_through)
   | [] -> fail "nothing was committed");
  (match requests fixture with
   | [ (_ : string); next ] -> check int "the next question shows the second turn alone" 1 (units_shown next)
   | (_ : string list) -> fail "the skip did not end in one more call");
  (match skip head with
   | Not_done (Not_the_head { now = None }) -> ()
   | (_ : Machine.act_answer) -> fail "a skip with nothing unread was not refused as no head");
  Eio.Promise.resolve released ()
;;

(* §12.4: an accepted skip empties how the last ask ended. A lane whose one
   slot answers the head item with a 400 leaves the writer resting at the
   bottom, with that refusal as its last read (§12.2). The operator's skip
   passes the item, and the value no longer holds a refusal of it. *)
let test_a_skip_at_the_bottom_forgets_the_last_read () =
  let refusal = `Bad_request, {|{"error":{"message":"fixture refusal","type":"invalid_request_error"}}|} in
  with_fixture ~reply:(fun (_ : int) (_ : string) -> refusal)
  @@ fun fixture ->
  let first = close_turn fixture 1 chat_text in
  let ask, (_ : int Atomic.t) = counted fixture in
  let writers = table fixture ask in
  Writers.declaration_changed writers (Some (declared ()));
  Writers.pulse writers [ keeper_id ];
  let machine () =
    match List.assoc_opt keeper_id (Writers.held writers) with
    | Some (Writer.Held value) -> Some value
    | Some (Writer.Held_booting | Writer.Held_retired) | None -> None
  in
  let resting =
    until fixture "resting at the bottom" (fun () ->
      match machine () with
      | Some ({ Machine.state = Resting (_ : Librarian_store.t); _ } as value) -> Some value
      | Some (_ : Machine.t) | None -> None)
  in
  check bool "the refusal is how the last ask ended" true (Option.is_some resting.last_read);
  let skip target = Writers.skip_item writers keeper_id ~by:"operator-1" ~target in
  let head =
    match skip (Unreadable_unit { turn_log = log_id; line = first }) with
    | Not_done (Not_the_head { now = Some (Head_item { line; _ } as head) }) when Int.equal line first ->
      head
    | (_ : Machine.act_answer) -> fail "the refusal does not name the first turn's item"
  in
  (match skip head with
   | Done -> ()
   | (_ : Machine.act_answer) -> fail "the head's name was refused");
  await_commit fixture writers 1;
  check (list string) "the skip is the one commit" [ "skip" ] (causes fixture);
  match machine () with
  | Some value -> check bool "and the last read is forgotten" true (Option.is_none value.last_read)
  | None -> fail "the writer holds no value"
;;

(* §7.1: an ask reads the tail only while the writer waits for its next
   event. A commit appends its line and then replaces the snapshot file,
   and the writer names the new line after both, so a tail read in between
   would pair the old line with the new bytes and end as [Memory_diverged].
   Here the writer is held inside an event while the ask reads. *)
let test_an_ask_reads_the_tail_between_events () =
  with_fixture ~reply:echo
  @@ fun fixture ->
  ignore (close_turn fixture 1 chat_text : int);
  let lane = declared () in
  let inside, now_inside = Eio.Promise.create () in
  let let_go, go = Eio.Promise.create () in
  let takes = Atomic.make 0 in
  (* The writer takes the declaration as its first event, and is held when
     it takes it again. *)
  let declaration () =
    if Atomic.fetch_and_add takes 1 > 0
    then (
      Eio.Promise.resolve now_inside ();
      Eio.Promise.await let_go);
    Some lane
  in
  let asked, now_asked = Eio.Promise.create () in
  let may_read, read_now = Eio.Promise.create () in
  let reading, now_reading = Eio.Promise.create () in
  let read, now_read = Eio.Promise.create () in
  let ask (input : Ask.input) : Librarian_read_result.t =
    Eio.Promise.resolve now_asked ();
    Eio.Promise.await may_read;
    Eio.Promise.resolve now_reading ();
    Eio.Promise.resolve now_read (input.tail ());
    (* A result that leaves the writer resting, so it asks no more. *)
    Ask_failed Flow_stopped
  in
  let writer =
    Writer.create ~now:Unix.gettimeofday ~registered:(fun () -> true) ~declared:declaration
      ~stores:fixture.stores ~ask ~ask_room:Masc_test_deps.never_makes_room
      ~start_turn_log:(fun () -> Ok ()) fixture.place
  in
  Eio.Fiber.fork_daemon ~sw:fixture.sw (fun () ->
    Writer.run writer;
    `Stop_daemon);
  Eio.Promise.await asked;
  Writer.declaration_changed writer;
  Eio.Promise.await inside;
  Eio.Promise.resolve read_now ();
  Eio.Promise.await reading;
  check bool "the tail is not read while the writer takes an event" true
    (Option.is_none (Eio.Promise.peek read));
  Eio.Promise.resolve go ();
  check bool "it is read once the event ended" true
    (match Eio.Promise.await read with
     | Some (Started _) -> true
     | Some (Committed _) | None -> false)
;;

(* §16, as one line: what a store that has passed [prior] lines does for
   one new turn, and then for [ticks] pulses with nothing new. *)
let costs prior =
  with_fixture ~reply:echo
  @@ fun fixture ->
  pass_lines fixture prior;
  let ask, calls = counted fixture in
  let writers = table fixture ask in
  Writers.declaration_changed writers (Some (declared ()));
  ignore (close_turn fixture 1 chat_text : int);
  Writers.turn_closed writers keeper_id;
  (* The skip that passed the prior lines is commit 1. *)
  await_commit fixture writers 2;
  settled writers;
  let asked =
    Printf.sprintf "%d asks, calls showing %s units, %d lines" (Atomic.get calls)
      (String.concat " and " (List.map (fun body -> Int.to_string (units_shown body)) (requests fixture)))
      (List.length (commits fixture))
  in
  let snapshot = snapshot_bytes fixture in
  for _tick = 1 to ticks do
    Writers.pulse writers [ keeper_id ]
  done;
  settled writers;
  Printf.sprintf "%s; after the ticks %d asks, %d calls, %d lines, %s snapshot" asked (Atomic.get calls)
    (Fixture.post_count fixture.server) (List.length (commits fixture))
    (if String.equal snapshot (snapshot_bytes fixture) then "the same" else "another")
;;

(* F10: one new turn costs the same after 10 lines as after 100,000, and a
   thousand ticks with nothing new cost no ask, no call and no line. The
   reads themselves are not counted here. *)
let test_a_tick_costs_nothing_and_a_turn_costs_the_same_after_many_lines () =
  let expected =
    "1 asks, calls showing 1 units, 2 lines; after the ticks 1 asks, 1 calls, 2 lines, the same snapshot"
  in
  check string (Printf.sprintf "after %d lines" few_lines) expected (costs few_lines);
  check string (Printf.sprintf "after %d lines" many_lines) expected (costs many_lines)
;;

(* A table whose first ask sends it [renewed] once the call has answered:
   the declaration changes while that ask is out, and its answer reaches the
   writer after the change. *)
let asking_with_a_change fixture renewed =
  let writers = ref None in
  let calls = Atomic.make 0 in
  let ask input =
    let result = Ask.run fixture.env input in
    if Atomic.fetch_and_add calls 1 = 0
    then Option.iter (fun writers -> Writers.declaration_changed writers (Some renewed)) !writers;
    result
  in
  let table = table fixture ask in
  writers := Some table;
  table, calls
;;

(* F11: the prompt changes while the call is out. The ask is cancelled with
   the old question, its answer comes back late and is counted, and the next
   question carries the new prompt. *)
let test_a_new_prompt_during_the_call_drops_its_answer () =
  with_fixture ~reply:echo
  @@ fun fixture ->
  ignore (close_turn fixture 1 chat_text : int);
  let writers, calls = asking_with_a_change fixture (declared ~prompt:other_prompt ()) in
  let late = late_answers () in
  Writers.declaration_changed writers (Some (declared ()));
  Writers.pulse writers [ keeper_id ];
  await_commit fixture writers 1;
  settled writers;
  check (float 0.0) "the answer to the old prompt is counted late" (late +. 1.0) (late_answers ());
  check int "asked twice" 2 (Atomic.get calls);
  check int "two calls" 2 (List.length (requests fixture));
  check (list (pair string bool)) "the first question carries the old prompt, the next the new one"
    [ "first", true; "next", true ]
    (List.map2
       (fun (label, prefix) body -> label, String.starts_with ~prefix (text_of body))
       [ "first", prompt; "next", other_prompt ]
       (requests fixture));
  check (list string) "one commit: the answer to the new prompt" [ "read" ] (causes fixture)
;;

(* F11: only the slots change while the call is out. The ask goes on and
   its answer is committed. Both lane values come from published
   registries. *)
let test_a_slot_change_during_the_call_keeps_its_answer () =
  with_fixture ~reply:echo
  @@ fun fixture ->
  ignore (close_turn fixture 1 chat_text : int);
  publish fixture (Some [ fast; wide ]);
  let widened = declared () in
  publish fixture (Some [ fast ]);
  let lane = declared () in
  check bool "the question side is the same" true
    (Lane.equal_question_side widened.value.question lane.value.question);
  check bool "the slots are not" false (Lane.equal widened.value lane.value);
  let writers, calls = asking_with_a_change fixture widened in
  let late = late_answers () in
  Writers.declaration_changed writers (Some lane);
  Writers.pulse writers [ keeper_id ];
  await_commit fixture writers 1;
  settled writers;
  check (float 0.0) "no answer is late" late (late_answers ());
  check int "asked once" 1 (Atomic.get calls);
  check int "one call" 1 (Fixture.post_count fixture.server);
  check (list string) "one commit: that answer" [ "read" ] (causes fixture)
;;

(* §9.5: the server's watcher sends the table the lane value when a runtime
   table is published. With no Librarian lane the writer asks nothing; once
   a table with the lane is published, it asks about the turn that waited. *)
let test_the_watcher_declares_a_published_lane () =
  with_fixture ~reply:echo
  @@ fun fixture ->
  publish fixture None;
  ignore (close_turn fixture 1 chat_text : int);
  let ask, calls = counted fixture in
  let writers = table fixture ask in
  Keeper_memory_writers.follow_declaration ~sw:fixture.sw ~prompt ~answer_schemas:schemas writers;
  Writers.pulse writers [ keeper_id ];
  settled writers;
  check int "no lane, no ask" 0 (Atomic.get calls);
  publish fixture (Some [ fast ]);
  await_commit fixture writers 1;
  settled writers;
  check int "the published lane asks once" 1 (Atomic.get calls);
  check (list string) "and its answer is committed" [ "read" ] (causes fixture)
;;

let () =
  run "librarian_writer_asks"
    [ ( "asking"
      , [ test_case "three closed turns are one question and one commit" `Quick
            test_three_closed_turns_are_one_question_and_one_commit
        ; test_case "one unknown name leaves one op out" `Quick test_one_unknown_name_leaves_one_op_out
        ; test_case "a write does not wait for a ten-minute call" `Quick
            test_a_write_does_not_wait_for_a_ten_minute_call
        ; test_case "a restart during the call asks once more" `Quick
            test_a_restart_during_the_call_asks_once_more
        ; test_case "a skip during the call passes the head" `Quick
            test_a_skip_during_the_call_passes_the_head
        ; test_case "a skip at the bottom forgets the last read" `Quick
            test_a_skip_at_the_bottom_forgets_the_last_read
        ; test_case "an ask reads the tail between events" `Quick
            test_an_ask_reads_the_tail_between_events
        ] )
    ; ( "ticks"
      , [ test_case "a tick costs nothing, a turn the same after many lines" `Quick
            test_a_tick_costs_nothing_and_a_turn_costs_the_same_after_many_lines
        ] )
    ; ( "declaration"
      , [ test_case "a new prompt during the call drops its answer" `Quick
            test_a_new_prompt_during_the_call_drops_its_answer
        ; test_case "a slot change during the call keeps its answer" `Quick
            test_a_slot_change_during_the_call_keeps_its_answer
        ; test_case "the watcher declares a published lane" `Quick
            test_the_watcher_declares_a_published_lane
        ] )
    ]
;;
