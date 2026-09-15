type navigation_source = { url : string; document_id : string }
type rect = { x : float; y : float; width : float; height : float }
type region_role =
  | Main
  | Navigation
  | Complementary
  | Named_region
  | Section
  | Article
  | Header
  | Footer
  | Search
  | Form
  | Log
  | Banner
  | Content_info
  | Scroll_area
  | Unknown of string

(* Role names arrive as strings from the browser. Classify them once at that
   boundary so navigation decisions can match a closed semantic set. Unknown
   roles remain visible for the operator and are never an implicit target. *)
let region_role_of_string value =
  let trimmed = String.trim value in
  match String.lowercase_ascii trimmed with
  | "main" -> Main
  | "navigation" -> Navigation
  | "complementary" -> Complementary
  | "region" -> Named_region
  | "section" -> Section
  | "article" -> Article
  | "header" -> Header
  | "footer" -> Footer
  | "search" -> Search
  | "form" -> Form
  | "log" -> Log
  | "banner" -> Banner
  | "contentinfo" -> Content_info
  | "scroll-area" -> Scroll_area
  | _ -> Unknown trimmed

let region_role_to_string = function
  | Main -> "main"
  | Navigation -> "navigation"
  | Complementary -> "complementary"
  | Named_region -> "region"
  | Section -> "section"
  | Article -> "article"
  | Header -> "header"
  | Footer -> "footer"
  | Search -> "search"
  | Form -> "form"
  | Log -> "log"
  | Banner -> "banner"
  | Content_info -> "contentinfo"
  | Scroll_area -> "scroll-area"
  | Unknown value -> value

type kind =
  | Text
  | Raster
  | Region of region_role
  | Control of {
      clickable : bool;
      editable : bool;
      disabled : bool;
      href : string option;
    }
type region_ref = { node_id : string; role : region_role; label : string }
(* HTML local names are observed browser data. Classify the closed heading
   subset once at this boundary so TUI presentation can render an outline
   without repeatedly matching tags or inventing selectors. *)
type text_role =
  | Plain_text
  | Heading of int

let text_role_of_tag tag =
  match String.lowercase_ascii (String.trim tag) with
  | "h1" -> Heading 1
  | "h2" -> Heading 2
  | "h3" -> Heading 3
  | "h4" -> Heading 4
  | "h5" -> Heading 5
  | "h6" -> Heading 6
  | _ -> Plain_text

type node = { node_id : string; kind : kind; tag : string; text : string;
  heading_level : int option;
  ancestor_region : region_ref option;
  rects : rect list; color : string; font_size : float; font_weight : string; white_space : string; source_context : Browser_source_context.t }
let text_role (node : node) =
  match node.kind with
  | Text | Control _ -> (match node.heading_level with
      | Some level -> Heading level
      | None -> text_role_of_tag node.tag)
  | Raster | Region _ -> Plain_text

type t = { document_id : string; url : string; title : string; width : float; height : float;
  scroll_x : float; scroll_y : float; nodes : node list; truncated : bool;
  view : Browser_lane.scene_view; scope : Browser_lane.node_ref option }
let ( let* ) = Result.bind
let field name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some v -> Ok v | None -> Error ("scene missing " ^ name))
  | _ -> Error "scene must be an object"
let string = function `String value -> Ok value | _ -> Error "scene string required"
let boolean = function `Bool value -> Ok value | _ -> Error "scene boolean required"
let optional_href json =
  match field "href" json with
  | Error _ -> Ok None
  | Ok `Null -> Ok None
  | Ok (`String value) when String.trim value <> "" -> Ok (Some value)
  | Ok _ -> Error "scene control href must be a nonempty string or null"
let optional_heading_level json =
  match field "headingLevel" json with
  | Error _ | Ok `Null -> Ok None
  | Ok (`Int value) when value >= 1 && value <= 6 -> Ok (Some value)
  | Ok _ -> Error "scene headingLevel must be an integer from 1 to 6 or null"
let number = function
  | `Int value -> Ok (float_of_int value)
  | `Float value when Float.is_finite value -> Ok value
  | _ -> Error "scene finite coordinate required"
let get parse name json = let* value = field name json in parse value
let nonempty json = let* value = string json in if value <> "" then Ok value else Error "empty scene identity"
let optional_region_ref json =
  match field "ancestorRegion" json with
  | Error _ | Ok `Null -> Ok None
  | Ok (`Assoc fields) when List.sort String.compare (List.map fst fields) =
      ["label"; "nodeId"; "role"] ->
      let value = `Assoc fields in
      let* node_id = get nonempty "nodeId" value in
      let* role = get (fun json ->
        let* value = nonempty json in Ok (region_role_of_string value)) "role" value in
      let* label = get nonempty "label" value in
      Ok (Some {node_id; role; label})
  | Ok _ -> Error "scene ancestorRegion must contain nodeId, role and label or null"
let nonnegative json = let* value = number json in if value >= 0. then Ok value else Error "scene size must be nonnegative"
let positive json = let* value = number json in if value > 0. then Ok value else Error "scene dimension must be positive"
let list parse = function
  | `List values ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest -> let* v = parse value in loop (v :: acc) rest
      in loop [] values
  | _ -> Error "scene array required"
let rect json =
  let* x = get number "x" json in let* y = get number "y" json in
  let* width = get positive "width" json in let* height = get positive "height" json in
  Ok {x;y;width;height}
let node json =
  let* node_id = get nonempty "nodeId" json in
  let* tag = get nonempty "tag" json in let* text = get string "text" json in
  let* heading_level = optional_heading_level json in
  let* ancestor_region = optional_region_ref json in
  let* rects = get (list rect) "rects" json in
  let* () = if rects <> [] then Ok () else Error "scene node has no rectangles" in
  let* color = get string "color" json in let* font_size = get nonnegative "fontSize" json in
  let* font_weight = get string "fontWeight" json in let* white_space = get string "whiteSpace" json in
  let* kind = get string "kind" json in
  let* kind = match kind with
    | "text" -> Ok Text | "raster" -> Ok Raster
    | "region" -> let* role = get nonempty "role" json in
      Ok (Region (region_role_of_string role))
    | "control" -> let* clickable = get boolean "clickable" json in
      let* editable = get boolean "editable" json in let* disabled = get boolean "disabled" json in
      let* href = optional_href json in
      Ok (Control {clickable;editable;disabled;href})
    | _ -> Error "unknown semantic scene node kind" in
  (* The extension always emits sourceContext, null when the element carries
     no dev-source hint. A node without the key is a producer defect, not an
     unmapped element, so it fails the scene decode. *)
  let* source_context = Result.map Browser_source_context.of_json (field "sourceContext" json) in
  Ok {node_id;kind;tag;text;heading_level;ancestor_region;rects;color;font_size;font_weight;white_space;source_context}
let scope_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["documentId";"nodeId"] ->
      let* document_id = get nonempty "documentId" (`Assoc fields) in
      let* node_id = get nonempty "nodeId" (`Assoc fields) in
      Ok ({document_id;node_id} : Browser_lane.node_ref)
  | _ -> Error "scope requires exactly documentId and nodeId from an observed region"

let navigation_source_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["documentId";"url"] ->
      let* document_id = get nonempty "documentId" (`Assoc fields) in
      let* url = get nonempty "url" (`Assoc fields) in
      Ok ({document_id;url} : navigation_source)
  | _ -> Error "navigationSource requires exactly documentId and url from the follow receipt"

let of_json json =
  let* schema = get string "schema" json in
  let* () = if schema = "masc.browser.scene.v1" then Ok () else Error "unknown semantic scene schema" in
  let* document_id = get nonempty "documentId" json in
  let* url = get string "url" json in let* title = get string "title" json in
  let* viewport = field "viewport" json in
  let* width = get positive "width" viewport in let* height = get positive "height" viewport in
  let* scroll_x = get number "scrollX" viewport in let* scroll_y = get number "scrollY" viewport in
  let* nodes = get (list node) "nodes" json in let* truncated = get boolean "truncated" json in
  let* view = get string "view" json in
  let* view = match view with "content" -> Ok Browser_lane.Content | "regions" -> Ok Browser_lane.Regions
    | _ -> Error "unknown scene view acknowledgement" in
  let* scope = field "scope" json in
  let* scope = match scope with `Null -> Ok None | value -> Result.map Option.some (scope_of_json value) in
  let* () = match scope with
    | Some target when target.document_id <> document_id -> Error "scene scope document mismatch"
    | Some _ | None -> Ok () in
  Ok {document_id;url;title;width;height;scroll_x;scroll_y;nodes;truncated;view;scope}
let read ?navigation_source ?expected_url ?(view=Browser_lane.Content) ?scope (request : Browser_surface.request) ~max_chars =
  let started = Mtime_clock.elapsed_ns () in
  let* tab_id = match request.tab_id with Some id -> Ok id | None -> Error "scene requires tabId" in
  let* target = Browser_surface.resolved_target request
    |> Result.map_error Browser_lane.selection_error_code in
  let* json = Browser_lane.issue_for ~target ~verb:(Browser_lane.Page_scene {tab_id;max_chars;view;scope})
    ~timeout_sec:20. |> Browser_surface.decode_answer in
  let* scene = of_json json in
  let* () = match expected_url with
    | Some url when scene.url <> url ->
        let evidence = Yojson.Safe.to_string (`Assoc ["expectedUrl",`String url;"observedUrl",`String scene.url]) in
        Error ("destination_url_not_observed " ^ evidence ^
          "; read this pinned tab without expectedUrl, retaining navigationSource, to inspect pending navigation or a possible redirect; verify destination content before pinning its observed URL; do not replay follow_link")
    | Some _ | None -> Ok () in
  let* () = match navigation_source with
    | Some (source : navigation_source) when source.url = scene.url && scene.document_id = source.document_id ->
        Error "same_url_document_transition_not_observed; retry only BrowserRead with navigationSource unchanged; do not replay follow_link"
    | Some _ | None -> Ok () in
  let* () = if scene.view = view && scene.scope = scope then Ok ()
    else Error "browser did not acknowledge the requested scene view/scope; update the connector" in
  let* actual = field "tabId" json in
  let* () = if actual = `Int tab_id then Ok () else Error "scene tab identity mismatch" in
  let elapsed_ms = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
  match json with
  | `Assoc fields ->
    (* These fields belong to the resolved local route, not page/backend JSON.
       Remove every supplied occurrence before attaching the authoritative
       values so first-key and last-key consumers see the same observation. *)
    let fields = List.filter (fun (key, _) ->
      not (List.mem key ["source"; "clientId"; "elapsed_ms"])) fields in
    Ok (`Assoc (fields @ ["source",`String (match request.source with Live -> "live" | Automation -> "automation");
      "clientId",Browser_surface.client_id_json target;"elapsed_ms",`Float elapsed_ms]))
  | _ -> Error "scene must be an object"


let read_request = function
  | `Assoc fields ->
      let allowed = ["lane";"clientId";"tabId";"view";"scope";"maxChars";"expectedUrl";"navigationSource"] in
      let keys = List.map fst fields in
      let* () = if List.for_all (fun key -> List.mem key allowed) keys
        && List.length keys=List.length (List.sort_uniq String.compare keys)
        then Ok () else Error "unknown or duplicate scene argument" in
      let* request = Browser_surface.parse_capture_request (`Assoc
        (List.filter (fun (key,_) -> List.mem key ["lane";"clientId";"tabId"]) fields)) in
      let* view = match List.assoc_opt "view" fields with
        | None | Some (`String "content") -> Ok Browser_lane.Content
        | Some (`String "regions") -> Ok Browser_lane.Regions
        | _ -> Error "scene view must be content or regions" in
      let* scope = match List.assoc_opt "scope" fields with
        | None -> Ok None | Some json -> Result.map Option.some (scope_of_json json) in
      let* expected_url = match List.assoc_opt "expectedUrl" fields with
        | None -> Ok None
        | Some (`String value) when String.trim value <> "" -> Ok (Some value)
        | _ -> Error "expectedUrl must be a nonempty string" in
      let* navigation_source = match List.assoc_opt "navigationSource" fields with
        | None -> Ok None
        | Some json -> Result.map Option.some (navigation_source_of_json json) in
      let* max_chars = match List.assoc_opt "maxChars" fields with
        | None -> Ok 50_000
        | Some (`Int value) when value>=1 && value<=100_000 -> Ok value
        | _ -> Error "maxChars must be between 1 and 100000" in
      read ~view ?scope ?expected_url ?navigation_source request ~max_chars
  | _ -> Error "scene request must be an object"
