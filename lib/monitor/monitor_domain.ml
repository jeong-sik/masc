(** Pure domain for keeper monitors (RFC-0379). *)

type trigger =
  | Port_up of
      { host : string
      ; port : int
      }
  | Port_down of
      { host : string
      ; port : int
      }
  | File_changed of { path : string }
  | Http_ok of { url : string }

type observation =
  | Reachable
  | Unreachable
  | File_snapshot of
      { mtime : float
      ; inode : int
      }
  | File_absent

type t =
  { id : string
  ; keeper : string
  ; trigger : trigger
  ; payload : Yojson.Safe.t
  ; expires_at : float
  ; max_fires : int
  ; fired_count : int
  ; created_at : float
  ; last_observation : observation option
  }

type fire_decision =
  | Fire of
      { from_ : observation
      ; to_ : observation
      }
  | Hold

let max_active_monitors_per_keeper = 8

let file_snapshot_equal left right =
  match left, right with
  | File_snapshot a, File_snapshot b ->
    Float.equal a.mtime b.mtime && Int.equal a.inode b.inode
  | File_absent, File_absent -> true
  | (Reachable | Unreachable), _
  | _, (Reachable | Unreachable)
  | File_snapshot _, File_absent
  | File_absent, File_snapshot _ -> false
;;

let decide trigger ~prev ~current =
  match prev with
  | None -> Hold
  | Some prev ->
    (match trigger, prev, current with
     (* Reachability triggers: fire on the named direction only. *)
     | (Port_up _ | Http_ok _), Unreachable, Reachable ->
       Fire { from_ = Unreachable; to_ = Reachable }
     | (Port_up _ | Http_ok _), Reachable, Reachable
     | (Port_up _ | Http_ok _), Unreachable, Unreachable
     | (Port_up _ | Http_ok _), Reachable, Unreachable -> Hold
     | Port_down _, Reachable, Unreachable ->
       Fire { from_ = Reachable; to_ = Unreachable }
     | Port_down _, Reachable, Reachable
     | Port_down _, Unreachable, Unreachable
     | Port_down _, Unreachable, Reachable -> Hold
     (* File trigger: any change of the identity pair fires, including
        absent <-> present. *)
     | File_changed _, (File_snapshot _ | File_absent), (File_snapshot _ | File_absent)
       ->
       if file_snapshot_equal prev current
       then Hold
       else Fire { from_ = prev; to_ = current }
     (* Incoherent pairs: the observation cannot belong to this trigger.
        The runner produced a defective observation; never wake on it. *)
     | (Port_up _ | Port_down _ | Http_ok _), (File_snapshot _ | File_absent), _
     | (Port_up _ | Port_down _ | Http_ok _), _, (File_snapshot _ | File_absent)
     | File_changed _, (Reachable | Unreachable), _
     | File_changed _, _, (Reachable | Unreachable) -> Hold)
;;

let expired record ~now = Float.compare now record.expires_at >= 0
let exhausted record = record.fired_count >= record.max_fires

let trim_to_error ~field value =
  if String.equal (String.trim value) ""
  then Error (Printf.sprintf "monitor %s must not be blank" field)
  else Ok ()
;;

let ( let* ) = Result.bind

let validate_trigger = function
  | Port_up { host; port } | Port_down { host; port } ->
    let* () = trim_to_error ~field:"host" host in
    if port >= 1 && port <= 65535
    then Ok ()
    else Error (Printf.sprintf "monitor port %d is outside 1-65535" port)
  | File_changed { path } -> trim_to_error ~field:"path" path
  | Http_ok { url } -> trim_to_error ~field:"url" url
;;

let validate_create ~keeper ~trigger ~expires_at ~max_fires ~now =
  let* () = trim_to_error ~field:"keeper" keeper in
  let* () = validate_trigger trigger in
  let* () =
    if Float.compare expires_at now > 0
    then Ok ()
    else Error "monitor expires_at must be in the future"
  in
  if max_fires >= 1 then Ok () else Error "monitor max_fires must be at least 1"
;;

(* --- closed JSON codecs (delivery-identity style: unknown/missing/duplicate
   fields are errors, never defaults) --- *)

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing monitor field %S" name)
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
  | _ -> Error (Printf.sprintf "monitor field %S must be a string" name)
;;

let number_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `Int value -> Ok (float_of_int value)
  | `Float value -> Ok value
  | _ -> Error (Printf.sprintf "monitor field %S must be a number" name)
;;

let int_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "monitor field %S must be an integer" name)
;;

let observation_label = function
  | Reachable -> "reachable"
  | Unreachable -> "unreachable"
  | File_snapshot _ -> "file_snapshot"
  | File_absent -> "file_absent"
;;

let trigger_to_yojson = function
  | Port_up { host; port } ->
    `Assoc [ "kind", `String "port_up"; "host", `String host; "port", `Int port ]
  | Port_down { host; port } ->
    `Assoc [ "kind", `String "port_down"; "host", `String host; "port", `Int port ]
  | File_changed { path } ->
    `Assoc [ "kind", `String "file_changed"; "path", `String path ]
  | Http_ok { url } -> `Assoc [ "kind", `String "http_ok"; "url", `String url ]
;;

let trigger_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "port_up" | "port_down" ->
       let* () =
         validate_fields
           ~context:(Printf.sprintf "%s trigger" kind)
           ~expected:[ "kind"; "host"; "port" ]
           fields
       in
       let* host = string_field "host" fields in
       let* port = int_field "port" fields in
       if String.equal kind "port_up"
       then Ok (Port_up { host; port })
       else Ok (Port_down { host; port })
     | "file_changed" ->
       let* () =
         validate_fields
           ~context:"file_changed trigger"
           ~expected:[ "kind"; "path" ]
           fields
       in
       let* path = string_field "path" fields in
       Ok (File_changed { path })
     | "http_ok" ->
       let* () =
         validate_fields ~context:"http_ok trigger" ~expected:[ "kind"; "url" ] fields
       in
       let* url = string_field "url" fields in
       Ok (Http_ok { url })
     | _ -> Error (Printf.sprintf "unsupported monitor trigger kind %S" kind))
  | _ -> Error "monitor trigger must be an object"
;;

let observation_to_yojson = function
  | Reachable -> `Assoc [ "kind", `String "reachable" ]
  | Unreachable -> `Assoc [ "kind", `String "unreachable" ]
  | File_snapshot { mtime; inode } ->
    `Assoc
      [ "kind", `String "file_snapshot"; "mtime", `Float mtime; "inode", `Int inode ]
  | File_absent -> `Assoc [ "kind", `String "file_absent" ]
;;

let observation_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "reachable" ->
       let* () =
         validate_fields ~context:"reachable observation" ~expected:[ "kind" ] fields
       in
       Ok Reachable
     | "unreachable" ->
       let* () =
         validate_fields ~context:"unreachable observation" ~expected:[ "kind" ] fields
       in
       Ok Unreachable
     | "file_snapshot" ->
       let* () =
         validate_fields
           ~context:"file_snapshot observation"
           ~expected:[ "kind"; "mtime"; "inode" ]
           fields
       in
       let* mtime = number_field "mtime" fields in
       let* inode = int_field "inode" fields in
       Ok (File_snapshot { mtime; inode })
     | "file_absent" ->
       let* () =
         validate_fields ~context:"file_absent observation" ~expected:[ "kind" ] fields
       in
       Ok File_absent
     | _ -> Error (Printf.sprintf "unsupported monitor observation kind %S" kind))
  | _ -> Error "monitor observation must be an object"
;;

let record_fields =
  [ "id"; "keeper"; "trigger"; "payload"; "expires_at"; "max_fires"; "fired_count"
  ; "created_at" ]
;;

let to_yojson record =
  `Assoc
    [ "id", `String record.id
    ; "keeper", `String record.keeper
    ; "trigger", trigger_to_yojson record.trigger
    ; "payload", record.payload
    ; "expires_at", `Float record.expires_at
    ; "max_fires", `Int record.max_fires
    ; "fired_count", `Int record.fired_count
    ; "created_at", `Float record.created_at
    ]
;;

let of_yojson = function
  | `Assoc fields ->
    let* () = validate_fields ~context:"monitor record" ~expected:record_fields fields in
    let* id = string_field "id" fields in
    let* keeper = string_field "keeper" fields in
    let* trigger_json = assoc_field "trigger" fields in
    let* trigger = trigger_of_yojson trigger_json in
    let* payload = assoc_field "payload" fields in
    let* expires_at = number_field "expires_at" fields in
    let* max_fires = int_field "max_fires" fields in
    let* fired_count = int_field "fired_count" fields in
    let* created_at = number_field "created_at" fields in
    Ok
      { id
      ; keeper
      ; trigger
      ; payload
      ; expires_at
      ; max_fires
      ; fired_count
      ; created_at
      ; last_observation = None
      }
  | _ -> Error "monitor record must be an object"
;;
