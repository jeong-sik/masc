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

module Receipt_id = struct
  type t = string

  let prefix = "chatq_"
  let rng = Random.State.make_self_init ()
  let rng_mutex = Stdlib.Mutex.create ()

  let generate () =
    let uuid =
      Stdlib.Mutex.protect rng_mutex (fun () -> Uuidm.v4_gen rng ())
    in
    prefix ^ Uuidm.to_string uuid
  ;;

  let of_string value =
    let prefix_length = String.length prefix in
    if
      String.length value <= prefix_length
      || not (String.equal (String.sub value 0 prefix_length) prefix)
    then Error "chat queue receipt id must start with chatq_"
    else
      let uuid =
        String.sub value prefix_length (String.length value - prefix_length)
      in
      match Uuidm.of_string uuid with
      | Some _ -> Ok value
      | None -> Error "chat queue receipt id must contain a UUID"
  ;;

  let to_string value = value
  let equal = String.equal
end

module Receipt_ids = struct
  type t = Receipt_id.t * Receipt_id.t list
  type error = Empty

  let of_list = function
    | [] -> Error Empty
    | first :: rest -> Ok (first, rest)
  ;;

  let error_to_string = function
    | Empty -> "queue delivery identity requires at least one receipt id"
  ;;

  let to_list (first, rest) = first :: rest
end

type delivery_key =
  | Direct_request of Request_id.t
  | Queue_receipts of Receipt_ids.t

type transcript_slot =
  | Accepted_user
  | Tool_call of
      { execution_id : Ids.Execution_id.t
      ; ordinal : int
      }
  | Terminal_assistant

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
  | Direct_request request_id ->
    `Assoc
      [ "kind", `String "direct_request"
      ; "request_id", `String (Request_id.to_string request_id)
      ]
  | Queue_receipts receipt_ids ->
    `Assoc
      [ "kind", `String "queue_receipts"
      ; ( "receipt_ids"
        , `List
            (List.map
               (fun receipt_id -> `String (Receipt_id.to_string receipt_id))
               (Receipt_ids.to_list receipt_ids)) )
      ]
;;

let delivery_key_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "direct_request" ->
       let* () =
         validate_fields
           ~context:"direct request delivery identity"
           ~expected:[ "kind"; "request_id" ]
           fields
       in
       let* request_id = string_field "request_id" fields in
       let* request_id = Request_id.of_string request_id in
       Ok (Direct_request request_id)
     | "queue_receipts" ->
       let* () =
         validate_fields
           ~context:"queue receipt delivery identity"
           ~expected:[ "kind"; "receipt_ids" ]
           fields
       in
       let* receipt_ids = assoc_field "receipt_ids" fields in
       let* receipt_ids =
         match receipt_ids with
         | `List values ->
           List.fold_right
             (fun value result ->
                let* rest = result in
                match value with
                | `String value ->
                  let* receipt_id = Receipt_id.of_string value in
                  Ok (receipt_id :: rest)
                | _ -> Error "queue receipt identity must be a string")
             values
             (Ok [])
         | _ -> Error "delivery identity receipt_ids must be a list"
       in
       let* receipt_ids =
         match Receipt_ids.of_list receipt_ids with
         | Ok receipt_ids -> Ok receipt_ids
         | Error error -> Error (Receipt_ids.error_to_string error)
       in
       Ok (Queue_receipts receipt_ids)
     | _ -> Error (Printf.sprintf "unsupported delivery identity kind %S" kind))
  | _ -> Error "delivery identity must be an object"
;;

let delivery_key_equal left right =
  match left, right with
  | Direct_request left, Direct_request right -> Request_id.equal left right
  | Queue_receipts left, Queue_receipts right ->
    let rec equal_lists left right =
      match left, right with
      | [], [] -> true
      | left :: left_rest, right :: right_rest ->
        Receipt_id.equal left right && equal_lists left_rest right_rest
      | [], _ :: _ | _ :: _, [] -> false
    in
    equal_lists (Receipt_ids.to_list left) (Receipt_ids.to_list right)
  | Direct_request _, Queue_receipts _
  | Queue_receipts _, Direct_request _ -> false
;;

let delivery_key_file_stem key =
  let digest =
    key
    |> delivery_key_to_yojson
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  match key with
  | Direct_request _ -> "direct-" ^ digest
  | Queue_receipts _ -> "queue-" ^ digest
;;

let transcript_slot_to_yojson = function
  | Accepted_user -> `Assoc [ "kind", `String "accepted_user" ]
  | Terminal_assistant -> `Assoc [ "kind", `String "terminal_assistant" ]
  | Tool_call { execution_id; ordinal } ->
    `Assoc
      [ "kind", `String "tool_call"
      ; "execution_id", `String (Ids.Execution_id.to_string execution_id)
      ; "ordinal", `Int ordinal
      ]
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
       let* ordinal = assoc_field "ordinal" fields in
       let* ordinal =
         match ordinal with
         | `Int value when value >= 0 -> Ok value
         | _ -> Error "tool transcript ordinal must be a non-negative integer"
       in
       Ok (Tool_call { execution_id; ordinal })
     | _ -> Error (Printf.sprintf "unsupported transcript slot kind %S" kind))
  | _ -> Error "transcript slot must be an object"
;;

let transcript_slot_equal left right =
  match left, right with
  | Accepted_user, Accepted_user
  | Terminal_assistant, Terminal_assistant -> true
  | Tool_call left, Tool_call right ->
    Ids.Execution_id.equal left.execution_id right.execution_id
    && Int.equal left.ordinal right.ordinal
  | Accepted_user, (Terminal_assistant | Tool_call _)
  | Terminal_assistant, (Accepted_user | Tool_call _)
  | Tool_call _, (Accepted_user | Terminal_assistant) -> false
;;
