module Http = Http_server_eio
module Digest = Agent_core.Checkpoint_objects
module Unwritable = Keeper_tool_memory_validation

let permission = Masc_domain.CanAdmin
let prefix = Server_dashboard_http_keeper_api_types.keeper_api_prefix

let route path =
  if not (String.starts_with ~prefix path)
  then None
  else (
    match
      String.sub path (String.length prefix) (String.length path - String.length prefix)
      |> String.split_on_char '/'
    with
    | [ keeper_name; "memory"; "act" ] when keeper_name <> "" -> Some keeper_name
    | _ -> None)
;;

type action =
  | Resume
  | Adopt of { observed : Digest.digest }
  | Restart_reading of { observed : Keeper_turn_log.Log_id.t }
  | Skip_item of { target : Librarian_machine.skip_target }
  | Skip_line of { offset : int }

(* The wire name of each action, from one closed list. *)
type kind =
  | Kind_resume
  | Kind_adopt
  | Kind_restart_reading
  | Kind_skip_item
  | Kind_skip_line

let kind_token = function
  | Kind_resume -> "resume"
  | Kind_adopt -> "adopt"
  | Kind_restart_reading -> "restart_reading"
  | Kind_skip_item -> "skip_item"
  | Kind_skip_line -> "skip_line"
;;

let kinds = [ Kind_resume; Kind_adopt; Kind_restart_reading; Kind_skip_item; Kind_skip_line ]
let kind_of_token token = List.find_opt (fun kind -> String.equal (kind_token kind) token) kinds
let field_action = "action"
let field_observed = "observed"
let field_target = "target"
let field_offset = "offset"

(* A skip's target, as the request names it and a [Not_the_head] refusal
   names the one now. *)
type target_kind =
  | Kind_head_item
  | Kind_unreadable_unit

let target_kind_token = function
  | Kind_head_item -> "head_item"
  | Kind_unreadable_unit -> "unreadable_unit"
;;

let target_kinds = [ Kind_head_item; Kind_unreadable_unit ]

let target_kind_of_token token =
  List.find_opt (fun kind -> String.equal (target_kind_token kind) token) target_kinds
;;

let field_kind = "kind"
let field_turn_log = "turn_log"
let field_line = "line"
let field_store = "store"
let field_at = "at"

let target_json : Librarian_machine.skip_target -> Yojson.Safe.t = function
  | Head_item { turn_log; line; item = { store; at } } ->
    `Assoc
      [ field_kind, `String (target_kind_token Kind_head_item)
      ; field_turn_log, `String (Keeper_turn_log.Log_id.to_string turn_log)
      ; field_line, `Int line
      ; field_store, `String (Librarian_log_codec.store_token store)
      ; field_at, `Int at
      ]
  | Unreadable_unit { turn_log; line } ->
    `Assoc
      [ field_kind, `String (target_kind_token Kind_unreadable_unit)
      ; field_turn_log, `String (Keeper_turn_log.Log_id.to_string turn_log)
      ; field_line, `Int line
      ]
;;

let request_shape =
  Printf.sprintf
    {|the request is {"%s":"%s"}, {"%s":"%s","%s":"<sha256 hex>"}, {"%s":"%s","%s":"<turn log id>"}, {"%s":"%s","%s":<offset>} or {"%s":"%s","%s":{"%s":"%s","%s":"<turn log id>","%s":<offset>,"%s":"<store>","%s":<index>}}, the last with "%s":"%s" and no %s or %s for a unit that does not read|}
    field_action (kind_token Kind_resume)
    field_action (kind_token Kind_adopt) field_observed
    field_action (kind_token Kind_restart_reading) field_observed
    field_action (kind_token Kind_skip_line) field_offset
    field_action (kind_token Kind_skip_item) field_target
    field_kind (target_kind_token Kind_head_item) field_turn_log field_line field_store field_at
    field_kind (target_kind_token Kind_unreadable_unit) field_store field_at
;;

let by_name (left, (_ : Yojson.Safe.t)) (right, (_ : Yojson.Safe.t)) = String.compare left right

(* Offsets and indexes are not negative, as a log line's are. *)
let not_negative name value = if value >= 0 then Ok value else Error (name ^ ": negative")

let target_of_fields fields : (Librarian_machine.skip_target, string) result =
  let ( let* ) = Result.bind in
  let turn_log text =
    match Keeper_turn_log.Log_id.of_string text with
    | Some id -> Ok id
    | None -> Error (field_turn_log ^ ": not a turn log id")
  in
  match List.sort by_name fields with
  | [ (at, `Int index); (kind, `String token); (line, `Int offset); (store, `String spelled)
    ; (log, `String id)
    ]
    when String.equal at field_at
         && String.equal kind field_kind
         && String.equal line field_line
         && String.equal store field_store
         && String.equal log field_turn_log
         && Option.equal ( = ) (target_kind_of_token token) (Some Kind_head_item) ->
    let* turn_log = turn_log id in
    let* line = not_negative field_line offset in
    let* at = not_negative field_at index in
    (match Librarian_log_codec.store_of_token spelled with
     | Some store -> Ok (Librarian_machine.Head_item { turn_log; line; item = { store; at } })
     | None -> Error (field_store ^ ": not a store"))
  | [ (kind, `String token); (line, `Int offset); (log, `String id) ]
    when String.equal kind field_kind
         && String.equal line field_line
         && String.equal log field_turn_log
         && Option.equal ( = ) (target_kind_of_token token) (Some Kind_unreadable_unit) ->
    let* turn_log = turn_log id in
    let* line = not_negative field_line offset in
    Ok (Librarian_machine.Unreadable_unit { turn_log; line })
  | _ -> Error request_shape
;;

let parse body =
  let adopt hex =
    match Digest.digest_of_hex hex with
    | Ok observed -> Ok (Adopt { observed })
    | Error detail -> Error (field_observed ^ ": " ^ detail)
  in
  let restart text =
    match Keeper_turn_log.Log_id.of_string text with
    | Some observed -> Ok (Restart_reading { observed })
    | None -> Error (field_observed ^ ": not a turn log id")
  in
  let skip fields =
    Result.map (fun target -> Skip_item { target }) (target_of_fields fields)
  in
  let skip_line value =
    Result.map (fun offset -> Skip_line { offset }) (not_negative field_offset value)
  in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  | `Assoc fields ->
    (match List.sort by_name fields with
     | [ (action, `String token) ] when String.equal action field_action ->
       (match kind_of_token token with
        | Some Kind_resume -> Ok Resume
        | Some (Kind_adopt | Kind_restart_reading | Kind_skip_item | Kind_skip_line) | None ->
          Error request_shape)
     | [ (action, `String token); (observed, `String value) ]
       when String.equal action field_action && String.equal observed field_observed ->
       (match kind_of_token token with
        | Some Kind_adopt -> adopt value
        | Some Kind_restart_reading -> restart value
        | Some (Kind_resume | Kind_skip_item | Kind_skip_line) | None -> Error request_shape)
     | [ (action, `String token); (offset, `Int value) ]
       when String.equal action field_action && String.equal offset field_offset ->
       (match kind_of_token token with
        | Some Kind_skip_line -> skip_line value
        | Some (Kind_resume | Kind_adopt | Kind_restart_reading | Kind_skip_item) | None ->
          Error request_shape)
     | [ (action, `String token); (target, `Assoc fields) ]
       when String.equal action field_action && String.equal target field_target ->
       (match kind_of_token token with
        | Some Kind_skip_item -> skip fields
        | Some (Kind_resume | Kind_adopt | Kind_restart_reading | Kind_skip_line) | None ->
          Error request_shape)
     | _ -> Error request_shape)
  | _ -> Error request_shape
;;

type store =
  | Open
  | Booting
  | Stopped of Librarian_store.stop
  | No_writer

type answer =
  | Acted of store
  | Refused of Librarian_machine.act_refusal
  | No_writers

let act ~base_path ~keeper ~actor action =
  match Keeper_memory_writers.find ~base_path with
  | None -> No_writers
  | Some writers ->
    let answer =
      match action with
      | Resume -> Librarian_writers.resume writers keeper
      | Adopt { observed } -> Librarian_writers.adopt writers keeper ~by:actor ~observed
      | Restart_reading { observed } -> Librarian_writers.restart_reading writers keeper ~observed
      | Skip_item { target } -> Librarian_writers.skip_item writers keeper ~by:actor ~target
      | Skip_line { offset } -> Librarian_writers.skip_line writers keeper ~offset
    in
    (match answer with
     | Not_done refusal -> Refused refusal
     | Done ->
       Acted
         (match Librarian_writers.view writers keeper with
          | Ok (_ : Librarian_writer.view) -> Open
          | Error `Booting -> Booting
          | Error (`Stopped stop) -> Stopped stop
          | Error `No_writer -> No_writer))
;;

let action_name = function
  | Resume -> kind_token Kind_resume
  | Adopt { observed = (_ : Digest.digest) } -> kind_token Kind_adopt
  | Restart_reading { observed = (_ : Keeper_turn_log.Log_id.t) } -> kind_token Kind_restart_reading
  | Skip_item { target = (_ : Librarian_machine.skip_target) } -> kind_token Kind_skip_item
  | Skip_line { offset = (_ : int) } -> kind_token Kind_skip_line
;;

(* A stopped store says why in the words the Memory tools use. A store whose
   log and snapshot disagree also names both snapshots: the one the file
   holds is what an adoption has to name. *)
let stop_fields (stop : Librarian_store.stop) =
  ( "stopped"
  , `String (Unwritable.memory_unwritable_to_string (Unwritable.Store_stopped stop)) )
  ::
  (match stop with
   | Log_diverged { expected; observed } ->
     [ "expected_snapshot", `String (expected :> string)
     ; "observed_snapshot", `String (observed :> string)
     ]
   | Raised { detail } -> [ "raised", `String detail ]
   | Memory_unreadable | Log_unreadable | Store_unwritable -> [])
;;

let store_fields = function
  | Open -> [ "store", `String "open" ]
  | Booting -> [ "store", `String "booting" ]
  | No_writer -> [ "store", `String "no_writer" ]
  | Stopped stop -> ("store", `String "stopped") :: stop_fields stop
;;

let refusal_fields : Librarian_machine.act_refusal -> (string * Yojson.Safe.t) list = function
  | Nothing_to_resume -> [ "code", `String "nothing_to_resume" ]
  | Not_stopped -> [ "code", `String "not_stopped" ]
  | Snapshot_mismatch -> [ "code", `String "snapshot_mismatch" ]
  | Snapshot_unreadable -> [ "code", `String "snapshot_unreadable" ]
  | Not_replaced -> [ "code", `String "not_replaced" ]
  | Turn_log_unread -> [ "code", `String "turn_log_unread" ]
  | Not_the_head { now } ->
    [ "code", `String "not_the_head"
    ; ( "now"
      , match now with
        | Some target -> target_json target
        | None -> `Null )
    ]
  | Not_the_faulted_line -> [ "code", `String "not_the_faulted_line" ]
  | Content_unread -> [ "code", `String "content_unread" ]
  | Act_unavailable (Store_stopped stop) -> ("code", `String "store_stopped") :: stop_fields stop
  | Act_unavailable Keeper_retired -> [ "code", `String "keeper_not_registered" ]
;;

let respond request reqd ~status fields =
  Http.Response.json_value
    ~status
    ~request
    ~extra_headers:[ "cache-control", "no-store" ]
    (`Assoc fields)
    reqd
;;

let handle_post state ~actor request reqd keeper_name body =
  match parse body with
  | Error detail ->
    respond request reqd ~status:`Bad_request
      [ "ok", `Bool false; "code", `String "invalid_request"; "error", `String detail ]
  | Ok action ->
    let config = Mcp_server.workspace_config state in
    let named = [ "keeper", `String keeper_name; "action", `String (action_name action) ] in
    let answer = act ~base_path:config.Workspace.base_path ~keeper:keeper_name ~actor action in
    Log.Keeper.info
      "admin Memory writer action keeper=%s actor=%s action=%s"
      keeper_name
      actor
      (action_name action);
    (match answer with
     | Acted store -> respond request reqd ~status:`OK ((("ok", `Bool true) :: named) @ store_fields store)
     | Refused refusal ->
       respond request reqd ~status:`Conflict
         ((("ok", `Bool false) :: named) @ refusal_fields refusal)
     | No_writers ->
       respond request reqd ~status:`Service_unavailable
         ((("ok", `Bool false) :: named) @ [ "code", `String "no_writer_in_process" ]))
;;
