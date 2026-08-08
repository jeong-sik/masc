(** Session lifecycle and metadata for agent executions.
    Tracks turn count, timestamps, and cross-turn state via Context.t. *)

type t =
  { id : string
  ; started_at : float
  ; last_active_at : float
  ; turn_count : int
  ; resumed_from : string option
  ; cwd : string option
  ; metadata : Context.t
  }

exception Entropy_unavailable of string

let generate_id () =
  match Llm_provider.Random_id.create () with
  | Ok value -> "session-" ^ value
  | Error message -> raise (Entropy_unavailable message)
;;

let create ?id ?resumed_from ?cwd ?(metadata = Context.create_sync ()) () =
  let now = Unix.gettimeofday () in
  { id =
      (match id with
       | Some id -> id
       | None -> generate_id ())
  ; started_at = now
  ; last_active_at = now
  ; turn_count = 0
  ; resumed_from
  ; cwd
  ; metadata
  }
;;

let record_turn t =
  { t with turn_count = t.turn_count + 1; last_active_at = Unix.gettimeofday () }
;;

let touch t = { t with last_active_at = Unix.gettimeofday () }
let elapsed t = Unix.gettimeofday () -. t.started_at

let resume_from (cp : Checkpoint.t) =
  let now = Unix.gettimeofday () in
  { id = generate_id ()
  ; started_at = now
  ; last_active_at = now
  ; turn_count = cp.turn_count
  ; resumed_from =
      (match cp.session_id with
       | "" -> None
       | sid -> Some sid)
  ; cwd = None
  ; metadata = Context.copy cp.context
  }
;;

let to_json t =
  `Assoc
    [ "id", `String t.id
    ; "started_at", `Float t.started_at
    ; "last_active_at", `Float t.last_active_at
    ; "turn_count", `Int t.turn_count
    ; ( "resumed_from"
      , match t.resumed_from with
        | Some s -> `String s
        | None -> `Null )
    ; ( "cwd"
      , match t.cwd with
        | Some s -> `String s
        | None -> `Null )
    ; "metadata", Context.to_json t.metadata
    ]
;;

let of_json json =
  try
    let open Yojson.Safe.Util in
    let metadata =
      match json |> member "metadata" with
      | `Null -> Context.create_sync ()
      | v -> Context.of_json v
    in
    Ok
      { id = json |> member "id" |> to_string
      ; started_at = json |> member "started_at" |> to_float
      ; last_active_at =
          (match json |> member "last_active_at" |> to_float_option with
           | Some v -> v
           | None -> json |> member "started_at" |> to_float)
      ; turn_count =
          (match json |> member "turn_count" |> to_int_option with
           | Some v -> v
           | None -> 0)
      ; resumed_from = json |> member "resumed_from" |> to_string_option
      ; cwd = json |> member "cwd" |> to_string_option
      ; metadata
      }
  with
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Session.of_json: %s" msg }))
  | Yojson.Json_error msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Session.of_json: %s" msg }))
  | Failure msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Session.of_json: %s" msg }))
  | Invalid_argument msg ->
    Error
      (Error.Serialization
         (JsonParseError { detail = Printf.sprintf "Session.of_json: %s" msg }))
;;
