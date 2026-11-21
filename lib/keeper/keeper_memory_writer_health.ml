module Machine = Librarian_machine
module Store = Librarian_store
module Level = Librarian_level
module Last = Librarian_last
module Log_line = Librarian_log
module Digest = Agent_core.Checkpoint_objects

let digest_json (digest : Digest.digest) = `String (digest :> string)

let state_token : Machine.state -> string = function
  | Idle _ -> "idle"
  | Asking _ -> "asking"
  | Resting _ -> "resting"
  | Refused_at_bottom _ -> "refused_at_bottom"
  | Stopped _ -> "stopped"
;;

let alarm_token : Level.alarm -> string = function
  | E1 -> "E1"
  | E2 -> "E2"
  | E3 -> "E3"
  | E4 -> "E4"
  | E5 -> "E5"
  | W1 -> "W1"
  | W3 -> "W3"
;;

let level_token : Level.level -> string = function
  | Ok -> "ok"
  | Warn -> "warn"
  | Error -> "error"
;;

let failed_token : Librarian_read_result.failed -> string = function
  | Raised -> "raised"
  | Flow_stopped -> "flow_stopped"
  | Read_failed -> "read_failed"
;;

(* The same reading the writer's next ask makes (§9.2): the first unit with
   an item past the store's tail. A turn log that does not read is counted
   as unread, as the next ask counts it. *)
let unread ~config ~keeper store =
  let turns_path =
    Keeper_turn_log_store.path_for_keepers_dir
      ~keepers_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_id:keeper
  in
  Librarian_unread.has_unread
    (Librarian_unread.read ~turns_path ~until:(First_with_items 1) (Store.tail store))
;;

let position_json : Log_line.position -> Yojson.Safe.t = function
  | Before_first -> `String "before_first"
  | Through { line; within } ->
    `Assoc
      [ "line", `Int line
      ; ( "within"
        , `String
            (match within with
             | Whole -> "whole"
             | Item (_ : Librarian_unit.item_name) -> "item") )
      ]
;;

let log_id_json id = `String (Keeper_turn_log.Log_id.to_string id)

(* The turn log the tail names is the [observed] a [Restart_reading] sends
   when the position in that same file is lost (§12.4). *)
let tail_fields (tail : Log_line.line) =
  match tail with
  | Started { at; turn_log; _ } ->
    [ "last_line", `String "started"
    ; "last_line_at", `Float at
    ; "turn_log", log_id_json turn_log
    ; "covers_through", `String "before_first"
    ]
  | Committed { seq; at; turn_log; covers_through; _ } ->
    [ "last_line", `String "commit"
    ; "last_seq", `Int seq
    ; "last_line_at", `Float at
    ; "turn_log", log_id_json turn_log
    ; "covers_through", position_json covers_through
    ]
;;

(* Each kind is its constructor's name. A Skip line of the commit log names
   [turn_log_replaced] and [position_lost] the same way. *)
let input_fault_json : Librarian_unit.input_fault -> Yojson.Safe.t = function
  | Line_unreadable { offset } -> `Assoc [ "kind", `String "line_unreadable"; "offset", `Int offset ]
  | Turn_log_replaced { expected; observed } ->
    `Assoc
      [ "kind", `String "turn_log_replaced"
      ; "expected", log_id_json expected
      ; "observed", Option.fold ~none:`Null ~some:log_id_json observed
      ]
  | Position_lost { offset; length } ->
    `Assoc [ "kind", `String "position_lost"; "offset", `Int offset; "length", `Int length ]
  | Content_unreadable { line } -> `Assoc [ "kind", `String "content_unreadable"; "line", `Int line ]
;;

(* What each slot of the walk said to a reading ask no slot answered. *)
let slots_json slots : Yojson.Safe.t =
  `List
    (List.map
       (fun ((key : Librarian_memory_lane.slot_key), outcome) ->
          `Assoc
            [ "slot", `String key.id; "outcome", `String (Machine.unanswered_token outcome) ])
       slots)
;;

(* Each end is its constructor's name. The refusal E4 reads keeps the lane
   value its verdict was folded over, so it says whether that is the value
   declared now, as [fits_none] does for a room ask. It carries no
   [one_item] and no [silent]: it is always one item with no slot silent.

   Whether an end is about what the writer holds now is the alarms' to judge
   (§12.2), and the row asks them: [about_memory_now] and [about_lane_now]
   are the two halves of what turns E4 and E5 on. *)
let read_json (machine : Machine.t) : Last.read -> Yojson.Safe.t = function
  | Committed -> `Assoc [ "ended", `String "committed" ]
  | Refused_not_all_sized { basis; lane; slots } ->
    `Assoc
      [ "ended", `String "refused_not_all_sized"
      ; "about_memory_now", `Bool (Level.snapshot_held_now machine basis)
      ; "about_lane_now", `Bool (Level.lane_value_held_now machine lane)
      ; "slots", slots_json slots
      ]
  | Lane { one_item; silent; basis; slots } ->
    `Assoc
      [ "ended", `String "lane"
      ; "one_item", `Bool one_item
      ; "silent", `Bool silent
      ; "about_memory_now", `Bool (Level.snapshot_held_now machine basis)
      ; "slots", slots_json slots
      ]
  | Input_fault fault -> `Assoc [ "ended", `String "input_fault"; "fault", input_fault_json fault ]
  | Ask_failed failed -> `Assoc [ "ended", `String "ask_failed"; "failed", `String (failed_token failed) ]
;;

let room_json (machine : Machine.t) : Last.room -> Yojson.Safe.t = function
  | Made -> `Assoc [ "ended", `String "made" ]
  | Unchanged -> `Assoc [ "ended", `String "unchanged" ]
  | Stale -> `Assoc [ "ended", `String "stale" ]
  | Not_judged -> `Assoc [ "ended", `String "not_judged" ]
  | Fits_none { memory; lane } ->
    `Assoc
      [ "ended", `String "fits_none"
      ; "about_memory_now", `Bool (Level.snapshot_held_now machine memory)
      ; "about_lane_now", `Bool (Level.lane_value_held_now machine lane)
      ]
;;

let asking_json : Machine.state -> Yojson.Safe.t = function
  | Asking { asking; store = (_ : Store.t) } ->
    `Assoc
      [ "ask", `Int asking.ask
      ; "since", `Float asking.since
      ; ( "asked"
        , `String
            (match asking.asked with
             | Read (Read_range (_ : Librarian_width.width)) -> "range"
             | Read Read_item_alone -> "item_alone"
             | Room (_ : Librarian_room_result.asked) -> "room") )
      ]
  | Idle _ | Resting _ | Refused_at_bottom _ | Stopped _ -> `Null
;;

(* A stopped store names why in the words the Memory tools use, and the
   snapshot file as it is on disk: what an adoption has to name (§12.2). *)
let stopped_fields ~config ~keeper (stop : Store.stop) =
  let path =
    Keeper_memory_os_current_layout.path_for_keepers_dir
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
      ~keeper_id:keeper
  in
  [ ( "stop"
    , `String
        (Keeper_tool_memory_validation.memory_unwritable_to_string
           (Keeper_tool_memory_validation.Store_stopped stop)) )
  ; ( "snapshot_file"
    , match Store.read_snapshot_bytes path with
      | Ok bytes ->
        `Assoc
          [ "sha", digest_json (Digest.digest_of_bytes bytes)
          ; "bytes", `Int (String.length bytes)
          ]
      | Error fault ->
        `Assoc
          [ ( "fault"
            , `String
                (match (fault : Librarian_snapshot_fault.t) with
                 | Absent -> "absent"
                 | Not_a_snapshot_file -> "not_a_snapshot_file"
                 | Not_read -> "not_read") )
          ] )
  ]
;;

let shown ~state ~alarms fields =
  let level = Level.level alarms in
  ( level
  , `Assoc
      ([ "state", `String state
       ; "level", `String (level_token level)
       ; "alarms", `List (List.map (fun alarm -> `String (alarm_token alarm)) alarms)
       ]
       @ fields) )
;;

let row_with_level ~config ~keeper : Librarian_writer.held -> Level.level * Yojson.Safe.t = function
  | Held_booting -> shown ~state:"booting" ~alarms:(Level.alarms Booting) [ "unread", `Null ]
  | Held_retired -> shown ~state:"retired" ~alarms:(Level.alarms Retired) []
  | Held machine ->
    (* An open store shows where reading stands and Memory; a stopped one
       shows why it stopped. *)
    let store, place =
      match machine.state with
      | Stopped stop -> None, stopped_fields ~config ~keeper stop
      | Idle { store; seen_length = (_ : int option) }
      | Asking { store; asking = (_ : Machine.asking) }
      | Resting store
      | Refused_at_bottom store ->
        ( Some store
        , tail_fields (Store.tail store)
          @ [ ( "memory"
              , `Assoc
                  [ "snapshot", digest_json (Log_line.snapshot_after (Store.tail store))
                  ; "facts", `Int (List.length (Store.memory store).facts)
                  ] )
            ] )
    in
    let unread = Option.fold ~none:false ~some:(unread ~config ~keeper) store in
    shown
      ~state:(state_token machine.state)
      ~alarms:(Level.alarms (Running { machine; unread }))
      ([ "unread", (match store with Some _ -> `Bool unread | None -> `Null)
       ; "lane", `Bool (Option.is_some machine.lane)
       ; "asking", asking_json machine.state
       ; "last_read", Option.fold ~none:`Null ~some:(read_json machine) machine.last_read
       ; "last_room", Option.fold ~none:`Null ~some:(room_json machine) machine.last_room
       ; "read_alone", `Bool machine.read_alone
       ]
       @ place)
;;

(* §8.6: a registered Keeper's writer is made by its first turn or by the
   first pulse. Until then no store of its was opened here, which is what
   [Held_booting] says, and reading the row makes no writer. *)
let held_by_keeper ~config writers =
  let made = Librarian_writers.held writers in
  let not_made =
    List.filter_map
      (fun keeper ->
         if List.mem_assoc keeper made
         then None
         else Some (keeper, Librarian_writer.Held_booting))
      (Keeper_memory_writers.registered ~base_path:config.Workspace.base_path)
  in
  made @ not_made
;;

let section_json ~config =
  match Keeper_memory_writers.find ~base_path:config.Workspace.base_path with
  | None -> `Assoc [ "writers", `String "none_in_process" ]
  | Some writers ->
    let rows =
      List.map
        (fun (keeper, held) -> keeper, row_with_level ~config ~keeper held)
        (List.sort
           (fun ((a : string), (_ : Librarian_writer.held)) (b, (_ : Librarian_writer.held)) ->
              String.compare a b)
           (held_by_keeper ~config writers))
    in
    let at wanted =
      List.length
        (List.filter
           (fun ((_ : string), ((level : Level.level), (_ : Yojson.Safe.t))) ->
              match level, wanted with
              | Error, `Error | Warn, `Warn -> true
              | (Ok | Warn | Error), (`Error | `Warn) -> false)
           rows)
    in
    `Assoc
      [ "writers", `String "running"
      ; "error", `Int (at `Error)
      ; "warn", `Int (at `Warn)
      ; ( "keepers"
        , `List
            (List.map
               (fun (keeper, ((_ : Level.level), row)) ->
                  `Assoc [ "keeper", `String keeper; "row", row ])
               rows) )
      ]
;;

let keeper_rows ~config =
  match Keeper_memory_writers.find ~base_path:config.Workspace.base_path with
  | None -> fun (_ : string) -> `Assoc [ "kind", `String "none_in_process" ]
  | Some writers ->
    let held = held_by_keeper ~config writers in
    fun keeper ->
      (match List.assoc_opt keeper held with
       | Some held ->
         let (_ : Level.level), row = row_with_level ~config ~keeper held in
         `Assoc [ "kind", `String "writer"; "row", row ]
       | None -> `Assoc [ "kind", `String "no_writer" ])
;;
