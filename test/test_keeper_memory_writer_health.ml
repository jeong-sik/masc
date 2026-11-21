(* The row each Keeper's Memory writer shows the operator, and the Librarian
   section of the full health answer (RFC librarian-call-only-proposes
   §12.1, §12.3): read from the writer this process runs, with closed
   tokens and numbers. *)

open Alcotest
module Health = Masc.Keeper_memory_writer_health
module Writers = Masc.Librarian_writers
module Writer = Masc.Librarian_writer
module Deps = Masc_test_deps

let keeper = "health-keeper"

let in_workspace case () =
  Eio_main.run (fun (_ : Eio_unix.Stdenv.base) ->
    Eio.Switch.run (fun sw ->
      let config = Masc.Workspace.default_config (Filename.temp_dir "writer-health" "") in
      case ~sw config))
;;

(* The same, with what the Librarian's own ask needs. *)
let in_workspace_with_ask case () =
  Eio_main.run (fun stdenv ->
    Eio.Switch.run (fun sw ->
      let config = Masc.Workspace.default_config (Filename.temp_dir "writer-health" "") in
      let env : Masc.Librarian_ask.env =
        { net = Eio.Stdenv.net stdenv
        ; clock = Eio.Stdenv.clock stdenv
        ; base_dir = config.base_path
        }
      in
      case ~sw ~env config))
;;

let member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> failf "no %s in the row" key)
  | json -> failf "not an object: %s" (Yojson.Safe.to_string json)
;;

let text key json =
  match member key json with
  | `String value -> value
  | other -> failf "%s is not a string: %s" key (Yojson.Safe.to_string other)
;;

let alarms row =
  match member "alarms" row with
  | `List alarms ->
    List.map
      (function
        | `String alarm -> alarm
        | other -> failf "an alarm is not a string: %s" (Yojson.Safe.to_string other))
      alarms
  | other -> failf "alarms is not a list: %s" (Yojson.Safe.to_string other)
;;

let writers config =
  match Masc.Keeper_memory_writers.find ~base_path:config.Masc.Workspace.base_path with
  | Some writers -> writers
  | None -> fail "the workspace has no Memory writers"
;;

(* A write waits for the writer's boot, and a store that did not open
   refuses it. *)
let refused_by_a_stopped_store config =
  match
    Writers.write (writers config) keeper ~by:Masc.Librarian_effects.Keeper ~trace:"turn"
      (Masc.Librarian_direct.Remember
         { claim = "the port is 8935"
         ; category = Masc.Keeper_memory_os_types.Constraint
         ; basis = Masc.Keeper_memory_os_types.Observed Masc.Keeper_memory_os_types.Transcript
         })
  with
  | Unavailable (Store_stopped (_ : Masc.Librarian_store.stop)) -> ()
  | Unavailable Keeper_retired -> fail "the Keeper has no writer"
  | Written _ | Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ ->
    fail "the store opened"
;;

(* The Keeper's row as the section carries it. *)
let row_of config =
  match member "keepers" (Health.section_json ~config) with
  | `List entries ->
    (match
       List.find_opt (fun entry -> String.equal (text "keeper" entry) keeper) entries
     with
     | Some entry -> member "row" entry
     | None -> fail "the section has no row for the Keeper")
  | other -> failf "keepers is not a list: %s" (Yojson.Safe.to_string other)
;;

let test_a_process_without_writers () =
  let config = Masc.Workspace.default_config (Filename.temp_dir "writer-health" "") in
  check string "the section says so" "none_in_process"
    (text "writers" (Health.section_json ~config));
  check bool "and it lists no Keeper" true
    (match Health.section_json ~config with
     | `Assoc fields -> not (List.mem_assoc "keepers" fields)
     | other -> failf "the section is not an object: %s" (Yojson.Safe.to_string other))
;;

(* A registered Keeper's writer is made by its first turn or the first
   pulse. Before that the section shows the Keeper as booting, and reading
   the section makes no writer. *)
let test_a_keeper_before_its_writer () =
  in_workspace (fun ~sw config ->
    Deps.ensure_memory_writer ~sw ~config keeper;
    let row = row_of config in
    check string "its state" "booting" (text "state" row);
    check (list string) "W1" [ "W1" ] (alarms row);
    check string "a warning" "warn" (text "level" row);
    check bool "the section counts it" true (member "warn" (Health.section_json ~config) = `Int 1);
    check int "and the table still holds no writer" 0 (List.length (Writers.held (writers config))))
    ()
;;

let turns_path config =
  Masc.Keeper_turn_log_store.path_for_keepers_dir
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper
;;

let turn_log_id config =
  match Masc.Keeper_turn_log_store.read_start (turns_path config) with
  | Ok (Some start) -> Masc.Keeper_turn_log.Log_id.to_string start.id
  | Ok None -> fail "the turn log has no first line"
  | Error (_ : Masc.Keeper_turn_log_store.read_error) -> fail "the turn log was not read"
;;

(* A writer with no lane value and nothing unread is open and has no alarm. *)
let test_an_open_writer () =
  in_workspace (fun ~sw config ->
    let (_ : Writer.view) = Deps.booted_memory_writer_view ~sw ~config keeper in
    let row = row_of config in
    check string "its state" "idle" (text "state" row);
    check string "its level" "ok" (text "level" row);
    check (list string) "no alarm" [] (alarms row);
    check bool "no lane value" true (member "lane" row = `Bool false);
    check bool "nothing unread" true (member "unread" row = `Bool false);
    check string "reading stands at the log's start" "started" (text "last_line" row);
    check string "of the turn log the Keeper has" (turn_log_id config) (text "turn_log" row);
    check bool "no ask has ended" true (member "last_read" row = `Null);
    check bool "Memory holds no fact" true (member "facts" (member "memory" row) = `Int 0);
    let section = Health.section_json ~config in
    check string "the section runs" "running" (text "writers" section);
    check bool "with none at error" true (member "error" section = `Int 0);
    check bool "and none at warn" true (member "warn" section = `Int 0);
    match member "keepers" section with
    | `List [ entry ] -> check string "one row, by Keeper" keeper (text "keeper" entry)
    | other -> failf "expected one row: %s" (Yojson.Safe.to_string other))
    ()
;;

(* A commit log whose last line does not decode stops the store at boot. The
   row says why in the words the Memory tools use, and names the snapshot
   file as it is on disk: here there is none. *)
let test_a_stopped_writer () =
  in_workspace (fun ~sw config ->
    Deps.ensure_memory_writer ~sw ~config keeper;
    let log_path =
      Masc.Librarian_log_store.path_for_keepers_dir
        ~keepers_dir:
          (Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path)
        ~keeper_id:keeper
    in
    Fs_compat.mkdir_p (Filename.dirname log_path);
    Out_channel.with_open_bin log_path (fun channel -> output_string channel "not json\n");
    refused_by_a_stopped_store config;
    let row = row_of config in
    check string "its state" "stopped" (text "state" row);
    check (list string) "E1" [ "E1" ] (alarms row);
    check string "an error" "error" (text "level" row);
    check string "why" "store_stopped_log_unreadable" (text "stop" row);
    check string "the snapshot file" "absent" (text "fault" (member "snapshot_file" row));
    check bool "the section counts it" true (member "error" (Health.section_json ~config) = `Int 1))
    ()
;;

(* A lane value that names one CLI slot: the ask below stops at the turn
   log before any slot is asked. *)
let declared : Masc.Librarian_machine.declared =
  { value =
      { question =
          { prompt = "memory prompt"
          ; answer_schemas =
              { Masc.Librarian_memory_lane.range = `Assoc [ "type", `String "object" ]
              ; item_alone = `Assoc [ "type", `String "object" ]
              ; room = `Assoc [ "type", `String "object" ]
              }
          ; max_output_tokens = 4096
          ; thinking = None
          }
      ; http = []
      ; cli =
          [ { id = "claude_code.fast"
            ; target = Cli { runtime_id = "claude_code.fast"; api_name = "claude-sonnet-5" }
            ; window = 200_000
            }
          ]
      ; unadmitted = []
      }
  ; resolved = { Runtime_exact_output_registry.selected_slots = []; cli_slots = [] }
  }
;;

(* How long the case waits for the writer's ask to end, and how often it
   looks: the bounds the writer's ask cases use. *)
let wait_s = 30.0
let poll_s = 0.001

let rested ~clock writers =
  let deadline = Eio.Time.now clock +. wait_s in
  let rec look () =
    match List.assoc_opt keeper (Writers.held writers) with
    | Some (Writer.Held { Masc.Librarian_machine.state = Resting (_ : Masc.Librarian_store.t); _ }) -> ()
    | Some (Writer.Held (_ : Masc.Librarian_machine.t) | Writer.Held_booting | Writer.Held_retired)
    | None ->
      if Eio.Time.now clock > deadline then failf "the writer did not rest in %.0f s" wait_s;
      Eio.Time.sleep clock poll_s;
      look ()
  in
  look ()
;;

(* §12.4: a line that does not decode, with nothing to read before it, ends
   the Librarian's own ask as an input fault. The row names the fault in the
   commit log's words, with the line's offset the operator's [Skip_line]
   sends. *)
let test_a_writer_resting_on_an_input_fault () =
  in_workspace_with_ask (fun ~sw ~env config ->
    let (_ : Writers.t) =
      Masc.Keeper_memory_writers.start ~sw ~ask:(Masc.Librarian_ask.run env)
        ~ask_room:Deps.never_makes_room
        ~start_turn_log:(Masc.Keeper_turn_log_store_start.run config) ~config
    in
    let (_ : Writer.view) = Deps.booted_memory_writer_view ~sw ~config keeper in
    let offset = Int64.to_int (In_channel.with_open_bin (turns_path config) In_channel.length) in
    Out_channel.with_open_gen [ Open_append; Open_binary ] 0o600 (turns_path config) (fun channel ->
      output_string channel "not json\n");
    Writers.declaration_changed (writers config) (Some declared);
    rested ~clock:env.clock (writers config);
    let row = row_of config in
    check string "its state" "resting" (text "state" row);
    check (list string) "E3" [ "E3" ] (alarms row);
    let read = member "last_read" row in
    check string "the ask ended on an input fault" "input_fault" (text "ended" read);
    let fault = member "fault" read in
    check string "the line does not decode" "line_unreadable" (text "kind" fault);
    check bool "at the offset the operator sends" true (member "offset" fault = `Int offset))
    ()
;;

let () =
  run "keeper_memory_writer_health"
    [ ( "row"
      , [ test_case "a process without writers" `Quick test_a_process_without_writers
        ; test_case "a registered Keeper before its writer" `Quick test_a_keeper_before_its_writer
        ; test_case "an open writer" `Quick test_an_open_writer
        ; test_case "a stopped writer" `Quick test_a_stopped_writer
        ; test_case "a writer resting on an input fault" `Quick test_a_writer_resting_on_an_input_fault
        ] )
    ]
;;
