let data_payload_line line =
  let line_len = String.length line in
  let line_len =
    if line_len > 0 && Char.equal line.[line_len - 1] '\r'
    then line_len - 1
    else line_len
  in
  let prefix = "data:" in
  let prefix_len = String.length prefix in
  if line_len >= prefix_len
     && String.equal (String.sub line 0 prefix_len) prefix
  then
    let payload_start =
      if line_len > prefix_len && Char.equal line.[prefix_len] ' '
      then prefix_len + 1
      else prefix_len
    in
    Some (String.sub line payload_start (line_len - payload_start))
  else if line_len = 4 && String.equal (String.sub line 0 line_len) "data"
  then Some ""
  else None


type frame = { id : string option; data : string }
type decoder = {
  line : Buffer.t;
  mutable first_line : bool;
  mutable skip_lf : bool;
  mutable data_rev : string list;
  mutable frame_id : string option;
}

let create_decoder () = {
  line = Buffer.create 256; first_line = true; skip_lf = false;
  data_rev = []; frame_id = None;
}

let consume_line t =
  let line = Buffer.contents t.line in
  Buffer.clear t.line;
  let line =
    if t.first_line && String.starts_with ~prefix:"\239\187\191" line
    then String.sub line 3 (String.length line - 3)
    else line in
  t.first_line <- false;
  if String.equal line "" then (
    let frame = match t.data_rev with
      | [] -> None
      | fields -> Some {id = t.frame_id; data = String.concat "\n" (List.rev fields)} in
    t.data_rev <- [];
    t.frame_id <- None;
    frame)
  else (
    (match data_payload_line line with
     | Some data -> t.data_rev <- data :: t.data_rev
     | None ->
       let field, value = match String.index_opt line ':' with
         | None -> line, ""
         | Some colon ->
             let start = if colon + 1 < String.length line && line.[colon + 1] = ' '
               then colon + 2 else colon + 1 in
             String.sub line 0 colon, String.sub line start (String.length line - start) in
       if String.equal field "id" && not (String.contains value '\000')
       then t.frame_id <- Some value);
    None)

let feed t chunk =
  let completed = ref [] in
  String.iter (fun c ->
    if t.skip_lf && c = '\n' then t.skip_lf <- false
    else (
      t.skip_lf <- false;
      if c = '\r' || c = '\n' then (
        Option.iter (fun frame -> completed := frame :: !completed) (consume_line t);
        t.skip_lf <- c = '\r')
      else Buffer.add_char t.line c)) chunk;
  List.rev !completed

let data_payloads_of_stream stream =
  feed (create_decoder ()) stream |> List.map (fun frame -> frame.data)

let add_header buf name value =
  Buffer.add_string buf name;
  Buffer.add_string buf ": ";
  Buffer.add_string buf value;
  Buffer.add_char buf '\n'
;;

let add_optional_headers buf ?id ?event_type () =
  Option.iter (fun event_id -> add_header buf "id" (string_of_int event_id)) id;
  Option.iter (add_header buf "event") event_type
;;

let format_event ?id ?event_type data =
  let buf = Buffer.create 64 in
  add_optional_headers buf ?id ?event_type ();
  String.split_on_char '\n' data
  |> List.iter (fun line -> add_header buf "data" line);
  Buffer.add_char buf '\n';
  Buffer.contents buf
;;

let format_event_yojson ?id ?event_type json =
  let buf = Buffer.create 128 in
  add_optional_headers buf ?id ?event_type ();
  Buffer.add_string buf "data: ";
  Yojson.Safe.to_buffer buf json;
  Buffer.add_string buf "\n\n";
  Buffer.contents buf
;;

type encoded_json =
  { json : Yojson.Safe.t
  ; text : string
  }

let encode_json json = { json; text = Yojson.Safe.to_string json }

(* Yojson writes an object as [{"key":value,...}] with no spacing, so joining
   the fields' texts that way writes the bytes encoding the whole object
   would. *)
let encoded_object fields =
  let text_bytes =
    List.fold_left (fun bytes (_, value) -> bytes + String.length value.text) 0 fields
  in
  let buf = Buffer.create (text_bytes + 64) in
  Buffer.add_char buf '{';
  List.iteri
    (fun index (key, value) ->
      if index > 0 then Buffer.add_char buf ',';
      Yojson.Safe.to_buffer buf (`String key);
      Buffer.add_char buf ':';
      Buffer.add_string buf value.text)
    fields;
  Buffer.add_char buf '}';
  { json = `Assoc (List.map (fun (key, value) -> key, value.json) fields)
  ; text = Buffer.contents buf
  }
;;

let format_event_encoded ?id ?event_type encoded =
  let buf = Buffer.create (String.length encoded.text + 64) in
  add_optional_headers buf ?id ?event_type ();
  Buffer.add_string buf "data: ";
  Buffer.add_string buf encoded.text;
  Buffer.add_string buf "\n\n";
  Buffer.contents buf
;;

type observer_cursor = { instance_id : string; event_id : int }
type observer_reset = Instance_changed | Unscoped_cursor
type observer_replay =
  | Fresh
  | Resumed
  | Resumed_after_gap of { missed_through : int }
  | Reset of observer_reset
type observer_handshake = { instance_id : string; replay : observer_replay }

let instance_header = "x-masc-sse-instance-id"
let replay_header = "x-masc-sse-replay"
let missed_through_header = "x-masc-sse-replay-missed-through"

let header name headers =
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value else None)
    headers
;;

let observer_cursor_headers = function
  | None -> []
  | Some { instance_id; event_id } ->
    [ instance_header, instance_id; "last-event-id", string_of_int event_id ]
;;

let negotiate_observer ~instance_id ~headers ~last_event_id =
  let replay, cursor =
    match last_event_id, header instance_header headers with
    | None, _ -> Fresh, None
    | Some _, None -> Reset Unscoped_cursor, None
    | Some event_id, Some requested when String.equal requested instance_id ->
      Resumed, Some event_id
    | Some _, Some _ -> Reset Instance_changed, None
  in
  { instance_id; replay }, cursor
;;

let observer_after_replay handshake ~missed_through =
  match handshake.replay, missed_through with
  | Resumed, Some missed_through ->
    { handshake with replay = Resumed_after_gap { missed_through } }
  | Resumed, None
  | (Fresh | Resumed_after_gap _ | Reset _), (Some _ | None) -> handshake
;;

let observer_response_headers { instance_id; replay } =
  let replay =
    match replay with
    | Fresh -> [ replay_header, "fresh" ]
    | Resumed -> [ replay_header, "resumed" ]
    | Resumed_after_gap { missed_through } ->
      [ replay_header, "resumed-after-gap"
      ; missed_through_header, string_of_int missed_through ]
    | Reset Instance_changed -> [ replay_header, "reset-instance-changed" ]
    | Reset Unscoped_cursor -> [ replay_header, "reset-unscoped-cursor" ]
  in
  (instance_header, instance_id) :: replay
;;

let decode_observer_response headers =
  match header instance_header headers, header replay_header headers with
  | None, None -> Ok None
  | Some instance_id, Some replay when not (String.equal instance_id "") ->
    let replay =
      match replay with
      | "fresh" -> Ok Fresh
      | "resumed" -> Ok Resumed
      | "resumed-after-gap" ->
        (match Option.bind (header missed_through_header headers) int_of_string_opt with
         | Some missed_through when missed_through > 0 ->
           Ok (Resumed_after_gap { missed_through })
         | Some _ | None -> Error "Observer replay gap without a positive missed-through id")
      | "reset-instance-changed" -> Ok (Reset Instance_changed)
      | "reset-unscoped-cursor" -> Ok (Reset Unscoped_cursor)
      | _ -> Error "Unknown observer replay response"
    in
    Result.map (fun replay -> Some { instance_id; replay }) replay
  | (None | Some _), (None | Some _) ->
    Error "Incomplete observer instance/replay response"
;;
