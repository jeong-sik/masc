let tool_name = "lane_machine_inputs"
let input_schema = `Assoc ["type",`String "object"; "additionalProperties",`Bool false;
  "required",`List (List.map (fun key -> `String key) ["incarnation";"entry_count";"before";"max_bytes"]);
  "properties",`Assoc ["incarnation",`Assoc ["type",`String "string";"minLength",`Int 1];
    "entry_count",`Assoc ["type",`String "integer";"minimum",`Int 0];
    "before",`Assoc ["type",`String "integer";"minimum",`Int 0];
    "max_bytes",`Assoc ["type",`String "integer";"minimum",`Int 1]]]

type 'a snapshot = { incarnation:string; count:int; entries:'a list;
  mutable cursor:int; mutable remaining:'a list }
type 'a t = { encode:'a -> Yojson.Safe.t; mutable snapshot:'a snapshot option }
let create ~encode () = {encode;snapshot=None}
let clear t = t.snapshot <- None
let publish t ~incarnation ~entry_count ~newest_first =
  t.snapshot <- Some {incarnation;count=entry_count;entries=newest_first;
    cursor=entry_count;remaining=newest_first};
  `Assoc ["incarnation",`String incarnation;"entry_count",`Int entry_count]
let ( let* ) = Result.bind
let read t ~arguments =
  let* fields = match arguments with
    | `Assoc fields when List.sort String.compare (List.map fst fields)
        = ["before";"entry_count";"incarnation";"max_bytes"] -> Ok fields
    | _ -> Error "input history requires incarnation, entry_count, before and max_bytes" in
  let* incarnation = match List.assoc "incarnation" fields with
    | `String name when name <> "" -> Ok name | _ -> Error "invalid history incarnation" in
  let integer name = match List.assoc name fields with
    | `Int n when n >= 0 -> Ok n | _ -> Error ("invalid history " ^ name) in
  let* count = integer "entry_count" in
  let* before = integer "before" in
  let* max_bytes = integer "max_bytes" in
  let* snapshot = match t.snapshot with
    | Some snapshot when snapshot.incarnation=incarnation && snapshot.count=count -> Ok snapshot
    | _ -> Error "input history snapshot is unavailable or superseded" in
  let* () = if before <= count && max_bytes > 0 then Ok () else Error "invalid history read bounds" in
  let rec skip n entries = if n=0 then Ok entries else match entries with
    | _::rest -> skip (n-1) rest | [] -> Error "input history count does not match capture" in
  let* entries = if before <= snapshot.cursor then skip (snapshot.cursor-before) snapshot.remaining
    else skip (count-before) snapshot.entries in
  let response next entries = `Assoc ["incarnation",`String incarnation;"entry_count",`Int count;
    "before",`Int before;"next_before",`Int next;"entries",`List entries] in
  let empty_bytes next = String.length (Yojson.Safe.to_string (response next [])) in
  let rec take next remaining reversed bytes =
    if next=0 then Ok (response 0 (List.rev reversed),next,remaining)
    else match remaining with
      | [] -> Error "input history ended before its declared cursor"
      | entry::rest ->
          let encoded = t.encode entry in
          let size = String.length (Yojson.Safe.to_string encoded) in
          let separator = if reversed=[] then 0 else 1 in
          (* Subtraction keeps a caller-supplied large byte limit from overflowing. *)
          let available = max_bytes - empty_bytes (next-1) - bytes - separator in
          if size > available then
            if reversed=[] then Error "one input record exceeds the requested payload envelope"
            else Ok (response next (List.rev reversed),next,remaining)
          else take (next-1) rest (encoded::reversed) (bytes+separator+size) in
  if empty_bytes before > max_bytes then Error "history metadata exceeds the requested payload envelope"
  else
    let* response,next,remaining = take before entries [] 0 in
    snapshot.cursor <- next; snapshot.remaining <- remaining;
    Ok response
