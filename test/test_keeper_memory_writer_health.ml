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

let () =
  run "keeper_memory_writer_health"
    [ ( "row"
      , [ test_case "a process without writers" `Quick test_a_process_without_writers
        ; test_case "a registered Keeper before its writer" `Quick test_a_keeper_before_its_writer
        ; test_case "an open writer" `Quick test_an_open_writer
        ; test_case "a stopped writer" `Quick test_a_stopped_writer
        ] )
    ]
;;
