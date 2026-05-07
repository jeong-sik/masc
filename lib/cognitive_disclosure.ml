(* Cognitive disclosure backend - implementation.

   See cognitive_disclosure.mli for the interface contract. *)

type level =
  | Perceive
  | Comprehend
  | Project

let level_to_string = function
  | Perceive -> "perceive"
  | Comprehend -> "comprehend"
  | Project -> "project"

let level_of_string = function
  | "perceive" -> Ok Perceive
  | "comprehend" -> Ok Comprehend
  | "project" -> Ok Project
  | other ->
    Error
      (Printf.sprintf
         "unknown disclosure level '%s' (expected perceive|comprehend|project)"
         other)

let all = [ Perceive; Comprehend; Project ]

let level_index = function
  | Perceive -> 1
  | Comprehend -> 2
  | Project -> 3

let level_label = function
  | Perceive -> "Perceive"
  | Comprehend -> "Comprehend"
  | Project -> "Project"

let level_caption = function
  | Perceive -> "Direct signal"
  | Comprehend -> "Grouped meaning"
  | Project -> "Forward state"

type item = {
  level : level;
  title : string;
  summary : string;
  detail : string option;
  metric : string option;
  default_open : bool;
}

type disclosure_summary = {
  total : int;
  perceive_count : int;
  comprehend_count : int;
  project_count : int;
  open_default_level : level option;
  complete : bool;
}

let summarize (items : item list) : disclosure_summary =
  let p = ref 0 in
  let c = ref 0 in
  let pj = ref 0 in
  let open_default = ref None in
  List.iter
    (fun it ->
      (match it.level with
       | Perceive -> incr p
       | Comprehend -> incr c
       | Project -> incr pj);
      if it.default_open && !open_default = None then
        open_default := Some it.level)
    items;
  let total = !p + !c + !pj in
  let complete = !p > 0 && !c > 0 && !pj > 0 in
  {
    total;
    perceive_count = !p;
    comprehend_count = !c;
    project_count = !pj;
    open_default_level = !open_default;
    complete;
  }

let items_at_level lv items =
  List.filter (fun it -> it.level = lv) items

(* JSON codec --------------------------------------------------------- *)

let opt_str_assoc key = function
  | None -> []
  | Some s -> [ key, `String s ]

let item_to_yojson { level; title; summary; detail; metric; default_open }
    : Yojson.Safe.t =
  `Assoc
    ([
       "level", `String (level_to_string level);
       "title", `String title;
       "summary", `String summary;
     ]
    @ opt_str_assoc "detail" detail
    @ opt_str_assoc "metric" metric
    @ if default_open then [ "defaultOpen", `Bool true ] else [])

let summary_to_yojson { total; perceive_count; comprehend_count;
                        project_count; open_default_level; complete }
    : Yojson.Safe.t =
  let by_level : Yojson.Safe.t =
    `Assoc
      [
        "perceive", `Int perceive_count;
        "comprehend", `Int comprehend_count;
        "project", `Int project_count;
      ]
  in
  let open_default : (string * Yojson.Safe.t) =
    "openDefaultLevel",
    (match open_default_level with
     | None -> `Null
     | Some l -> `String (level_to_string l))
  in
  `Assoc
    [
      "total", `Int total;
      "byLevel", by_level;
      open_default;
      "complete", `Bool complete;
    ]

let ( let* ) = Result.bind

let expect_assoc ~where = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Printf.sprintf "%s: expected JSON object" where)

let find_field fields name =
  try Some (List.assoc name fields) with Not_found -> None

let require_string fields name =
  match find_field fields name with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "field '%s' must be a string" name)
  | None -> Error (Printf.sprintf "missing required field '%s'" name)

let optional_string fields name =
  match find_field fields name with
  | None | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ ->
    Error (Printf.sprintf "field '%s' must be a string when present" name)

let optional_bool fields name =
  match find_field fields name with
  | None | Some `Null -> Ok false
  | Some (`Bool b) -> Ok b
  | Some _ ->
    Error (Printf.sprintf "field '%s' must be a bool when present" name)

let item_of_yojson json =
  let* fields = expect_assoc ~where:"disclosure item" json in
  let* level_str = require_string fields "level" in
  let* level = level_of_string level_str in
  let* title = require_string fields "title" in
  let* summary = require_string fields "summary" in
  let* detail = optional_string fields "detail" in
  let* metric = optional_string fields "metric" in
  let* default_open = optional_bool fields "defaultOpen" in
  Ok { level; title; summary; detail; metric; default_open }

(* Invariant check ---------------------------------------------------- *)

let is_well_formed it =
  if String.length it.title = 0 then Error "title must be non-empty"
  else if String.length it.summary = 0 then
    Error "summary must be non-empty"
  else Ok ()
