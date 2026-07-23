type t =
  { slot_id : string
  ; call_id : string
  ; target_identity_fingerprint : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; plan_fingerprint : string
  ; receipt_plan_fingerprint : string
  ; receipt_request_body_sha256 : string
  ; before_checkpoint_bytes : int
  ; after_checkpoint_bytes : int
  ; before_message_count : int
  ; after_message_count : int
  ; summarized_message_count : int
  ; dropped_message_count : int
  ; before_tool_use_count : int
  ; after_tool_use_count : int
  ; before_tool_result_count : int
  ; after_tool_result_count : int
  }

type field =
  | Slot_id
  | Call_id
  | Target_identity_fingerprint
  | Catalog_generation_fingerprint
  | Catalog_evidence_sha256
  | Plan_fingerprint
  | Receipt_plan_fingerprint
  | Receipt_request_body_sha256
  | Before_checkpoint_bytes
  | After_checkpoint_bytes
  | Before_message_count
  | After_message_count
  | Summarized_message_count
  | Dropped_message_count
  | Before_tool_use_count
  | After_tool_use_count
  | Before_tool_result_count
  | After_tool_result_count

type field_error =
  | Missing
  | Duplicate
  | Expected_string
  | Expected_integer
  | Blank_string
  | Negative_integer

type measure =
  | Checkpoint_bytes
  | Messages
  | Tool_uses
  | Tool_results

type decode_error =
  | Expected_object
  | Unknown_field of string
  | Invalid_field of field * field_error
  | Plan_fingerprint_mismatch of
      { plan_fingerprint : string
      ; receipt_plan_fingerprint : string
      }
  | Invalid_transition of measure * int * int
  | Invalid_message_accounting of
      { before_message_count : int
      ; after_message_count : int
      ; summarized_message_count : int
      ; dropped_message_count : int
      }
  | No_messages_compacted

let field_name = function
  | Slot_id -> "slot_id"
  | Call_id -> "call_id"
  | Target_identity_fingerprint -> "target_identity_fingerprint"
  | Catalog_generation_fingerprint -> "catalog_generation_fingerprint"
  | Catalog_evidence_sha256 -> "catalog_evidence_sha256"
  | Plan_fingerprint -> "plan_fingerprint"
  | Receipt_plan_fingerprint -> "receipt_plan_fingerprint"
  | Receipt_request_body_sha256 -> "receipt_request_body_sha256"
  | Before_checkpoint_bytes -> "before_checkpoint_bytes"
  | After_checkpoint_bytes -> "after_checkpoint_bytes"
  | Before_message_count -> "before_message_count"
  | After_message_count -> "after_message_count"
  | Summarized_message_count -> "summarized_message_count"
  | Dropped_message_count -> "dropped_message_count"
  | Before_tool_use_count -> "before_tool_use_count"
  | After_tool_use_count -> "after_tool_use_count"
  | Before_tool_result_count -> "before_tool_result_count"
  | After_tool_result_count -> "after_tool_result_count"
;;

let exact_fields =
  [ Slot_id
  ; Call_id
  ; Target_identity_fingerprint
  ; Catalog_generation_fingerprint
  ; Catalog_evidence_sha256
  ; Plan_fingerprint
  ; Receipt_plan_fingerprint
  ; Receipt_request_body_sha256
  ]
;;

let integer_fields =
  [ Before_checkpoint_bytes
  ; After_checkpoint_bytes
  ; Before_message_count
  ; After_message_count
  ; Summarized_message_count
  ; Dropped_message_count
  ; Before_tool_use_count
  ; After_tool_use_count
  ; Before_tool_result_count
  ; After_tool_result_count
  ]
;;

let wire_field_names = List.map field_name (exact_fields @ integer_fields)
let exact_evidence_key = "exact_evidence"

let known_field name = List.exists (String.equal name) wire_field_names
;;

let field_error_to_string = function
  | Missing -> "missing"
  | Duplicate -> "duplicate"
  | Expected_string -> "expected_string"
  | Expected_integer -> "expected_integer"
  | Blank_string -> "blank_string"
  | Negative_integer -> "negative_integer"
;;

let measure_to_string = function
  | Checkpoint_bytes -> "checkpoint_bytes"
  | Messages -> "messages"
  | Tool_uses -> "tool_uses"
  | Tool_results -> "tool_results"
;;

let decode_error_to_string = function
  | Expected_object -> "expected_object"
  | Unknown_field name -> "unknown_field:" ^ name
  | Invalid_field (field, error) ->
    Printf.sprintf
      "invalid_field:%s:%s"
      (field_name field)
      (field_error_to_string error)
  | Plan_fingerprint_mismatch
      { plan_fingerprint; receipt_plan_fingerprint } ->
    Printf.sprintf
      "plan_fingerprint_mismatch:plan=%s:receipt=%s"
      plan_fingerprint
      receipt_plan_fingerprint
  | Invalid_transition (measure, before, after) ->
    Printf.sprintf
      "invalid_transition:%s:%d:%d"
      (measure_to_string measure)
      before
      after
  | Invalid_message_accounting
      { before_message_count
      ; after_message_count
      ; summarized_message_count
      ; dropped_message_count
      } ->
    Printf.sprintf
      "invalid_message_accounting:before=%d:after=%d:summarized=%d:dropped=%d"
      before_message_count
      after_message_count
      summarized_message_count
      dropped_message_count
  | No_messages_compacted -> "no_messages_compacted"
;;

let ( let* ) = Result.bind

let message_accounting_is_exact
      ~before_message_count
      ~after_message_count
      ~summarized_message_count
      ~dropped_message_count
  =
  summarized_message_count <= before_message_count
  && dropped_message_count <= before_message_count - summarized_message_count
  && after_message_count = before_message_count - dropped_message_count
;;

let decode_nonblank_string fields field =
  match
    List.filter
      (fun (name, _) -> String.equal name (field_name field))
      fields
  with
  | [] -> Error (Invalid_field (field, Missing))
  | [ _, `String value ] when String.trim value = "" ->
    Error (Invalid_field (field, Blank_string))
  | [ _, `String value ] -> Ok value
  | [ _ ] -> Error (Invalid_field (field, Expected_string))
  | _ -> Error (Invalid_field (field, Duplicate))
;;

let decode_nonnegative_integer fields field =
  match
    List.filter
      (fun (name, _) -> String.equal name (field_name field))
      fields
  with
  | [] -> Error (Invalid_field (field, Missing))
  | [ _, `Int value ] when value >= 0 -> Ok value
  | [ _, `Int _ ] -> Error (Invalid_field (field, Negative_integer))
  | [ _ ] -> Error (Invalid_field (field, Expected_integer))
  | _ -> Error (Invalid_field (field, Duplicate))
;;

let create
      ~slot_id
      ~call_id
      ~target_identity_fingerprint
      ~catalog_generation_fingerprint
      ~catalog_evidence_sha256
      ~plan_fingerprint
      ~receipt_plan_fingerprint
      ~receipt_request_body_sha256
      ~before_checkpoint_bytes
      ~after_checkpoint_bytes
      ~before_message_count
      ~after_message_count
      ~summarized_message_count
      ~dropped_message_count
      ~before_tool_use_count
      ~after_tool_use_count
      ~before_tool_result_count
      ~after_tool_result_count
  =
  let values =
    [ Before_checkpoint_bytes, before_checkpoint_bytes
    ; After_checkpoint_bytes, after_checkpoint_bytes
    ; Before_message_count, before_message_count
    ; After_message_count, after_message_count
    ; Summarized_message_count, summarized_message_count
    ; Dropped_message_count, dropped_message_count
    ; Before_tool_use_count, before_tool_use_count
    ; After_tool_use_count, after_tool_use_count
    ; Before_tool_result_count, before_tool_result_count
    ; After_tool_result_count, after_tool_result_count
    ]
  in
  match List.find_opt (fun (_, value) -> value < 0) values with
  | Some (field, _) -> Error (Invalid_field (field, Negative_integer))
  | None ->
    (match
       List.find_opt
         (fun (_, value) -> String.trim value = "")
         [ Slot_id, slot_id
         ; Call_id, call_id
         ; Target_identity_fingerprint, target_identity_fingerprint
         ; Catalog_generation_fingerprint, catalog_generation_fingerprint
         ; Catalog_evidence_sha256, catalog_evidence_sha256
         ; Plan_fingerprint, plan_fingerprint
         ; Receipt_plan_fingerprint, receipt_plan_fingerprint
         ; Receipt_request_body_sha256, receipt_request_body_sha256
         ]
     with
     | Some (field, _) -> Error (Invalid_field (field, Blank_string))
     | None ->
       if not (String.equal plan_fingerprint receipt_plan_fingerprint)
       then
         Error
           (Plan_fingerprint_mismatch
              { plan_fingerprint; receipt_plan_fingerprint })
       else if after_checkpoint_bytes >= before_checkpoint_bytes
       then
         Error
           (Invalid_transition
              (Checkpoint_bytes, before_checkpoint_bytes, after_checkpoint_bytes))
       else if after_message_count > before_message_count
       then
         Error
           (Invalid_transition
              (Messages, before_message_count, after_message_count))
       else if after_tool_use_count <> before_tool_use_count
       then
         Error
           (Invalid_transition
              (Tool_uses, before_tool_use_count, after_tool_use_count))
       else if after_tool_result_count <> before_tool_result_count
       then
         Error
           (Invalid_transition
              (Tool_results, before_tool_result_count, after_tool_result_count))
       else if summarized_message_count = 0 && dropped_message_count = 0
       then Error No_messages_compacted
       else if
         not
           (message_accounting_is_exact
              ~before_message_count
              ~after_message_count
              ~summarized_message_count
              ~dropped_message_count)
       then
         Error
           (Invalid_message_accounting
              { before_message_count
              ; after_message_count
              ; summarized_message_count
              ; dropped_message_count
              })
       else
         Ok
           { slot_id
           ; call_id
           ; target_identity_fingerprint
           ; catalog_generation_fingerprint
           ; catalog_evidence_sha256
           ; plan_fingerprint
           ; receipt_plan_fingerprint
           ; receipt_request_body_sha256
           ; before_checkpoint_bytes
           ; after_checkpoint_bytes
           ; before_message_count
           ; after_message_count
           ; summarized_message_count
           ; dropped_message_count
           ; before_tool_use_count
           ; after_tool_use_count
           ; before_tool_result_count
           ; after_tool_result_count
           })
;;

let of_json = function
  | `Assoc fields ->
    let* () =
      match
        List.find_opt
          (fun (name, _) -> not (known_field name))
          fields
      with
      | None -> Ok ()
      | Some (name, _) -> Error (Unknown_field name)
    in
    let string = decode_nonblank_string fields in
    let integer = decode_nonnegative_integer fields in
    let* slot_id = string Slot_id in
    let* call_id = string Call_id in
    let* target_identity_fingerprint = string Target_identity_fingerprint in
    let* catalog_generation_fingerprint = string Catalog_generation_fingerprint in
    let* catalog_evidence_sha256 = string Catalog_evidence_sha256 in
    let* plan_fingerprint = string Plan_fingerprint in
    let* receipt_plan_fingerprint = string Receipt_plan_fingerprint in
    let* receipt_request_body_sha256 = string Receipt_request_body_sha256 in
    let* before_checkpoint_bytes = integer Before_checkpoint_bytes in
    let* after_checkpoint_bytes = integer After_checkpoint_bytes in
    let* before_message_count = integer Before_message_count in
    let* after_message_count = integer After_message_count in
    let* summarized_message_count = integer Summarized_message_count in
    let* dropped_message_count = integer Dropped_message_count in
    let* before_tool_use_count = integer Before_tool_use_count in
    let* after_tool_use_count = integer After_tool_use_count in
    let* before_tool_result_count = integer Before_tool_result_count in
    let* after_tool_result_count = integer After_tool_result_count in
    create
      ~slot_id
      ~call_id
      ~target_identity_fingerprint
      ~catalog_generation_fingerprint
      ~catalog_evidence_sha256
      ~plan_fingerprint
      ~receipt_plan_fingerprint
      ~receipt_request_body_sha256
      ~before_checkpoint_bytes
      ~after_checkpoint_bytes
      ~before_message_count
      ~after_message_count
      ~summarized_message_count
      ~dropped_message_count
      ~before_tool_use_count
      ~after_tool_use_count
      ~before_tool_result_count
      ~after_tool_result_count
  | _ -> Error Expected_object
;;

let to_json evidence =
  `Assoc
    [ "slot_id", `String evidence.slot_id
    ; "call_id", `String evidence.call_id
    ; "target_identity_fingerprint", `String evidence.target_identity_fingerprint
    ; "catalog_generation_fingerprint", `String evidence.catalog_generation_fingerprint
    ; "catalog_evidence_sha256", `String evidence.catalog_evidence_sha256
    ; "plan_fingerprint", `String evidence.plan_fingerprint
    ; "receipt_plan_fingerprint", `String evidence.receipt_plan_fingerprint
    ; "receipt_request_body_sha256", `String evidence.receipt_request_body_sha256
    ; "before_checkpoint_bytes", `Int evidence.before_checkpoint_bytes
    ; "after_checkpoint_bytes", `Int evidence.after_checkpoint_bytes
    ; "before_message_count", `Int evidence.before_message_count
    ; "after_message_count", `Int evidence.after_message_count
    ; "summarized_message_count", `Int evidence.summarized_message_count
    ; "dropped_message_count", `Int evidence.dropped_message_count
    ; "before_tool_use_count", `Int evidence.before_tool_use_count
    ; "after_tool_use_count", `Int evidence.after_tool_use_count
    ; "before_tool_result_count", `Int evidence.before_tool_result_count
    ; "after_tool_result_count", `Int evidence.after_tool_result_count
    ]
;;
