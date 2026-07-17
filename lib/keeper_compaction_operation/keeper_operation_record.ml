module Cursor = struct
  type t = int
  type error = Negative of int
  let zero = 0
  let of_int value = if value < 0 then Error (Negative value) else Ok value
  let equal = Int.equal
  let compare = Int.compare
  let to_int value = value
end

type 'event row =
  { recorded_at : float
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; event : 'event
  }

type 'event_error envelope_error =
  | Expected_object
  | Unknown_field of string
  | Duplicate_field of string
  | Missing_field of string
  | Invalid_recorded_at
  | Invalid_event of 'event_error

type encode_error = Non_finite_recorded_at

type 'event_error issue =
  | Incomplete_tail
  | Malformed_json of string
  | Invalid_envelope of 'event_error envelope_error

type 'event_error decode_error =
  { row_number : int option
  ; start_cursor : Cursor.t
  ; end_cursor : Cursor.t
  ; issue : 'event_error issue
  }

let ( let* ) = Result.bind

let required_field name fields =
  match List.filter (fun (field, _) -> String.equal field name) fields with
  | [] -> Error (Missing_field name)
  | [ _, value ] -> Ok value
  | _ -> Error (Duplicate_field name)
;;

let decode_envelope ~decode_event = function
  | `Assoc fields ->
    let* () =
      match
        List.find_opt
          (fun (name, _) ->
             not
               (String.equal name "recorded_at"
                || String.equal name "event"))
          fields
      with
      | None -> Ok ()
      | Some (name, _) -> Error (Unknown_field name)
    in
    let* recorded_json = required_field "recorded_at" fields in
    let* recorded_at =
      match recorded_json with
      | `Float value when Float.is_finite value -> Ok value
      | _ -> Error Invalid_recorded_at
    in
    let* event_json = required_field "event" fields in
    decode_event event_json
    |> Result.map_error (fun error -> Invalid_event error)
    |> Result.map (fun event -> recorded_at, event)
  | _ -> Error Expected_object
;;

let encode ~encode_event ~recorded_at event =
  if not (Float.is_finite recorded_at)
  then Error Non_finite_recorded_at
  else
    Ok
      (`Assoc
         [ "recorded_at", `Float recorded_at
         ; "event", encode_event event
         ]
       |> Yojson.Safe.to_string
       |> fun value -> value ^ "\n")
;;

let decode_rows ~decode_event ~from ~row_number bytes =
  let base = Cursor.to_int from in
  let length = String.length bytes in
  let locate number start_cursor end_cursor issue =
    Error { row_number = number; start_cursor; end_cursor; issue }
  in
  let rec loop position number rows =
    if position = length
    then Ok (List.rev rows)
    else
      match String.index_from_opt bytes position '\n' with
      | None ->
        locate number (base + position) (base + length) Incomplete_tail
      | Some newline ->
        let start_cursor = base + position in
        let end_cursor = base + newline + 1 in
        let payload = String.sub bytes position (newline - position) in
        (match
           try Ok (Yojson.Safe.from_string payload) with
           | Yojson.Json_error detail -> Error (Malformed_json detail)
         with
         | Error issue -> locate number start_cursor end_cursor issue
         | Ok json ->
           (match decode_envelope ~decode_event json with
            | Error error ->
              locate number start_cursor end_cursor (Invalid_envelope error)
            | Ok (recorded_at, event) ->
              loop
                (newline + 1)
                (Option.map succ number)
                ({ recorded_at; start_cursor; end_cursor; event } :: rows)))
  in
  loop 0 row_number []
;;
