(** Closed browser interactions. Caller strings are values, never script source. *)
type request = { source : Browser_surface.source; tab_id : int;
  expected_url : string option; action : Browser_lane.interaction }
let ( let* ) = Result.bind
let parse = function
  | `Assoc fields ->
    let allowed = ["lane"; "tabId"; "expectedUrl"; "action"; "selector"; "text"; "x"; "y"] in
    let* () = if List.for_all (fun (key, _) -> List.mem key allowed) fields
      && List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
      then Ok () else Error "unknown or duplicate browser interaction argument" in
    let* base = Browser_surface.parse_capture_request
      (`Assoc (List.filter (fun (key, _) -> List.mem key ["lane"; "tabId"]) fields)) in
    let* tab_id = match base.tab_id with Some id -> Ok id | None -> Error "tabId is required" in
    let* expected_url = match List.assoc_opt "expectedUrl" fields with
      | None -> Ok None
      | Some (`String url) when String.trim url <> "" -> Ok (Some url)
      | _ -> Error "expectedUrl must be a nonempty string" in
    let selector () = match List.assoc_opt "selector" fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | _ -> Error "selector must be a nonempty CSS selector" in
    let integer key = match List.assoc_opt key fields with
      | Some (`Int value) when Int64.abs (Int64.of_int value) <= 9007199254740991L -> Ok value
      | _ -> Error (key ^ " must be a JavaScript-safe integer") in
    let excludes keys =
      if List.exists (fun key -> List.mem_assoc key fields) keys
      then Error "arguments do not match the selected interaction action" else Ok () in
    let* action = match List.assoc_opt "action" fields with
      | Some (`String "click") ->
        let* () = excludes ["text"; "x"; "y"] in
        let* selector = selector () in Ok (Browser_lane.Click selector)
      | Some (`String "fill") ->
        let* () = excludes ["x"; "y"] in
        let* selector = selector () in
        (match List.assoc_opt "text" fields with
         | Some (`String text) -> Ok (Browser_lane.Fill {selector; text})
         | _ -> Error "fill requires string text (empty text clears the input)")
      | Some (`String "scroll") ->
        let* () = excludes ["selector"; "text"] in
        let* x = integer "x" in let* y = integer "y" in Ok (Browser_lane.Scroll {x; y})
      | _ -> Error "action must be click, fill, or scroll" in
    Ok { source = base.source; tab_id; expected_url; action }
  | _ -> Error "browser interaction arguments must be an object"

let script = {js|function interactInPage(args) {
  if (args.expectedUrl !== undefined && args.expectedUrl !== location.href)
    throw new Error("page_url_changed");
  const before = location.href;
  if (args.action === "scroll") {
    if (!Number.isSafeInteger(args.x) || !Number.isSafeInteger(args.y))
      throw new Error("scroll_coordinates_must_be_integers");
    window.scrollBy({left: args.x, top: args.y, behavior: "instant"});
  } else if (args.action === "click" || args.action === "fill") {
    if (typeof args.selector !== "string" || !args.selector.trim())
      throw new Error("selector_required");
    let elements;
    try { elements = document.querySelectorAll(args.selector); }
    catch { throw new Error("invalid_css_selector"); }
    if (elements.length !== 1)
      throw new Error(elements.length === 0 ? "element_not_found" : "selector_is_ambiguous");
    const element = elements[0];
    const style = getComputedStyle(element);
    if (!element.getClientRects().length || style.visibility === "hidden" || style.display === "none")
      throw new Error("element_not_visible");
    if (element.matches(":disabled")) throw new Error("element_disabled");
    if (args.action === "click") {
      if (typeof element.click !== "function") throw new Error("element_not_clickable");
      element.click();
    } else {
      if (typeof args.text !== "string") throw new Error("fill_text_required");
      const input = element instanceof HTMLInputElement;
      const textarea = element instanceof HTMLTextAreaElement;
      if ((!input && !textarea) || (input && !["text", "search", "email", "url", "tel", "password", "number"].includes(element.type)))
        throw new Error("element_is_not_a_text_input");
      if (element.readOnly) throw new Error("element_read_only");
      const prototype = input ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, "value").set;
      const previousValue = element.value;
      setter.call(element, args.text);
      if (element.value !== args.text) {
        setter.call(element, previousValue);
        throw new Error("input_rejected_value");
      }
      element.dispatchEvent(new Event("input", {bubbles: true}));
      element.dispatchEvent(new Event("change", {bubbles: true}));
      if (element.value !== args.text) throw new Error("input_changed_during_events");
    }
  } else throw new Error("unknown_interaction_action");
  return {action: args.action, urlBefore: before, url: location.href,
    title: document.title, scrollX: window.scrollX, scrollY: window.scrollY};
}

return interactInPage(arguments[0]);
|js}
