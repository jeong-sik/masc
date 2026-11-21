(* One round of a Keeper's Memory writer on the wiring a server gives it
   (RFC librarian-call-only-proposes §20 L11, widened to the ask and the
   commit). The other writer suites look at one piece each. This case goes
   from the runtime table on disk to the row the operator reads, in order:

   - [runtime.toml] in the base path's config directory declares
     [runtime.exact_output_lanes.librarian_memory], and the exact-output
     registry is published from that file;
   - the writers table starts with the arguments
     [Server_runtime_bootstrap.claim_and_start_keeper_persistence] passes,
     and the lane value reaches it through
     [Keeper_memory_writers.follow_declaration], with the shipped prompt and
     [Librarian_answer.schemas];
   - a registered Keeper gets its writer from the maintenance tick's pulse;
   - a turn closes through [Keeper_turn_log_turn.around], which tells the
     writer;
   - the writer asks the lane's slot over HTTP and commits the answer;
   - the Keeper's memory-health row, read by the TUI's decoder, shows the
     commit under [writer].

   Three things are not the server's own. The provider is a loopback HTTP
   server. The Keeper is put in the registry by hand, and its turn's body
   only appends one chat row. The bootstrap's start of the writers and the
   maintenance tick's pulse are local to their functions, so their calls are
   repeated here with the same arguments. *)

open Alcotest
open Masc
module Writers = Librarian_writers
module Writer = Librarian_writer
module Machine = Librarian_machine
module Log_line = Librarian_log
module Log_store = Librarian_log_store
module Lane = Librarian_memory_lane
module Registry = Runtime_exact_output_registry
module Fixture = Exact_output_fixture
module Types = Keeper_memory_os_types
module Current = Keeper_memory_os_current
module Shown = Tui_decode_memory_writer
module Row = Tui_decode_memory_health
module Health = Server_dashboard_http_keeper_memory_health

let keeper = "cycle-keeper"

(* [provider.model] of the runtime table below. The provider is a row of the
   provider catalog, as in the other ask suites, and its endpoint is the
   loopback server. *)
let slot = "openrouter.reader"
let credential_env = "OPENROUTER_API_KEY"
let reserve = 1024
let chat_text = "the owner says the garden gate opens at nine"
let claim = "the garden gate opens at nine"

(* The name a question gives the first unit it shows. *)
let first_unit = "u1"

(* How long the case waits for the writer, and how often it looks. *)
let wait_s = 30.0
let poll_s = 0.001

(* HITL and board attention are declared because bootstrap refuses a
   runtime table without both. *)
let runtime_toml ~endpoint =
  Printf.sprintf
    {|[runtime]
default = "%s"
[runtime.exact_output_lanes.librarian_memory]
slots = ["%s"]
max_output_tokens = %d
[runtime.exact_output_lanes.board_attention_exact]
slots = ["%s"]
[runtime.exact_output_lanes.hitl_auto_judge]
slots = ["%s"]
[providers.openrouter]
protocol = "openai-compatible-http"
endpoint = "%s"
connect-timeout-s = 60.0
exact-body-timeout-s = 60.0
[providers.openrouter.credentials]
type = "env"
key = "%s"
[models.reader]
api-name = "z-ai/glm-5.3-flash"
tools-support = true
max-context = 128000
[openrouter.reader]
|}
    slot
    slot
    reserve
    slot
    slot
    endpoint
    credential_env
;;

(* {1 The fake provider} *)

(* The text of every message of an OpenAI chat request. *)
let text_of body =
  let open Yojson.Safe.Util in
  Yojson.Safe.from_string body
  |> member "messages"
  |> to_list
  |> List.map (fun message ->
    match member "content" message with
    | `String text -> text
    | `List parts -> String.concat "" (List.map (fun part -> member "text" part |> to_string) parts)
    | _ -> "")
  |> String.concat "\n"
;;

(* What follows [label] on the first line of the question that starts with
   it. *)
let labelled label text =
  let prefix = label ^ ": " in
  String.split_on_char '\n' text
  |> List.find_opt (String.starts_with ~prefix)
  |> Option.map (fun line ->
    String.sub line (String.length prefix) (String.length line - String.length prefix))
;;

(* A model that reads one fact from the first unit of every question and
   names the question it read. A request it cannot read is a server error,
   which the writer's row then shows as a failed ask. *)
let answering (_ : int) body =
  let text = text_of body in
  let fact : Librarian_answer.new_fact =
    { claim; category = Types.Fact; basis = Types.Observed Types.Transcript; from_units = [ first_unit ] }
  in
  let ops : Librarian_answer.op list = [ Librarian_answer.Add fact ] in
  match labelled "question" text, labelled "question-end" text with
  | Some front, Some back ->
    (match Librarian_question_id.of_halves ~front ~back with
     | Some question ->
       ( `OK
       , Fixture.openai_response
           (Librarian_answer.to_json { question; ops; working_state = Keep }) )
     | None -> `Internal_server_error, "the question's halves are not an id")
  | None, (Some _ | None) | Some _, None ->
    `Internal_server_error, "the request shows no question id"
;;

(* How many units a request's question shows. *)
let units_shown body =
  match labelled "units" (text_of body) with
  | Some units -> Yojson.Safe.from_string units |> Yojson.Safe.Util.to_list |> List.length
  | None -> fail "the question has no units line"
;;

(* {1 The Keeper} *)

let speaker : Keeper_chat_store.speaker =
  { speaker_id = Some "owner"; speaker_name = Some "Owner"; speaker_authority = Owner }
;;

let turn_log_rows (config : Workspace.config) =
  let path =
    Keeper_turn_log_store.path_for_keepers_dir
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper
  in
  In_channel.with_open_bin path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun row -> not (String.equal row ""))
  |> List.length
;;

(* {1 The writer} *)

(* The [writer] member of the Keeper's memory-health row, as the server
   writes it. *)
let writer_json config =
  Yojson.Safe.to_string (Keeper_memory_writer_health.keeper_rows ~config keeper)
;;

(* The same member, read by the decoder the TUI reads the row with. *)
let shown config =
  match Shown.decode (Keeper_memory_writer_health.keeper_rows ~config keeper) with
  | Ok shown -> shown
  | Error reason -> failf "the TUI does not read the writer's row: %s" reason
;;

(* Looks until [look] answers. Past [wait_s] the case fails with what
   [describe] says then. *)
let until ~clock ~describe label look =
  let deadline = Eio.Time.now clock +. wait_s in
  let rec again () =
    match look () with
    | Some value -> value
    | None ->
      if Eio.Time.now clock > deadline
      then failf "%s: not reached in %.0f s; %s" label wait_s (describe ());
      Eio.Time.sleep clock poll_s;
      again ()
  in
  again ()
;;

(* The last line of the Keeper's commit log, once the store is open. *)
let tail writers : Log_line.line option =
  match List.assoc_opt keeper (Writers.statuses writers) with
  | Some (Writer.Open line) -> Some line
  | Some (Writer.Booting | Writer.Stopped (_ : Librarian_store.stop) | Writer.Retired) | None ->
    None
;;

(* The writer has taken every event sent to it before this: its mailbox is
   one queue, and a resume is answered after the boot. A writer that is idle
   or asking has nothing to resume. *)
let settled ~describe writers =
  match Writers.resume writers keeper with
  | Machine.Not_done Machine.Nothing_to_resume -> ()
  | Machine.Done | Machine.Not_done _ ->
    failf "the writer is not idle or asking; %s" (describe ())
;;

let cause_text : Log_line.cause -> string = function
  | Log_line.Direct _ -> "direct"
  | Log_line.Adopt _ -> "adopt"
  | Log_line.Read _ -> "read"
  | Log_line.Make_room _ -> "make_room"
  | Log_line.Skip _ -> "skip"
  | Log_line.Molt_and_synthesize _ -> "molt_and_synthesize"
  | Log_line.Checkpoint _ -> "checkpoint"
;;

(* The cause of every commit in the Keeper's commit log, in order. *)
let causes ~keepers_dir =
  match
    Log_store.fold
      (Log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper)
      ~init:[]
      ~f:(fun causes (scanned : Log_store.scanned) ->
        match scanned.line with
        | Ok (Log_line.Committed commit) -> cause_text commit.cause :: causes
        | Ok (Log_line.Started _) -> causes
        | Error (_ : Log_store.undecodable) -> fail "a commit line does not decode")
  with
  | Ok causes -> List.rev causes
  | Error _ -> fail "the commit log was not read"
;;

(* {1 The case} *)

let test_a_closed_turn_is_asked_committed_and_shown () =
  Eio_main.run
  @@ fun stdenv ->
  Fs_compat.set_fs (Eio.Stdenv.fs stdenv);
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let root = Unix.realpath (Filename.temp_dir "librarian-cycle-" "") in
  let config_root =
    Filename.concat (Common.masc_dir_from_base_path ~base_path:root) Config_dir_resolver.config_dirname
  in
  (* The environment of a server on this base path. A model catalog or a
     config directory the shell exported would be read in its place. *)
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some root)
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key (Some config_root)
  @@ fun () ->
  Masc_test_deps.with_process_env "AGENT_CORE_MODEL_CATALOG" None
  @@ fun () ->
  Masc_test_deps.with_process_env credential_env (Some "synthetic-loopback")
  @@ fun () ->
  (* The switch ends inside: the writers and the provider are gone before
     the directory is. *)
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root)
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let config = Workspace.default_config root in
  ignore (Workspace.init config ~agent_name:None : string);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path in
  let server : Fixture.test_server =
    Fixture.start_server ~sw ~net ~clock (Fixture.Reply_with answering)
  in
  let describe () =
    Printf.sprintf "the writer's row is %s and the provider took %d requests" (writer_json config)
      (List.length (Fixture.request_bodies server))
  in
  (* The runtime table, read from the file the way a server's start reads
     it. *)
  Fs_compat.mkdir_p config_root;
  let runtime_path = Filename.concat config_root Config_dir_resolver.runtime_toml_filename in
  Fs_compat.save_file runtime_path (runtime_toml ~endpoint:server.base_url);
  Llm_provider.Catalog_snapshot.reset ();
  (match Runtime.init_default ~config_path:runtime_path with
   | Ok () -> ()
   | Error detail -> failf "the runtime table was not read: %s" detail);
  Server_runtime_bootstrap.For_testing.configure_exact_output_registry ~config_root ();
  (* The writers, started as the bootstrap starts them. *)
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  let prompt =
    match Prompt_registry.render_prompt_template Prompt_names.librarian_ask [] with
    | Ok prompt -> prompt
    | Error reason ->
      failf "the prompt %s was not rendered: %s" Prompt_names.librarian_ask reason
  in
  let ask_env : Librarian_ask.env = { net; clock; base_dir = config.base_path } in
  let started =
    Keeper_memory_writers.start
      ~sw
      ~ask:(Librarian_ask.run ask_env)
      ~ask_room:(Librarian_ask.run_room ask_env)
      ~start_turn_log:(Keeper_turn_log_store_start.run config)
      ~config
  in
  Keeper_memory_writers.follow_declaration
    ~sw
    ~prompt
    ~answer_schemas:Librarian_answer.schemas
    started;
  let writers =
    match Keeper_memory_writers.find ~base_path:config.base_path with
    | Some writers -> writers
    | None -> fail "the workspace has no Memory writers"
  in
  (* The lane value, read from the published registry as the watcher reads
     it. *)
  let lane =
    match Registry.current () with
    | Error error -> failf "no exact-output registry: %s" (Registry.publication_error_to_string error)
    | Ok registry ->
      (match Lane.resolve ~prompt ~answer_schemas:Librarian_answer.schemas registry with
       | Ok (lane, (_ : Registry.resolved_lane)) -> lane
       | Error why -> failf "the Librarian lane has no value: %s" (Lane.show_unavailable why))
  in
  check (list string) "the lane walks the slot the table declares" [ slot ]
    (List.map (fun (key : Lane.slot_key) -> key.id) lane.http);
  check (list string) "and the registry admitted it" [] lane.unadmitted;
  check int "the question reserves the declared output" reserve lane.question.max_output_tokens;
  (* A Keeper in the registry, with its metadata on disk as for a Keeper the
     server brought up. *)
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String keeper; "trace_id", `String ("trace-" ^ keeper) ])
    with
    | Ok meta -> meta
    | Error detail -> failf "the Keeper's metadata fixture: %s" detail
  in
  let (_ : Keeper_registry.registry_entry) =
    Keeper_registry.register_offline ~base_path:config.base_path keeper meta
  in
  Eio.Switch.on_release sw (fun () ->
    Keeper_registry.For_testing.unregister ~base_path:config.base_path keeper);
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "the Keeper's metadata was not saved: %s" detail);
  (* The maintenance tick's pulse. *)
  let registered = Keeper_memory_writers.registered ~base_path:config.base_path in
  check (list string) "the pulse is for the registered Keeper" [ keeper ] registered;
  Writers.pulse writers registered;
  settled ~describe writers;
  check int "the writer's boot started the turn log" 1 (turn_log_rows config);
  let revision_at_start =
    match tail writers with
    | Some (Log_line.Started { revision; _ }) -> revision
    | Some (Log_line.Committed (_ : Log_line.commit)) | None ->
      failf "the writer's store is not open at its start; %s" (describe ())
  in
  (match shown config with
   | Shown.Writer
       { Shown.level = Librarian_level.Ok
       ; alarms = []
       ; row =
           Shown.Open
             { activity = Shown.Idle
             ; unread = false
             ; kept = { Shown.lane = true; last_read = None; _ }
             ; last_line = Shown.Line_started
             ; facts = 0
             ; _
             }
       } -> ()
   | Shown.Writer (_ : Shown.shown) | Shown.None_in_process | Shown.No_writer ->
     failf "after the pulse the writer is not open, idle and holding the lane value; %s"
       (describe ()));
  check int "no slot was asked before a turn closed" 0
    (List.length (Fixture.request_bodies server));
  (* One turn of the Keeper. Its body appends one chat row, so the row is the
     turn's own item. *)
  let place : Keeper_turn_log_recorder.place = Keeper_turn_log_process_start.place_of config meta in
  Keeper_turn_log_turn.around
    ~place
    ~turn_ref:(Ids.Turn_ref.make ~trace_id:place.session_id ~absolute_turn:1)
    ~runtime:slot
    ~task:Keeper_turn_log.No_task
    ~stimuli:[]
    ~succeeded:(fun () -> true)
    (fun (_ : Keeper_turn_log_turn.t) ->
       Keeper_chat_store.append_user_message
         ~base_dir:config.base_path
         ~keeper_name:keeper
         ~content:chat_text
         ~speaker
         ());
  check int "the turn log holds the turn, opened and closed" 3 (turn_log_rows config);
  (* The ask and the commit. *)
  let commit : Log_line.commit =
    until ~clock ~describe "the answer's commit" (fun () ->
      match tail writers with
      | Some (Log_line.Committed commit) -> Some commit
      | Some (Log_line.Started _) | None -> None)
  in
  settled ~describe writers;
  (match Fixture.request_bodies server with
   | [ body ] ->
     let text = text_of body in
     check bool "the question carries the shipped prompt" true
       (String_util.contains_substring text (String.trim prompt));
     check int "and shows the closed turn as one unit" 1 (units_shown body);
     check bool "with the turn's chat row" true (String_util.contains_substring text chat_text)
   | bodies -> failf "the slot was asked %d times" (List.length bodies));
  (match commit.cause with
   | Log_line.Read { slot = answered; _ } ->
     check string "the declared slot answered" slot answered
   | Log_line.Direct _ | Log_line.Adopt _ | Log_line.Make_room _ | Log_line.Skip _
   | Log_line.Molt_and_synthesize _ | Log_line.Checkpoint _ ->
     fail "the commit is not of a read");
  check (list string) "the answer added its fact" [ claim ]
    (List.map (fun (fact : Types.fact) -> fact.claim) commit.effects.added);
  check bool "Memory's revision moved" true (commit.revision > revision_at_start);
  check (list string) "the commit log holds the one read" [ "read" ] (causes ~keepers_dir);
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper with
   | Ok (Some snapshot) ->
     check (list string) "the snapshot the Keeper's requests read holds the fact" [ claim ]
       (List.map (fun (fact : Types.fact) -> fact.claim) snapshot.facts);
     check int "at the commit's revision" commit.revision snapshot.revision
   | Ok None -> fail "the Keeper has no Memory snapshot"
   | Error detail -> failf "the Memory snapshot was not read: %s" detail);
  (* The row the operator reads. *)
  let row =
    match
      Row.decode_memory_health_row ~keeper
        (Health.keeper_memory_health_row_http_json ~base_path:config.base_path ~keeper)
    with
    | Ok { Row.mhr_keeper = Row.Row_present row; _ } -> row
    | Ok { Row.mhr_keeper = Row.Row_refused refusal; _ } ->
      failf "the TUI refuses the Keeper's row: %s" refusal.Row.mkr_reason
    | Ok { Row.mhr_keeper = Row.Row_absent; _ } -> fail "the health answer has no row for the Keeper"
    | Error detail -> failf "the TUI does not read the health answer: %s" detail
  in
  check int "the row counts the fact" 1 row.Row.mkh_facts;
  check int "at the commit's revision" commit.revision row.Row.mkh_revision;
  match row.Row.mkh_writer with
  | Shown.Writer
      { Shown.level = Librarian_level.Ok
      ; alarms = []
      ; row =
          Shown.Open
            { activity = Shown.Idle
            ; unread = false
            ; kept = { Shown.lane = true; last_read = Some Shown.Read_committed; _ }
            ; last_line = Shown.Line_commit { seq }
            ; facts = 1
            ; _
            }
      }
    when Int.equal seq commit.seq -> ()
  | Shown.Writer (_ : Shown.shown) | Shown.None_in_process | Shown.No_writer ->
    failf "the row's writer does not show the committed read; %s" (describe ())
;;

let () =
  run "librarian_cycle_one_round"
    [ ( "cycle"
      , [ test_case "a closed turn is asked, committed and shown" `Quick
            test_a_closed_turn_is_asked_committed_and_shown
        ] )
    ]
;;
