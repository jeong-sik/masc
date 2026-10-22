(** Browser tool arguments shared by {!Browser_addon_tools}: input errors,
    the lane/client/tab request, required browser actions, the read mode and
    the BrowserInstruct sentence. [retain_read_result] commits a scene or
    regions read as an observation receipt. *)

(* These failures come from caller-input parsing, before browser dispatch.
   Waiting for a different page cannot repair the same malformed arguments. *)
let make_input_err ~tool_name ~start_time detail =
  Tool_result.make_err ~tool_name ~start_time
    ~class_:Tool_result.Policy_rejection
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~data:(Tool_error.to_json (Tool_error.Invalid_input {detail}))
    ("Invalid browser arguments: " ^ detail
     ^ ". Correct the arguments using the tool schema and exact observed identities; no browser command was dispatched.")
;;

let tool_request args =
  let input = match args with
    | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> List.mem key ["lane"; "tabId"; "clientId"]) fields)
    | other -> other in
  Browser_surface.parse_request input

let required_actions args = match args with
  | `Assoc fields -> (match List.filter (fun (key,_) -> key="requiredActions") fields with
      | [] -> Ok []
      | [(_,value)] -> Browser_capabilities.parse_required_actions value
      | _::_::_ -> Error "requiredActions must occur only once")
  | _ -> Error "body must be a JSON object"

(* The [mode] argument of BrowserRead, read once. The top-level reads take
   the page as a whole; [frames] and [dialog] read the automation lane's page
   context. The tool schema's enum names the same values. *)
type top_level_read =
  [ `Text | `Elements | `Scene | `Regions | `Screenshot | `Downloads | `Console | `Network | `Cookies ]
[@@deriving enumerate]

type read_mode = [ top_level_read | `Frames | `Dialog ] [@@deriving enumerate]

let read_mode_to_string : read_mode -> string = function
  | `Text -> "text"
  | `Elements -> "elements"
  | `Scene -> "scene"
  | `Regions -> "regions"
  | `Screenshot -> "screenshot"
  | `Downloads -> "downloads"
  | `Console -> "console"
  | `Network -> "network"
  | `Cookies -> "cookies"
  | `Frames -> "frames"
  | `Dialog -> "dialog"
;;

let read_mode_of_args args : (read_mode, string) result =
  let unknown () =
    Error
      ("mode must be one of "
       ^ String.concat ", " (List.map read_mode_to_string all_of_read_mode))
  in
  match Json_util.assoc_member_opt "mode" args with
  | None -> Ok `Text
  | Some (`String raw) ->
    (match
       List.find_opt
         (fun mode -> String.equal (read_mode_to_string mode) raw)
         all_of_read_mode
     with
     | Some mode -> Ok mode
     | None -> unknown ())
  | Some _ -> unknown ()
;;

(* Retention requires an owner that will commit the observation receipt. *)
let retain_read_result ~base_path ~tool_name ~start_time args result =
  let retained = match read_mode_of_args args with
    | Ok `Scene -> Browser_observation.retain ~base_path ~view:Browser_lane.Content result
    | Ok `Regions -> Browser_observation.retain ~base_path ~view:Browser_lane.Regions result
    | Ok (`Text | `Elements | `Screenshot | `Downloads | `Console | `Network | `Cookies | `Frames | `Dialog) | Error _ -> Ok result in
  match retained with
  | Ok result -> result
  | Error detail ->
    Tool_result.make_err ~tool_name ~start_time
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_pre_effect
      ~data:(Tool_result.data result)
      ("Browser observation received but could not be retained: " ^ detail
       ^ "; retry only the read, not preceding navigation or interaction.")
;;

let instruct_arguments = [ "action"; "instruction"; "tabId"; "schema" ]

type instruct_action = Act | Observe | Extract

let instruct_action = function
  | Some (`String "act") -> Ok Act
  | Some (`String "observe") -> Ok Observe
  | Some (`String "extract") -> Ok Extract
  | Some _ | None -> Error "action must be one of: act, observe, extract"
;;

let instruct_verb fields =
  let ( let* ) = Result.bind in
  let* instruction =
    match List.assoc_opt "instruction" fields with
    | None -> Ok None
    | Some (`String text) when String.trim text <> "" -> Ok (Some text)
    | Some _ -> Error "instruction must be a nonempty string"
  in
  let* tab_id =
    match List.assoc_opt "tabId" fields with
    | Some (`Int id) when id >= 0 -> Ok id
    | Some _ | None -> Error "tabId must be an observed BrowserTabs id on the selected owned browser"
  in
  let* schema =
    match List.assoc_opt "schema" fields with
    | None -> Ok None
    | Some (`String text) ->
      (match Yojson.Safe.from_string text with
       | `Assoc _ as schema -> Ok (Some schema)
       | _ -> Error "schema must be a JSON object"
       | exception Yojson.Json_error detail -> Error ("schema is not JSON: " ^ detail))
    | Some _ -> Error "schema must be JSON Schema text"
  in
  let* action = instruct_action (List.assoc_opt "action" fields) in
  match action, instruction, schema with
  | Act, Some instruction, None -> Ok (Browser_lane.Page_instruct { tab_id; instruction })
  | Observe, instruction, None -> Ok (Browser_lane.Page_locate { tab_id; instruction })
  | Extract, Some instruction, schema -> Ok (Browser_lane.Page_extract { tab_id; instruction; schema })
  | (Act | Extract), None, _ -> Error "act and extract need an instruction"
  | (Act | Observe), _, Some _ -> Error "schema is for extract only"
;;
