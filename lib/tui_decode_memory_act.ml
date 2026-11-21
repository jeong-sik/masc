open Tui_decode_fields

let ( let* ) = Result.bind

module Writer = Tui_decode_memory_writer

type act =
  | Resume
  | Adopt of { observed : string }
  | Restart_reading of { observed : string }
  | Skip_unreadable_unit of
      { turn_log : string
      ; line : int
      }

(* What the last read's end leaves for the operator to pass (§12.4). A
   replaced turn log restarts on the id the disk has now, a lost position on
   the id the tail names: the same file. A unit whose content does not read is
   skipped in the turn log reading stands in, the one the tail names. *)
let reading_acts ~turn_log (kept : Writer.kept) =
  match kept.Writer.last_read with
  | Some
      (Writer.Read_input_fault
        (Writer.Turn_log_replaced { expected = (_ : string); observed = Some observed })) ->
    [ Restart_reading { observed } ]
  | Some (Writer.Read_input_fault (Writer.Position_lost { offset = (_ : int); length = (_ : int) }))
    -> [ Restart_reading { observed = turn_log } ]
  | Some (Writer.Read_input_fault (Writer.Content_unreadable { line })) ->
    [ Skip_unreadable_unit { turn_log; line } ]
  | Some
      (Writer.Read_input_fault
        (Writer.Turn_log_replaced { expected = (_ : string); observed = None }))
  | Some (Writer.Read_input_fault (Writer.Line_unreadable { offset = (_ : int) }))
  | Some (Writer.Read_committed | Writer.Read_lane _ | Writer.Read_ask_failed _)
  | None -> []
;;

let offered (row : Writer.row) =
  match row with
  | Writer.Booting | Writer.Retired -> []
  | Writer.Stopped { stop; snapshot_file; kept = (_ : Writer.kept) } ->
    let adopt =
      match stop, snapshot_file with
      | (Writer.Log_diverged | Writer.Log_unreadable), Writer.File { sha; bytes = (_ : int) } ->
        [ Adopt { observed = sha } ]
      | ( (Writer.Log_diverged | Writer.Log_unreadable)
        , (Writer.File_absent | Writer.File_not_a_snapshot | Writer.File_not_read) )
      | ( (Writer.Memory_unreadable | Writer.Store_unwritable | Writer.Store_raised)
        , (Writer.File _ | Writer.File_absent | Writer.File_not_a_snapshot | Writer.File_not_read) )
        -> []
    in
    Resume :: adopt
  | Writer.Open { activity; kept; turn_log; _ } ->
    let resume =
      match activity with
      | Writer.Resting | Writer.Refused_at_bottom -> [ Resume ]
      | Writer.Idle | Writer.Asking _ -> []
    in
    resume @ reading_acts ~turn_log kept
;;

let act_token = function
  | Resume -> "resume"
  | Adopt { observed = (_ : string) } -> "adopt"
  | Restart_reading { observed = (_ : string) } -> "restart_reading"
  | Skip_unreadable_unit { turn_log = (_ : string); line = (_ : int) } -> "skip_item"
;;

let equal_act left right =
  match left, right with
  | Resume, Resume -> true
  | Adopt { observed = left }, Adopt { observed = right }
  | Restart_reading { observed = left }, Restart_reading { observed = right } ->
    String.equal left right
  | ( Skip_unreadable_unit { turn_log = left_log; line = left_line }
    , Skip_unreadable_unit { turn_log = right_log; line = right_line } ) ->
    String.equal left_log right_log && Int.equal left_line right_line
  | (Resume | Adopt _ | Restart_reading _ | Skip_unreadable_unit _), _ -> false
;;

let step offered ~armed =
  let first = List.nth_opt offered 0 in
  match armed with
  | None -> first
  | Some current ->
    let rec after = function
      | [] -> first
      | act :: rest when equal_act act current ->
        (match rest with
         | next :: _ -> Some next
         | [] -> first)
      | (_ : act) :: rest -> after rest
    in
    after offered
;;

let request act : Yojson.Safe.t =
  let action = "action", `String (act_token act) in
  match act with
  | Resume -> `Assoc [ action ]
  | Adopt { observed } | Restart_reading { observed } ->
    `Assoc [ action; "observed", `String observed ]
  | Skip_unreadable_unit { turn_log; line } ->
    `Assoc
      [ action
      ; ( "target"
        , `Assoc
            [ "kind", `String "unreadable_unit"
            ; "turn_log", `String turn_log
            ; "line", `Int line
            ] )
      ]
;;

type stop_detail =
  | Plain
  | Diverged of
      { expected : string
      ; observed : string
      }
  | Raised of string

type stop =
  { stopped : string
  ; detail : stop_detail
  }

type store =
  | Store_open
  | Store_booting
  | Store_no_writer
  | Store_stopped of stop

type target =
  | Head_item of
      { turn_log : string
      ; line : int
      ; store : string
      ; at : int
      }
  | Unreadable_unit of
      { turn_log : string
      ; line : int
      }

type refusal =
  | Nothing_to_resume
  | Not_stopped
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Not_replaced
  | Turn_log_unread
  | Not_the_head of target option
  | Content_unread
  | Refused_store_stopped of stop
  | Keeper_not_registered

type answer =
  | Done of store
  | Refused of refusal
  | Invalid_request of string
  | No_writer_in_process

let has json name = Option.is_some (Json_util.assoc_member_opt name json)

(* A stopped store names its stop in the server's sentence, with the fields
   the server adds: both snapshots for a diverged log, the detail of a raise.
   The names of the fields it read come back for the exact-field check. *)
let decode_stop json =
  let* stopped = required_string_field json "stopped" in
  match has json "expected_snapshot", has json "raised" with
  | true, false ->
    let* expected = required_string_field json "expected_snapshot" in
    let* observed = required_string_field json "observed_snapshot" in
    Ok
      ( { stopped; detail = Diverged { expected; observed } }
      , [ "stopped"; "expected_snapshot"; "observed_snapshot" ] )
  | false, true ->
    let* raised = required_string_field json "raised" in
    Ok ({ stopped; detail = Raised raised }, [ "stopped"; "raised" ])
  | false, false -> Ok ({ stopped; detail = Plain }, [ "stopped" ])
  | true, true -> Error "a stop names both diverged snapshots and a raise"
;;

let decode_target json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "head_item" ->
    let* () =
      require_exact_object_fields "now" [ "kind"; "turn_log"; "line"; "store"; "at" ] json
    in
    let* turn_log = required_string_field json "turn_log" in
    let* line = required_nonnegative_int_field json "line" in
    let* store = required_string_field json "store" in
    let* at = required_nonnegative_int_field json "at" in
    Ok (Head_item { turn_log; line; store; at })
  | "unreadable_unit" ->
    let* () = require_exact_object_fields "now" [ "kind"; "turn_log"; "line" ] json in
    let* turn_log = required_string_field json "turn_log" in
    let* line = required_nonnegative_int_field json "line" in
    Ok (Unreadable_unit { turn_log; line })
  | other -> Error ("now: unknown kind " ^ other)
;;

let decode_refusal json = function
  | "nothing_to_resume" -> Ok (Nothing_to_resume, [])
  | "not_stopped" -> Ok (Not_stopped, [])
  | "snapshot_mismatch" -> Ok (Snapshot_mismatch, [])
  | "snapshot_unreadable" -> Ok (Snapshot_unreadable, [])
  | "not_replaced" -> Ok (Not_replaced, [])
  | "turn_log_unread" -> Ok (Turn_log_unread, [])
  | "content_unread" -> Ok (Content_unread, [])
  | "keeper_not_registered" -> Ok (Keeper_not_registered, [])
  | "not_the_head" ->
    let* now = required_member json "now" in
    (match now with
     | `Null -> Ok (Not_the_head None, [ "now" ])
     | target ->
       let* target = decode_target target in
       Ok (Not_the_head (Some target), [ "now" ]))
  | "store_stopped" ->
    let* (stop, fields) = decode_stop json in
    Ok (Refused_store_stopped stop, fields)
  | other -> Error ("code: unknown " ^ other)
;;

let decode_store json = function
  | "open" -> Ok (Store_open, [])
  | "booting" -> Ok (Store_booting, [])
  | "no_writer" -> Ok (Store_no_writer, [])
  | "stopped" ->
    let* (stop, fields) = decode_stop json in
    Ok (Store_stopped stop, fields)
  | other -> Error ("store: unknown " ^ other)
;;

let named_fields = [ "ok"; "keeper"; "action" ]

(* An answer names the Keeper and the act it answers; a body about another
   one is not this act's answer. *)
let check_named ~keeper ~act json =
  let* answered = required_string_field json "keeper" in
  let* action = required_string_field json "action" in
  if not (String.equal answered keeper)
  then Error ("keeper: answers " ^ answered)
  else if not (String.equal action (act_token act))
  then Error ("action: answers " ^ action)
  else Ok ()
;;

let decode_done ~keeper ~act json =
  let* () = check_named ~keeper ~act json in
  let* token = required_string_field json "store" in
  let* (store, fields) = decode_store json token in
  let* () = require_exact_object_fields "answer" (named_fields @ ("store" :: fields)) json in
  Ok (Done store)
;;

let decode_refused ~keeper ~act json =
  let* () = check_named ~keeper ~act json in
  let* code = required_string_field json "code" in
  let* (refusal, fields) = decode_refusal json code in
  let* () = require_exact_object_fields "answer" (named_fields @ ("code" :: fields)) json in
  Ok (Refused refusal)
;;

let decode_invalid json =
  let* () = require_exact_object_fields "answer" [ "ok"; "code"; "error" ] json in
  let* code = required_string_field json "code" in
  let* error = required_string_field json "error" in
  match code with
  | "invalid_request" -> Ok (Invalid_request error)
  | other -> Error ("code: unknown " ^ other)
;;

let decode_no_writer ~keeper ~act json =
  let* () = require_exact_object_fields "answer" (named_fields @ [ "code" ]) json in
  let* () = check_named ~keeper ~act json in
  let* code = required_string_field json "code" in
  match code with
  | "no_writer_in_process" -> Ok No_writer_in_process
  | other -> Error ("code: unknown " ^ other)
;;

let expect_ok json expected =
  let* ok = required_bool_field json "ok" in
  if Bool.equal ok expected then Ok () else Error (Printf.sprintf "ok: %b" ok)
;;

(* 200, 400, 409 and 503 are the route's own answers. Another status comes
   from before the route -- the credential, a route this server lacks -- or
   from a crash. *)
let read_answer ~keeper ~act ~status_code ~body =
  let decode ~ok decoder =
    Some
      (match Yojson.Safe.from_string body with
       | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
       | json ->
         let* () = expect_ok json ok in
         decoder json)
  in
  match status_code with
  | 200 -> decode ~ok:true (decode_done ~keeper ~act)
  | 409 -> decode ~ok:false (decode_refused ~keeper ~act)
  | 400 -> decode ~ok:false decode_invalid
  | 503 -> decode ~ok:false (decode_no_writer ~keeper ~act)
  | (_ : int) -> None
;;

let act_text act =
  match act with
  | Resume -> act_token act
  | Adopt { observed } | Restart_reading { observed } -> act_token act ^ " " ^ observed
  | Skip_unreadable_unit { turn_log; line } ->
    Printf.sprintf "%s unreadable_unit %s:%d" (act_token act) turn_log line
;;

let stop_text { stopped; detail } =
  match detail with
  | Plain -> stopped
  | Diverged { expected; observed } ->
    Printf.sprintf "%s expected_snapshot=%s observed_snapshot=%s" stopped expected observed
  | Raised raised -> Printf.sprintf "%s raised=%s" stopped raised
;;

let store_text = function
  | Store_open -> "store=open"
  | Store_booting -> "store=booting"
  | Store_no_writer -> "store=no_writer"
  | Store_stopped stop -> "store=stopped stopped=" ^ stop_text stop
;;

let target_text = function
  | Head_item { turn_log; line; store; at } ->
    Printf.sprintf "head_item %s:%d %s#%d" turn_log line store at
  | Unreadable_unit { turn_log; line } -> Printf.sprintf "unreadable_unit %s:%d" turn_log line
;;

(* The refusal's code and what it carries, in the wire's words. *)
let refusal_text = function
  | Nothing_to_resume -> "code=nothing_to_resume"
  | Not_stopped -> "code=not_stopped"
  | Snapshot_mismatch -> "code=snapshot_mismatch"
  | Snapshot_unreadable -> "code=snapshot_unreadable"
  | Not_replaced -> "code=not_replaced"
  | Turn_log_unread -> "code=turn_log_unread"
  | Not_the_head None -> "code=not_the_head now=null"
  | Not_the_head (Some now) -> "code=not_the_head now=" ^ target_text now
  | Content_unread -> "code=content_unread"
  | Refused_store_stopped stop -> "code=store_stopped stopped=" ^ stop_text stop
  | Keeper_not_registered -> "code=keeper_not_registered"
;;

(* The verdict and the server's words lead and the Keeper closes the line:
   the footer cuts a long notice from its end, and the row on screen already
   names the Keeper. *)
let answer_text ~ko ~keeper act answer =
  let said accepted words =
    match ko, accepted with
    | true, true -> Printf.sprintf "%s 받음: %s · %s 기억 쓰는 쪽" (act_token act) words keeper
    | true, false -> Printf.sprintf "%s 거절: %s · %s 기억 쓰는 쪽" (act_token act) words keeper
    | false, true -> Printf.sprintf "%s accepted: %s · %s Memory writer" (act_token act) words keeper
    | false, false -> Printf.sprintf "%s refused: %s · %s Memory writer" (act_token act) words keeper
  in
  match answer with
  | Done store -> said true (store_text store)
  | Refused refusal -> said false (refusal_text refusal)
  | Invalid_request error -> said false ("code=invalid_request error=" ^ error)
  | No_writer_in_process -> said false "code=no_writer_in_process"
;;
