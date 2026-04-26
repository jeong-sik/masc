type result =
  | Start_dispatched
  | Failed of { reason : string }
  | Timed_out

let result_to_string = function
  | Start_dispatched -> "start_dispatched"
  | Failed _ -> "failed"
  | Timed_out -> "timed_out"
;;

let result_of_string_opt = function
  | "start_dispatched" -> Some Start_dispatched
  | "failed" -> Some (Failed { reason = "" })
  | "timed_out" -> Some Timed_out
  | _ -> None
;;

type t =
  { generation : int
  ; attempt_number : int
  ; attempt_id : string
  ; last_result : result
  ; next_retry_unix : float option
  ; updated_unix : float
  }

let make_next ~now ~backoff_seconds ~generation ~last_result ~previous =
  let attempt_number =
    match previous with
    | Some p when p.generation = generation -> p.attempt_number + 1
    | _ -> 1
  in
  { generation
  ; attempt_number
  ; attempt_id = Printf.sprintf "%d:%d" generation attempt_number
  ; last_result
  ; next_retry_unix = Some (now +. backoff_seconds)
  ; updated_unix = now
  }
;;

let is_backoff_active ~now t =
  match t.next_retry_unix with
  | Some deadline -> deadline > now
  | None -> false
;;

let to_json t =
  let failure_reason =
    match t.last_result with
    | Failed { reason } -> `String reason
    | Start_dispatched | Timed_out -> `Null
  in
  let next_retry =
    match t.next_retry_unix with
    | Some v -> `Float v
    | None -> `Null
  in
  `Assoc
    [ "generation", `Int t.generation
    ; "attempt_number", `Int t.attempt_number
    ; "attempt_id", `String t.attempt_id
    ; "last_result", `String (result_to_string t.last_result)
    ; "failure_reason", failure_reason
    ; "next_retry_unix", next_retry
    ; "updated_unix", `Float t.updated_unix
    ]
;;

let int_of_json = function
  | `Int n -> Some n
  | _ -> None
;;

let string_of_json = function
  | `String s -> Some s
  | _ -> None
;;

let float_of_json = function
  | `Float f -> Some f
  | `Int n -> Some (float_of_int n)
  | _ -> None
;;

let optional_float_of_json = function
  | `Null -> Some None
  | `Float f -> Some (Some f)
  | `Int n -> Some (Some (float_of_int n))
  | _ -> None
;;

let of_json = function
  | `Assoc fields ->
    let ( let* ) = Option.bind in
    let* generation =
      List.assoc_opt "generation" fields |> Option.map int_of_json |> Option.join
    in
    let* attempt_number =
      List.assoc_opt "attempt_number" fields |> Option.map int_of_json |> Option.join
    in
    let* attempt_id =
      List.assoc_opt "attempt_id" fields |> Option.map string_of_json |> Option.join
    in
    let* last_result_token =
      List.assoc_opt "last_result" fields |> Option.map string_of_json |> Option.join
    in
    let* last_result_base = result_of_string_opt last_result_token in
    let last_result =
      match last_result_base with
      | Failed _ ->
        let reason =
          match List.assoc_opt "failure_reason" fields with
          | Some (`String s) -> s
          | _ -> ""
        in
        Failed { reason }
      | Start_dispatched | Timed_out -> last_result_base
    in
    let* next_retry_unix =
      match List.assoc_opt "next_retry_unix" fields with
      | Some v -> optional_float_of_json v
      | None -> Some None
    in
    let* updated_unix =
      List.assoc_opt "updated_unix" fields |> Option.map float_of_json |> Option.join
    in
    Some
      { generation
      ; attempt_number
      ; attempt_id
      ; last_result
      ; next_retry_unix
      ; updated_unix
      }
  | _ -> None
;;
