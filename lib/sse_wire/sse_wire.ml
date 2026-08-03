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
