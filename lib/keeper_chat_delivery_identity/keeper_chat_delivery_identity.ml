(** Exact identities shared by Keeper delivery producers and consumers. *)
module Request_id = struct
  type t = string

  let max_length = 128

  let of_string value =
    let length = String.length value in
    let rec valid_chars index =
      if index = length
      then true
      else
        match value.[index] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' ->
          valid_chars (index + 1)
        | _ -> false
    in
    if length = 0
    then Error "Keeper request id must not be empty"
    else if length > max_length
    then Error "Keeper request id exceeds 128 bytes"
    else if String.equal value "." || String.equal value ".."
    then Error "Keeper request id must not be a path segment"
    else if valid_chars 0
    then Ok value
    else Error "Keeper request id contains an unsupported character"
  ;;

  let generate () = Random_id.prefixed ~prefix:"kmsg-" ~bytes:16
  let to_string value = value
  let equal = String.equal
end

type delivery_key =
  | Operation of Request_id.t
  | Fusion_run of Request_id.t
  | Workspace_message of Request_id.t
  | Approval_lifecycle of Request_id.t

type transcript_slot =
  | Accepted_user
  | Tool_call of
      { execution_id : Ids.Execution_id.t
      ; ordinal : int
      }
  | Tool_delivery of { ordinal : int }
  | Terminal_assistant
  | Approval_request
  | Approval_resolution
  | Approval_replay
  | Approval_replay_correction
  | Approval_continuation

type delivery_provenance =
  { delivery_key : delivery_key
  ; transcript_slot : transcript_slot
  }

let ( let* ) = Result.bind

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing delivery identity field %S" name)
;;

let validate_fields ~context ~expected fields =
  let rec loop seen = function
    | [] ->
      (match List.find_opt (fun name -> not (List.mem name seen)) expected with
       | Some name -> Error (Printf.sprintf "%s is missing field %S" context name)
       | None -> Ok ())
    | (name, _) :: rest ->
      if List.mem name seen
      then Error (Printf.sprintf "%s has duplicate field %S" context name)
      else if not (List.mem name expected)
      then Error (Printf.sprintf "%s has unknown field %S" context name)
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let string_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "delivery identity field %S must be a string" name)
;;

let delivery_key_to_yojson = function
  | Operation operation_id ->
    `Assoc
      [ "kind", `String "operation"
      ; "operation_id", `String (Request_id.to_string operation_id)
      ]
  | Fusion_run request_id ->
    `Assoc
      [ "kind", `String "fusion_run"
      ; "request_id", `String (Request_id.to_string request_id)
      ]
  | Workspace_message request_id ->
    `Assoc
      [ "kind", `String "workspace_message"
      ; "request_id", `String (Request_id.to_string request_id)
      ]
  | Approval_lifecycle approval_id ->
    `Assoc
      [ "kind", `String "approval_lifecycle"
      ; "approval_id", `String (Request_id.to_string approval_id)
      ]
;;

let delivery_key_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "operation" ->
       let* () =
         validate_fields
           ~context:"operation delivery identity"
           ~expected:[ "kind"; "operation_id" ]
           fields
       in
       let* operation_id = string_field "operation_id" fields in
       let* operation_id = Request_id.of_string operation_id in
       Ok (Operation operation_id)
     | "fusion_run" ->
       let* () =
         validate_fields
           ~context:"Fusion run delivery identity"
           ~expected:[ "kind"; "request_id" ]
           fields
       in
       let* request_id = string_field "request_id" fields in
       let* request_id = Request_id.of_string request_id in
       Ok (Fusion_run request_id)
     | "workspace_message" ->
       let* () =
         validate_fields
           ~context:"workspace message delivery identity"
           ~expected:[ "kind"; "request_id" ]
           fields
       in
       let* request_id = string_field "request_id" fields in
       let* request_id = Request_id.of_string request_id in
       Ok (Workspace_message request_id)
     | "approval_lifecycle" ->
       let* () =
         validate_fields
           ~context:"approval lifecycle delivery identity"
           ~expected:[ "kind"; "approval_id" ]
           fields
       in
       let* approval_id = string_field "approval_id" fields in
       let* approval_id = Request_id.of_string approval_id in
       Ok (Approval_lifecycle approval_id)
     | _ -> Error (Printf.sprintf "unsupported delivery identity kind %S" kind))
  | _ -> Error "delivery identity must be an object"
;;

let delivery_key_equal left right =
  match left, right with
  | Operation left, Operation right -> Request_id.equal left right
  | Fusion_run left, Fusion_run right -> Request_id.equal left right
  | Workspace_message left, Workspace_message right -> Request_id.equal left right
  | Approval_lifecycle left, Approval_lifecycle right -> Request_id.equal left right
  | (Operation _ | Fusion_run _ | Workspace_message _ | Approval_lifecycle _),
    (Operation _ | Fusion_run _ | Workspace_message _ | Approval_lifecycle _) ->
    false
;;

let transcript_slot_to_yojson = function
  | Accepted_user -> `Assoc [ "kind", `String "accepted_user" ]
  | Terminal_assistant -> `Assoc [ "kind", `String "terminal_assistant" ]
  | Approval_request -> `Assoc [ "kind", `String "approval_request" ]
  | Approval_resolution -> `Assoc [ "kind", `String "approval_resolution" ]
  | Approval_replay -> `Assoc [ "kind", `String "approval_replay" ]
  | Approval_replay_correction ->
    `Assoc [ "kind", `String "approval_replay_correction" ]
  | Approval_continuation -> `Assoc [ "kind", `String "approval_continuation" ]
  | Tool_call { execution_id; ordinal } ->
    `Assoc
      [ "kind", `String "tool_call"
      ; "execution_id", `String (Ids.Execution_id.to_string execution_id)
      ; "ordinal", `Int ordinal
      ]
  | Tool_delivery { ordinal } ->
    `Assoc [ "kind", `String "tool_delivery"; "ordinal", `Int ordinal ]
;;

let transcript_ordinal fields =
  let* ordinal = assoc_field "ordinal" fields in
  match ordinal with
  | `Int value when value >= 0 -> Ok value
  | _ -> Error "tool transcript ordinal must be a non-negative integer"
;;

let transcript_slot_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "accepted_user" ->
       let* () =
         validate_fields
           ~context:"accepted user transcript slot"
           ~expected:[ "kind" ]
           fields
       in
       Ok Accepted_user
     | "terminal_assistant" ->
       let* () =
         validate_fields
           ~context:"terminal assistant transcript slot"
           ~expected:[ "kind" ]
           fields
       in
       Ok Terminal_assistant
     | "approval_request" ->
       let* () =
         validate_fields
           ~context:"approval request transcript slot"
           ~expected:[ "kind" ]
           fields
       in
       Ok Approval_request
     | "approval_resolution" ->
       let* () =
         validate_fields
           ~context:"approval resolution transcript slot"
           ~expected:[ "kind" ]
           fields
       in
       Ok Approval_resolution
     | "approval_replay" ->
       let* () =
         validate_fields
           ~context:"approval replay transcript slot"
           ~expected:[ "kind" ]
           fields
       in
       Ok Approval_replay
     | "approval_replay_correction" ->
       let* () =
         validate_fields
           ~context:"approval replay correction transcript slot"
           ~expected:[ "kind" ]
           fields
       in
       Ok Approval_replay_correction
     | "approval_continuation" ->
       let* () =
         validate_fields
           ~context:"approval continuation transcript slot"
           ~expected:[ "kind" ]
           fields
       in
       Ok Approval_continuation
     | "tool_call" ->
       let* () =
         validate_fields
           ~context:"tool call transcript slot"
           ~expected:[ "kind"; "execution_id"; "ordinal" ]
           fields
       in
       let* execution_id = string_field "execution_id" fields in
       let* execution_id =
         if String.equal (String.trim execution_id) ""
         then Error "tool transcript execution_id must not be blank"
         else Ok (Ids.Execution_id.of_string execution_id)
       in
       let* ordinal = transcript_ordinal fields in
       Ok (Tool_call { execution_id; ordinal })
     | "tool_delivery" ->
       let* () =
         validate_fields
           ~context:"tool delivery transcript slot"
           ~expected:[ "kind"; "ordinal" ]
           fields
       in
       let* ordinal = transcript_ordinal fields in
       Ok (Tool_delivery { ordinal })
     | _ -> Error (Printf.sprintf "unsupported transcript slot kind %S" kind))
  | _ -> Error "transcript slot must be an object"
;;

let transcript_slot_equal left right =
  match left, right with
  | Accepted_user, Accepted_user
  | Terminal_assistant, Terminal_assistant
  | Approval_request, Approval_request
  | Approval_resolution, Approval_resolution
  | Approval_replay, Approval_replay
  | Approval_replay_correction, Approval_replay_correction
  | Approval_continuation, Approval_continuation -> true
  | Tool_call left, Tool_call right ->
    Ids.Execution_id.equal left.execution_id right.execution_id
    && Int.equal left.ordinal right.ordinal
  | Tool_delivery left, Tool_delivery right -> Int.equal left.ordinal right.ordinal
  | Accepted_user, (Terminal_assistant | Tool_call _ | Tool_delivery _ | Approval_request | Approval_resolution | Approval_replay | Approval_replay_correction | Approval_continuation)
  | Terminal_assistant, (Accepted_user | Tool_call _ | Tool_delivery _ | Approval_request | Approval_resolution | Approval_replay | Approval_replay_correction | Approval_continuation)
  | Tool_call _, (Accepted_user | Terminal_assistant | Tool_delivery _ | Approval_request | Approval_resolution | Approval_replay | Approval_replay_correction | Approval_continuation)
  | Tool_delivery _, (Accepted_user | Terminal_assistant | Tool_call _ | Approval_request | Approval_resolution | Approval_replay | Approval_replay_correction | Approval_continuation)
  | Approval_request, (Accepted_user | Terminal_assistant | Tool_call _ | Tool_delivery _ | Approval_resolution | Approval_replay | Approval_replay_correction | Approval_continuation)
  | Approval_resolution, (Accepted_user | Terminal_assistant | Tool_call _ | Tool_delivery _ | Approval_request | Approval_replay | Approval_replay_correction | Approval_continuation)
  | Approval_replay, (Accepted_user | Terminal_assistant | Tool_call _ | Tool_delivery _ | Approval_request | Approval_resolution | Approval_replay_correction | Approval_continuation)
  | Approval_replay_correction, (Accepted_user | Terminal_assistant | Tool_call _ | Tool_delivery _ | Approval_request | Approval_resolution | Approval_replay | Approval_continuation)
  | Approval_continuation, (Accepted_user | Terminal_assistant | Tool_call _ | Tool_delivery _ | Approval_request | Approval_resolution | Approval_replay | Approval_replay_correction) -> false
;;

let delivery_provenance_fields { delivery_key; transcript_slot } =
  [ "delivery_key", delivery_key_to_yojson delivery_key
  ; "transcript_slot", transcript_slot_to_yojson transcript_slot
  ]
;;

let delivery_provenance_of_fields fields =
  match
    List.assoc_opt "delivery_key" fields, List.assoc_opt "transcript_slot" fields
  with
  | None, None -> Ok None
  | Some _, None | None, Some _ ->
    Error "delivery_key and transcript_slot must appear together"
  | Some delivery_key_json, Some transcript_slot_json ->
    let* delivery_key = delivery_key_of_yojson delivery_key_json in
    let* transcript_slot = transcript_slot_of_yojson transcript_slot_json in
    Ok (Some { delivery_key; transcript_slot })
;;

let delivery_provenance_equal left right =
  delivery_key_equal left.delivery_key right.delivery_key
  && transcript_slot_equal left.transcript_slot right.transcript_slot
;;
