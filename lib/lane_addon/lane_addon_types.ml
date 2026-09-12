type contribution = Observe | Derive
type row_kind = Event | Value | Relation
type evidence = { uri : string; sha256 : string option }
type clock = { domain : string; value : string }
type row = {
  id : string; lane_id : string; kind : row_kind; title : string;
  observed_at : float; subject_id : string; clock : clock option;
  actor : string option; fields : (string * Yojson.Safe.t) list;
  evidence : evidence list; related_ids : string list;
}
type coverage = {
  source_id : string; incarnation : string; cursor : string option;
  complete : bool; detail : string option;
}
type output = { rows : row list; coverage : coverage list }
type resources = { cpus : float; memory_bytes : int64; pids : int; max_reply_bytes : int }
type package = {
  id : string; revision : string; title : string; contributions : contribution list;
  image : string; command : string list; directory : string;
  skills_directory : Skill_resource_path.t option; resources : resources;
}
type phase = Attached | Observing | Failed of string | Detaching | Detached

let ( let* ) = Result.bind
let string value = `String value
let optional f = function None -> `Null | Some value -> f value
let strings values = `List (List.map string values)
let object_fields expected = function
  | `Assoc fields ->
      let names = List.map fst fields |> List.sort String.compare in
      if names = List.sort String.compare expected then Ok fields
      else Error ("expected exactly fields: " ^ String.concat ", " expected)
  | _ -> Error "expected an object"
let field fields name = List.assoc name fields
let text name = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error (name ^ ": expected non-blank string")
let nullable parse = function `Null -> Ok None | value -> Result.map Option.some (parse value)
let list parse = function
  | `List values ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest -> let* value = parse value in loop (value :: acc) rest
      in loop [] values
  | _ -> Error "expected an array"
let finite = function
  | `Int n -> Ok (float_of_int n)
  | `Float value ->
      (match classify_float value with
       | FP_normal | FP_subnormal | FP_zero -> Ok value
       | FP_nan | FP_infinite -> Error "expected finite timestamp")
  | _ -> Error "expected numeric timestamp"
let evidence_to_json (e : evidence) =
  `Assoc ["uri", string e.uri; "sha256", optional string e.sha256]
let evidence_of_json json =
  let* fields = object_fields ["uri"; "sha256"] json in
  let* uri = text "uri" (field fields "uri") in
  let* sha256 = nullable (text "sha256") (field fields "sha256") in
  Ok { uri; sha256 }
let clock_to_json (c : clock) = `Assoc ["domain", string c.domain; "value", string c.value]
let clock_of_json json =
  let* fields = object_fields ["domain"; "value"] json in
  let* domain = text "domain" (field fields "domain") in
  let* value = text "value" (field fields "value") in
  Ok { domain; value }
let kind_to_string = function Event -> "event" | Value -> "value" | Relation -> "relation"
let kind_of_json = function
  | `String "event" -> Ok Event | `String "value" -> Ok Value
  | `String "relation" -> Ok Relation | _ -> Error "unknown row kind"
let row_to_json (r : row) =
  `Assoc ["id", string r.id; "lane_id", string r.lane_id;
    "kind", string (kind_to_string r.kind); "title", string r.title;
    "observed_at", `Float r.observed_at; "subject_id", string r.subject_id;
    "clock", optional clock_to_json r.clock; "actor", optional string r.actor;
    "fields", `Assoc r.fields; "evidence", `List (List.map evidence_to_json r.evidence);
    "related_ids", strings r.related_ids]
let row_of_json json =
  let* f = object_fields ["id"; "lane_id"; "kind"; "title"; "observed_at";
    "subject_id"; "clock"; "actor"; "fields"; "evidence"; "related_ids"] json in
  let* id = text "id" (field f "id") in
  let* lane_id = text "lane_id" (field f "lane_id") in
  let* kind = kind_of_json (field f "kind") in
  let* title = text "title" (field f "title") in
  let* observed_at = finite (field f "observed_at") in
  let* subject_id = text "subject_id" (field f "subject_id") in
  let* clock = nullable clock_of_json (field f "clock") in
  let* actor = nullable (text "actor") (field f "actor") in
  let* fields = match field f "fields" with
    | `Assoc values ->
        let names = List.map fst values in
        if List.length names = List.length (List.sort_uniq String.compare names)
        then Ok values else Error "duplicate display field"
    | _ -> Error "fields: expected object" in
  let* evidence = list evidence_of_json (field f "evidence") in
  let* related_ids = list (text "related_ids") (field f "related_ids") in
  Ok { id; lane_id; kind; title; observed_at; subject_id; clock; actor;
       fields; evidence; related_ids }
let coverage_to_json (c : coverage) =
  `Assoc ["source_id", string c.source_id; "incarnation", string c.incarnation;
    "cursor", optional string c.cursor; "complete", `Bool c.complete;
    "detail", optional string c.detail]
let coverage_of_json json =
  let* f = object_fields ["source_id"; "incarnation"; "cursor"; "complete"; "detail"] json in
  let* source_id = text "source_id" (field f "source_id") in
  let* incarnation = text "incarnation" (field f "incarnation") in
  let* cursor = nullable (text "cursor") (field f "cursor") in
  let* complete = match field f "complete" with `Bool b -> Ok b | _ -> Error "complete: expected bool" in
  let* detail = nullable (text "detail") (field f "detail") in
  Ok { source_id; incarnation; cursor; complete; detail }
let output_to_json (o : output) =
  `Assoc ["rows", `List (List.map row_to_json o.rows);
          "coverage", `List (List.map coverage_to_json o.coverage)]
let output_of_json json =
  let* f = object_fields ["rows"; "coverage"] json in
  let* rows = list row_of_json (field f "rows") in
  let* coverage = list coverage_of_json (field f "coverage") in
  let ids = List.map (fun (r : row) -> r.id) rows in
  if List.length ids <> List.length (List.sort_uniq String.compare ids)
  then Error "duplicate row identity in one observation"
  else Ok { rows; coverage }
let phase_to_json = function
  | Attached -> `Assoc ["kind", string "attached"]
  | Observing -> `Assoc ["kind", string "observing"]
  | Failed message -> `Assoc ["kind", string "failed"; "message", string message]
  | Detaching -> `Assoc ["kind", string "detaching"]
  | Detached -> `Assoc ["kind", string "detached"]
let phase_of_json = function
  | `Assoc ["kind", `String "attached"] -> Ok Attached
  | `Assoc ["kind", `String "observing"] -> Ok Observing
  | `Assoc ["kind", `String "detaching"] -> Ok Detaching
  | `Assoc ["kind", `String "detached"] -> Ok Detached
  | `Assoc fields ->
      let* f = object_fields ["kind"; "message"] (`Assoc fields) in
      (match field f "kind", field f "message" with
       | `String "failed", `String message -> Ok (Failed message)
       | _ -> Error "invalid Lane phase")
  | _ -> Error "invalid Lane phase"
let package_to_json (p : package) =
  `Assoc ["id", string p.id; "revision", string p.revision; "title", string p.title;
    "contributions", strings (List.map (function Observe -> "observe" | Derive -> "derive") p.contributions);
    "image", string p.image; "command", strings p.command; "directory", string p.directory;
    "skills_directory", (match p.skills_directory with None -> `Null
      | Some path -> string (Skill_resource_path.to_string path));
    "resources", `Assoc ["cpus", `Float p.resources.cpus;
      "memory_bytes", `Intlit (Int64.to_string p.resources.memory_bytes);
      "pids", `Int p.resources.pids; "max_reply_bytes", `Int p.resources.max_reply_bytes]]
