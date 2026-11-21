open Tui_decode_fields
open Result.Syntax

type slot_outcome =
  | Input_too_large
  | Output_over_reserve
  | Window_reached
  | Refused
  | Not_called
  | Unavailable
  | Busy
  | Overdue
  | Lost
  | Unusable

type input_fault =
  | Line_unreadable of { offset : int }
  | Turn_log_replaced of
      { expected : string
      ; observed : string option
      }
  | Position_lost of
      { offset : int
      ; length : int
      }
  | Content_unreadable of { line : int }

type ask_failure =
  | Raised
  | Flow_stopped
  | Read_failed

type last_read =
  | Read_committed
  | Read_refused_not_all_sized of
      { about_memory_now : bool
      ; about_lane_now : bool
      ; slots : (string * slot_outcome) list
      }
  | Read_lane of
      { one_item : bool
      ; silent : bool
      ; about_memory_now : bool
      ; slots : (string * slot_outcome) list
      }
  | Read_input_fault of input_fault
  | Read_ask_failed of ask_failure

type last_room =
  | Room_made
  | Room_unchanged
  | Room_stale
  | Room_not_judged
  | Room_fits_none of
      { about_memory_now : bool
      ; about_lane_now : bool
      }

type asked =
  | Asked_range
  | Asked_item_alone
  | Asked_room

type asking =
  { ask : int
  ; since : float
  ; asked : asked
  }

type activity =
  | Idle
  | Asking of asking
  | Resting
  | Refused_at_bottom

type position =
  | Before_first
  | Through of
      { line : int
      ; within_item : bool
      }

type last_line =
  | Line_started
  | Line_commit of { seq : int }

type stop =
  | Log_diverged
  | Memory_unreadable
  | Log_unreadable
  | Store_unwritable
  | Store_raised

type snapshot_file =
  | File of
      { sha : string
      ; bytes : int
      }
  | File_absent
  | File_not_a_snapshot
  | File_not_read

type kept =
  { lane : bool
  ; last_read : last_read option
  ; last_room : last_room option
  ; read_alone : bool
  }

type row =
  | Booting
  | Retired
  | Open of
      { activity : activity
      ; unread : bool
      ; kept : kept
      ; last_line : last_line
      ; last_line_at : float
      ; turn_log : string
      ; covers_through : position
      ; snapshot : string
      ; facts : int
      }
  | Stopped of
      { stop : stop
      ; snapshot_file : snapshot_file
      ; kept : kept
      }

type shown =
  { level : Librarian_level.level
  ; alarms : Librarian_level.alarm list
  ; row : row
  }

type t =
  | None_in_process
  | No_writer
  | Writer of shown

let unknown what token = Error (Printf.sprintf "unsupported writer %s: %s" what token)

let alarm_of_wire : string -> (Librarian_level.alarm, string) result = function
  | "E1" -> Ok E1
  | "E2" -> Ok E2
  | "E3" -> Ok E3
  | "E4" -> Ok E4
  | "E5" -> Ok E5
  | "W1" -> Ok W1
  | "W2" -> Ok W2
  | "W3" -> Ok W3
  | other -> unknown "alarm" other
;;

let level_of_wire : string -> (Librarian_level.level, string) result = function
  | "ok" -> Ok Ok
  | "warn" -> Ok Warn
  | "error" -> Ok Error
  | other -> unknown "level" other
;;

let slot_outcome_of_wire = function
  | "input_too_large" -> Ok Input_too_large
  | "output_over_reserve" -> Ok Output_over_reserve
  | "window_reached" -> Ok Window_reached
  | "refused" -> Ok Refused
  | "not_called" -> Ok Not_called
  | "unavailable" -> Ok Unavailable
  | "busy" -> Ok Busy
  | "overdue" -> Ok Overdue
  | "lost" -> Ok Lost
  | "unusable" -> Ok Unusable
  | other -> unknown "slot outcome" other
;;

let nullable decode = function
  | `Null -> Ok None
  | value -> Result.map Option.some (decode value)
;;

let non_negative what value =
  if value >= 0 then Ok value else Error (Printf.sprintf "writer %s must be non-negative" what)
;;

let moment json name =
  let* at = Json_util.require_float json name in
  if Float.is_finite at && at >= 0.
  then Ok at
  else Error (Printf.sprintf "writer %s must be a moment" name)
;;

let non_blank json name =
  let* value = required_string_field json name in
  if String.equal (String.trim value) ""
  then Error (Printf.sprintf "writer %s is empty" name)
  else Ok value
;;

let decode_input_fault json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "line_unreadable" ->
    let* () = require_exact_object_fields "writer input fault" [ "kind"; "offset" ] json in
    let* offset = Result.bind (required_int_field json "offset") (non_negative "offset") in
    Ok (Line_unreadable { offset })
  | "turn_log_replaced" ->
    let* () =
      require_exact_object_fields "writer input fault" [ "kind"; "expected"; "observed" ] json
    in
    let* expected = non_blank json "expected" in
    let* observed = required_nullable_nonblank_string_field json "observed" in
    Ok (Turn_log_replaced { expected; observed })
  | "position_lost" ->
    let* () =
      require_exact_object_fields "writer input fault" [ "kind"; "offset"; "length" ] json
    in
    let* offset = Result.bind (required_int_field json "offset") (non_negative "offset") in
    let* length = Result.bind (required_int_field json "length") (non_negative "length") in
    Ok (Position_lost { offset; length })
  | "content_unreadable" ->
    let* () = require_exact_object_fields "writer input fault" [ "kind"; "line" ] json in
    let* line = Result.bind (required_int_field json "line") (non_negative "line") in
    Ok (Content_unreadable { line })
  | other -> unknown "input fault" other
;;

let decode_slot json =
  let* () = require_exact_object_fields "writer slot outcome" [ "slot"; "outcome" ] json in
  let* slot = non_blank json "slot" in
  let* outcome = Result.bind (required_string_field json "outcome") slot_outcome_of_wire in
  Ok (slot, outcome)
;;

let decode_last_read json =
  let* ended = required_string_field json "ended" in
  match ended with
  | "committed" ->
    let* () = require_exact_object_fields "writer last read" [ "ended" ] json in
    Ok Read_committed
  | "refused_not_all_sized" ->
    let* () =
      require_exact_object_fields
        "writer last read"
        [ "ended"; "about_memory_now"; "about_lane_now"; "slots" ]
        json
    in
    let* about_memory_now = required_bool_field json "about_memory_now" in
    let* about_lane_now = required_bool_field json "about_lane_now" in
    let* slots = Result.bind (required_list_field json "slots") (decode_list "slots" decode_slot) in
    Ok (Read_refused_not_all_sized { about_memory_now; about_lane_now; slots })
  | "lane" ->
    let* () =
      require_exact_object_fields
        "writer last read"
        [ "ended"; "one_item"; "silent"; "about_memory_now"; "slots" ]
        json
    in
    let* one_item = required_bool_field json "one_item" in
    let* silent = required_bool_field json "silent" in
    let* about_memory_now = required_bool_field json "about_memory_now" in
    let* slots = Result.bind (required_list_field json "slots") (decode_list "slots" decode_slot) in
    Ok (Read_lane { one_item; silent; about_memory_now; slots })
  | "input_fault" ->
    let* () = require_exact_object_fields "writer last read" [ "ended"; "fault" ] json in
    let* fault = Result.bind (required_object_field json "fault") decode_input_fault in
    Ok (Read_input_fault fault)
  | "ask_failed" ->
    let* () = require_exact_object_fields "writer last read" [ "ended"; "failed" ] json in
    let* failed = required_string_field json "failed" in
    (match failed with
     | "raised" -> Ok (Read_ask_failed Raised)
     | "flow_stopped" -> Ok (Read_ask_failed Flow_stopped)
     | "read_failed" -> Ok (Read_ask_failed Read_failed)
     | other -> unknown "ask failure" other)
  | other -> unknown "last read" other
;;

let decode_last_room json =
  let* ended = required_string_field json "ended" in
  let plain room =
    let* () = require_exact_object_fields "writer last room" [ "ended" ] json in
    Ok room
  in
  match ended with
  | "made" -> plain Room_made
  | "unchanged" -> plain Room_unchanged
  | "stale" -> plain Room_stale
  | "not_judged" -> plain Room_not_judged
  | "fits_none" ->
    let* () =
      require_exact_object_fields
        "writer last room"
        [ "ended"; "about_memory_now"; "about_lane_now" ]
        json
    in
    let* about_memory_now = required_bool_field json "about_memory_now" in
    let* about_lane_now = required_bool_field json "about_lane_now" in
    Ok (Room_fits_none { about_memory_now; about_lane_now })
  | other -> unknown "last room" other
;;

let decode_asking json =
  let* () = require_exact_object_fields "writer asking" [ "ask"; "since"; "asked" ] json in
  let* ask = Result.bind (required_int_field json "ask") (non_negative "ask") in
  let* since = moment json "since" in
  let* asked = required_string_field json "asked" in
  let* asked =
    match asked with
    | "range" -> Ok Asked_range
    | "item_alone" -> Ok Asked_item_alone
    | "room" -> Ok Asked_room
    | other -> unknown "question" other
  in
  Ok { ask; since; asked }
;;

let decode_position = function
  | `String "before_first" -> Ok Before_first
  | `Assoc _ as json ->
    let* () = require_exact_object_fields "writer position" [ "line"; "within" ] json in
    let* line = Result.bind (required_int_field json "line") (non_negative "line") in
    let* within = required_string_field json "within" in
    (match within with
     | "whole" -> Ok (Through { line; within_item = false })
     | "item" -> Ok (Through { line; within_item = true })
     | other -> unknown "position" other)
  | `String other -> unknown "position" other
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    Error "writer covers_through is neither before_first nor a position"
;;

let decode_snapshot_file json =
  match member "fault" json with
  | `Null ->
    let* () = require_exact_object_fields "writer snapshot file" [ "sha"; "bytes" ] json in
    let* sha = non_blank json "sha" in
    let* bytes = Result.bind (required_int_field json "bytes") (non_negative "bytes") in
    Ok (File { sha; bytes })
  | `String fault ->
    let* () = require_exact_object_fields "writer snapshot file" [ "fault" ] json in
    (match fault with
     | "absent" -> Ok File_absent
     | "not_a_snapshot_file" -> Ok File_not_a_snapshot
     | "not_read" -> Ok File_not_read
     | other -> unknown "snapshot file fault" other)
  | `Assoc _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    Error "writer snapshot file fault is not a token"
;;

let stop_of_wire = function
  | "store_stopped_log_diverged" -> Ok Log_diverged
  | "store_stopped_memory_unreadable" -> Ok Memory_unreadable
  | "store_stopped_log_unreadable" -> Ok Log_unreadable
  | "store_stopped_store_unwritable" -> Ok Store_unwritable
  | "store_stopped_raised" -> Ok Store_raised
  | other -> unknown "stop" other
;;

(* The fields every row of a made writer carries, open or stopped. *)
let kept_fields = [ "lane"; "last_read"; "last_room"; "read_alone" ]

let decode_kept json =
  let* lane = required_bool_field json "lane" in
  let* last_read = Result.bind (required_member json "last_read") (nullable decode_last_read) in
  let* last_room = Result.bind (required_member json "last_room") (nullable decode_last_room) in
  let* read_alone = required_bool_field json "read_alone" in
  Ok { lane; last_read; last_room; read_alone }
;;

let shown_fields = [ "state"; "level"; "alarms"; "request" ]

let decode_cause json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "other_trace" | "log_end_unread" | "lines_unread" ->
    require_exact_object_fields "writer request cause" [ "kind" ] json
  | "reset_between" ->
    let* () = require_exact_object_fields "writer request cause" [ "kind"; "offset" ] json in
    let* (_ : int) = Result.bind (required_int_field json "offset") (non_negative "offset") in
    Ok ()
  | other -> unknown "request cause" other
;;

let decode_positions json ~behind =
  let* () =
    require_exact_object_fields "writer request" [ "kind"; "sends_from"; "read_end" ] json
  in
  let* sends_from = Result.bind (required_int_field json "sends_from") (non_negative "sends_from") in
  let* read_end = Result.bind (required_int_field json "read_end") (non_negative "read_end") in
  if Bool.equal behind (sends_from > read_end)
  then Ok behind
  else Error "writer request disagrees with its positions"
;;

(* Where the Keeper's latest request started against the read end (§11.3).
   The screen draws W2 and nothing else of it, so the decode keeps only
   whether the request starts past the read end, to check W2 against. *)
let decode_request_behind json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "unknown_until_next_request" | "view_unavailable" | "no_read_end" ->
    let* () = require_exact_object_fields "writer request" [ "kind" ] json in
    Ok false
  | "not_behind" -> decode_positions json ~behind:false
  | "behind" -> decode_positions json ~behind:true
  | "not_comparable" ->
    let* () = require_exact_object_fields "writer request" [ "kind"; "cause" ] json in
    let* () = Result.bind (required_object_field json "cause") decode_cause in
    Ok false
  | other -> unknown "request" other
;;

let decode_open ~state json =
  let* last_line = required_string_field json "last_line" in
  let place = [ "last_line_at"; "turn_log"; "covers_through"; "memory" ] in
  let* last_line, line_fields =
    match last_line with
    | "started" -> Ok (Line_started, [ "last_line" ])
    | "commit" ->
      let* seq = Result.bind (required_int_field json "last_seq") (non_negative "last_seq") in
      Ok (Line_commit { seq }, [ "last_line"; "last_seq" ])
    | other -> unknown "last line" other
  in
  let* () =
    require_exact_object_fields
      "writer row"
      (shown_fields @ [ "unread"; "asking" ] @ kept_fields @ line_fields @ place)
      json
  in
  let* unread = required_bool_field json "unread" in
  let* asking = Result.bind (required_member json "asking") (nullable decode_asking) in
  let* activity =
    match state, asking with
    | `Idle, None -> Ok Idle
    | `Resting, None -> Ok Resting
    | `Refused_at_bottom, None -> Ok Refused_at_bottom
    | `Asking, Some asking -> Ok (Asking asking)
    | `Asking, None -> Error "an asking writer names no ask"
    | (`Idle | `Resting | `Refused_at_bottom), Some _ ->
      Error "a writer that is not asking names an ask"
  in
  let* kept = decode_kept json in
  let* last_line_at = moment json "last_line_at" in
  let* turn_log = non_blank json "turn_log" in
  let* covers_through = Result.bind (required_member json "covers_through") decode_position in
  let* memory = required_object_field json "memory" in
  let* () = require_exact_object_fields "writer memory" [ "snapshot"; "facts" ] memory in
  let* snapshot = non_blank memory "snapshot" in
  let* facts = Result.bind (required_int_field memory "facts") (non_negative "facts") in
  Ok
    (Open
       { activity
       ; unread
       ; kept
       ; last_line
       ; last_line_at
       ; turn_log
       ; covers_through
       ; snapshot
       ; facts
       })
;;

let decode_stopped json =
  let* () =
    require_exact_object_fields
      "writer row"
      (shown_fields @ [ "unread"; "asking" ] @ kept_fields @ [ "stop"; "snapshot_file" ])
      json
  in
  (* A stopped store has no tail to read what is unread from, and no ask. *)
  let* () = require_null_field json "unread" in
  let* () = require_null_field json "asking" in
  let* kept = decode_kept json in
  let* stop = Result.bind (required_string_field json "stop") stop_of_wire in
  let* snapshot_file =
    Result.bind (required_object_field json "snapshot_file") decode_snapshot_file
  in
  Ok (Stopped { stop; snapshot_file; kept })
;;

let decode_row json =
  let* state = required_string_field json "state" in
  let* level = Result.bind (required_string_field json "level") level_of_wire in
  let* alarms =
    Result.bind
      (require_string_list json "alarms")
      (decode_list "alarms" alarm_of_wire)
  in
  let* () =
    if level = Librarian_level.level alarms
    then Ok ()
    else Error "writer level disagrees with its alarms"
  in
  let* request_behind =
    Result.bind (required_object_field json "request") decode_request_behind
  in
  let* () =
    if Bool.equal request_behind (List.mem Librarian_level.W2 alarms)
    then Ok ()
    else Error "writer alarm W2 disagrees with its request"
  in
  let* row =
    match state with
    | "booting" ->
      let* () = require_exact_object_fields "writer row" (shown_fields @ [ "unread" ]) json in
      let* () = require_null_field json "unread" in
      Ok Booting
    | "retired" ->
      let* () = require_exact_object_fields "writer row" shown_fields json in
      Ok Retired
    | "stopped" -> decode_stopped json
    | "idle" -> decode_open ~state:`Idle json
    | "asking" -> decode_open ~state:`Asking json
    | "resting" -> decode_open ~state:`Resting json
    | "refused_at_bottom" -> decode_open ~state:`Refused_at_bottom json
    | other -> unknown "state" other
  in
  Ok { level; alarms; row }
;;

let decode json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "none_in_process" ->
    let* () = require_exact_object_fields "writer" [ "kind" ] json in
    Ok None_in_process
  | "no_writer" ->
    let* () = require_exact_object_fields "writer" [ "kind" ] json in
    Ok No_writer
  | "writer" ->
    let* () = require_exact_object_fields "writer" [ "kind"; "row" ] json in
    let* shown = Result.bind (required_object_field json "row") decode_row in
    Ok (Writer shown)
  | other -> unknown "kind" other
;;
