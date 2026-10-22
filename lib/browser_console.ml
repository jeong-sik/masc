let ( let* ) = Result.bind
let subscribed_method = "log.entryAdded"
let entries_per_context = 200
let text_bytes_limit = 4000

type entry = {
  kind : string;
  level : string;
  text : string;
  text_cut : bool;
  timestamp : int;
}

(* Newest first, so a new entry is one cons and the oldest drop off the end. *)
type context_log = { mutable entries : entry list; mutable kept : int; mutable dropped : int }
type t = (string, context_log) Hashtbl.t

let create () : t = Hashtbl.create 8

let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string key json = match field key json with
  | Some (`String value) -> Ok value
  | _ -> Error ("BiDi log entry missing string: " ^ key)

let event (t : t) params =
  let* kind = string "type" params in
  let* level = string "level" params in
  let* text = string "text" params in
  let* timestamp = match field "timestamp" params with
    | Some (`Int value) -> Ok value
    | _ -> Error "BiDi log entry missing integer: timestamp" in
  let* context = match field "source" params with
    | Some source -> string "context" source
    | None -> Error "BiDi log entry missing source" in
  let kept_text = String_util.utf8_prefix ~max_bytes:text_bytes_limit text in
  let entry = { kind; level; text = kept_text; text_cut = String.length kept_text < String.length text; timestamp } in
  let log = match Hashtbl.find_opt t context with
    | Some log -> log
    | None -> let log = { entries = []; kept = 0; dropped = 0 } in Hashtbl.replace t context log; log in
  log.entries <- entry :: log.entries;
  if log.kept < entries_per_context then log.kept <- log.kept + 1
  else begin
    log.entries <- List.filteri (fun index _ -> index < entries_per_context) log.entries;
    log.dropped <- log.dropped + 1
  end;
  Ok ()

let entry_json entry = `Assoc [
  "type", `String entry.kind;
  "level", `String entry.level;
  "text", `String entry.text;
  "textCut", `Bool entry.text_cut;
  "timestamp", `Int entry.timestamp ]

let to_json (t : t) ~context =
  let entries, dropped = match Hashtbl.find_opt t context with
    | Some log -> List.rev log.entries, log.dropped
    | None -> [], 0 in
  `Assoc [ "entries", `List (List.map entry_json entries); "dropped", `Int dropped ]
