(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module Conversation_id = Authz_id.Make ()
module Turn_id = Authz_id.Make ()

let ( let* ) = Result.bind
let ( let$ ) = Option.bind

type root = string

let directory_name = "keeper-conversations"
let index_name = "index.jsonl"
let turns_name = "turns.jsonl"
let cwd_name = "cwd"

(* The directories hold what a person asked and was answered. *)
let private_directory_mode = 0o700
let permission_bits = 0o777

let root ~base_path ~namespace =
  Filename.concat (Runtime_account_home_layout.person_runtime_root ~base_path ~namespace) directory_name
;;

type conversation =
  { conversation_id : Conversation_id.t
  ; provider_account_id : Provider_account_id.t
  }

type failure =
  | Not_signed_in
  | No_quota
  | Silent
  | Not_started
  | Configuration_refused
  | No_answer

type file =
  | Index
  | Turns

type error =
  | Not_written of string
  | Not_read of string
  | Row_not_understood of
      { file : file
      ; row : int
      }
  | Id_not_drawn of Authz_id.error

let file_name = function
  | Index -> index_name
  | Turns -> turns_name
;;

let error_to_string = function
  | Not_written detail -> "the conversation record was not written: " ^ detail
  | Not_read detail -> "the conversation record was not read: " ^ detail
  | Row_not_understood { file; row } ->
    Printf.sprintf "row %d of %s is not a row of the conversation record" row (file_name file)
  | Id_not_drawn error -> "the id drawn is not an id: " ^ Authz_id.error_to_string error
;;

(* The names of the rows and of their fields, as the files spell them. *)
let kind_field = "kind"
let conversation_field = "conversation_id"
let keeper_field = "keeper_id"
let account_field = "provider_account_id"
let turn_field = "turn_id"
let message_field = "message"
let text_field = "text"
let model_field = "model"
let session_field = "session_id"
let failure_field = "failure"
let at_field = "at_ms"
let started_kind = "started"
let asked_kind = "asked"
let answered_kind = "answered"
let failed_kind = "failed"

let failure_to_string = function
  | Not_signed_in -> "not_signed_in"
  | No_quota -> "no_quota"
  | Silent -> "silent"
  | Not_started -> "not_started"
  | Configuration_refused -> "configuration_refused"
  | No_answer -> "no_answer"
;;

let failures = [ Not_signed_in; No_quota; Silent; Not_started; Configuration_refused; No_answer ]

let failure_of_string name =
  List.find_opt (fun failure -> String.equal (failure_to_string failure) name) failures
;;

let row kind fields = Yojson.Safe.to_string (`Assoc ((kind_field, `String kind) :: fields)) ^ "\n"

let text_of fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None
;;

(* The fields of a row of [kind]: exactly [names] beside the kind, each once.
   The names differ, so as many fields as names, each name among them, is
   that. *)
let fields_of kind names = function
  | `Assoc fields ->
    let names = kind_field :: names in
    if
      List.compare_lengths fields names = 0
      && List.for_all (fun name -> List.mem_assoc name fields) names
      && Option.equal String.equal (text_of fields kind_field) (Some kind)
    then Some fields
    else None
  | _ -> None
;;

let time fields =
  match List.assoc_opt at_field fields with
  | Some (`Int at_ms) -> Some at_ms
  | Some _ | None -> None
;;

let id of_string fields name =
  let$ value = text_of fields name in
  Result.to_option (of_string value)
;;

type started =
  { conversation : conversation
  ; keeper_id : Keeper_id.t
  }

let started_of json =
  let$ fields = fields_of started_kind [ conversation_field; keeper_field; account_field; at_field ] json in
  let$ conversation_id = id Conversation_id.of_string fields conversation_field in
  let$ keeper_id = id Keeper_id.of_string fields keeper_field in
  let$ provider_account_id = id Provider_account_id.of_string fields account_field in
  let$ (_ : int) = time fields in
  Some { conversation = { conversation_id; provider_account_id }; keeper_id }
;;

(* What the turn that resumes reads of a row: the session an answered turn
   ran in. The other rows are read for being rows. *)
type turn_row =
  | Asked
  | Answered of { session_id : string }
  | Failed

let asked_of json =
  let$ fields = fields_of asked_kind [ turn_field; message_field; at_field ] json in
  let$ (_ : Turn_id.t) = id Turn_id.of_string fields turn_field in
  let$ (_ : string) = text_of fields message_field in
  let$ (_ : int) = time fields in
  Some Asked
;;

let answered_of json =
  let$ fields =
    fields_of answered_kind [ turn_field; text_field; model_field; session_field; at_field ] json
  in
  let$ (_ : Turn_id.t) = id Turn_id.of_string fields turn_field in
  let$ (_ : string) = text_of fields text_field in
  let$ (_ : string) = text_of fields model_field in
  let$ session_id = text_of fields session_field in
  let$ (_ : int) = time fields in
  Some (Answered { session_id })
;;

let failed_of json =
  let$ fields = fields_of failed_kind [ turn_field; failure_field; at_field ] json in
  let$ (_ : Turn_id.t) = id Turn_id.of_string fields turn_field in
  let$ name = text_of fields failure_field in
  let$ (_ : failure) = failure_of_string name in
  let$ (_ : int) = time fields in
  Some Failed
;;

let turn_row_of json =
  match asked_of json with
  | Some _ as asked -> asked
  | None ->
    (match answered_of json with
     | Some _ as answered -> answered
     | None -> failed_of json)
;;

(* The rows of the bytes of a file, each through [decode]. Every row ends in
   a newline, so what follows the last newline is empty. *)
let rows_of file decode bytes =
  let rec rows number read = function
    | [] | [ "" ] -> Ok (List.rev read)
    | text :: rest ->
      let decoded =
        match Yojson.Safe.from_string text with
        | exception Yojson.Json_error (_ : string) -> None
        | json -> decode json
      in
      (match decoded with
       | Some value -> rows (number + 1) (value :: read) rest
       | None -> Error (Row_not_understood { file; row = number }))
  in
  rows 1 [] (String.split_on_char '\n' bytes)
;;

(* The writer of a file reads it before it appends, so a row a stopped server
   left half written is cut as the append would cut it. *)
let read file decode path =
  match
    Eio_guard.run_in_systhread ~label:"keeper-conversation-read" (fun () ->
      Fs_compat.recover_private_jsonl_durable_locked_result path)
  with
  | Ok snapshot -> rows_of file decode snapshot.Fs_compat.bytes
  | Error error -> Error (Not_read (Fs_compat.private_jsonl_transaction_error_to_string error))
;;

let append path text =
  match
    Eio_guard.run_in_systhread ~label:"keeper-conversation-append" (fun () ->
      Fs_compat.append_private_jsonl_durable_stable_result path text
      |> Fs_compat.private_jsonl_cursor_success_receipt)
  with
  | Ok receipt ->
    (* The row is committed; what failed after it is closing the file. *)
    Option.iter
      (fun error ->
         Log.Server.warn
           "a conversation row was appended and its file was not settled: %s"
           (Fs_compat.private_jsonl_transaction_error_to_string error))
      receipt.Fs_compat.settlement_error;
    Ok ()
  | Error error -> Error (Not_written (Fs_compat.private_jsonl_transaction_error_to_string error))
;;

(* The runtime root of the person is there: the home of the account the turn
   runs on is under it. *)
let private_directory path =
  let refused detail = Error (Not_written (Printf.sprintf "%s: %s" path detail)) in
  match Unix.mkdir path private_directory_mode with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
    (* What is there is used only as the directory this module makes: not a
       file, not a link to another place, not a directory others can enter. *)
    (match Unix.lstat path with
     | { Unix.st_kind = Unix.S_DIR; st_perm; _ } ->
       if Int.equal (st_perm land permission_bits) private_directory_mode
       then Ok ()
       else refused (Printf.sprintf "its mode is %o" (st_perm land permission_bits))
     | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
       refused "it is not a directory"
     | exception Unix.Unix_error (error, _, _) -> refused (Unix.error_message error))
  | exception Unix.Unix_error (error, _, _) -> refused (Unix.error_message error)
;;

let now_field now_ms = at_field, `Int (now_ms ())

(* Orders reading the index and appending a [started] row to it. The account
   server is the one process that writes the records. A reader that raises
   leaves the files as the last append left them, so the lock is not
   poisoned. *)
let index_lock = Eio.Mutex.create ()

let append_started ~index keeper_id provider_account_id ~draw ~now_ms =
  let* conversation_id =
    Conversation_id.of_string (draw ()) |> Result.map_error (fun error -> Id_not_drawn error)
  in
  let* () =
    append
      index
      (row
         started_kind
         [ conversation_field, `String (Conversation_id.to_string conversation_id)
         ; keeper_field, `String (Keeper_id.to_string keeper_id)
         ; account_field, `String (Provider_account_id.to_string provider_account_id)
         ; now_field now_ms
         ])
  in
  Ok { conversation_id; provider_account_id }
;;

let start root keeper_id provider_account_id ~draw ~now_ms =
  Eio.Mutex.use_ro index_lock (fun () ->
    let* () = private_directory root in
    append_started ~index:(Filename.concat root index_name) keeper_id provider_account_id ~draw ~now_ms)
;;

let current_or_start root keeper_id provider_account_id ~draw ~now_ms =
  Eio.Mutex.use_ro index_lock (fun () ->
    let* () = private_directory root in
    let index = Filename.concat root index_name in
    let* started = read Index started_of index in
    let last =
      List.fold_left
        (fun last (started : started) ->
           if Keeper_id.equal started.keeper_id keeper_id then Some started.conversation else last)
        None
        started
    in
    match last with
    | Some conversation -> Ok conversation
    | None -> append_started ~index keeper_id provider_account_id ~draw ~now_ms)
;;

type turn =
  { turns : string
  ; cwd : string
  ; session_id : string option
  }

let cwd turn = turn.cwd
let session_id turn = turn.session_id

let open_turn root (conversation : conversation) =
  let directory = Filename.concat root (Conversation_id.to_string conversation.conversation_id) in
  let turns = Filename.concat directory turns_name in
  let* () = private_directory directory in
  let* rows = read Turns turn_row_of turns in
  let session_id =
    List.fold_left
      (fun last -> function
         | Answered { session_id } -> Some session_id
         | Asked | Failed -> last)
      None
      rows
  in
  let cwd = Filename.concat directory cwd_name in
  let* () = private_directory cwd in
  (* macOS spells a temporary base path through the /var link, and the client
     gets the real path as its directory. *)
  match Unix.realpath cwd with
  | cwd -> Ok { turns; cwd; session_id }
  | exception Unix.Unix_error (error, _, _) ->
    Error (Not_written (Printf.sprintf "%s: %s" cwd (Unix.error_message error)))
;;

type asked =
  { turns : string
  ; turn_id : Turn_id.t
  }

let ask (turn : turn) ~message ~draw ~now_ms =
  let* turn_id = Turn_id.of_string (draw ()) |> Result.map_error (fun error -> Id_not_drawn error) in
  let* () =
    append
      turn.turns
      (row
         asked_kind
         [ turn_field, `String (Turn_id.to_string turn_id)
         ; message_field, `String message
         ; now_field now_ms
         ])
  in
  Ok { turns = turn.turns; turn_id }
;;

let answered (asked : asked) ~text ~model ~session_id ~now_ms =
  append
    asked.turns
    (row
       answered_kind
       [ turn_field, `String (Turn_id.to_string asked.turn_id)
       ; text_field, `String text
       ; model_field, `String model
       ; session_field, `String session_id
       ; now_field now_ms
       ])
;;

let failed (asked : asked) failure ~now_ms =
  append
    asked.turns
    (row
       failed_kind
       [ turn_field, `String (Turn_id.to_string asked.turn_id)
       ; failure_field, `String (failure_to_string failure)
       ; now_field now_ms
       ])
;;
