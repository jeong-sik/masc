(* The Memory writers of a workspace (RFC librarian-call-only-proposes
   §8.6, §9.5): a workspace has a table from its start to the end of the
   switch it was started on, the Keepers that table writes for are the
   Keeper registry's, their files are the workspace's, and a turn that
   closes is told to its Keeper's writer. *)

open Alcotest
module Host = Masc.Keeper_memory_writers
module Writers = Masc.Librarian_writers
module Machine = Masc.Librarian_machine
module Direct = Masc.Librarian_direct
module Effects = Masc.Librarian_effects
module Types = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module Log_store = Masc.Librarian_log_store
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Registry = Masc.Keeper_registry
module Recorder = Masc.Keeper_turn_log_recorder
module Turn_writer = Masc.Keeper_turn_log_writer

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let mark : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 0
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

(* The turn log is where the Keeper's turns write it: in the workspace's
   Keeper runtime directory. *)
let start_turn_log (config : Masc.Workspace.config) keeper_id =
  match
    Turn_store.append
      ~path:
        (Turn_store.path_for_keepers_dir
           ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
           ~keeper_id)
      ~at_end:0
      (Turn_log.Log_started { id = turn_log; at = 50.0; mark }, [])
  with
  | Ok (_ : Turn_store.appended) -> ()
  | Error (_ : Turn_store.append_error) -> fail "the turn log of the fixture was not written"
;;

let register (config : Masc.Workspace.config) name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Error error -> fail ("meta fixture failed: " ^ error)
  | Ok meta ->
    let (_ : Masc.Keeper_registry_types.registry_entry) =
      Registry.register_offline ~base_path:config.base_path name meta
    in
    ()
;;

(* The store start's first step, as the server passes it. *)
let store_start = Masc.Keeper_turn_log_store_start.run

(* A Keeper's metadata on disk, as for a Keeper the server brought up: it
   names the session that holds the Keeper's stores. *)
let persist (config : Masc.Workspace.config) name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Error error -> fail ("meta fixture failed: " ^ error)
  | Ok meta ->
    (match Masc.Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error detail -> fail ("keeper meta persistence failed: " ^ detail))
;;

let turn_log_rows (config : Masc.Workspace.config) keeper_id =
  let path =
    Turn_store.path_for_keepers_dir ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
      ~keeper_id
  in
  In_channel.with_open_bin path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun row -> not (String.equal row ""))
  |> List.length
;;

(* A workspace in a temporary directory. The configuration directory is
   named for the length of the case: one a shell exported would otherwise be
   the Memory directory. The Keeper registry is the process's, so what a
   case registers is taken out when the case ends. *)
let with_workspace body =
  let root = Unix.realpath (Filename.temp_dir "memory-writers" "") in
  let config_root =
    Filename.concat (Common.masc_dir_from_base_path ~base_path:root) Config_dir_resolver.config_dirname
  in
  Masc_test_deps.with_process_env "MASC_CONFIG_DIR" (Some config_root) (fun () ->
    Fun.protect ~finally:Registry.For_testing.clear (fun () ->
      Eio_main.run (fun (_ : Eio_unix.Stdenv.base) ->
        body (Masc.Workspace.default_config root))))
;;

let table (config : Masc.Workspace.config) =
  match Host.find ~base_path:config.base_path with
  | Some table -> table
  | None -> fail "the workspace has no table"
;;

let remember claim =
  Direct.Remember { claim; category = Types.Fact; basis = Types.Observed Types.Transcript }
;;

let answer_text : Machine.write_answer -> string = function
  | Written _ -> "written"
  | Already_held -> "already held"
  | Already_done -> "already done"
  | Already_absent -> "already absent"
  | Refused (_ : Direct.refusal) -> "refused"
  | Not_a_snapshot (_ : Masc.Librarian_envelope.refusal) -> "not a snapshot"
  | Unavailable Keeper_retired -> "keeper retired"
  | Unavailable (Store_stopped (_ : Masc.Librarian_store.stop)) -> "store stopped"
;;

let write config keeper claim =
  answer_text
    (Writers.write (table config) keeper ~by:Effects.Keeper ~trace:"turn-1" (remember claim))
;;

let test_table_lives_with_its_switch () =
  with_workspace (fun config ->
    check bool "no table before the start" true
      (Option.is_none (Host.find ~base_path:config.base_path));
    Eio.Switch.run (fun sw ->
      let (_ : Writers.t) = Host.start ~sw ~ask:Masc_test_deps.never_asks ~start_turn_log:(store_start config) ~config in
      check bool "a table after the start" true
        (Option.is_some (Host.find ~base_path:config.base_path));
      check bool "another workspace has none" true
        (Option.is_none (Host.find ~base_path:(Filename.temp_dir "memory-writers-other" ""))));
    check bool "no table after its switch ended" true
      (Option.is_none (Host.find ~base_path:config.base_path)))
;;

(* The first table's switch ends before the second's. *)
let test_a_second_start_replaces_the_table () =
  with_workspace (fun config ->
    Eio.Switch.run (fun long ->
      let second =
        Eio.Switch.run (fun short ->
          let (_ : Writers.t) = Host.start ~sw:short ~ask:Masc_test_deps.never_asks ~start_turn_log:(store_start config) ~config in
          let first = table config in
          let (_ : Writers.t) = Host.start ~sw:long ~ask:Masc_test_deps.never_asks ~start_turn_log:(store_start config) ~config in
          let second = table config in
          check bool "the later table is the workspace's" false (second == first);
          second)
      in
      check bool "the end of the first table's switch leaves the later table" true
        (table config == second)))
;;

let test_writers_are_the_registry_s () =
  with_workspace (fun config ->
    Eio.Switch.run (fun sw ->
      let (_ : Writers.t) = Host.start ~sw ~ask:Masc_test_deps.never_asks ~start_turn_log:(store_start config) ~config in
      start_turn_log config "keeper-a";
      check string "a Keeper that is not registered has no writer" "keeper retired"
        (write config "keeper-a" "the port is 8935");
      register config "keeper-a";
      check string "a registered Keeper is written to" "written"
        (write config "keeper-a" "the port is 8935")))
;;

let test_files_are_the_workspace_s () =
  with_workspace (fun config ->
    Eio.Switch.run (fun sw ->
      let (_ : Writers.t) = Host.start ~sw ~ask:Masc_test_deps.never_asks ~start_turn_log:(store_start config) ~config in
      register config "keeper-a";
      start_turn_log config "keeper-a";
      check string "written" "written" (write config "keeper-a" "the port is 8935");
      let keepers_dir =
        Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path
      in
      (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper-a" with
       | Ok (Some snapshot) ->
         check (list string) "the snapshot the Keeper's requests read holds the claim"
           [ "the port is 8935" ]
           (List.map (fun (fact : Types.fact) -> fact.claim) snapshot.facts)
       | Ok None -> fail "no snapshot in the Keeper config directory"
       | Error detail -> fail detail);
      check bool "the commit log is beside it" true
        (Sys.file_exists (Log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper-a"))))
;;

(* §8.6: a Keeper whose first pulse or write comes before its first turn.
   Its writer's boot writes the turn log's first line, and the store opens.
   A Keeper whose metadata is not on disk has no stores to name the first
   line from, and its store stops. *)
let test_a_keeper_without_a_turn_log () =
  with_workspace (fun config ->
    ignore (Masc.Workspace.init config ~agent_name:None);
    Eio.Switch.run (fun sw ->
      let (_ : Writers.t) = Host.start ~sw ~ask:Masc_test_deps.never_asks ~start_turn_log:(store_start config) ~config in
      register config "keeper-a";
      persist config "keeper-a";
      check string "the first boot starts the turn log, and the store opens" "written"
        (write config "keeper-a" "the port is 8935");
      check int "the turn log has its one first line" 1 (turn_log_rows config "keeper-a");
      register config "keeper-b";
      check string "a Keeper with no metadata on disk" "store stopped"
        (write config "keeper-b" "the port is 8935")))
;;

(* §9.5: the step that appends a turn's [Closed] line tells the Keeper's
   writer, and the table makes the writer on that hint. The [Opened] line
   tells nothing. *)
let test_a_closed_turn_is_told_to_the_writer () =
  with_workspace (fun config ->
    Eio.Switch.run (fun sw ->
      let (_ : Writers.t) = Host.start ~sw ~ask:Masc_test_deps.never_asks ~start_turn_log:(store_start config) ~config in
      register config "keeper-a";
      let place : Recorder.place =
        { keepers_dir = Masc.Workspace.keepers_runtime_dir config
        ; base_path = config.base_path
        ; keeper_name = "keeper-a"
        ; session_dir = Filename.temp_dir "memory-writers-session" ""
        ; session_id = "trace-1"
        }
      in
      let record event =
        let answer = Recorder.record ~at:100.0 ~new_log_id:turn_log place event in
        (match answer with
         | Ok (Appended _) -> ()
         | Ok Nothing_to_append -> fail "nothing was appended"
         | Error error -> fail (Recorder.not_recorded_to_string error));
        answer
      in
      let writers () = List.map fst (Writers.statuses (table config)) in
      let admitted =
        record
          (Turn_writer.Admit
             { turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:1
             ; runtime = "test-runtime"
             ; task = Turn_log.No_task
             ; stimuli = []
             })
      in
      check (list string) "an opened turn makes no writer" [] (writers ());
      let (_ : (Recorder.recorded, Recorder.not_recorded) result) =
        record
          (Turn_writer.Finish { admitted = Recorder.admitted admitted; ending = Turn_writer.Completed })
      in
      check (list string) "its closed line made the Keeper's writer" [ "keeper-a" ] (writers ())))
;;

let () =
  run "keeper_memory_writers"
    [ ( "table"
      , [ test_case "lives with its switch" `Quick test_table_lives_with_its_switch
        ; test_case "a second start replaces it" `Quick test_a_second_start_replaces_the_table
        ] )
    ; ( "writers"
      , [ test_case "are the registry's" `Quick test_writers_are_the_registry_s
        ; test_case "write the workspace's files" `Quick test_files_are_the_workspace_s
        ; test_case "a Keeper without a turn log" `Quick test_a_keeper_without_a_turn_log
        ; test_case "a closed turn is told to the writer" `Quick
            test_a_closed_turn_is_told_to_the_writer
        ] )
    ]
;;
