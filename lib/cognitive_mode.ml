(* Cognitive mode FSM - implementation.

   See cognitive_mode.mli for the interface contract. *)

type t =
  | Cockpit
  | Code
  | Split
  | Explode

let all = [ Cockpit; Code; Split; Explode ]

let to_string = function
  | Cockpit -> "cockpit"
  | Code -> "code"
  | Split -> "split"
  | Explode -> "explode"

let of_string = function
  | "cockpit" -> Ok Cockpit
  | "code" -> Ok Code
  | "split" -> Ok Split
  | "explode" -> Ok Explode
  | other ->
    Error
      (Printf.sprintf
         "unknown cognitive mode '%s' (expected cockpit|code|split|explode)"
         other)

type load_kind =
  | Situational
  | Focused
  | Comparative
  | Exploratory

let load_to_string = function
  | Situational -> "situational"
  | Focused -> "focused"
  | Comparative -> "comparative"
  | Exploratory -> "exploratory"

let load_of_string = function
  | "situational" -> Ok Situational
  | "focused" -> Ok Focused
  | "comparative" -> Ok Comparative
  | "exploratory" -> Ok Exploratory
  | other ->
    Error
      (Printf.sprintf
         "unknown load kind '%s' (expected situational|focused|comparative|exploratory)"
         other)

let load_of_mode = function
  | Cockpit -> Situational
  | Code -> Focused
  | Split -> Comparative
  | Explode -> Exploratory

type layout =
  | All_panels
  | Editor_first
  | Side_by_side
  | Graph_map

let layout_to_string = function
  | All_panels -> "all-panels"
  | Editor_first -> "editor-first"
  | Side_by_side -> "side-by-side"
  | Graph_map -> "graph-map"

let layout_of_string = function
  | "all-panels" -> Ok All_panels
  | "editor-first" -> Ok Editor_first
  | "side-by-side" -> Ok Side_by_side
  | "graph-map" -> Ok Graph_map
  | other ->
    Error
      (Printf.sprintf
         "unknown layout '%s' (expected all-panels|editor-first|side-by-side|graph-map)"
         other)

let layout_of_mode = function
  | Cockpit -> All_panels
  | Code -> Editor_first
  | Split -> Side_by_side
  | Explode -> Graph_map

type state = {
  mode : t;
  label : string;
  load : load_kind;
  layout : layout;
}

let state_of_mode m =
  let label =
    match m with
    | Cockpit -> "Cockpit"
    | Code -> "Code"
    | Split -> "Split"
    | Explode -> "Explode"
  in
  {
    mode = m;
    label;
    load = load_of_mode m;
    layout = layout_of_mode m;
  }

(* Transitions ---------------------------------------------------------- *)

type signal =
  | Project_open
  | Review_started
  | File_edit_started
  | Sustained_focus_window
  | Diff_view_requested
  | Reference_lookup
  | Codebase_exploration
  | Learning_session
  | Reset_to_overview

let signal_to_string = function
  | Project_open -> "project_open"
  | Review_started -> "review_started"
  | File_edit_started -> "file_edit_started"
  | Sustained_focus_window -> "sustained_focus_window"
  | Diff_view_requested -> "diff_view_requested"
  | Reference_lookup -> "reference_lookup"
  | Codebase_exploration -> "codebase_exploration"
  | Learning_session -> "learning_session"
  | Reset_to_overview -> "reset_to_overview"

(* Master Report section 1.4 transition triggers:
     COCKPIT <- project open / review start / explicit reset to overview
     CODE    <- file edit start / sustained focus
     SPLIT   <- diff view / reference lookup while editing
     EXPLODE <- codebase exploration / learning session

   Every (current, signal) pair maps to a target mode. Signals are
   interpreted as observed user intent, not as guarded edge labels, so
   callers do not need a separate invalid-transition policy. *)
let transition ~current:_ ~signal =
  match signal with
  | Project_open
  | Review_started
  | Reset_to_overview -> Cockpit
  | File_edit_started
  | Sustained_focus_window -> Code
  | Diff_view_requested
  | Reference_lookup -> Split
  | Codebase_exploration
  | Learning_session -> Explode

(* JSON codec ----------------------------------------------------------- *)

let to_yojson m : Yojson.Safe.t = `String (to_string m)

let of_yojson = function
  | `String s -> of_string s
  | _ -> Error "cognitive mode must be a JSON string"

let ( let* ) = Result.bind

let expect_assoc = function
  | `Assoc fields -> Ok fields
  | _ -> Error "cognitive mode state must be a JSON object"

let require_string fields name =
  match List.assoc_opt name fields with
  | Some (`String s) -> Ok s
  | Some _ -> Error (Printf.sprintf "field '%s' must be a string" name)
  | None -> Error (Printf.sprintf "missing required field '%s'" name)

let state_to_yojson { mode; label; load; layout } : Yojson.Safe.t =
  `Assoc
    [
      "mode", `String (to_string mode);
      "label", `String label;
      "load", `String (load_to_string load);
      "layout", `String (layout_to_string layout);
    ]

let state_of_yojson json =
  let* fields = expect_assoc json in
  let* mode_str = require_string fields "mode" in
  let* mode = of_string mode_str in
  let* label = require_string fields "label" in
  let* load_str = require_string fields "load" in
  let* load = load_of_string load_str in
  let* layout_str = require_string fields "layout" in
  let* layout = layout_of_string layout_str in
  Ok { mode; label; load; layout }
