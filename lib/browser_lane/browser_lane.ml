module Native_workflow = Browser_native_workflow
(** Browser_lane — the in-process state of the masc ↔ browser lanes
    (docs/design/browser-lane.md, task-1382).

    A lane is one connected browser backend: "live" is the user's real
    Firefox/Zen through the extension's native-messaging host. "automation"
    is the in-process OCaml WebDriver executor. "stagehand" is a Chromium the
    server launches with the Stagehand runtime, reached over CDP
    (RFC-browser-lane-stagehand). Only the live host long-polls this process
    and posts results through the HTTP transport; automation and stagehand
    own their sessions directly inside the server.

    Verbs are a closed variant: an unknown verb is refused by name on every
    boundary (tool input, lane issue, backend), the same rule the observe
    gate learned the hard way (#33638). *)

open Time_compat
module Pointer = Browser_pointer
module Action = Browser_action
module Keyboard = Browser_keyboard
module Upload_lease = Browser_upload_lease
module Document = Browser_document
module Capture = Browser_capture_options
module Lane_name = Browser_lane_name
module Backend = Browser_backend
module Lane_token = Browser_lane_token

(* Shared default for ordinary browser transport requests, in core and workers. *)
let default_timeout_sec = 20.

type node_ref = { document_id : string; node_id : string }
type scene_view = Content | Regions
(* What an accessibility snapshot covers: the viewport, the whole page, or the
   subtree under one ref an earlier snapshot of the same page printed. *)
type snapshot_scope = Snapshot_viewport | Snapshot_full_page | Snapshot_subtree of int
(* What an ego connection's own element actions find: a ref an ego snapshot
   printed, an accessibility role with its name, or page text. [exact] is the
   whole name or text, case-sensitive; otherwise a part of it, any case. *)
type snapshot_target =
  | Target_ref of int
  | Target_role of { role : string; name : string; exact : bool }
  | Target_text of { text : string; exact : bool }
type pointer_target = Selector of string | Scene_node of node_ref

(* A CSS-pixel size the browser's viewport is forced to, or the browser's own size again. *)
type viewport_size = Fit of { width : int; height : int } | Browser_default

(* The bounds of a requested viewport side, in CSS pixels. Firefox 158 accepts 0 and 100000 without
   an error (probed 2026-10-22), so these are this lane's policy, not the browser's limit. *)
let viewport_side_min_px = 100
let viewport_side_max_px = 4096

type option_selection = Single_option of string | Multiple_options of string list

type interaction = Activate_tab | Click of string | Fill of { selector : string; text : string }
  | Select_option of { selector : string; selection : option_selection }
  | Set_zoom of { factor : float }
  | Set_viewport of viewport_size
  | Double_click of pointer_target
  | Double_click_at of { point : Pointer.point; viewport : Pointer.viewport }
  | Type_text of { document_id : string; text : string }
  | Press_key of { document_id : string; key : Keyboard.t }
  | Scroll of { x : int; y : int }
  | Hover of pointer_target
  | Drag_to of { source : pointer_target; destination : pointer_target; via : Pointer.point list; duration_ms : int }
  | Hover_at of { point : Pointer.point; viewport : Pointer.viewport }
  | Tap_at of { point : Pointer.point; viewport : Pointer.viewport }
  | Swipe of { from : Pointer.point; to_ : Pointer.point; viewport : Pointer.viewport; via : Pointer.point list; duration_ms : int }
  | Click_at of { point : Pointer.point; viewport : Pointer.viewport; button : Pointer.button }
  | Scroll_at of { point : Pointer.point; viewport : Pointer.viewport; x : int; y : int }
  | Drag of { from : Pointer.point; to_ : Pointer.point; viewport : Pointer.viewport; via : Pointer.point list; duration_ms : int }
  | Follow_link of node_ref | Click_node of node_ref | Fill_node of { target : node_ref; text : string }
  | Click_target of snapshot_target | Fill_target of { target : snapshot_target; text : string }
  | Hover_target of snapshot_target | Double_click_target of snapshot_target

(* Whether an interaction acts on an ego snapshot target, which only an ego
   connection serves. *)
let acts_on_snapshot_target = function
  | Click_target _ | Fill_target _ | Hover_target _ | Double_click_target _ -> true
  | Activate_tab | Click _ | Fill _ | Select_option _ | Set_zoom _ | Set_viewport _ | Double_click _
  | Double_click_at _ | Type_text _ | Press_key _ | Scroll _ | Hover _ | Drag_to _ | Hover_at _ | Tap_at _
  | Swipe _ | Click_at _ | Scroll_at _ | Drag _ | Follow_link _ | Click_node _ | Fill_node _ -> false

type elements_filter = { within : string option; selector : string option }

let unfiltered_elements = { within = None; selector = None }

let elements_filter_fields {within; selector} =
  List.filter_map (fun (key, value) -> Option.map (fun value -> key, `String value) value)
    ["within", within; "selector", selector]

type verb =
  | Tabs_list
  | Page_read of { tab_id : int option; max_chars : int option }
  | Page_document of { tab_id : int }
  | Page_downloads of { tab_id : int }
  | Page_console of { tab_id : int }
  | Page_network of { tab_id : int }
  | Page_cookies of { tab_id : int }
  | Page_capture of { tab_id : int; options : Capture.t option }
  | Page_scene of { tab_id : int; max_chars : int; view : scene_view; scope : node_ref option }
  (* The connection's own accessibility snapshot of a page, with the refs its
     element actions accept (an ego task space; RFC-browser-live-ego). *)
  | Page_snapshot of { tab_id : int; max_chars : int; scope : snapshot_scope }
  | Page_native_workflow of Native_workflow.t
  | Page_interact of { tab_id : int; frame_path : string list; expected_url : string option; action : interaction }
  | Session_open of { headless : bool option }
  | Session_close
  (* Reads the backend's own record of whether a session exists. It issues no
     browser request, so it answers while a session is closed -- which is the
     question a keeper has before deciding to open one. *)
  | Session_status
  | Page_goto of { url : string; tab_id : int option }
  | Page_elements of { tab_id : int option; filter : elements_filter }
  | Page_act of Browser_action.t
  | Page_context of { tab_id : int; frame_path : string list; mode : [ `Text of int | `Elements of elements_filter | `Frames | `Dialog ] }
  (* Sentences for the Stagehand runtime (RFC-browser-lane-stagehand §3.2):
     act on, locate, or extract from the page, with element choice left to
     the model the runtime asks. *)
  | Page_instruct of { tab_id : int; instruction : string }
  | Page_locate of { tab_id : int; instruction : string option }
  | Page_extract of { tab_id : int; instruction : string; schema : Yojson.Safe.t option }

(** Shared reply observation policy for built-in and Add-on callers. A timed-out
    observation does not establish that the browser effect did not happen.
    Model-backed Stagehand verbs retain their executor-owned wait policy. *)
let reply_timeout_sec = function
  | Session_open _ | Session_close -> 60.
  | Session_status -> 10.
  | Page_goto _ -> 45.
  | Page_act action -> Action.reply_timeout_sec action
  | Tabs_list | Page_read _ | Page_document _ | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _ | Page_capture _
  | Page_scene _ | Page_snapshot _ | Page_interact _ | Page_native_workflow _ | Page_elements _ | Page_context _
  | Page_instruct _ | Page_locate _ | Page_extract _ -> default_timeout_sec

type reply_policy = Reply_window | Executor_owned
let reply_policy = function
  | Page_native_workflow _ -> Executor_owned
  | Page_act action ->
    (match action with
     | Action.Control (Action.Space_status|Action.Finish_space _|Action.Wait_for_control _|Action.Adopt_tab _|Action.Release_tab _) -> Executor_owned
     | Action.Open_tab _ | Action.Open_window _ | Action.Control (Action.Hand_off|Action.Take_over) -> Reply_window
     | Action.On_tab {interaction;_} ->
       (match interaction with
        | Action.Upload _ -> Executor_owned
        | Action.Set_cookie _ | Action.Delete_cookie _ | Action.Set_emulation _ | Action.Clear_emulation
        | Action.Block_requests _ | Action.Unblock_requests | Action.Accept_dialog _ | Action.Dismiss_dialog
        | Action.Back | Action.Forward | Action.Reload | Action.Close_tab -> Reply_window))
  | Tabs_list | Page_read _ | Page_document _ | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _
  | Page_capture _ | Page_scene _ | Page_snapshot _ | Page_interact _ | Session_open _ | Session_close | Session_status
  | Page_goto _ | Page_elements _ | Page_context _ | Page_instruct _ | Page_locate _ | Page_extract _ -> Reply_window

(* SDK-native navigation and selector/ref input need no MASC execution clock. Scene,
   coordinate and custom-waypoint adapters retain their existing guards. *)
let ego_reply_policy = function
  | Page_capture _ -> Executor_owned
  | Page_goto _ -> Executor_owned
  | Page_act action ->
    (match action with
     | Action.Open_tab _ -> Executor_owned
     | Action.On_tab {interaction=Action.Reload;_} -> Executor_owned
     | (Action.Open_window _ | Action.Control _
       | Action.On_tab {interaction=(Action.Upload _ | Action.Set_cookie _ | Action.Delete_cookie _
         | Action.Set_emulation _ | Action.Clear_emulation | Action.Block_requests _
         | Action.Unblock_requests | Action.Accept_dialog _ | Action.Dismiss_dialog
         | Action.Back | Action.Forward | Action.Close_tab);_}) -> reply_policy (Page_act action))
  | Page_interact {action;_} ->
    (match action with
     | Activate_tab | Click _ | Fill _ | Select_option _ | Click_target _ | Fill_target _
     | Hover_target _ | Double_click_target _ -> Executor_owned
     | Hover (Selector _) | Double_click (Selector _) -> Executor_owned
     | Drag_to {source;destination;via;duration_ms} ->
       (match source,destination with
        | Selector _,Selector _ ->
          (match via with [] when duration_ms=0 -> Executor_owned
           | [] | _::_ -> Reply_window)
        | Scene_node _,(Selector _|Scene_node _) | Selector _,Scene_node _ -> Reply_window)
     | Hover (Scene_node _) | Double_click (Scene_node _)
     | Set_zoom _ | Set_viewport _ | Double_click_at _ | Type_text _
     | Press_key _ | Scroll _ | Hover_at _ | Tap_at _ | Swipe _ | Click_at _
     | Scroll_at _ | Drag _ | Follow_link _ | Click_node _ | Fill_node _ -> Reply_window)
  | (Tabs_list | Page_read _ | Page_document _ | Page_downloads _ | Page_console _
    | Page_network _ | Page_cookies _ | Page_scene _ | Page_snapshot _
    | Page_native_workflow _ | Session_open _ | Session_close | Session_status
    | Page_elements _ | Page_context _ | Page_instruct _
    | Page_locate _ | Page_extract _) as verb -> reply_policy verb

(* The CSS scope an elements read carries, top-level or in a frame. Every
   caller that relays such a read checks the answer against it. *)
let elements_filter = function
  | Page_elements { filter; _ } -> filter
  | Page_context { mode = `Elements filter; _ } -> filter
  | Page_context { mode = (`Text _ | `Frames | `Dialog); _ }
  | Tabs_list | Page_read _ | Page_document _ | Page_downloads _ | Page_console _ | Page_network _
  | Page_cookies _ | Page_capture _ | Page_scene _ | Page_snapshot _ | Page_interact _ | Page_native_workflow _ | Session_open _ | Session_close
  | Session_status | Page_goto _ | Page_act _ | Page_instruct _ | Page_locate _ | Page_extract _ -> unfiltered_elements
;;

let verb_to_string = function
  | Tabs_list -> "tabs.list"
  | Page_read _ -> "page.read"
  | Page_document _ -> "page.document"
  | Page_downloads _ -> "page.downloads"
  | Page_console _ -> "page.console"
  | Page_network _ -> "page.network"
  | Page_cookies _ -> "page.cookies"
  | Page_capture _ -> "page.capture"
  | Page_scene _ -> "page.scene"
  | Page_snapshot _ -> "page.snapshot"
  | Page_interact _ -> "page.interact"
  | Page_native_workflow _ -> "page.native_workflow"
  | Session_open _ -> "session.open"
  | Session_close -> "session.close"
  | Session_status -> "session.status"
  | Page_goto _ -> "page.goto"
  | Page_elements _ -> "page.elements"
  | Page_act _ -> "page.act"
  | Page_context _ -> "page.context"
  | Page_instruct _ -> "page.instruct"
  | Page_locate _ -> "page.locate"
  | Page_extract _ -> "page.extract"
;;

(* The wire carries a verb name plus args; the closed variant is the only
   thing that crosses a boundary. *)
let interaction_verb = function
  | Activate_tab -> "activate_tab"
  | Set_zoom _ -> "set_zoom"
  | Set_viewport _ -> "set_viewport"
  | Select_option _ -> "select_option"
  | Double_click _ | Double_click_target _ -> "double_click"
  | Double_click_at _ -> "double_click_at"
  | Type_text _ -> "type_text"
  | Press_key _ -> "press_key"
  | Scroll_at _ -> "scroll_at"
  | Hover _ | Hover_target _ -> "hover"
  | Drag_to _ -> "drag_to"
  | Hover_at _ -> "hover_at"
  | Tap_at _ -> "tap_at"
  | Swipe _ -> "swipe"
  | Click_at _ -> "click_at"
  | Drag _ -> "drag"
  | Click _ | Click_node _ | Click_target _ -> "click"
  | Fill _ | Fill_node _ | Fill_target _ -> "fill"
  | Follow_link _ -> "follow_link"
  | Scroll _ -> "scroll"
;;

let drag_fields via duration_ms =
  (match via with [] -> [] | _::_ -> ["via", `List (List.map Pointer.point_to_json via)])
  @ (if duration_ms = 0 then [] else ["durationMs", `Int duration_ms])

let snapshot_target_to_json = function
  | Target_ref node -> `Assoc ["ref",`Int node]
  | Target_role {role;name;exact} -> `Assoc ["role",`String role;"name",`String name;"exact",`Bool exact]
  | Target_text {text;exact} -> `Assoc ["text",`String text;"exact",`Bool exact]
let snapshot_target_of_json = function
  | `Assoc fields ->
    let open Result.Syntax in
    let exact () = match List.assoc_opt "exact" fields with
      | None -> Ok true
      | Some (`Bool exact) -> Ok exact
      | Some _ -> Error "target exact must be true or false" in
    let nonblank key = match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None -> Error ("target " ^ key ^ " must be nonblank text") in
    (match List.sort String.compare (List.map fst fields) with
     | ["ref"] -> (match List.assoc "ref" fields with
         | `Int node when node >= 0 -> Ok (Target_ref node)
         | _ -> Error "target ref is the number an ego snapshot printed, such as 12 for ref=12")
     | ["name";"role"] | ["exact";"name";"role"] ->
       let* role = nonblank "role" in
       let* () = if String.for_all (fun c -> c >= 'a' && c <= 'z') role then Ok ()
         else Error "target role is one lowercase ARIA role, such as button" in
       let* name = nonblank "name" in
       let* exact = exact () in
       Ok (Target_role {role;name;exact})
     | ["text"] | ["exact";"text"] ->
       let* text = nonblank "text" in
       let* exact = exact () in
       (* ego trims ECMAScript whitespace before reading a leading quote as
          exact text. String.trim alone misses NBSP, BOM and Unicode spaces.
          https://tc39.es/ecma262/#sec-white-space *)
       let rec quoted i =
         if i >= String.length text then false else
         let decoded = String.get_utf_8_uchar text i in
         match Uchar.to_int (Uchar.utf_decode_uchar decoded) with
         | 0x22 | 0x27 -> true
         | 0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x20 | 0xA0 | 0x1680
         | 0x2028 | 0x2029 | 0x202F | 0x205F | 0x3000 | 0xFEFF ->
           quoted (i + Uchar.utf_decode_length decoded)
         | code when code >= 0x2000 && code <= 0x200A ->
           quoted (i + Uchar.utf_decode_length decoded)
         | _ -> false in
       (* >> starts a chained selector. *)
       let rec chained i = i + 1 < String.length text && ((text.[i] = '>' && text.[i + 1] = '>') || chained (i + 1)) in
       let* () = if exact || not (quoted 0 || chained 0) then Ok ()
         else Error "a part-of-text target cannot start with a quote or contain >>; set exact to true" in
       Ok (Target_text {text;exact})
     | _ -> Error "target is {ref}, {role, name, exact} or {text, exact}")
  | _ -> Error "target must be an object"

let interaction_args ~tab_id ~frame_path ~expected_url action =
  let node_fields target = ["documentId",`String target.document_id; "nodeId",`String target.node_id] in
  let target_fields = function Selector selector -> ["selector",`String selector]
    | Scene_node target -> node_fields target in
  let verb = "action", `String (interaction_verb action) in
  let fields = match action with
    | Activate_tab -> [verb]
    | Set_zoom {factor} -> [verb;"factor",`Float factor]
    | Set_viewport Browser_default -> [verb]
    | Set_viewport (Fit {width;height}) -> [verb;"width",`Int width;"height",`Int height]
    | Double_click target -> verb :: target_fields target
    | Double_click_at {point;viewport} -> [verb;
        "point",Pointer.point_to_json point;"viewport",Pointer.viewport_to_json viewport]
    | Type_text {document_id;text} -> [verb;"documentId",`String document_id;"text",`String text]
    | Press_key {document_id;key} -> [verb;"documentId",`String document_id] @ Keyboard.to_json_fields key
    | Hover target -> verb :: target_fields target
    | Drag_to {source;destination;via;duration_ms} -> [verb; "source",`Assoc (target_fields source);
        "destination",`Assoc (target_fields destination)] @ drag_fields via duration_ms
    | Scroll_at {point;viewport;x;y} -> [verb;
        "point", Pointer.point_to_json point; "viewport", Pointer.viewport_to_json viewport;
        "x",`Int x; "y",`Int y]
    | Hover_at {point;viewport} -> [verb;
        "point", Pointer.point_to_json point; "viewport", Pointer.viewport_to_json viewport]
    | Tap_at {point;viewport} -> [verb;
        "point", Pointer.point_to_json point; "viewport", Pointer.viewport_to_json viewport]
    | Swipe {from;to_;viewport;via;duration_ms} -> [verb;
        "from", Pointer.point_to_json from; "to", Pointer.point_to_json to_;
        "viewport", Pointer.viewport_to_json viewport] @ drag_fields via duration_ms
    | Click_at {point;viewport;button} -> [verb;
        "point", Pointer.point_to_json point; "viewport", Pointer.viewport_to_json viewport]
        @ (match button with
           | Pointer.Primary -> []
           | Pointer.Middle | Pointer.Secondary -> ["button", `String (Pointer.button_to_string button)])
    | Drag {from;to_;viewport;via;duration_ms} -> [verb;
        "from", Pointer.point_to_json from; "to", Pointer.point_to_json to_;
        "viewport", Pointer.viewport_to_json viewport] @ drag_fields via duration_ms
    | Click selector -> [verb; "selector", `String selector]
    | Fill {selector; text} -> [verb; "selector", `String selector; "text", `String text]
    | Select_option {selector; selection} ->
      [verb; "selector", `String selector] @ (match selection with
        | Single_option value -> ["value", `String value]
        | Multiple_options values -> ["values", `List (List.map (fun value -> `String value) values)])
    | Follow_link target -> verb :: node_fields target
    | Click_node target -> verb :: node_fields target
    | Fill_node {target;text} -> verb :: ("text",`String text) :: node_fields target
    | Click_target target | Hover_target target | Double_click_target target -> [verb;"target",snapshot_target_to_json target]
    | Fill_target {target;text} -> [verb;"target",snapshot_target_to_json target;"text",`String text]
    | Scroll {x; y} -> [verb; "x", `Int x; "y", `Int y] in
  `Assoc (("tabId", `Int tab_id) :: fields @
    (if frame_path = [] then [] else ["framePath", `List (List.map (fun s -> `String s) frame_path)]) @
    (Option.map (fun url -> "expectedUrl", `String url) expected_url |> Option.to_list))

let scene_args ~tab_id ~max_chars ~view ~scope =
  `Assoc (["tabId",`Int tab_id;"maxChars",`Int max_chars;
    "view",`String (match view with Content -> "content" | Regions -> "regions")]
    @ (match scope with None -> [] | Some target -> ["scope",`Assoc [
      "documentId",`String target.document_id;"nodeId",`String target.node_id]]))

(* A ref as an ego snapshot prints it ([@12]) or as its selectors accept it
   ([ref=12]): decimal digits only. *)
let snapshot_ref_of_string raw =
  let after prefix = String.sub raw (String.length prefix) (String.length raw - String.length prefix) in
  let digits = if String.starts_with ~prefix:"@" raw then after "@"
    else if String.starts_with ~prefix:"ref=" raw then after "ref="
    else "" in
  let decimal = digits <> "" && String.for_all (fun c -> c >= '0' && c <= '9') digits in
  match decimal, int_of_string_opt digits with
  | true, Some node -> Ok node
  | true, None | false, _ -> Error "root must be a ref an ego snapshot printed, such as @12"
let snapshot_scope_of_wire ~scope ~root = match scope, root with
  | "viewport", None -> Ok Snapshot_viewport
  | "full_page", None -> Ok Snapshot_full_page
  | "subtree", Some raw -> Result.map (fun node -> Snapshot_subtree node) (snapshot_ref_of_string raw)
  | "subtree", None -> Error "a subtree snapshot needs root, a ref an ego snapshot printed such as @12"
  | ("viewport" | "full_page"), Some _ -> Error "root applies only to a subtree snapshot"
  | _, (None | Some _) -> Error "snapshot scope is viewport, full_page or subtree"
let snapshot_scope_fields = function
  | Snapshot_viewport -> ["scope",`String "viewport"]
  | Snapshot_full_page -> ["scope",`String "full_page"]
  | Snapshot_subtree node -> ["scope",`String "subtree";"root",`String ("@" ^ string_of_int node)]
let snapshot_args ~tab_id ~max_chars ~scope =
  `Assoc (["tabId",`Int tab_id;"maxChars",`Int max_chars] @ snapshot_scope_fields scope)

let verb_json = function
  | Tabs_list -> `Assoc [ ("verb", `String "tabs.list"); ("args", `Assoc []) ]
  | Page_read { tab_id; max_chars } ->
    `Assoc
      [ ("verb", `String "page.read")
      ; ( "args"
        , `Assoc
            ([ Option.map (fun v -> ("tabId", `Int v)) tab_id
             ; Option.map (fun v -> ("maxChars", `Int v)) max_chars
             ]
             |> List.filter_map Fun.id) )
      ]
  | Page_document {tab_id} ->
    `Assoc ["verb", `String "page.read";
      "args", `Assoc ["tabId", `Int tab_id; "includeHtml", `Bool true]]
  | Page_downloads {tab_id} ->
    `Assoc ["verb",`String "page.downloads";"args",`Assoc ["tabId",`Int tab_id]]
  | Page_console {tab_id} ->
    `Assoc ["verb",`String "page.console";"args",`Assoc ["tabId",`Int tab_id]]
  | Page_network {tab_id} ->
    `Assoc ["verb",`String "page.network";"args",`Assoc ["tabId",`Int tab_id]]
  | Page_cookies {tab_id} ->
    `Assoc ["verb",`String "page.cookies";"args",`Assoc ["tabId",`Int tab_id]]
  | Page_scene {tab_id;max_chars;view;scope} ->
    `Assoc ["verb",`String "page.scene";"args",scene_args ~tab_id ~max_chars ~view ~scope]
  | Page_snapshot {tab_id;max_chars;scope} ->
    `Assoc ["verb",`String "page.snapshot";"args",snapshot_args ~tab_id ~max_chars ~scope]
  | Page_capture { tab_id; options } ->
    `Assoc ["verb", `String "page.capture"; "args", `Assoc (["tabId", `Int tab_id]
      @ Option.to_list (Option.map (fun value -> "options",Capture.to_json value) options))]
  | Page_native_workflow workflow ->
    `Assoc ["verb",`String "page.native_workflow";"args",Native_workflow.to_json workflow]
  | Page_interact { tab_id; frame_path; expected_url; action } ->
    `Assoc ["verb", `String "page.interact"; "args", interaction_args ~tab_id ~frame_path ~expected_url action]
  | Session_open { headless } ->
    `Assoc
      [ ("verb", `String "session.open")
      ; ( "args"
        , `Assoc (Option.map (fun v -> ("headless", `Bool v)) headless |> Option.to_list) )
      ]
  | Session_close -> `Assoc [ ("verb", `String "session.close"); ("args", `Assoc []) ]
  | Session_status -> `Assoc [ ("verb", `String "session.status"); ("args", `Assoc []) ]
  | Page_goto { url; tab_id } ->
    `Assoc ["verb", `String "page.goto"; "args", `Assoc
      (["url", `String url] @ Option.to_list (Option.map (fun id -> "tabId", `Int id) tab_id))]
  | Page_elements { tab_id; filter } ->
    `Assoc ["verb", `String "page.elements"; "args", `Assoc
      (Option.to_list (Option.map (fun id -> "tabId", `Int id) tab_id)
       @ elements_filter_fields filter)]
  | Page_context {tab_id;frame_path;mode} ->
    let name, extra = match mode with
      | `Text cap -> "text", ["maxChars",`Int cap]
      | `Elements filter -> "elements", elements_filter_fields filter
      | `Frames -> "frames", [] | `Dialog -> "dialog", [] in
    `Assoc ["verb",`String "page.context";"args",`Assoc
      (["tabId",`Int tab_id;"framePath",`List (List.map (fun s -> `String s) frame_path);"mode",`String name] @ extra)]
  | Page_act action ->
    `Assoc ["verb", `String "page.act"; "args", Browser_action.to_json action]
  | Page_instruct { tab_id; instruction } ->
    `Assoc ["verb", `String "page.instruct"; "args", `Assoc ["tabId", `Int tab_id; "instruction", `String instruction]]
  | Page_locate { tab_id; instruction } ->
    `Assoc ["verb", `String "page.locate"; "args", `Assoc
      (["tabId", `Int tab_id] @ Option.to_list (Option.map (fun text -> "instruction", `String text) instruction))]
  | Page_extract { tab_id; instruction; schema } ->
    `Assoc ["verb", `String "page.extract"; "args", `Assoc
      (["tabId", `Int tab_id; "instruction", `String instruction] @ Option.to_list (Option.map (fun s -> "schema", s) schema))]
;;

(* Two different questions, two different classifications, both exhaustive
   over the closed verb set:

   - [verb_is_read]: does this leave browser content and lifecycle unchanged?
     Interaction, navigation, and session changes are writes.
   - [live_capability]: what does this ask of the operator's browser, if it
     may run there at all? Readers and explicit-tab interactions are
     supported. Session ownership and direct navigation remain with the
     automation backend. *)
let verb_is_read = function
  | Tabs_list | Page_read _ | Page_document _ | Page_elements _ | Page_capture _ | Page_scene _ | Page_snapshot _ | Page_context _ | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _
  | Session_status | Page_locate _ | Page_extract _ -> true
  | Session_open _ | Session_close | Page_goto _ | Page_act _ | Page_interact _ | Page_native_workflow _ | Page_instruct _ -> false
let verb_uses_model = function
  | Page_instruct _ | Page_locate _ | Page_extract _ -> true
  | Tabs_list | Page_read _ | Page_document _ | Page_elements _ | Page_capture _ | Page_scene _ | Page_snapshot _
  | Page_context _ | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _ | Session_open _ | Session_close | Session_status
  | Page_goto _ | Page_act _ | Page_interact _ | Page_native_workflow _ -> false
;;

(* What the live lane asks of the operator's browser, named by what the
   connection must be able to do there. The two live transports reach the
   browser differently and each serves a different part of this list;
   [live_transport_serves] is the one place that says which. *)
type live_capability =
  | Tab_listing
  | Text_read
  | Document_source
  | Element_inventory
  | Viewport_capture
  | Scene_read
  | Accessibility_snapshot
  | Snapshot_target_input
  | Native_workflow
  | Dom_interaction
  | Point_click
  | Point_scroll
  | Trusted_hover
  | Trusted_drag
  | Trusted_double_click
  | Trusted_button_click
  | Touch_input
  | Trusted_keyboard
  | Browser_zoom
  | Viewport_resize
  | Tab_activation
  | Tab_history
  | Tab_navigation
  | Tab_closing
  | Tab_creation
  | Dialog_answer
  | Frame_read
  | Operator_handoff
  | Page_management
  | Download_listing
  | File_upload
[@@deriving enumerate]

let live_capability_to_wire = function
  | Tab_listing -> "tab_listing"
  | Text_read -> "text_read"
  | Document_source -> "document_source"
  | Element_inventory -> "element_inventory"
  | Viewport_capture -> "viewport_capture"
  | Scene_read -> "scene_read"
  | Accessibility_snapshot -> "accessibility_snapshot"
  | Snapshot_target_input -> "snapshot_target_input"
  | Native_workflow -> "native_workflow"
  | Operator_handoff -> "operator_handoff"
  | Page_management -> "page_management"
  | Dom_interaction -> "dom_interaction"
  | Point_click -> "point_click"
  | Point_scroll -> "point_scroll"
  | Trusted_hover -> "trusted_hover"
  | Trusted_drag -> "trusted_drag"
  | Trusted_double_click -> "trusted_double_click"
  | Trusted_button_click -> "trusted_button_click"
  | Touch_input -> "touch_input"
  | Trusted_keyboard -> "trusted_keyboard"
  | Browser_zoom -> "browser_zoom"
  | Viewport_resize -> "viewport_resize"
  | Tab_activation -> "tab_activation"
  | Tab_history -> "tab_history"
  | Tab_navigation -> "tab_navigation"
  | Tab_closing -> "tab_closing"
  | Tab_creation -> "tab_creation"
  | Dialog_answer -> "dialog_answer"
  | Frame_read -> "frame_read"
  | Download_listing -> "download_listing"
  | File_upload -> "file_upload"
;;

let live_capability_of_wire raw =
  List.find_opt
    (fun capability -> String.equal (live_capability_to_wire capability) raw)
    all_of_live_capability
;;

let live_capability_of_interaction = function
  | Activate_tab -> Tab_activation
  | Set_zoom _ -> Browser_zoom
  | Set_viewport _ -> Viewport_resize
  | Double_click _ | Double_click_at _ -> Trusted_double_click
  | Type_text _ | Press_key _ -> Trusted_keyboard
  | Click _ | Fill _ | Select_option _ | Scroll _ | Follow_link _ | Click_node _ | Fill_node _ -> Dom_interaction
  | Click_target _ | Fill_target _ | Hover_target _ | Double_click_target _ -> Snapshot_target_input
  | Click_at {button = Pointer.Primary; _} -> Point_click
  | Click_at {button = Pointer.Middle | Pointer.Secondary; _} -> Trusted_button_click
  | Scroll_at _ -> Point_scroll
  | Hover _ | Hover_at _ -> Trusted_hover
  | Drag_to _ | Drag _ -> Trusted_drag
  | Tap_at _ | Swipe _ -> Touch_input
;;

let live_capability = function
  | Tabs_list -> Some Tab_listing
  | Page_read _ -> Some Text_read
  | Page_document _ -> Some Document_source
  | Page_elements _ -> Some Element_inventory
  | Page_capture {options=None;_} -> Some Viewport_capture
  | Page_capture {options=Some _;_} -> Some Native_workflow
  | Page_scene _ -> Some Scene_read
  | Page_native_workflow _ -> Some Native_workflow
  | Page_snapshot _ -> Some Accessibility_snapshot
  | Page_interact { action; _ } -> Some (live_capability_of_interaction action)
  | Page_act (Action.Open_tab _ | Action.Open_window _) -> Some Tab_creation
  | Page_act (Action.Control (Action.Hand_off | Action.Take_over | Action.Space_status | Action.Finish_space _ | Action.Wait_for_control _)) -> Some Operator_handoff
  | Page_act (Action.Control (Action.Adopt_tab _|Action.Release_tab _)) -> Some Page_management
  | Page_act (Action.On_tab {interaction = (Action.Back | Action.Forward | Action.Reload); _}) -> Some Tab_history
  | Page_act (Action.On_tab {interaction = Action.Close_tab; _}) -> Some Tab_closing
  | Page_goto _ -> Some Tab_navigation
  | Page_act (Action.On_tab {interaction = (Action.Accept_dialog _ | Action.Dismiss_dialog); _}) -> Some Dialog_answer
  | Page_context { mode = (`Text _ | `Elements _ | `Frames); _ } -> Some Frame_read
  | Page_downloads _ -> Some Download_listing
  | Page_context { mode = `Dialog; _ } | Page_console _ | Page_network _ | Page_cookies _ -> None
  (* The operator's browser owns itself, so it has no session to report on.
     Answering here would describe something the automation backend holds. *)
  | Page_act (Action.On_tab {interaction = Action.Upload _; _}) -> Some File_upload
  | Session_open _ | Session_close | Session_status
  | Page_act (Action.On_tab { interaction = (Action.Set_cookie _ | Action.Delete_cookie _ | Action.Set_emulation _ | Action.Clear_emulation
      | Action.Block_requests _ | Action.Unblock_requests); _ }) -> None
  | Page_instruct _ | Page_locate _ | Page_extract _ -> None
;;

let verb_allowed_on_live verb = Option.is_some (live_capability verb)

(* Gecko's selected read-only locate consumer does not execute instructions. *)
let sentence_verbs_refused = "act and extract require the stagehand lane"
let snapshot_refused = "an accessibility snapshot is served only by an ego connection on the live lane"
let snapshot_target_refused = "a snapshot target is acted on only by an ego connection on the live lane"
let handoff_refused = "Space control actions apply only to an ego connection on the live lane"
(* Why the automation lane does not serve a verb, if it does not.
   Model-assisted locate is admitted separately by the installed executor. *)
let automation_refusal = function
  | Page_capture {options=Some _;_} -> Some "native screenshot options require an Ego connection"
  | Page_native_workflow _ -> Some "native workflows require an ego connection"
  | Page_interact {action; _} when acts_on_snapshot_target action -> Some snapshot_target_refused
  | Page_act (Action.Control (Action.Hand_off | Action.Take_over | Action.Space_status | Action.Finish_space _ | Action.Wait_for_control _ | Action.Adopt_tab _ | Action.Release_tab _)) -> Some handoff_refused
  | Tabs_list | Page_read _ | Page_document _ | Page_elements _ | Page_capture _ | Page_scene _ | Page_context _
  | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _ | Page_interact _ | Session_open _ | Session_close | Session_status | Page_goto _
  | Page_act (Action.Open_tab _ | Action.Open_window _ | Action.On_tab _)
  | Page_locate _ -> None
  | Page_instruct _ | Page_extract _ -> Some sentence_verbs_refused
  | Page_snapshot _ -> Some snapshot_refused
;;
let verb_allowed_on_automation verb = Option.is_none (automation_refusal verb)

(* What the Stagehand backend serves once its executor is installed
   (RFC-browser-lane-stagehand §7 step 7): its session, tabs, navigation,
   screenshots, text, element and scene reads, interaction, and the three
   sentence verbs. Native tab creation and top-level history/close actions
   are served; frames, dialogs, downloads, the idle document observer and
   other BrowserAct actions are not served. *)
let verb_allowed_on_stagehand = function
  | Page_capture {options=Some _;_} -> false
  | Page_native_workflow _ -> false
  | Page_interact {action; _} when acts_on_snapshot_target action -> false
  | Session_open _ | Session_close | Session_status | Tabs_list | Page_goto _ | Page_capture _
  | Page_read _ | Page_elements _ | Page_scene _ | Page_interact _ | Page_instruct _ | Page_locate _
  | Page_extract _ -> true
  | Page_act (Action.Open_tab _) -> true
  | Page_act (Action.Open_window _ | Action.Control (Action.Hand_off | Action.Take_over | Action.Space_status | Action.Finish_space _ | Action.Wait_for_control _ | Action.Adopt_tab _ | Action.Release_tab _)) -> false
  | Page_act (Action.On_tab {frame_path;interaction;_}) ->
    (match interaction with
     | Action.Back | Forward | Reload | Close_tab -> frame_path = []
     | Action.Upload _ | Accept_dialog _ | Dismiss_dialog | Set_cookie _ | Delete_cookie _ | Set_emulation _ | Clear_emulation
     | Block_requests _ | Unblock_requests -> false)
  | Page_document _ | Page_context _ | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _
  | Page_snapshot _ -> false
;;

let verb_allowed (lane : Lane_name.t) verb =
  match lane with
  | Live -> verb_allowed_on_live verb
  | Automation -> verb_allowed_on_automation verb
  | Stagehand -> verb_allowed_on_stagehand verb
;;


type issued = { id : string; verb_json : Yojson.Safe.t }

type answer =
  | Answered of Yojson.Safe.t
  | Lane_absent
  | Timed_out
  | Refused of string
  | Rejected_before_effect of string

(* A browser worker's owner says which lanes it serves while it serves them.
   Read it at admission; do not keep a second copy here. *)
type activity = Enabled | Disabled | Unobserved
let activity_observer : (Lane_name.t -> activity) option Atomic.t = Atomic.make None
let install_activity_observer observer = Atomic.set activity_observer observer
let activity lane = match Atomic.get activity_observer with
  | None -> Unobserved
  | Some observe -> observe lane

type activity_rejection = Lane_off of Lane_name.t | Activity_unavailable
let activity_rejection_message = function
  | Lane_off lane -> "no " ^ Lane_name.to_wire lane ^ " browser runs here; new browser work is refused"
  | Activity_unavailable -> "no browser worker serves this process"

(* The same check against an activity the caller observed, such as the one a
   worker reported in its snapshot. *)
let activity_rejection_with ~activity lane = function
  | Session_close | Session_status -> None
  | Tabs_list | Page_read _ | Page_document _ | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _ | Page_capture _
  | Page_scene _ | Page_snapshot _ | Page_interact _ | Page_native_workflow _ | Session_open _ | Page_goto _ | Page_elements _
  | Page_act _ | Page_context _ | Page_instruct _ | Page_locate _ | Page_extract _ ->
    match activity with
    | Enabled -> None
    | Disabled -> Some (Lane_off lane)
    | Unobserved -> Some Activity_unavailable
let activity_rejection lane verb = activity_rejection_with ~activity:(activity lane) lane verb

let activity_refusal lane verb =
  Option.map (fun rejection -> Rejected_before_effect (activity_rejection_message rejection))
    (activity_rejection lane verb)

type browser = Firefox | Zen | Ego_lite
let browser_name = function Firefox -> "firefox" | Zen -> "zen" | Ego_lite -> "ego_lite"
let browser_of_string = function
  | "firefox" -> Ok Firefox | "zen" -> Ok Zen | "ego_lite" -> Ok Ego_lite | _ -> Error "unsupported_browser"
type client_id = Uuidm.t
let client_id_to_string = Uuidm.to_string
let client_id_of_string value =
  match Uuidm.of_string value with
  | Some id when String.equal (Uuidm.to_string id) value -> Ok id
  | _ -> Error "invalid_client_id"
type live_transport = Web_extension | Webdriver_bidi | Ego_task_space [@@deriving enumerate]
let live_reply_policy transport verb = match transport with
  | Ego_task_space -> ego_reply_policy verb
  | Web_extension | Webdriver_bidi -> reply_policy verb
let live_transport_to_string = function
  | Web_extension -> "web_extension"
  | Webdriver_bidi -> "webdriver_bidi"
  | Ego_task_space -> "ego_task_space"
let live_transport_of_string = function
  | "web_extension" -> Ok Web_extension
  | "webdriver_bidi" -> Ok Webdriver_bidi
  | "ego_task_space" -> Ok Ego_task_space
  | _ -> Error "unsupported_browser_transport"

(* Which live work each transport serves. Every pair is spelled out, so a new
   capability or transport does not compile until this table answers for it.

   The extension acts through DOM calls inside the page, so it has no pointer
   the browser treats as the operator's: it cannot hover or drag, and its
   point click is the element's own [click()]. The BiDi peer sends pointer
   and wheel input through the browser. Both switch the active tab; BiDi's
   activation also gives the browser window system focus. The BiDi peer's
   history, close and navigation act only on tabs it opened; the extension
   opens none. test_browser_bidi_peer holds this table to what that peer
   does.

   The ego connection runs fixed scripts in one ego lite task space
   (RFC-browser-live-ego). It reads that space's pages with the same page
   scripts as the other connections, and opens, moves and closes only the
   pages an agent opened there. It hands its space to the operator and takes
   it back, lists downloads saved into the worker's own folder, and sets files
   on their file inputs from the worker's upload copies;
   test_browser_ego_peer holds its column to what Browser_ego_peer does. *)
let live_transport_serves transport capability =
  match transport, capability with
  | ( (Web_extension | Webdriver_bidi)
    , ( Tab_listing | Text_read | Document_source | Element_inventory | Viewport_capture
      | Scene_read | Dom_interaction | Point_click | Point_scroll ) ) -> true
  | (Web_extension | Webdriver_bidi), Tab_activation -> true
  | Web_extension, Browser_zoom -> true
  | Web_extension, (Trusted_hover | Trusted_drag | Trusted_double_click | Trusted_button_click | Touch_input
                    | Trusted_keyboard | Tab_creation | Viewport_resize | Tab_history | Tab_navigation
                    | Tab_closing | Dialog_answer | Frame_read | Accessibility_snapshot | Snapshot_target_input | Native_workflow
                    | Operator_handoff | Page_management | Download_listing | File_upload) -> false
  | Webdriver_bidi, (Trusted_hover | Trusted_drag | Trusted_double_click | Trusted_button_click | Touch_input
                    | Trusted_keyboard | Tab_creation | Viewport_resize | Tab_history | Tab_navigation
                    | Tab_closing | Dialog_answer | Frame_read) -> true
  | Webdriver_bidi, (Browser_zoom | Accessibility_snapshot | Snapshot_target_input | Native_workflow | Operator_handoff | Page_management | Download_listing
                    | File_upload) -> false
  | Ego_task_space, (Tab_listing | Text_read | Element_inventory | Viewport_capture | Scene_read
                    | Tab_creation | Tab_navigation | Tab_closing | Dom_interaction | Point_click
                    | Point_scroll | Trusted_hover | Trusted_double_click | Trusted_button_click
                    | Trusted_drag | Trusted_keyboard | Tab_history | Accessibility_snapshot | Dialog_answer
                    | Snapshot_target_input | Native_workflow | Operator_handoff | Page_management | Download_listing | File_upload | Tab_activation) -> true
  | Ego_task_space, (Document_source | Touch_input | Browser_zoom | Viewport_resize
                    | Frame_read) -> false
;;

let live_transports_serving capability =
  List.filter (fun transport -> live_transport_serves transport capability) all_of_live_transport
;;

(* Where the steps for attaching a connection of this transport are written. *)
let live_transport_setup_doc = function
  | Web_extension -> "connectors/browser/host/README.md"
  | Webdriver_bidi -> "docs/design/browser-bidi-live-host.md"
  | Ego_task_space -> "docs/rfc/RFC-browser-live-ego.md"
;;

type ego_space = { id : int; name : string }
let ego_space_to_json (space : ego_space) = `Assoc ["id",`Int space.id;"name",`String space.name]
let ego_space_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["id";"name"] ->
    (match List.assoc_opt "id" fields,List.assoc_opt "name" fields with
     | Some (`Int id),Some (`String name) when id>=0 && Int64.of_int id<=9007199254740991L && String.trim name<>"" -> Ok {id;name}
     | (None|Some _),(None|Some _) -> Error "invalid Ego Space identity")
  | _ -> Error "invalid or duplicate Ego Space fields"
let client_space_to_json = function None -> `Null | Some space -> ego_space_to_json space
let client_space_of_json ~transport value = match transport,value with
  | Ego_task_space,value -> Result.map Option.some (ego_space_of_json value)
  | (Web_extension|Webdriver_bidi),`Null -> Ok None
  | (Web_extension|Webdriver_bidi),_ -> Error "Space context requires an Ego connection"
let same_space_id left right =
  Option.map (fun (space : ego_space) -> space.id) left
  = Option.map (fun (space : ego_space) -> space.id) right
type client_info = { client_id : client_id; browser : browser; version : string; engine_version : string;
  transport : live_transport; space : ego_space option }
type interaction_phase = Interaction_queued | Interaction_running
type interaction_activity = { request_id : string; actor : string option;
  action : string; tab_id : int option; phase : interaction_phase }
type activity_outcome = Activity_returned | Activity_refused | Activity_partial | Activity_unknown
type settled_activity = { work : interaction_activity; outcome : activity_outcome }
let interaction_activity_json work = `Assoc ["requestId",`String work.request_id;
  "actor",(match work.actor with Some name -> `String name | None -> `Null);
  "action",`String work.action;"tabId",(match work.tab_id with Some id -> `Int id | None -> `Null);
  "phase",`String (match work.phase with Interaction_queued->"queued"|Interaction_running->"running")]
let interaction_activity_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = ["action";"actor";"phase";"requestId";"tabId"] ->
    let actor = match List.assoc_opt "actor" fields with
      | Some (`String name) when String.trim name<>"" -> Some (Some name)
      | Some `Null -> Some None | _ -> None in
    let tab_id = match List.assoc_opt "tabId" fields with
      | Some (`Int id) when id>=0 -> Some (Some id) | Some `Null -> Some None | _ -> None in
    let phase = match List.assoc_opt "phase" fields with
      | Some (`String "queued") -> Some Interaction_queued
      | Some (`String "running") -> Some Interaction_running | _ -> None in
    (match List.assoc_opt "requestId" fields,actor,List.assoc_opt "action" fields,
      tab_id,phase with
     | Some (`String request_id),Some actor,Some (`String action),Some tab_id,Some phase
       when String.trim request_id<>"" && String.trim action<>"" ->
       Ok {request_id;actor;action;tab_id;phase}
     | _ -> Error "invalid browser interaction activity")
  | _ -> Error "invalid browser interaction activity"
let activity_outcome_to_wire = function
  | Activity_returned -> "returned" | Activity_refused -> "refused"
  | Activity_partial -> "partial" | Activity_unknown -> "unknown"
let settled_activity_json {work;outcome} = `Assoc [
  "work",interaction_activity_json work;"outcome",`String (activity_outcome_to_wire outcome)]
let settled_activity_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["outcome";"work"] ->
    let outcome=match List.assoc_opt "outcome" fields with
      | Some (`String "returned") -> Some Activity_returned | Some (`String "refused") -> Some Activity_refused
      | Some (`String "partial") -> Some Activity_partial | Some (`String "unknown") -> Some Activity_unknown
      | None|Some _ -> None in
    (match List.assoc_opt "work" fields,outcome with
     | Some value,Some outcome -> Result.map (fun work -> {work;outcome}) (interaction_activity_of_json value)
     | (None|Some _),_ -> Error "invalid settled browser activity")
  | _ -> Error "invalid settled browser activity"
let activity_scope = function
  | Page_native_workflow workflow -> Some workflow.tab_id
  | Page_interact {tab_id;_} | Page_document {tab_id} | Page_downloads {tab_id}
  | Page_console {tab_id} | Page_network {tab_id} | Page_cookies {tab_id} | Page_capture {tab_id;_}
  | Page_scene {tab_id;_} | Page_snapshot {tab_id;_} | Page_context {tab_id;_}
  | Page_instruct {tab_id;_} | Page_locate {tab_id;_} | Page_extract {tab_id;_}
  | Page_act (Action.Control (Action.Adopt_tab {tab_id;_}|Action.Release_tab tab_id))
  | Page_act (Action.On_tab {tab_id;_}) -> Some tab_id
  | Page_read {tab_id;_} | Page_elements {tab_id;_} | Page_goto {tab_id;_} -> tab_id
  | Tabs_list | Session_open _ | Session_close | Session_status
  | Page_act (Action.Open_tab _|Open_window _|Control (Hand_off|Take_over|Space_status|Finish_space _|Wait_for_control _)) -> None
let activity_name = function
  | Page_act (Action.Control Action.Space_status) -> "space_status"
  | Page_act (Action.Control (Action.Finish_space _)) -> "finish_space"
  | Page_act (Action.Control (Action.Wait_for_control _)) -> "wait_for_control"
  | Page_act (Action.Control (Action.Adopt_tab _)) -> "adopt_tab"
  | Page_act (Action.Control (Action.Release_tab _)) -> "release_tab"
  | Page_interact {action;_} -> interaction_verb action
  | Page_native_workflow _ -> "workflow"
  | (Tabs_list|Page_read _|Page_document _|Page_downloads _|Page_console _|Page_network _|Page_cookies _
    |Page_capture _|Page_scene _|Page_snapshot _|Session_open _|Session_close|Session_status|Page_goto _
    |Page_elements _|Page_act (Action.Open_tab _|Open_window _|Control (Hand_off|Take_over)|On_tab _)
    |Page_context _|Page_instruct _|Page_locate _|Page_extract _) as verb -> verb_to_string verb
let activity_result = function
  | `Assoc fields ->
    (match List.assoc_opt "ok" fields,List.assoc_opt "effectPhase" fields with
     | Some (`Bool true),_ -> Activity_returned
     | Some (`Bool false),Some (`String "not_started") -> Activity_refused
     | Some (`Bool false),Some (`String "partial") -> Activity_partial
     | (None|Some _),(None|Some _) -> Activity_unknown)
  | _ -> Activity_unknown
(* How the lane learns a client is gone. A native host that stops polling
   says nothing, so it is gone once its window without a poll passes. A
   connection this worker runs itself (owned Firefox, ego) is disconnected by
   the worker when it ends; elapsed time, which on macOS includes system
   sleep, says nothing about it. *)
type liveness = Polled of Monotonic_deadline.t | Worker_held
type live_waiter = { resolver : Yojson.Safe.t Eio.Promise.u; deadline : Monotonic_deadline.t option }
type live_request_window = No_live_waiter | Live_executor_owned | Live_waiting_until of Monotonic_deadline.t
type client = { info : client_info; commands : issued Eio.Stream.t;
  mutex : Eio.Mutex.t;
  waiters : (string, live_waiter) Hashtbl.t;
  interactions : (string, interaction_activity) Hashtbl.t;
  last_activities : (string option, settled_activity) Hashtbl.t;
  executor_work : (string, interaction_phase) Hashtbl.t;
  mutable last_delivered_result : (string * Yojson.Safe.t) option;
  mutable liveness : liveness; mutable closed : bool }
let settle_activity client id outcome = match Hashtbl.find_opt client.interactions id with
  | None -> ()
  | Some work -> Hashtbl.replace client.last_activities work.actor {work;outcome};
      Hashtbl.remove client.interactions id
type target = Automation | Live_client of client | Stagehand
let clients : (string, client) Hashtbl.t = Hashtbl.create 4
let clients_mutex = Eio.Mutex.create ()
(* Retain only IDs after disconnect; queues and page payloads must be reclaimed. *)
let retired_clients : (string, unit) Hashtbl.t = Hashtbl.create 4
let command_uuid = Uuidm.v4_gen (Random.State.make_self_init ())
let lane_connected_window_sec = 120.
(* A delivered executor-owned request is still using this connection while its
   SDK owns the wait. Queued requests do not prove a client is executing them;
   explicit disconnect always wins, and settlement releases this ownership. *)
let connected_unlocked client =
  not client.closed &&
  (match client.liveness with
   | Worker_held -> true
   | Polled until ->
     not (Monotonic_deadline.passed until)
     || Hashtbl.fold (fun _ phase running -> match phase with
          | Interaction_running -> true | Interaction_queued -> running)
          client.executor_work false)
let connected client = Eio.Mutex.use_ro client.mutex (fun () -> connected_unlocked client)
(* A poll or a delivered result shows a polled client is still there. *)
let refresh_unlocked client = match client.liveness with
  | Polled _ -> client.liveness <- Polled (Monotonic_deadline.after ~seconds:lane_connected_window_sec)
  | Worker_held -> ()
let same_info left right = left.browser = right.browser
  && left.transport = right.transport
  && same_space_id left.space right.space
  && String.equal left.version right.version && String.equal left.engine_version right.engine_version
let retire_unlocked key client =
  Hashtbl.remove clients key;
  Hashtbl.replace retired_clients key ();
  Eio.Mutex.use_rw ~protect:true client.mutex (fun () ->
    client.closed <- true;
    Hashtbl.iter (fun _ waiter -> Eio.Promise.resolve waiter.resolver
      (`Assoc ["ok", `Bool false; "error", `String "client_disconnected"])) client.waiters;
    Hashtbl.clear client.waiters; Hashtbl.clear client.interactions;
    Hashtbl.clear client.executor_work);
  while Option.is_some (Eio.Stream.take_nonblocking client.commands) do () done
let prune_unlocked () =
  Hashtbl.fold (fun key client acc -> if connected client then acc else (key,client)::acc) clients []
  |> List.iter (fun (key,client) -> retire_unlocked key client)
let active_clients () =
  Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
    prune_unlocked ();
    Hashtbl.fold (fun _ client acc -> client.info :: acc) clients [])
  |> List.sort (fun left right -> String.compare
       (client_id_to_string left.client_id) (client_id_to_string right.client_id))
let connected_clients () =
  Eio.Mutex.use_ro clients_mutex (fun () ->
    Hashtbl.fold (fun _ client found -> if connected client then client.info::found else found) clients [])
  |> List.sort (fun left right -> String.compare
      (client_id_to_string left.client_id) (client_id_to_string right.client_id))
let client_interactions client = Eio.Mutex.use_ro client.mutex (fun () ->
  Hashtbl.fold (fun _ work acc -> work::acc) client.interactions [])
  |> List.sort (fun a b -> String.compare a.request_id b.request_id)
let activity_for info =
  let client = Eio.Mutex.use_ro clients_mutex (fun () ->
    Hashtbl.find_opt clients (client_id_to_string info.client_id)) in
  match client with
  | Some client when connected client -> Eio.Mutex.use_ro client.mutex (fun () ->
      Hashtbl.fold (fun _ work acc -> work::acc) client.interactions [],
      Hashtbl.fold (fun _ work acc -> work::acc) client.last_activities [])
  | Some _ | None -> [],[]
let client_json info =
  let active,settled=activity_for info in
  `Assoc ["clientId", `String (client_id_to_string info.client_id);
  "browser", `String (browser_name info.browser); "version", `String info.version;
  "engineVersion", `String info.engine_version;
  "transport", `String (live_transport_to_string info.transport);
  "space",client_space_to_json info.space;
  "interactions",`List (List.map interaction_activity_json active);
  "lastActivities",`List (List.map settled_activity_json settled)]
let target_client_id = function Automation | Stagehand -> None | Live_client client -> Some client.info.client_id
(* Where an answer came from, as every successful answer states it: a live
   connection's ID and how its browser is reached. The server's own browsers
   have no client, and no transport to name. *)
let client_id_field = "clientId"
let transport_field = "transport"
let space_field = "browserSpace"
let connection_field_names = [client_id_field; transport_field;space_field]
let live_connection_fields ~client_id ~transport ~space =
  [client_id_field, `String (client_id_to_string client_id);
   transport_field, `String (live_transport_to_string transport)]
  @ Option.to_list (Option.map (fun space -> space_field,ego_space_to_json space) space)
let target_connection_fields = function
  | Live_client client ->
    live_connection_fields ~client_id:client.info.client_id ~transport:client.info.transport ~space:client.info.space
  | Automation | Stagehand -> [client_id_field, `Null]
(* Those fields read back from an answer, for a holder that keeps only what
   it can check. An answer states no connection, the server's own browser, or
   a live connection together with its transport. A client ID without its
   transport, or a transport without its client, is none of the three. *)
let connection_fields_of_json fields =
  let keys=List.filter_map (fun (key,_) -> if List.mem key connection_field_names then Some key else None) fields in
  if List.length keys<>List.length (List.sort_uniq String.compare keys) then Error "duplicate_connection_fields"
  else
  let space=List.assoc_opt space_field fields in
  match List.assoc_opt client_id_field fields, List.assoc_opt transport_field fields,space with
  | None, None,None -> Ok []
  | Some `Null, None,None -> Ok [client_id_field, `Null]
  | Some (`String client_id), Some (`String transport),space ->
    Result.bind (client_id_of_string client_id) (fun client_id ->
      Result.bind (live_transport_of_string transport) (fun transport ->
        let parsed=match transport,space with
          | Ego_task_space,Some value -> Result.map Option.some (ego_space_of_json value)
          | Ego_task_space,None -> Error "ego_connection_without_space"
          | (Web_extension|Webdriver_bidi),None -> Ok None
          | (Web_extension|Webdriver_bidi),Some _ -> Error "space_requires_ego_connection" in
        Result.map (fun space -> live_connection_fields ~client_id ~transport ~space) parsed))
  | Some (`String client_id), None,None ->
    Result.bind (client_id_of_string client_id) (fun _ -> Error "client_without_transport")
  | (Some _, _,_) | (None, Some _,_) | (None,None,Some _) -> Error "invalid_connection_fields"
(* The route's own values replace anything a page or backend supplied under
   the same names, so a reader that takes the first key and one that takes the
   last see the same connection. *)
let with_connection_fields target fields =
  target_connection_fields target
  @ List.filter (fun (key, _) -> not (List.mem key connection_field_names)) fields
;;

(* Which backend a request names. A browser client id belongs to the live
   source, so a request for the automation backend has nowhere to carry one. *)
type route = Automation_route | Live_route of client_id option | Stagehand_route

let route_lane_name = function
  | Automation_route -> Lane_name.Automation
  | Live_route _ -> Lane_name.Live
  | Stagehand_route -> Lane_name.Stagehand
;;

(* Why a live request names no browser to send its command to. Each case has
   a different next step: a browser has to connect, or the caller has to
   choose one of several. No command is dispatched in any of them. *)
type selection_error =
  | Activity_rejected of activity_rejection
  | No_live_client
  | Selected_client_disconnected of client_id
  | Ambiguous_clients of client_id list
  (* The chosen browser is connected, and its connection does not serve this
     work. Another connection may: that is the caller's next choice. *)
  | Transport_unsupported of
      { client_id : client_id; transport : live_transport; capability : live_capability }

(* The refusal's name without its details: what a reader of a recorded
   rejection recovers from the code. *)
type selection_case =
  | Lane_off_case
  | Activity_unavailable_case
  | No_live_client_case
  | Selected_client_disconnected_case
  | Ambiguous_clients_case
  | Transport_unsupported_case
[@@deriving enumerate]

let selection_case = function
  | Activity_rejected (Lane_off _) -> Lane_off_case
  | Activity_rejected Activity_unavailable -> Activity_unavailable_case
  | No_live_client -> No_live_client_case
  | Selected_client_disconnected _ -> Selected_client_disconnected_case
  | Ambiguous_clients _ -> Ambiguous_clients_case
  | Transport_unsupported _ -> Transport_unsupported_case

let selection_case_code = function
  | Lane_off_case -> "browser_lane_off"
  | Activity_unavailable_case -> "browser_activity_unavailable"
  | No_live_client_case -> "no_live_client"
  | Selected_client_disconnected_case -> "selected_client_disconnected"
  | Ambiguous_clients_case -> "ambiguous_browser_clients"
  | Transport_unsupported_case -> "live_transport_unsupported"

let selection_case_of_code code =
  List.find_opt (fun case -> String.equal (selection_case_code case) code) all_of_selection_case

let selection_error_code error = selection_case_code (selection_case error)

(* The same, for a call that named no lane: Browser_selection could not choose
   a browser for it. Its refusal names the case in [code], where a
   [selection_case] refusal names its case in [error]. *)
type choice_case =
  | Binding_required_case
  | No_available_browser_case
  | Ambiguous_browsers_case
  | Required_actions_unavailable_case
  | Unsupported_required_actions_case
[@@deriving enumerate]

let choice_case_code = function
  | Binding_required_case -> "browser_binding_required"
  | No_available_browser_case -> "no_available_browser"
  | Ambiguous_browsers_case -> "ambiguous_browsers"
  | Required_actions_unavailable_case -> "required_browser_actions_unavailable"
  | Unsupported_required_actions_case -> "unsupported_required_browser_actions"

let choice_case_of_code code =
  List.find_opt (fun case -> String.equal (choice_case_code case) code) all_of_choice_case

let selection_error_message = function
  | Activity_rejected rejection -> activity_rejection_message rejection
  | Transport_unsupported { transport; capability; _ } as error ->
    Printf.sprintf "%s: this browser is connected over %s, which does not serve %s; a %s connection does"
      (selection_error_code error) (live_transport_to_string transport)
      (live_capability_to_wire capability)
      (String.concat " or " (List.map live_transport_to_string (live_transports_serving capability)))
  | (No_live_client | Selected_client_disconnected _ | Ambiguous_clients _) as error ->
    selection_error_code error

(* Check activity before offering connection/selection remedies. Dispatch still
   checks again so a target resolved while on cannot admit new work after off. *)
let resolve_target ~verb route =
  match activity_rejection (route_lane_name route) verb with
  | Some rejection -> Error (Activity_rejected rejection)
  | None -> match route with
  | Automation_route -> Ok Automation
  | Stagehand_route -> Ok Stagehand
  | Live_route selected ->
    Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
      prune_unlocked ();
      match selected with
      | Some id ->
        (match Hashtbl.find_opt clients (client_id_to_string id) with
         | Some client when connected client -> Ok (Live_client client)
         | Some _ | None -> Error (Selected_client_disconnected id))
      | None ->
        match Hashtbl.fold (fun _ client acc -> if connected client then client :: acc else acc) clients [] with
        | [client] -> Ok (Live_client client)
        | [] -> Error No_live_client
        | _ :: _ as several ->
          Error (Ambiguous_clients
            (List.map (fun client -> client.info.client_id) several
             |> List.sort (fun left right ->
                  String.compare (client_id_to_string left) (client_id_to_string right)))))
(* Why the lane turns a poll's client away. [Client_retired]: the lane ended
   this connection, after [lane_connected_window_sec] without a poll or running
   executor-owned work for a polled client, or on the
   client's own disconnect, and its ID is never served again; a client that
   is still there registers under a new one. [Client_identity_changed]: the
   ID is connected as another browser or transport, and asking again gets
   the same answer. *)
type registration_refusal = Client_retired | Client_identity_changed
let registration_refusal_to_wire = function
  | Client_retired -> "client_disconnected"
  | Client_identity_changed -> "client_identity_changed"
let registration_refusal_of_wire = function
  | "client_disconnected" -> Some Client_retired
  | "client_identity_changed" -> Some Client_identity_changed
  | _ -> None
let register info =
  Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
    prune_unlocked ();
    let key = client_id_to_string info.client_id in
    if Hashtbl.mem retired_clients key then Error Client_retired
    else match Hashtbl.find_opt clients key with
    | Some client when client.closed -> Error Client_retired
    | Some client when not (same_info client.info info) -> Error Client_identity_changed
    | Some client ->
      Eio.Mutex.use_rw ~protect:true client.mutex (fun () -> refresh_unlocked client);
      Ok client
    | None ->
      let client = {info; commands=Eio.Stream.create 16; mutex=Eio.Mutex.create ();
        waiters=Hashtbl.create 8; interactions=Hashtbl.create 8; last_activities=Hashtbl.create 8;
        executor_work=Hashtbl.create 8;
        last_delivered_result=None; closed=false;
        liveness=Polled (Monotonic_deadline.after ~seconds:lane_connected_window_sec)} in
      Hashtbl.add clients key client; Ok client)
let take_registered_command ~client ~window_sec =
    let rec take () =
      let issued = Eio.Stream.take client.commands in
      if not (connected client) then None
      else if Eio.Mutex.use_rw ~protect:true client.mutex (fun () ->
        match Hashtbl.find_opt client.waiters issued.id with
        | None -> false
        | Some _ ->
          Option.iter (fun _ -> Hashtbl.replace client.executor_work issued.id Interaction_running)
            (Hashtbl.find_opt client.executor_work issued.id);
          Option.iter (fun work -> Hashtbl.replace client.interactions issued.id
            {work with phase=Interaction_running}) (Hashtbl.find_opt client.interactions issued.id);
          true)
      then Some issued else take () in
    (* A command taken as the window passed is delivered, not dropped:
       [Fiber.first] would have consumed it from the stream and returned
       the window's [None], and the issuer would have waited out its own
       timeout for an answer nobody was asked for. *)
    Ok (Watched_work.run take ~watcher:(fun () -> Time_compat.sleep window_sec; None))
let take_command ~client_info ~window_sec =
  match register client_info with
  | Error _ as error -> error
  | Ok client -> take_registered_command ~client ~window_sec
(* This is a local observation of the original waiting issuer, not part of
   the external host wire. A missing waiter cannot authorize a new effect. *)
let live_request_window ~client_id ~id =
  match Eio.Mutex.use_ro clients_mutex (fun () ->
      Hashtbl.find_opt clients (client_id_to_string client_id)) with
  | None -> No_live_waiter
  | Some client -> Eio.Mutex.use_ro client.mutex (fun () ->
      match Hashtbl.find_opt client.waiters id with
      | None -> No_live_waiter
      | Some {deadline=None;_} -> Live_executor_owned
      | Some {deadline=Some deadline;_} -> Live_waiting_until deadline)
let deliver_result ~client_id ~id ~payload =
  match Eio.Mutex.use_ro clients_mutex (fun () ->
    Hashtbl.find_opt clients (client_id_to_string client_id)) with
  | None -> Error "unknown_client"
  | Some client when not (connected client) -> Error "client_not_connected"
  | Some client ->
    Eio.Mutex.use_rw ~protect:true client.mutex (fun () ->
      match Hashtbl.find_opt client.waiters id with
      | Some waiter ->
        Hashtbl.remove client.waiters id;
        settle_activity client id (activity_result payload);
        Hashtbl.remove client.executor_work id;
        refresh_unlocked client;
        client.last_delivered_result <- Some (id, payload);
        Eio.Promise.resolve waiter.resolver payload;
        Ok ()
      | None ->
        (match client.last_delivered_result with
         | Some (last_id, last_payload) when String.equal id last_id && payload = last_payload -> Ok ()
         | Some (last_id, _) when String.equal id last_id -> Error "result_id_reused_with_different_payload"
         | None | Some _ -> Error "request_not_owned_by_client"))
let disconnect_client ~client_id =
  Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
    let key = client_id_to_string client_id in
    match Hashtbl.find_opt clients key with
    | None when Hashtbl.mem retired_clients key -> Ok ()
    | None -> Error "unknown_client"
    | Some client -> retire_unlocked key client; Ok ())
(* The worker that runs this connection disconnects it itself when it ends,
   so the lane stops timing it. Only a client still inside its window is
   held: one retired, unknown or past its window is not brought back, even
   while a request it took is still running. A browser extension is a native
   host that no worker runs, so it stays timed. *)
let hold_client ~client_id =
  Eio.Mutex.use_rw ~protect:true clients_mutex (fun () ->
    match Hashtbl.find_opt clients (client_id_to_string client_id) with
    | None -> Error "unknown_client"
    | Some client ->
      Eio.Mutex.use_rw ~protect:true client.mutex (fun () ->
        match client.info.transport, client.liveness with
        | Web_extension, (Polled _ | Worker_held) -> Error "client_not_worker_run"
        | (Webdriver_bidi | Ego_task_space), _ when client.closed -> Error "client_not_connected"
        | (Webdriver_bidi | Ego_task_space), Worker_held -> Ok ()
        | (Webdriver_bidi | Ego_task_space), Polled until ->
          if Monotonic_deadline.passed until then Error "client_not_connected"
          else (client.liveness <- Worker_held; Ok ())))
(* A browser whose lease ended after its target was resolved is the same
   selection failure as naming it when it had already gone, so the caller
   answers both from one place. Work this connection's transport does not
   serve is a selection failure too: nothing is queued, and another
   connection is the remedy. *)
let issue_live_with ~activity_check ?actor ?(only_if_idle = false) client ~verb ~timeout_sec =
  match activity_check verb with
  | Some refusal -> Ok refusal
  | None -> if not (connected client) then
    Error (Selected_client_disconnected client.info.client_id)
  else match live_capability verb with
  | None ->
    Ok (Rejected_before_effect "session ownership, direct navigation and sentence verbs belong to the server's lanes")
  | Some capability when not (live_transport_serves client.info.transport capability) ->
    Error (Transport_unsupported
      { client_id = client.info.client_id; transport = client.info.transport; capability })
  | Some _ ->
    Ok (Eio.Switch.run (fun sw ->
      let policy = live_reply_policy client.info.transport verb in
      let id = Uuidm.to_string (command_uuid ()) in
      let promise, resolver = Eio.Promise.create () in
      let deadline = match policy with
        | Reply_window -> Some (Monotonic_deadline.after ~seconds:timeout_sec)
        | Executor_owned -> None in
      let accepted = Eio.Mutex.use_rw ~protect:true client.mutex (fun () ->
        match activity_check verb with
        | Some refusal -> Error refusal
        | None -> if only_if_idle &&
           (Hashtbl.length client.waiters <> 0 || Eio.Stream.length client.commands <> 0)
        then Error (Refused "optional_document_observation_busy")
        else (Hashtbl.add client.waiters id {resolver;deadline};
          (match policy with
           | Executor_owned -> Hashtbl.add client.executor_work id Interaction_queued
           | Reply_window -> ());
          Hashtbl.add client.interactions id
            {request_id=id;actor;action=activity_name verb;tab_id=activity_scope verb;phase=Interaction_queued};
          Ok ())) in
      Eio.Switch.on_release sw (fun () ->
        Eio.Mutex.use_rw ~protect:true client.mutex (fun () -> Hashtbl.remove client.waiters id;
          (match Hashtbl.find_opt client.interactions id with
           | None -> ()
           | Some work -> settle_activity client id (match work.phase with
               | Interaction_queued -> Activity_refused | Interaction_running -> Activity_unknown));
          Hashtbl.remove client.executor_work id));
      match accepted with
      | Error refusal -> refusal
      | Ok () ->
        let execute () =
          let payload = match verb_json verb, actor with
            | `Assoc fields, Some actor -> `Assoc (("actor",`String actor)::fields)
            | payload, None -> payload
            | payload, Some _ -> payload in
          Eio.Stream.add client.commands {id; verb_json=payload};
          Answered (Eio.Promise.await promise) in
        match policy with
        | Executor_owned -> execute ()
        | Reply_window -> Watched_work.run execute
            ~watcher:(fun () ->
              Time_compat.sleep (match deadline with
                | Some deadline -> Monotonic_deadline.remaining_seconds deadline
                | None -> timeout_sec);
              Timed_out)))
let issue_live ?only_if_idle client ~verb ~timeout_sec =
  issue_live_with ~activity_check:(activity_refusal Lane_name.Live) ?only_if_idle client ~verb ~timeout_sec
(* The port this process serves the browser-lane routes on: the port its HTTP
   listener actually bound, installed once it is bound and withdrawn when that
   listener's switch ends. Before that, and in a process that serves no
   routes, the port is unknown rather than any number. *)
type serving_port = Serving_port of int | Serving_port_unknown
let serving_port_cell : serving_port Atomic.t = Atomic.make Serving_port_unknown
let install_serving_port port = Atomic.set serving_port_cell (Serving_port port)
let withdraw_serving_port () = Atomic.set serving_port_cell Serving_port_unknown
let serving_port () = Atomic.get serving_port_cell
type automation_backend = { execute : verb -> answer; locate : bool }
let automation_executor : automation_backend option Atomic.t = Atomic.make None
let install_automation_executor ?(locate=false) executor =
  Atomic.set automation_executor (Option.map (fun execute -> {execute;locate}) executor)
let automation_locate_available () = match Atomic.get automation_executor with
  | None -> false | Some backend -> backend.locate
let automation_document_observer : (tab_id:int -> answer) option Atomic.t = Atomic.make None
let install_automation_document_observer observer = Atomic.set automation_document_observer observer
let issue_automation_with ~activity_check ~verb ~timeout_sec =
  match automation_refusal verb with
  | Some refusal -> Rejected_before_effect refusal
  | None -> match activity_check verb with
  | Some refusal -> refusal
  | None -> match Atomic.get automation_executor with
  | None -> Lane_absent
  | Some backend ->
      (match verb with
       | Page_locate _ when not backend.locate -> Rejected_before_effect "browser locate Exact Output is not selected"
       | Page_locate _ -> backend.execute verb
       | Tabs_list|Page_read _|Page_document _|Page_elements _|Page_capture _|Page_scene _ | Page_snapshot _|Page_context _
       | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _|Page_interact _ | Page_native_workflow _|Session_open _|Session_close|Session_status|Page_goto _|Page_act _
       | Page_instruct _|Page_extract _ ->
           Watched_work.run (fun () -> backend.execute verb)
             ~watcher:(fun () -> Time_compat.sleep timeout_sec; Timed_out))
let issue_automation ~verb ~timeout_sec =
  issue_automation_with ~activity_check:(activity_refusal Lane_name.Automation) ~verb ~timeout_sec
type stagehand_backend = {execute : actor:string option -> verb -> answer; models : bool}
let stagehand_executor : stagehand_backend option Atomic.t = Atomic.make None
let install_stagehand_executor ?(models=true) executor =
  Atomic.set stagehand_executor (Option.map (fun execute -> {execute;models}) executor)
let stagehand_models_available () = match Atomic.get stagehand_executor with
  | None -> false | Some backend -> backend.models
type backend_observation = Live_clients of int | Executor_registered of bool
type inventory_observation = { activity : activity; backend : backend_observation }
(* Reading inventory must not prune clients or resolve their waiting requests. *)
let inventory_observation ?observed_activity lane =
  let activity = match observed_activity with
    | Some value -> value | None -> activity lane in
  let backend = match lane with
  | Lane_name.Live -> Live_clients (Eio.Mutex.use_ro clients_mutex (fun () ->
      Hashtbl.fold (fun _ client count -> if connected client then count+1 else count) clients 0))
  | Lane_name.Automation -> Executor_registered (Option.is_some (Atomic.get automation_executor))
  | Lane_name.Stagehand -> Executor_registered (Option.is_some (Atomic.get stagehand_executor))
  in { activity; backend }
let issue_stagehand_with ~actor ~activity_check ~verb ~timeout_sec =
  if not (verb_allowed_on_stagehand verb) then
    Rejected_before_effect ("the stagehand lane does not serve " ^ verb_to_string verb)
  else match activity_check verb with
  | Some refusal -> refusal
  | None -> match Atomic.get stagehand_executor with
  | None -> Lane_absent
  | Some backend when verb_uses_model verb && not backend.models ->
    Rejected_before_effect "browser stagehand Exact Output is not selected"
  | Some backend when verb_uses_model verb -> backend.execute ~actor verb
  | Some backend ->
    (match timeout_sec with
     | None -> backend.execute ~actor verb
     | Some timeout_sec -> Watched_work.run (fun () -> backend.execute ~actor verb)
         ~watcher:(fun () -> Time_compat.sleep timeout_sec; Timed_out))
let issue_stagehand ~verb ~timeout_sec =
  issue_stagehand_with ~actor:None ~activity_check:(activity_refusal Lane_name.Stagehand) ~verb ~timeout_sec
(* The lanes whose browser the server owns; sessions and navigation belong
   to them, and the live browser belongs to the operator. *)
type server_lane = Server_automation | Server_stagehand

type session_observation = Browser_closed | Browser_open | Browser_changing | Browser_unknown
let automation_session_observer : (unit -> session_observation) option Atomic.t = Atomic.make None
let stagehand_session_observer : (unit -> session_observation) option Atomic.t = Atomic.make None
let session_observer = function
  | Server_automation -> automation_session_observer
  | Server_stagehand -> stagehand_session_observer
let install_server_session_observer lane observer = Atomic.set (session_observer lane) observer
let server_session_observation lane = match Atomic.get (session_observer lane) with
  | None -> Browser_unknown
  | Some observe -> observe ()

let server_lane_of_name : Lane_name.t -> server_lane option = function
  | Lane_name.Automation -> Some Server_automation
  | Lane_name.Stagehand -> Some Server_stagehand
  | Lane_name.Live -> None
;;

let server_lane_name = function
  | Server_automation -> Lane_name.Automation
  | Server_stagehand -> Lane_name.Stagehand
;;

let server_lanes_expected =
  String.concat " or " (List.map (fun lane -> Lane_name.to_wire (server_lane_name lane)) [ Server_automation; Server_stagehand ])
;;

let server_lane_refused = "lane must be " ^ server_lanes_expected

(* A wire lane name as a server lane, or why not. Models often reach for live
   here, since the read tools default to it, so that refusal says whose
   browser it is. *)
let parse_server_lane raw =
  match Lane_name.of_wire raw with
  | Some Lane_name.Live -> Error ("the live browser belongs to the operator; " ^ server_lane_refused)
  | Some ((Lane_name.Automation | Lane_name.Stagehand) as name) ->
    Option.to_result ~none:server_lane_refused (server_lane_of_name name)
  | None -> Error server_lane_refused
;;

(* Opening waits for Chromium, CDP, and Stagehand's own bounded attach. The
   generic server-lane deadline can expire while those are still running,
   leaving the caller unsure whether a browser opened. *)
module Stagehand_open_budget = struct
  (* On 2026-09-24 the port file appeared in 0.3–5.7 s, a CDP readiness
     command in under 2 s, the extension worker in under 0.5 s, and init
     answered in 0.6–5.1 s on Chrome Canary / Chrome for Testing. The server
     and its TUI caller share these waits so a cold open cannot expire before
     bounded startup finishes. The final CDP window covers process and HTTP
     transport overhead; the server itself does not abandon the open then. *)
  let devtools_port_timeout_s = 20.
  let cdp_command_deadline_s = 30.
  let service_worker_wait_s = 20.
  let init_answer_s = 30.
  let attach_deadline_s = service_worker_wait_s +. cdp_command_deadline_s +. init_answer_s
  let http_timeout_s =
    devtools_port_timeout_s +. cdp_command_deadline_s +. attach_deadline_s
    +. cdp_command_deadline_s
end

let stagehand_server_deadline verb ~timeout_sec =
  match verb with
  | Session_open _ -> None
  | Session_close | Session_status | Tabs_list | Page_read _ | Page_document _ | Page_downloads _ | Page_console _ | Page_network _ | Page_cookies _ | Page_capture _
  | Page_scene _ | Page_snapshot _ | Page_interact _ | Page_native_workflow _ | Page_goto _ | Page_elements _ | Page_act _ | Page_context _ | Page_instruct _
  | Page_locate _ | Page_extract _ -> Some timeout_sec
;;

let issue_server_lane lane ~verb ~timeout_sec =
  match lane with
  | Server_automation -> issue_automation ~verb ~timeout_sec
  | Server_stagehand -> issue_stagehand ~verb ~timeout_sec:(stagehand_server_deadline verb ~timeout_sec)
;;

let issue_for_actor ~actor ~target ~verb ~timeout_sec =
  match target with
  | Live_client client -> issue_live_with ~activity_check:(activity_refusal Lane_name.Live) ?actor client ~verb ~timeout_sec
  | Automation -> Ok (issue_automation ~verb ~timeout_sec)
  | Stagehand -> Ok (issue_stagehand_with ~actor ~activity_check:(activity_refusal Lane_name.Stagehand) ~verb
      ~timeout_sec:(stagehand_server_deadline verb ~timeout_sec))

(** Additional observations never queue behind an existing browser command.
    Busy or missing browsers leave this optional source unavailable. The caller
    supplies the same transport timeout used by existing browser reads. *)
let issue_document_if_idle ~target ~tab_id ~timeout_sec =
  match target with
  | Live_client client ->
    (match issue_live ~only_if_idle:true client ~verb:(Page_document {tab_id}) ~timeout_sec with
     | Ok (Answered (`Assoc fields)) ->
       (match List.assoc_opt "data" fields with
        | Some (`Assoc data) ->
          let data = `Assoc (with_connection_fields target data) in
          Ok (Answered (`Assoc (("data", data) :: List.remove_assoc "data" fields)))
        | Some _ | None -> Ok (Answered (`Assoc fields)))
     | (Ok (Answered (`Null | (`List _ | (`Bool _ | (`Float _ | (`Int _ | (`Intlit _ | `String _))))))) | Ok (Lane_absent | (Timed_out | (Refused _ | Rejected_before_effect _))) | Error _) as answer -> answer)
  (* The Stagehand backend has no idle document observer; the optional
     source is unavailable there, as it is for a busy browser. *)
  | Stagehand -> Ok Lane_absent
  | Automation ->
    match activity_refusal Lane_name.Automation (Page_document {tab_id}) with
    | Some refusal -> Ok refusal
    | None -> match Atomic.get automation_document_observer with
    | None -> Ok Lane_absent
    | Some observe -> Ok (Watched_work.run (fun () -> observe ~tab_id)
        ~watcher:(fun () -> Time_compat.sleep timeout_sec; Timed_out))
