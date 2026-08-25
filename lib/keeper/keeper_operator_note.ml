(** See [keeper_operator_note.mli]. *)

type note =
  { text : string
  ; created_at : float
  ; created_by : string
  ; consumed_at : float option
  ; consumed_turn : int option
  }

type write_error =
  | Unknown_keeper of string
  | Empty_text
  | Too_large of
      { bytes : int
      ; max_bytes : int
      }
  | Write_failed of string

type read_error =
  | Read_unknown_keeper of string
  | No_note
  | Malformed of string

let write_error_to_string = function
  | Unknown_keeper keeper -> Printf.sprintf "invalid keeper name: %s" keeper
  | Empty_text -> "an operator note needs text"
  | Too_large { bytes; max_bytes } ->
    Printf.sprintf
      "operator note is %d bytes; the cap is %d. It is rejected rather than \
       truncated because a truncated instruction is a different instruction."
      bytes
      max_bytes
  | Write_failed detail -> Printf.sprintf "operator note write failed: %s" detail
;;

let read_error_to_string = function
  | Read_unknown_keeper keeper -> Printf.sprintf "invalid keeper name: %s" keeper
  | No_note -> "this keeper has no operator note"
  | Malformed detail -> Printf.sprintf "operator note could not be decoded: %s" detail
;;

let filename = "pending-note.json"

let path_for config keeper =
  let keeper_dir =
    Filename.dirname (Keeper_types_support.keeper_raw_trace_dir config keeper)
  in
  Filename.concat keeper_dir filename
;;

(* A note is one instruction for one turn. The cap is a constant rather than a
   knob because nothing has asked to tune it, and an operator who needs more
   than this is describing standing context, which belongs in the keeper's
   instructions or in memory rather than in a note that expires next turn. *)
let max_note_bytes = 4 * 1024
let max_bytes () = max_note_bytes

let to_json note =
  `Assoc
    [ "text", `String note.text
    ; "created_at", `Float note.created_at
    ; "created_by", `String note.created_by
    ; ( "consumed_at"
      , match note.consumed_at with None -> `Null | Some at -> `Float at )
    ; ( "consumed_turn"
      , match note.consumed_turn with None -> `Null | Some turn -> `Int turn )
    ]
;;

let of_json = function
  | `Assoc fields ->
    (match
       ( List.assoc_opt "text" fields
       , List.assoc_opt "created_at" fields
       , List.assoc_opt "created_by" fields )
     with
     | Some (`String text), Some (`Float created_at), Some (`String created_by) ->
       let consumed_at =
         match List.assoc_opt "consumed_at" fields with
         | Some (`Float at) -> Some at
         | _ -> None
       in
       let consumed_turn =
         match List.assoc_opt "consumed_turn" fields with
         | Some (`Int turn) -> Some turn
         | _ -> None
       in
       Ok { text; created_at; created_by; consumed_at; consumed_turn }
     | _ -> Error "note is missing text/created_at/created_by")
  | _ -> Error "note is not a JSON object"
;;

let save config keeper note =
  let path = path_for config keeper in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file_atomic path (Yojson.Safe.to_string (to_json note))
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn -> Error (Printexc.to_string exn)
;;

let write ~config ~keeper ~text ~created_by =
  if not (Keeper_config.validate_name keeper)
  then Error (Unknown_keeper keeper)
  else if String.equal (String.trim text) ""
  then Error Empty_text
  else (
    let bytes = String.length text in
    let cap = max_bytes () in
    if bytes > cap
    then Error (Too_large { bytes; max_bytes = cap })
    else (
      let note =
        { text
        ; created_at = Time_compat.now ()
        ; created_by
        ; consumed_at = None
        ; consumed_turn = None
        }
      in
      match save config keeper note with
      | Ok () -> Ok note
      | Error detail -> Error (Write_failed detail)))
;;

let read ~config ~keeper =
  if not (Keeper_config.validate_name keeper)
  then Error (Read_unknown_keeper keeper)
  else (
    match Fs_compat.load_file_opt (path_for config keeper) with
    | None -> Error No_note
    | Some contents ->
      (match Yojson.Safe.from_string contents with
       | json ->
         (match of_json json with
          | Ok note -> Ok note
          | Error message -> Error (Malformed message))
       | exception Yojson.Json_error message -> Error (Malformed message)))
;;

(* A consumed note stays on disk as the delivery record. Rendering it again
   would make a one-turn instruction a standing one, which is the shape this
   store exists to avoid. *)
let pending ~config ~keeper =
  match read ~config ~keeper with
  | Ok ({ consumed_at = None; _ } as note) -> Some note
  | Ok _ | Error _ -> None
;;

let mark_consumed ~config ~keeper ~absolute_turn =
  match read ~config ~keeper with
  (* Nothing to stamp is the ordinary case; anything else means the note is
     there and unreadable, which the save arm below already reports. *)
  | Error No_note -> ()
  | Error err ->
    Log.Keeper.warn
      ~keeper_name:keeper
      "operator note consumption stamp skipped: %s"
      (read_error_to_string err)
  | Ok note ->
    let stamped =
      { note with consumed_at = Some (Time_compat.now ()); consumed_turn = Some absolute_turn }
    in
    (match save config keeper stamped with
     | Ok () -> ()
     | Error detail ->
       Log.Keeper.warn
         ~keeper_name:keeper
         "operator note consumption stamp failed: %s"
         detail)
;;

let render note =
  match String.trim note.text with
  | "" -> None
  | text ->
    Some
      (Printf.sprintf
         "--- Operator Note ---\n\
          Left by %s for this turn only. It is not stored as memory and will not \
          appear again.\n\
          %s"
         note.created_by
         text)
;;
