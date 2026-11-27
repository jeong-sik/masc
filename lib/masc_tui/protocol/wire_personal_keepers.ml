open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let keepers_path = "/api/v1/auth/keepers"
let assign_path = "/api/v1/auth/keepers/assign"
let turn_path = "/api/v1/auth/keepers/turn"
let conversation_path = "/api/v1/auth/keepers/conversation"

let conversation_read_path ~keeper_id ?conversation_id () =
  let base =
    conversation_path ^ "?keeper_id=" ^ percent_encode (String.trim keeper_id)
  in
  match conversation_id with
  | None -> base
  | Some cid -> base ^ "&conversation_id=" ^ percent_encode (String.trim cid)

let conversation_delete_path ~conversation_id =
  conversation_path ^ "/" ^ percent_encode (String.trim conversation_id)

let max_keeper_id_length = 128
let max_authz_id_length = 255
let max_message_bytes = 4096
let turn_timeout_sec = 130.0

(* Reserved root store directory names rejected by [Common.is_keepers_root_store_dirname]. *)
let reserved_keeper_store_dirnames =
  [ "tool_usage"; ".shutdown-operations"; ".configuration-removals" ]

let is_portable_keeper_char = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
  | _ -> false

let has_ascii_uppercase s =
  let len = String.length s in
  let rec loop i =
    if i >= len then false
    else
      match s.[i] with
      | 'A' .. 'Z' -> true
      | _ -> loop (i + 1)
  in
  loop 0

let is_authz_id_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | ':' | '-' -> true
  | _ -> false

let all_chars_satisfy pred s =
  let len = String.length s in
  let rec loop i =
    if i >= len then true
    else if pred s.[i] then loop (i + 1)
    else false
  in
  loop 0

let validate_keeper_id raw =
  let trimmed = String.trim raw in
  let len = String.length trimmed in
  if len = 0 then Error "Keeper ID is required"
  else if String.equal trimmed "." || String.equal trimmed ".." then
    Error "Keeper ID cannot be reserved path segment '.' or '..'"
  else if len > max_keeper_id_length then
    Error
      (Printf.sprintf "Keeper ID length %d exceeds maximum %d bytes" len
         max_keeper_id_length)
  else if has_ascii_uppercase trimmed then
    Error "Keeper ID must be lowercase (only [a-z0-9._-])"
  else if not (all_chars_satisfy is_portable_keeper_char trimmed) then
    Error "Keeper ID may only contain [a-z0-9._-]"
  else if
    List.exists
      (String.equal trimmed)
      reserved_keeper_store_dirnames
  then
    Error
      (Printf.sprintf "Keeper ID %S is a reserved runtime store directory name"
         trimmed)
  else Ok trimmed

let validate_authz_id ~field raw =
  let trimmed = String.trim raw in
  let len = String.length trimmed in
  if len = 0 then Error (Printf.sprintf "%s is required" field)
  else if String.equal trimmed "." || String.equal trimmed ".." then
    Error (Printf.sprintf "%s cannot be '.' or '..'" field)
  else if len > max_authz_id_length then
    Error
      (Printf.sprintf "%s length %d exceeds maximum %d bytes" field len
         max_authz_id_length)
  else if not (all_chars_satisfy is_authz_id_char trimmed) then
    Error (Printf.sprintf "%s may only contain [A-Za-z0-9._:-]" field)
  else Ok trimmed

type turn_message_error =
  | Message_blank
  | Message_too_long of { bytes : int; max_bytes : int }

let validate_turn_message raw =
  if String.equal (String.trim raw) "" then Error Message_blank
  else
    let bytes = String.length raw in
    if bytes > max_message_bytes then
      Error (Message_too_long { bytes; max_bytes = max_message_bytes })
    else Ok raw

(* ---- Types ---- *)

type personal_keeper = {
  keeper_id : string;
  runtime_id : string option;
}

type make_record =
  | Record_made
  | Record_existing

let equal_make_record a b =
  match (a, b) with
  | Record_made, Record_made | Record_existing, Record_existing -> true
  | Record_made, Record_existing | Record_existing, Record_made -> false

let make_record_to_string = function
  | Record_made -> "made"
  | Record_existing -> "existing"

type made_keeper = {
  keeper_id : string;
  record : make_record;
}

type assign_record =
  | Record_assigned
  | Record_assign_existing

let equal_assign_record a b =
  match (a, b) with
  | Record_assigned, Record_assigned
  | Record_assign_existing, Record_assign_existing ->
      true
  | Record_assigned, Record_assign_existing
  | Record_assign_existing, Record_assigned ->
      false

let assign_record_to_string = function
  | Record_assigned -> "assigned"
  | Record_assign_existing -> "existing"

type assigned_keeper = {
  keeper_id : string;
  runtime_id : string;
  record : assign_record;
}

type conversation_deletion =
  | Deletion_kept
  | Deletion_failed

let equal_conversation_deletion a b =
  match (a, b) with
  | Deletion_kept, Deletion_kept | Deletion_failed, Deletion_failed -> true
  | Deletion_kept, Deletion_failed | Deletion_failed, Deletion_kept -> false

type conversation_summary = {
  conversation_id : string;
  provider_account_id : string;
  started_at_ms : int;
  deletion : conversation_deletion;
}

type turn_failure =
  | Failure_not_signed_in
  | Failure_key_refused
  | Failure_no_quota
  | Failure_silent
  | Failure_not_started
  | Failure_configuration_refused
  | Failure_no_answer
  | Failure_unrecognised of string

let turn_failure_rank = function
  | Failure_not_signed_in -> 0
  | Failure_key_refused -> 1
  | Failure_no_quota -> 2
  | Failure_silent -> 3
  | Failure_not_started -> 4
  | Failure_configuration_refused -> 5
  | Failure_no_answer -> 6
  | Failure_unrecognised _ -> 7

let equal_turn_failure a b =
  if not (Int.equal (turn_failure_rank a) (turn_failure_rank b)) then false
  else
    match (a, b) with
    | Failure_not_signed_in, Failure_not_signed_in
    | Failure_key_refused, Failure_key_refused
    | Failure_no_quota, Failure_no_quota
    | Failure_silent, Failure_silent
    | Failure_not_started, Failure_not_started
    | Failure_configuration_refused, Failure_configuration_refused
    | Failure_no_answer, Failure_no_answer ->
        true
    | Failure_unrecognised x, Failure_unrecognised y -> String.equal x y
    | ( ( Failure_not_signed_in
        | Failure_key_refused
        | Failure_no_quota
        | Failure_silent
        | Failure_not_started
        | Failure_configuration_refused
        | Failure_no_answer
        | Failure_unrecognised _ )
      , ( Failure_not_signed_in
        | Failure_key_refused
        | Failure_no_quota
        | Failure_silent
        | Failure_not_started
        | Failure_configuration_refused
        | Failure_no_answer
        | Failure_unrecognised _ ) ) ->
        false

let turn_failure_of_string = function
  | "not_signed_in" -> Failure_not_signed_in
  | "key_refused" -> Failure_key_refused
  | "no_quota" -> Failure_no_quota
  | "silent" -> Failure_silent
  | "not_started" -> Failure_not_started
  | "configuration_refused" -> Failure_configuration_refused
  | "no_answer" -> Failure_no_answer
  | other -> Failure_unrecognised other

let turn_failure_to_string = function
  | Failure_not_signed_in -> "not_signed_in"
  | Failure_key_refused -> "key_refused"
  | Failure_no_quota -> "no_quota"
  | Failure_silent -> "silent"
  | Failure_not_started -> "not_started"
  | Failure_configuration_refused -> "configuration_refused"
  | Failure_no_answer -> "no_answer"
  | Failure_unrecognised raw -> raw

let turn_failure_say = function
  | Failure_not_signed_in ->
      Say.make
        ~ko:"프로바이더 계정이 로그인되어 있지 않습니다 (@ 계정에서 다시 로그인하세요)"
        ~en:"Runtime provider account is not signed in (re-login in @ Account)"
  | Failure_key_refused ->
      Say.make
        ~ko:"프로바이더가 API 키를 거부했습니다 (@ 계정에서 키를 교체하세요)"
        ~en:"Provider refused the API key (rotate key in @ Account)"
  | Failure_no_quota ->
      Say.make ~ko:"이 런타임 구독의 남은 할당량이 없습니다"
        ~en:"Runtime subscription has no quota remaining"
  | Failure_silent ->
      Say.make ~ko:"클라이언트가 제한 시간 동안 응답하지 않았습니다"
        ~en:"Client sent no response before timeout"
  | Failure_not_started ->
      Say.make ~ko:"모델 클라이언트를 시작하지 못했습니다"
        ~en:"Model client did not start"
  | Failure_configuration_refused ->
      Say.make ~ko:"클라이언트가 런타임 설정을 거부했습니다"
        ~en:"Client refused the runtime configuration"
  | Failure_no_answer ->
      Say.make
        ~ko:"응답 없이 턴이 종료되었습니다 (반복되면 [N]으로 새 대화를 시작하세요)"
        ~en:"Turn ended without an answer (press [N] for a new conversation if repeated)"
  | Failure_unrecognised raw ->
      Say.make
        ~ko:("알 수 없는 실패 코드: " ^ raw)
        ~en:("Unrecognised turn failure: " ^ raw)

type turn_outcome =
  | Turn_answered of {
      text : string;
      model : string;
      answered_at_ms : int;
    }
  | Turn_failed of {
      failure : turn_failure;
      failed_at_ms : int;
      model_may_have_read : bool;
    }
  | Turn_unrecorded of { model_may_have_read : bool }

type conversation_turn = {
  message : string;
  asked_at_ms : int;
  outcome : turn_outcome;
}

type conversation_snapshot = {
  keeper_id : string;
  current_conversation_id : string option;
  conversations : conversation_summary list;
  conversation_id : string option;
  turns : conversation_turn list;
}

type started_conversation = {
  keeper_id : string;
  conversation_id : string;
}

type turn_recording =
  | Turn_recorded of {
      conversation_id : string;
      continued : bool;
    }
  | Turn_ephemeral

type turn_answer = {
  keeper_id : string;
  runtime_id : string;
  model : string;
  text : string;
  recording : turn_recording;
}

type vendor_copy_state =
  | Vendor_copy_removed
  | Vendor_copy_none
  | Vendor_copy_may_remain

let vendor_copy_state_rank = function
  | Vendor_copy_removed -> 0
  | Vendor_copy_none -> 1
  | Vendor_copy_may_remain -> 2

let equal_vendor_copy_state a b =
  Int.equal (vendor_copy_state_rank a) (vendor_copy_state_rank b)

let vendor_copy_state_to_string = function
  | Vendor_copy_removed -> "removed"
  | Vendor_copy_none -> "none"
  | Vendor_copy_may_remain -> "may_remain"

let vendor_copy_state_of_string = function
  | "removed" -> Ok Vendor_copy_removed
  | "none" -> Ok Vendor_copy_none
  | "may_remain" -> Ok Vendor_copy_may_remain
  | other -> Error (Printf.sprintf "unknown vendor_copy state %S" other)

let vendor_copy_outcome_say = function
  | Vendor_copy_removed ->
      Say.make
        ~ko:"대화 기록과 공급자 사본을 모두 삭제했습니다 (vendor_copy: removed)"
        ~en:"Conversation and vendor copy removed (vendor_copy: removed)"
  | Vendor_copy_none ->
      Say.make ~ko:"대화 기록을 삭제했습니다 (vendor_copy: none)"
        ~en:"Conversation deleted (vendor_copy: none)"
  | Vendor_copy_may_remain ->
      Say.make
        ~ko:"로컬 대화 기록은 삭제했으나 공급자 사본이 남아 있을 수 있습니다 (vendor_copy: may_remain)"
        ~en:"Local conversation deleted; vendor copy may remain (vendor_copy: may_remain)"

type deleted_conversation = {
  conversation_id : string;
  vendor_copy : vendor_copy_state;
}

(* ---- Strict Encoders ---- *)

let encode_make_keeper ~keeper_id =
  `Assoc [ ("keeper_id", `String (String.trim keeper_id)) ]

let encode_assign_keeper ~keeper_id ~runtime_id =
  (* Strict server key order: keeper_id first, runtime_id second. *)
  `Assoc
    [
      ("keeper_id", `String (String.trim keeper_id));
      ("runtime_id", `String (String.trim runtime_id));
    ]

let encode_start_conversation ~keeper_id =
  `Assoc [ ("keeper_id", `String (String.trim keeper_id)) ]

let encode_turn ~keeper_id ~message =
  `Assoc
    [
      ("keeper_id", `String (String.trim keeper_id));
      ("message", `String message);
    ]

(* ---- Strict Field Helpers ---- *)

let require_object ~context = function
  | `Assoc _ as obj -> Ok obj
  | bad -> field_type_error context "an object" bad

let assoc_member_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _
  | `Tuple _ | `Variant _ ->
      None

let required_bool_field json key =
  let* value = required_member json key in
  match value with
  | `Bool b -> Ok b
  | bad -> field_type_error key "a boolean" bad

let required_nonneg_timestamp_ms json key =
  let* v = required_int_field json key in
  if v < 0 then
    Error (Printf.sprintf "field %S must be a non-negative timestamp_ms" key)
  else Ok v

let required_nullable_nonblank_string json key =
  let* value = required_member json key in
  match value with
  | `Null -> Ok None
  | `String s ->
      let trimmed = String.trim s in
      if String.equal trimmed "" then
        Error (Printf.sprintf "field %S must not be blank" key)
      else Ok (Some trimmed)
  | bad -> field_type_error key "a string or null" bad

(* ---- Fail-Closed Response Decoders ---- *)

let decode_personal_keeper json =
  let* obj = require_object ~context:"personal_keeper" json in
  let* keeper_id = required_nonblank_string obj "keeper_id" in
  let* runtime_id = required_nullable_nonblank_string obj "runtime_id" in
  Ok { keeper_id; runtime_id }

let decode_keepers_list json =
  let* obj = require_object ~context:keepers_path json in
  let* items = required_list_field obj "keepers" in
  let* rows = decode_list "keepers" decode_personal_keeper items in
  let seen = Hashtbl.create (List.length rows) in
  let rec check_dups = function
    | [] -> Ok rows
    | (k : personal_keeper) :: rest ->
        if Hashtbl.mem seen k.keeper_id then
          Error
            (Printf.sprintf "duplicate keeper_id %S in %s response" k.keeper_id
               keepers_path)
        else (
          Hashtbl.add seen k.keeper_id ();
          check_dups rest)
  in
  check_dups rows

let decode_made_keeper ~expected_keeper_id json =
  let* obj = require_object ~context:("POST " ^ keepers_path) json in
  let* keeper_id = required_nonblank_string obj "keeper_id" in
  let* () =
    if String.equal keeper_id expected_keeper_id then Ok ()
    else
      Error
        (Printf.sprintf "POST %s returned keeper_id %S (expected %S)"
           keepers_path keeper_id expected_keeper_id)
  in
  let* rec_raw = required_nonblank_string obj "record" in
  let* record =
    match rec_raw with
    | "made" -> Ok Record_made
    | "existing" -> Ok Record_existing
    | other -> Error (Printf.sprintf "unknown make record %S" other)
  in
  Ok { keeper_id; record }

let decode_assigned_keeper ~expected_keeper_id ~expected_runtime_id json =
  let* obj = require_object ~context:("POST " ^ assign_path) json in
  let* keeper_id = required_nonblank_string obj "keeper_id" in
  let* runtime_id = required_nonblank_string obj "runtime_id" in
  let* () =
    if String.equal keeper_id expected_keeper_id then Ok ()
    else
      Error
        (Printf.sprintf "POST %s returned keeper_id %S (expected %S)" assign_path
           keeper_id expected_keeper_id)
  in
  let* () =
    if String.equal runtime_id expected_runtime_id then Ok ()
    else
      Error
        (Printf.sprintf "POST %s returned runtime_id %S (expected %S)"
           assign_path runtime_id expected_runtime_id)
  in
  let* rec_raw = required_nonblank_string obj "record" in
  let* record =
    match rec_raw with
    | "assigned" -> Ok Record_assigned
    | "existing" -> Ok Record_assign_existing
    | other -> Error (Printf.sprintf "unknown assign record %S" other)
  in
  Ok { keeper_id; runtime_id; record }

let decode_conversation_summary json =
  let* obj = require_object ~context:"conversation_summary" json in
  let* conversation_id = required_nonblank_string obj "conversation_id" in
  let* provider_account_id =
    required_nonblank_string obj "provider_account_id"
  in
  let* started_at_ms = required_nonneg_timestamp_ms obj "started_at_ms" in
  let* deletion =
    match assoc_member_opt "deletion" obj with
    | None -> Ok Deletion_kept
    | Some (`String "failed") -> Ok Deletion_failed
    | Some bad ->
        field_type_error "deletion" "omitted or \"failed\"" bad
  in
  Ok { conversation_id; provider_account_id; started_at_ms; deletion }

let decode_turn_outcome obj =
  let* outcome = required_nonblank_string obj "outcome" in
  match outcome with
  | "answered" ->
      let* text = required_string_field obj "text" in
      let* model = required_string_field obj "model" in
      let* answered_at_ms = required_nonneg_timestamp_ms obj "answered_at_ms" in
      Ok (Turn_answered { text; model; answered_at_ms })
  | "failed" ->
      let* failure_raw = required_nonblank_string obj "failure" in
      let* failed_at_ms = required_nonneg_timestamp_ms obj "failed_at_ms" in
      let* model_may_have_read =
        required_bool_field obj "model_may_have_read"
      in
      Ok
        (Turn_failed
           {
             failure = turn_failure_of_string failure_raw;
             failed_at_ms;
             model_may_have_read;
           })
  | "unrecorded" ->
      let* model_may_have_read =
        required_bool_field obj "model_may_have_read"
      in
      Ok (Turn_unrecorded { model_may_have_read })
  | other -> Error (Printf.sprintf "unknown turn outcome %S" other)

let decode_conversation_turn json =
  let* obj = require_object ~context:"conversation_turn" json in
  let* message = required_string_field obj "message" in
  let* asked_at_ms = required_nonneg_timestamp_ms obj "asked_at_ms" in
  let* outcome = decode_turn_outcome obj in
  Ok { message; asked_at_ms; outcome }

let decode_conversation ~expected_keeper_id ?requested_conversation_id json =
  let ctx = "GET " ^ conversation_path in
  let* obj = require_object ~context:ctx json in
  let* keeper_id = required_nonblank_string obj "keeper_id" in
  let* () =
    if String.equal keeper_id expected_keeper_id then Ok ()
    else
      Error
        (Printf.sprintf "%s returned keeper_id %S (expected %S)" ctx keeper_id
           expected_keeper_id)
  in
  let* current_conversation_id =
    required_nullable_nonblank_string obj "current_conversation_id"
  in
  let* conversation_id =
    required_nullable_nonblank_string obj "conversation_id"
  in
  let* () =
    match requested_conversation_id with
    | Some req_id ->
        if Option.equal String.equal conversation_id (Some req_id) then Ok ()
        else
          Error
            (Printf.sprintf "%s returned conversation_id %s (expected %S)" ctx
               (Option.value ~default:"null" conversation_id)
               req_id)
    | None ->
        if Option.equal String.equal conversation_id current_conversation_id
        then Ok ()
        else
          Error
            (Printf.sprintf
               "%s current read mismatch: conversation_id=%s vs current_conversation_id=%s"
               ctx
               (Option.value ~default:"null" conversation_id)
               (Option.value ~default:"null" current_conversation_id))
  in
  let* conv_items = required_list_field obj "conversations" in
  let* conversations =
    decode_list "conversations" decode_conversation_summary conv_items
  in
  let seen_ids = Hashtbl.create (List.length conversations) in
  let rec check_conv_dups = function
    | [] -> Ok ()
    | (c : conversation_summary) :: rest ->
        if Hashtbl.mem seen_ids c.conversation_id then
          Error
            (Printf.sprintf "%s duplicate conversation_id %S" ctx
               c.conversation_id)
        else (
          Hashtbl.add seen_ids c.conversation_id ();
          check_conv_dups rest)
  in
  let* () = check_conv_dups conversations in
  let* () =
    match current_conversation_id with
    | Some cid when not (Hashtbl.mem seen_ids cid) ->
        Error
          (Printf.sprintf
             "%s current_conversation_id %S missing from conversations list" ctx
             cid)
    | Some _ | None -> Ok ()
  in
  let* () =
    match conversation_id with
    | Some cid when not (Hashtbl.mem seen_ids cid) ->
        Error
          (Printf.sprintf
             "%s conversation_id %S missing from conversations list" ctx cid)
    | Some _ | None -> Ok ()
  in
  let* turn_items = required_list_field obj "turns" in
  let* () =
    match (conversation_id, turn_items) with
    | None, _ :: _ ->
        Error
          (Printf.sprintf "%s returned turns while conversation_id is null" ctx)
    | None, [] | Some _, _ -> Ok ()
  in
  let* turns = decode_list "turns" decode_conversation_turn turn_items in
  Ok
    {
      keeper_id;
      current_conversation_id;
      conversations;
      conversation_id;
      turns;
    }

let decode_started_conversation ~expected_keeper_id json =
  let ctx = "POST " ^ conversation_path in
  let* obj = require_object ~context:ctx json in
  let* keeper_id = required_nonblank_string obj "keeper_id" in
  let* () =
    if String.equal keeper_id expected_keeper_id then Ok ()
    else
      Error
        (Printf.sprintf "%s returned keeper_id %S (expected %S)" ctx keeper_id
           expected_keeper_id)
  in
  let* conversation_id = required_nonblank_string obj "conversation_id" in
  Ok { keeper_id; conversation_id }

let decode_turn_answer ~expected_keeper_id json =
  let ctx = "POST " ^ turn_path in
  let* obj = require_object ~context:ctx json in
  let* keeper_id = required_nonblank_string obj "keeper_id" in
  let* () =
    if String.equal keeper_id expected_keeper_id then Ok ()
    else
      Error
        (Printf.sprintf "%s returned keeper_id %S (expected %S)" ctx keeper_id
           expected_keeper_id)
  in
  let* runtime_id = required_nonblank_string obj "runtime_id" in
  let* model = required_nonblank_string obj "model" in
  let* text = required_string_field obj "text" in
  let has_conv = has_field obj "conversation_id" in
  let has_cont = has_field obj "continued" in
  let* recording =
    match (has_conv, has_cont) with
    | true, true ->
        let* conversation_id = required_nonblank_string obj "conversation_id" in
        let* continued = required_bool_field obj "continued" in
        Ok (Turn_recorded { conversation_id; continued })
    | false, false -> Ok Turn_ephemeral
    | true, false | false, true ->
        Error
          (Printf.sprintf
             "%s requires conversation_id and continued to be both present or both absent"
             ctx)
  in
  Ok { keeper_id; runtime_id; model; text; recording }

let decode_deleted_conversation ~expected_conversation_id json =
  let ctx = "DELETE " ^ conversation_delete_path ~conversation_id:expected_conversation_id in
  let* obj = require_object ~context:ctx json in
  let* conversation_id = required_nonblank_string obj "conversation_id" in
  let* () =
    if String.equal conversation_id expected_conversation_id then Ok ()
    else
      Error
        (Printf.sprintf "%s returned conversation_id %S (expected %S)" ctx
           conversation_id expected_conversation_id)
  in
  let* vc_raw = required_nonblank_string obj "vendor_copy" in
  let* vendor_copy = vendor_copy_state_of_string vc_raw in
  Ok { conversation_id; vendor_copy }
