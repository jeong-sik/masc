type hello = {
  proto : int;
  write_token : string option;
  label : string option;
}

type header = {
  keeper : string;
  operation : string;
}

type live_state = {
  active : bool;
  guests : int;
}

type welcome = {
  proto : int;
  header : header;
  state : live_state;
  entry_count : int;
  read_only : bool;
}

type snapshot_chunk = {
  entries : Yojson.Safe.t list;
  final : bool;
}

type entry = {
  seq : int;
  op : string;
  op_seq : int;
  ts : float;
  event : Yojson.Safe.t;
}

type fetch_transcript = {
  req_id : int;
  max_bytes : int;
}

type transcript = {
  req_id : int;
  text : string;
  new_size : int;
  error : string option;
}

type frame =
  | Hello of hello
  | Welcome of welcome
  | Snapshot_chunk of snapshot_chunk
  | Entry of entry
  | Live_state of live_state
  | Prompt of string
  | Abort
  | Fetch_transcript of fetch_transcript
  | Transcript of transcript
  | Bye of string
  | Error_frame of string

let opt_field name f = function
  | None -> []
  | Some v -> [ name, f v ]
;;

let frame_to_json = function
  | Hello { proto; write_token; label } ->
    `Assoc
      ([ "t", `String "hello"; "proto", `Int proto ]
       @ opt_field "write_token" (fun s -> `String s) write_token
       @ opt_field "label" (fun s -> `String s) label)
  | Welcome { proto; header; state; entry_count; read_only } ->
    `Assoc
      [ "t", `String "welcome"
      ; "proto", `Int proto
      ; ( "header",
          `Assoc
            [ "keeper", `String header.keeper
            ; "operation", `String header.operation
            ] )
      ; ( "state",
          `Assoc
            [ "active", `Bool state.active; "guests", `Int state.guests ] )
      ; "entry_count", `Int entry_count
      ; "read_only", `Bool read_only
      ]
  | Snapshot_chunk { entries; final } ->
    `Assoc
      [ "t", `String "snapshot-chunk"
      ; "entries", `List entries
      ; "final", `Bool final
      ]
  | Entry { seq; op; op_seq; ts; event } ->
    `Assoc
      [ "t", `String "entry"
      ; "seq", `Int seq
      ; "op", `String op
      ; "op_seq", `Int op_seq
      ; "ts", `Float ts
      ; "event", event
      ]
  | Live_state { active; guests } ->
    `Assoc
      [ "t", `String "state"; "active", `Bool active; "guests", `Int guests ]
  | Prompt text -> `Assoc [ "t", `String "prompt"; "text", `String text ]
  | Abort -> `Assoc [ "t", `String "abort" ]
  | Fetch_transcript { req_id; max_bytes } ->
    `Assoc
      [ "t", `String "fetch-transcript"
      ; "req_id", `Int req_id
      ; "max_bytes", `Int max_bytes
      ]
  | Transcript { req_id; text; new_size; error } ->
    `Assoc
      ([ "t", `String "transcript"
       ; "req_id", `Int req_id
       ; "text", `String text
       ; "new_size", `Int new_size
       ]
       @ opt_field "error" (fun s -> `String s) error)
  | Bye reason -> `Assoc [ "t", `String "bye"; "reason", `String reason ]
  | Error_frame message ->
    `Assoc [ "t", `String "error"; "message", `String message ]
;;

let frame_to_string frame = Yojson.Safe.to_string (frame_to_json frame)
let ( let* ) = Option.bind

let as_int = function
  | `Int n -> Some n
  | `Intlit _ | `Float _ | `Null | `Bool _ | `String _ | `Assoc _ | `List _ ->
    None
;;

let as_nonneg_int json =
  let* n = as_int json in
  if n >= 0 then Some n else None
;;

let as_string = function
  | `String s -> Some s
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> None
;;

let as_bool = function
  | `Bool b -> Some b
  | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
    None
;;

let as_float = function
  | `Float f -> Some f
  | `Int n -> Some (float_of_int n)
  | `Null | `Bool _ | `Intlit _ | `String _ | `Assoc _ | `List _ -> None
;;

let as_list = function
  | `List items -> Some items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    None
;;

let as_assoc = function
  | `Assoc fields -> Some fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    None
;;

let opt_string fields name =
  match List.assoc_opt name fields with
  | None | Some `Null -> Some None
  | Some (`String s) -> Some (Some s)
  | Some _ -> None
;;

let hello_of_json fields =
  let* proto = Option.bind (List.assoc_opt "proto" fields) as_int in
  let* write_token = opt_string fields "write_token" in
  let* label = opt_string fields "label" in
  Some (Hello { proto; write_token; label })
;;

let welcome_of_json fields =
  let* proto = Option.bind (List.assoc_opt "proto" fields) as_int in
  let* header_fields = Option.bind (List.assoc_opt "header" fields) as_assoc in
  let* keeper = Option.bind (List.assoc_opt "keeper" header_fields) as_string in
  let* operation = Option.bind (List.assoc_opt "operation" header_fields) as_string in
  let* state_fields = Option.bind (List.assoc_opt "state" fields) as_assoc in
  let* active = Option.bind (List.assoc_opt "active" state_fields) as_bool in
  let* guests = Option.bind (List.assoc_opt "guests" state_fields) as_nonneg_int in
  let* entry_count = Option.bind (List.assoc_opt "entry_count" fields) as_nonneg_int in
  let* read_only = Option.bind (List.assoc_opt "read_only" fields) as_bool in
  Some
    (Welcome
       { proto
       ; header = { keeper; operation }
       ; state = { active; guests }
       ; entry_count
       ; read_only
       })
;;

let snapshot_chunk_of_json fields =
  let* entries = Option.bind (List.assoc_opt "entries" fields) as_list in
  let* final = Option.bind (List.assoc_opt "final" fields) as_bool in
  Some (Snapshot_chunk { entries; final })
;;

let entry_of_json fields =
  let* seq = Option.bind (List.assoc_opt "seq" fields) as_nonneg_int in
  let* op = Option.bind (List.assoc_opt "op" fields) as_string in
  let* op_seq = Option.bind (List.assoc_opt "op_seq" fields) as_nonneg_int in
  let* ts = Option.bind (List.assoc_opt "ts" fields) as_float in
  let* event = List.assoc_opt "event" fields in
  Some (Entry { seq; op; op_seq; ts; event })
;;

let live_state_of_json fields =
  let* active = Option.bind (List.assoc_opt "active" fields) as_bool in
  let* guests = Option.bind (List.assoc_opt "guests" fields) as_nonneg_int in
  Some (Live_state { active; guests })
;;

let fetch_transcript_of_json fields =
  let* req_id = Option.bind (List.assoc_opt "req_id" fields) as_nonneg_int in
  let* max_bytes = Option.bind (List.assoc_opt "max_bytes" fields) as_nonneg_int in
  Some (Fetch_transcript { req_id; max_bytes })
;;

let transcript_of_json fields =
  let* req_id = Option.bind (List.assoc_opt "req_id" fields) as_nonneg_int in
  let* text = Option.bind (List.assoc_opt "text" fields) as_string in
  let* new_size = Option.bind (List.assoc_opt "new_size" fields) as_nonneg_int in
  let* error = opt_string fields "error" in
  Some (Transcript { req_id; text; new_size; error })
;;

let frame_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "t" fields with
     | Some (`String "hello") -> hello_of_json fields
     | Some (`String "welcome") -> welcome_of_json fields
     | Some (`String "snapshot-chunk") -> snapshot_chunk_of_json fields
     | Some (`String "entry") -> entry_of_json fields
     | Some (`String "state") -> live_state_of_json fields
     | Some (`String "prompt") ->
       let* text = Option.bind (List.assoc_opt "text" fields) as_string in
       Some (Prompt text)
     | Some (`String "abort") -> Some Abort
     | Some (`String "fetch-transcript") -> fetch_transcript_of_json fields
     | Some (`String "transcript") -> transcript_of_json fields
     | Some (`String "bye") ->
       let* reason = Option.bind (List.assoc_opt "reason" fields) as_string in
       Some (Bye reason)
     | Some (`String "error") ->
       let* message = Option.bind (List.assoc_opt "message" fields) as_string in
       Some (Error_frame message)
     | Some _ | None -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    None
;;

let frame_of_string s =
  match Yojson.Safe.from_string s with
  | json -> frame_of_json json
  | exception Yojson.Json_error _ -> None
;;
