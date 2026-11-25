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

let string_list key row =
  match member key row with
  | `List xs ->
    List.map
      (function
        | `String s -> s
        | other -> failf "%s item is not a string: %s" key (Yojson.Safe.to_string other))
      xs
  | other -> failf "%s is not a list: %s" key (Yojson.Safe.to_string other)
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

let keeper_row_of config name = Health.keeper_rows ~config name ;;

let test_a_process_without_writers () =
  let config = Masc.Workspace.default_config (Filename.temp_dir "writer-health" "") in
  check string "a Keeper's row says the process runs none" "none_in_process"
    (text "kind" (keeper_row_of config keeper));
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
    let krow = keeper_row_of config keeper in
    check string "the Keeper's row kind is writer" "writer" (text "kind" krow);
    check string "the Keeper's row matches the section row"
      (Yojson.Safe.to_string row) (Yojson.Safe.to_string (member "row" krow));
    check string "and a Keeper outside the registry has no writer" "no_writer"
      (text "kind" (keeper_row_of config "outside-the-registry"));
    check int "and the table still holds no writer" 0 (List.length (Writers.held (writers config))))
    ()
;;

let turns_path config =
  Masc.Keeper_turn_log_store.path_for_keepers_dir
    ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper
;;

let turn_log_start config =
  match Masc.Keeper_turn_log_store.read_start (turns_path config) with
  | Ok (Some start) -> start
  | Ok None -> fail "the turn log has no first line"
  | Error (_ : Masc.Keeper_turn_log_store.read_error) -> fail "the turn log was not read"
;;

let turn_log_id config = Masc.Keeper_turn_log.Log_id.to_string (turn_log_start config).id

(* A writer with no lane value and nothing unread is open and has no alarm. *)
let test_an_open_writer () =
  in_workspace (fun ~sw config ->
    let (_ : Writer.view) = Deps.booted_memory_writer_view ~sw ~config keeper in
    let row = row_of config in
    check string "its state" "idle" (text "state" row);
    check string "its level" "ok" (text "level" row);
    check (list string) "no alarm" [] (alarms row);
    check (list string) "idle writer has no recovery acts" [] (string_list "available_acts" row);
    check bool "idle writer has no pending molt" true (member "pending_molt" row = `Null);
    check (list string) "idle writer has no pending molt categories" []
      (string_list "pending_molt_categories" row);
    check bool "no lane value" true (member "lane" row = `Bool false);
    check bool "nothing unread" true (member "unread" row = `Bool false);
    check string "reading stands at the log's start" "started" (text "last_line" row);
    check string "of the turn log the Keeper has" (turn_log_id config) (text "turn_log" row);
    check bool "no ask has ended" true (member "last_read" row = `Null);
    check bool "Memory holds no fact" true (member "facts" (member "memory" row) = `Int 0);
    let krow = keeper_row_of config keeper in
    check string "the Keeper's row kind is writer" "writer" (text "kind" krow);
    check string "the Keeper's row shows the same open writer"
      (Yojson.Safe.to_string row) (Yojson.Safe.to_string (member "row" krow));
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
    let stopped_acts = string_list "available_acts" row in
    check bool "stopped writer offers adopt" true (List.mem "adopt" stopped_acts);
    check bool "stopped writer offers resume" true (List.mem "resume" stopped_acts);
    let krow = keeper_row_of config keeper in
    check string "the Keeper's row shows the same stopped store"
      (Yojson.Safe.to_string row) (Yojson.Safe.to_string (member "row" krow));
    check bool "the section counts it" true (member "error" (Health.section_json ~config) = `Int 1))
    ()
;;

(* The one slot the lane value below declares. *)
let slot_id = "claude_code.fast"

(* A lane value that names one CLI slot. No case runs the slot: one ask stops
   at the turn log before any slot is asked, and the other is made here. *)
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
          [ { id = slot_id
            ; target = Cli { runtime_id = slot_id; api_name = "claude-sonnet-5" }
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

(* Waits until the writer's machine is what [reached] says. *)
let held_as ~clock writers ~what reached =
  let deadline = Eio.Time.now clock +. wait_s in
  let rec look () =
    match List.assoc_opt keeper (Writers.held writers) with
    | Some (Writer.Held machine) when reached machine -> ()
    | Some (Writer.Held (_ : Masc.Librarian_machine.t) | Writer.Held_booting | Writer.Held_retired)
    | None ->
      if Eio.Time.now clock > deadline then failf "the writer did not %s in %.0f s" what wait_s;
      Eio.Time.sleep clock poll_s;
      look ()
  in
  look ()
;;

let rested ~clock writers =
  held_as ~clock writers ~what:"rest" (fun (machine : Masc.Librarian_machine.t) ->
    match machine.state with
    | Resting (_ : Masc.Librarian_store.t) -> true
    | Idle _ | Asking _ | Refused_at_bottom _ | Stopped _ -> false)
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
    let e3_acts = string_list "available_acts" row in
    check bool "input fault offers resume" true (List.mem "resume" e3_acts);
    check bool "input fault offers skip_line" true (List.mem "skip_line" e3_acts);
    let read = member "last_read" row in
    check string "the ask ended on an input fault" "input_fault" (text "ended" read);
    let fault = member "fault" read in
    check string "the line does not decode" "line_unreadable" (text "kind" fault);
    check bool "at the offset the operator sends" true (member "offset" fault = `Int offset);
    let krow = keeper_row_of config keeper in
    check string "the Keeper's row shows the same fault"
      (Yojson.Safe.to_string row) (Yojson.Safe.to_string (member "row" krow)))
    ()
;;

(* One completed turn whose chat grew by a byte: a unit with an item, past
   where the writer has read. *)
let close_a_turn_with_an_item config =
  let path = turns_path config in
  let mark : Masc.Keeper_turn_log.mark = (turn_log_start config).mark in
  let opened_at = Int64.to_int (In_channel.with_open_bin path In_channel.length) in
  match
    Masc.Keeper_turn_log_store.append ~path ~at_end:opened_at
      ( Masc.Keeper_turn_log.Opened
          { at = 2.0
          ; turn_ref = Ids.Turn_ref.make ~trace_id:mark.trace ~absolute_turn:1
          ; runtime = "fixture"
          ; task = Masc.Keeper_turn_log.No_task
          ; stimuli = []
          ; baseline = mark
          }
      , [ Masc.Keeper_turn_log.Closed
            { turn = opened_at
            ; at = 3.0
            ; outcome = Masc.Keeper_turn_log.Completed
            ; after = { mark with chat_bytes = mark.chat_bytes + 1 }
            ; unattributed = []
            ; own = []
            }
        ] )
  with
  | Ok (_ : Masc.Keeper_turn_log_store.appended) -> ()
  | Error (_ : Masc.Keeper_turn_log_store.append_error) -> fail "the turn was not appended"
;;

let question_id =
  match
    Masc.Librarian_question_id.of_halves ~front:(String.make 32 'c') ~back:(String.make 32 'd')
  with
  | Some id -> id
  | None -> fail "the test question halves are not 32 hexadecimal characters"
;;

(* An ask no model answers: every slot of the lane value it started with
   refused the first unread unit, read whole as one item, and gave no size.
   The question names the snapshot the writer's tail names, as the
   Librarian's own ask does. *)
let refused_without_a_size config (input : Masc.Librarian_ask.input)
  : Masc.Librarian_read_result.t
  =
  let tail =
    match input.tail () with
    | Some tail -> tail
    | None -> fail "the writer that asked is not open"
  in
  let span =
    match
      Masc.Librarian_unread.read ~turns_path:(turns_path config) ~until:(First_with_items 1) tail
    with
    | Ok { spans; stop = (_ : Masc.Librarian_unread.stop); bytes = (_ : int) } ->
      (match List.rev spans with
       | last :: _ -> last
       | [] -> fail "nothing is unread")
    | Error (_ : Masc.Librarian_unread.read_error) -> fail "the turn log was not read"
  in
  No_answer
    { question =
        { id = question_id
        ; shown = Range { memory = []; units = [ "u1", span.line ] }
        ; basis = Masc.Librarian_log.snapshot_after tail
        ; reach = Masc.Librarian_unread.reach span Whole
        ; trace = span.through.trace
        ; missing = []
        ; offered = { units = 1; head_items = 1 }
        ; personal_sources = []
        }
    ; slots =
        List.map
          (fun slot -> slot, Masc.Librarian_slot_outcome.Refused Unsized)
          (input.lane.http @ input.lane.cli)
    }
;;

(* §12.2 E4: every slot the lane declares refused one item, and not every one
   gave a size. The row names that end by its own word and says whether the
   lane value the refusals were read against is the one declared now, so a
   lane value that is gone shows on the row and E4 is off. *)
let test_a_writer_every_slot_refused () =
  in_workspace_with_ask (fun ~sw ~env config ->
    let (_ : Writers.t) =
      Masc.Keeper_memory_writers.start ~sw ~ask:(refused_without_a_size config)
        ~ask_room:Deps.never_makes_room
        ~start_turn_log:(Masc.Keeper_turn_log_store_start.run config) ~config
    in
    let (_ : Writer.view) = Deps.booted_memory_writer_view ~sw ~config keeper in
    close_a_turn_with_an_item config;
    Writers.declaration_changed (writers config) (Some declared);
    rested ~clock:env.clock (writers config);
    let wire ~about_lane_now : Yojson.Safe.t =
      `Assoc
        [ "ended", `String "refused_not_all_sized"
        ; "about_memory_now", `Bool true
        ; "about_lane_now", `Bool about_lane_now
        ; "slots", `List [ `Assoc [ "slot", `String slot_id; "outcome", `String "refused" ] ]
        ]
    in
    let row = row_of config in
    check string "its state" "resting" (text "state" row);
    check (list string) "E4, and W1 for what is still unread" [ "E4"; "W1" ] (alarms row);
    let e4_acts = string_list "available_acts" row in
    check bool "E4 offers resume" true (List.mem "resume" e4_acts);
    check bool "E4 offers skip_item" true (List.mem "skip_item" e4_acts);
    check string "the refusal has its own end, about the lane value declared now"
      (Yojson.Safe.to_string (wire ~about_lane_now:true))
      (Yojson.Safe.to_string (member "last_read" row));
    check string "the Keeper's row shows the same refusal"
      (Yojson.Safe.to_string row)
      (Yojson.Safe.to_string (member "row" (keeper_row_of config keeper)));
    Writers.declaration_changed (writers config) None;
    held_as ~clock:env.clock (writers config) ~what:"let the lane value go"
      (fun (machine : Masc.Librarian_machine.t) -> Option.is_none machine.lane);
    let row = row_of config in
    check (list string) "with the lane value gone E4 is off" [ "W1" ] (alarms row);
    check string "and the refusal is about a lane value that is not declared now"
      (Yojson.Safe.to_string (wire ~about_lane_now:false))
      (Yojson.Safe.to_string (member "last_read" row));
    check string "which the Keeper's row shows"
      (Yojson.Safe.to_string row)
      (Yojson.Safe.to_string (member "row" (keeper_row_of config keeper))))
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
        ; test_case "a writer every slot refused without a size" `Quick
            test_a_writer_every_slot_refused
        ] )
    ]
;;
