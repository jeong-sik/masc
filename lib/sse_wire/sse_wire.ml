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

type observer_cursor = { instance_id : string; event_id : int }
type observer_reset = Instance_changed | Unscoped_cursor
type observer_replay = Fresh | Resumed | Reset of observer_reset
type observer_handshake = { instance_id : string; replay : observer_replay }

let instance_header = "x-masc-sse-instance-id"
let replay_header = "x-masc-sse-replay"

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

let observer_response_headers { instance_id; replay } =
  let replay =
    match replay with
    | Fresh -> "fresh"
    | Resumed -> "resumed"
    | Reset Instance_changed -> "reset-instance-changed"
    | Reset Unscoped_cursor -> "reset-unscoped-cursor"
  in
  [ instance_header, instance_id; replay_header, replay ]
;;

let decode_observer_response headers =
  match header instance_header headers, header replay_header headers with
  | None, None -> Ok None
  | Some instance_id, Some replay when not (String.equal instance_id "") ->
    let replay =
      match replay with
      | "fresh" -> Ok Fresh
      | "resumed" -> Ok Resumed
      | "reset-instance-changed" -> Ok (Reset Instance_changed)
      | "reset-unscoped-cursor" -> Ok (Reset Unscoped_cursor)
      | _ -> Error "Unknown observer replay response"
    in
    Result.map (fun replay -> Some { instance_id; replay }) replay
  | (None | Some _), (None | Some _) ->
    Error "Incomplete observer instance/replay response"
;;
