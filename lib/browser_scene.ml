type rect = { x : float; y : float; width : float; height : float }
type kind = Text | Raster | Control of { clickable : bool; editable : bool; disabled : bool }
type node = { node_id : string; kind : kind; tag : string; text : string;
  rects : rect list; color : string; font_size : float; font_weight : string; white_space : string }
type t = { document_id : string; url : string; title : string; width : float; height : float;
  scroll_x : float; scroll_y : float; nodes : node list; truncated : bool }
let ( let* ) = Result.bind
let field name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some v -> Ok v | None -> Error ("scene missing " ^ name))
  | _ -> Error "scene must be an object"
let string = function `String value -> Ok value | _ -> Error "scene string required"
let boolean = function `Bool value -> Ok value | _ -> Error "scene boolean required"
let number = function
  | `Int value -> Ok (float_of_int value)
  | `Float value when Float.is_finite value -> Ok value
  | _ -> Error "scene finite coordinate required"
let get parse name json = let* value = field name json in parse value
let nonempty json = let* value = string json in if value <> "" then Ok value else Error "empty scene identity"
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
  let* rects = get (list rect) "rects" json in
  let* () = if rects <> [] then Ok () else Error "scene node has no rectangles" in
  let* color = get string "color" json in let* font_size = get nonnegative "fontSize" json in
  let* font_weight = get string "fontWeight" json in let* white_space = get string "whiteSpace" json in
  let* kind = get string "kind" json in
  let* kind = match kind with
    | "text" -> Ok Text | "raster" -> Ok Raster
    | "control" -> let* clickable = get boolean "clickable" json in
      let* editable = get boolean "editable" json in let* disabled = get boolean "disabled" json in
      Ok (Control {clickable;editable;disabled})
    | _ -> Error "unknown semantic scene node kind" in
  Ok {node_id;kind;tag;text;rects;color;font_size;font_weight;white_space}
let of_json json =
  let* schema = get string "schema" json in
  let* () = if schema = "masc.browser.scene.v1" then Ok () else Error "unknown semantic scene schema" in
  let* document_id = get nonempty "documentId" json in
  let* url = get string "url" json in let* title = get string "title" json in
  let* viewport = field "viewport" json in
  let* width = get positive "width" viewport in let* height = get positive "height" viewport in
  let* scroll_x = get number "scrollX" viewport in let* scroll_y = get number "scrollY" viewport in
  let* nodes = get (list node) "nodes" json in let* truncated = get boolean "truncated" json in
  Ok {document_id;url;title;width;height;scroll_x;scroll_y;nodes;truncated}
let read (request : Browser_surface.request) ~max_chars =
  let started = Mtime_clock.elapsed_ns () in
  let* tab_id = match request.tab_id with Some id -> Ok id | None -> Error "scene requires tabId" in
  let* target = Browser_surface.resolved_target request in
  let* json = Browser_lane.issue_for ~target ~verb:(Browser_lane.Page_scene {tab_id;max_chars})
    ~timeout_sec:20. |> Browser_surface.decode_answer in
  let* _scene = of_json json in
  let* actual = field "tabId" json in
  let* () = if actual = `Int tab_id then Ok () else Error "scene tab identity mismatch" in
  let elapsed_ms = Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e6 in
  match json with
  | `Assoc fields -> Ok (`Assoc (fields @ ["source",`String (match request.source with Live -> "live" | Automation -> "automation");
      "clientId",Browser_surface.client_id_json target;"elapsed_ms",`Float elapsed_ms]))
  | _ -> Error "scene must be an object"
