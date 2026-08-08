type source_clock =
  | Wall
  | Monotonic
  | Logical
  | Unknown

type t =
  { event_id : string
  ; correlation_id : string
  ; run_id : string
  ; event_time : float
  ; observed_at : float
  ; seq : int option
  ; parent_event_id : string option
  ; caused_by : string option
  ; source_clock : source_clock
  }

let id_counter = Atomic.make 0

let fresh_id () =
  let n = Atomic.fetch_and_add id_counter 1 in
  let now_us = Int.of_float (Unix.gettimeofday () *. 1e6) in
  Printf.sprintf "evt-%x-%x-%x" (Unix.getpid ()) now_us n
;;

let source_clock_to_string = function
  | Wall -> "wall"
  | Monotonic -> "monotonic"
  | Logical -> "logical"
  | Unknown -> "unknown"
;;

let source_clock_of_string = function
  | "wall" -> Ok Wall
  | "monotonic" -> Ok Monotonic
  | "logical" -> Ok Logical
  | "unknown" -> Ok Unknown
  | s -> Error (Printf.sprintf "unknown source_clock: %s" s)
;;

let make
      ?event_id
      ?correlation_id
      ?run_id
      ?event_time
      ?observed_at
      ?seq
      ?parent_event_id
      ?caused_by
      ?(source_clock = Wall)
      ()
  =
  let time_or_now = function
    | Some value -> value
    | None -> Unix.gettimeofday ()
  in
  let event_time = time_or_now event_time in
  let value_or_fresh = function
    | Some value -> value
    | None -> fresh_id ()
  in
  { event_id = value_or_fresh event_id
  ; correlation_id = value_or_fresh correlation_id
  ; run_id = value_or_fresh run_id
  ; event_time
  ; observed_at = time_or_now observed_at
  ; seq
  ; parent_event_id
  ; caused_by
  ; source_clock
  }
;;

let option_to_json f = function
  | None -> `Null
  | Some v -> f v
;;

let to_json t =
  `Assoc
    [ "event_id", `String t.event_id
    ; "correlation_id", `String t.correlation_id
    ; "run_id", `String t.run_id
    ; "event_time", `Float t.event_time
    ; "observed_at", `Float t.observed_at
    ; "seq", option_to_json (fun v -> `Int v) t.seq
    ; "parent_event_id", option_to_json (fun v -> `String v) t.parent_event_id
    ; "caused_by", option_to_json (fun v -> `String v) t.caused_by
    ; "source_clock", `String (source_clock_to_string t.source_clock)
    ]
;;

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "missing field: %s" name)
;;

let string_field name fields =
  match assoc_field name fields with
  | Ok (`String v) -> Ok v
  | Ok _ -> Error (Printf.sprintf "field %s must be a string" name)
  | Error _ as err -> err
;;

let float_field name fields =
  match assoc_field name fields with
  | Ok (`Float v) -> Ok v
  | Ok (`Int v) -> Ok (float_of_int v)
  | Ok _ -> Error (Printf.sprintf "field %s must be a number" name)
  | Error _ as err -> err
;;

let option_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String v) -> Ok (Some v)
  | Some _ -> Error (Printf.sprintf "field %s must be a string or null" name)
;;

let option_int_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int v) -> Ok (Some v)
  | Some _ -> Error (Printf.sprintf "field %s must be an int or null" name)
;;

open Result_syntax

let of_json = function
  | `Assoc fields ->
    let* event_id = string_field "event_id" fields in
    let* correlation_id = string_field "correlation_id" fields in
    let* run_id = string_field "run_id" fields in
    let* event_time = float_field "event_time" fields in
    let* observed_at = float_field "observed_at" fields in
    let* seq = option_int_field "seq" fields in
    let* parent_event_id = option_string_field "parent_event_id" fields in
    let* caused_by = option_string_field "caused_by" fields in
    let* source_clock =
      match List.assoc_opt "source_clock" fields with
      | None -> Ok Unknown
      | Some (`String s) -> source_clock_of_string s
      | Some _ -> Error "field source_clock must be a string"
    in
    Ok
      { event_id
      ; correlation_id
      ; run_id
      ; event_time
      ; observed_at
      ; seq
      ; parent_event_id
      ; caused_by
      ; source_clock
      }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "event envelope must be a JSON object"
;;
