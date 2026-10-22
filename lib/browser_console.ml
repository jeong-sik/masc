let ( let* ) = Result.bind
let subscribed_method = "log.entryAdded"
let entries_per_context = 200
let text_bytes_limit = 4000

type entry = {
  kind : string;
  level : string;
  text : string option;
  text_cut : bool;
  timestamp : int;
}

(* Newest first, so a new entry is one cons and the oldest drop off the end. *)
type context_log = { mutable entries : entry list; mutable kept : int; mutable dropped : int }

type t = {
  by_context : (string, context_log) Hashtbl.t;
  mutable unattributed : int;
  mutable malformed : int;
  mutable last_malformed : string option;
}

let create () = { by_context = Hashtbl.create 8; unattributed = 0; malformed = 0; last_malformed = None }

let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string key json = match field key json with
  | Some (`String value) -> Ok value
  | _ -> Error ("BiDi log entry missing string: " ^ key)

(* [log.BaseLogEntry] allows a null text. *)
let text params = match field "text" params with
  | Some (`String value) -> Ok (Some value)
  | Some `Null -> Ok None
  | _ -> Error "BiDi log entry has no text or null"

(* [script.Source] carries a realm and may carry a context. *)
let context params = match field "source" params with
  | None -> Error "BiDi log entry missing source"
  | Some source -> (match field "context" source with
      | Some (`String value) -> Ok (Some value)
      | None | Some `Null -> Ok None
      | Some _ -> Error "BiDi log entry source context is not a string")

let parse params =
  let* kind = string "type" params in
  let* level = string "level" params in
  let* text = text params in
  let* timestamp = match field "timestamp" params with
    | Some (`Int value) -> Ok value
    | _ -> Error "BiDi log entry missing integer: timestamp" in
  let* context = context params in
  let kept_text = Option.map (String_util.utf8_prefix ~max_bytes:text_bytes_limit) text in
  let text_cut = match text, kept_text with
    | Some full, Some kept -> String.length kept < String.length full
    | None, _ | _, None -> false in
  Ok (context, { kind; level; text = kept_text; text_cut; timestamp })

let event (t : t) params =
  match parse params with
  | Error reason -> t.malformed <- t.malformed + 1; t.last_malformed <- Some reason
  | Ok (None, _) -> t.unattributed <- t.unattributed + 1
  | Ok (Some context, entry) ->
    let log = match Hashtbl.find_opt t.by_context context with
      | Some log -> log
      | None -> let log = { entries = []; kept = 0; dropped = 0 } in Hashtbl.replace t.by_context context log; log in
    log.entries <- entry :: log.entries;
    if log.kept < entries_per_context then log.kept <- log.kept + 1
    else begin
      log.entries <- List.filteri (fun index _ -> index < entries_per_context) log.entries;
      log.dropped <- log.dropped + 1
    end

let entry_json entry = `Assoc [
  "type", `String entry.kind;
  "level", `String entry.level;
  "text", (match entry.text with Some text -> `String text | None -> `Null);
  "textCut", `Bool entry.text_cut;
  "timestamp", `Int entry.timestamp ]

let to_json (t : t) ~context =
  let entries, dropped = match Hashtbl.find_opt t.by_context context with
    | Some log -> List.rev log.entries, log.dropped
    | None -> [], 0 in
  `Assoc [ "entries", `List (List.map entry_json entries); "dropped", `Int dropped
         ; "unattributedEntries", `Int t.unattributed
         ; "malformedEvents", `Assoc [ "count", `Int t.malformed
                                     ; "last", (match t.last_malformed with Some reason -> `String reason | None -> `Null) ] ]
