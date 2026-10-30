open Alcotest
module Types = Masc_tui_types
module Catalog = Masc_tui_resource_catalog
module Doc = Masc_tui_resource_document
module Diagrams = Masc_tui_resource_diagrams
module Position = Masc_tui_scroll.Position

let cols = 80
let height = 1
let key = Catalog.Mcp_uri "masc://anchor"
let first_source = "flowchart TD\n A[First] --> B[Second]"
let second_source = "flowchart LR\n C[Other] --> D[Last]"
let fence source = "```mermaid\n" ^ source ^ "\n```\n"
let prefix = "# Before\n\n"
let first_fence = fence first_source
let between = "\nBetween\n\n"
let repeated_start = String.length (prefix ^ first_fence ^ between)
let after_start = String.length (prefix ^ first_fence ^ between ^ first_fence ^ "\n")
let original = prefix ^ first_fence ^ between ^ first_fence ^ "\nAfter diagrams\n\n"
  ^ fence second_source ^ String.concat "\n" (List.init 20 (fun i -> "Tail " ^ string_of_int i))
let parts () = List.map (fun source ->
  {Masc_tui_mcp.rc_uri=Some "masc://anchor";rc_mime_type=Some "text/markdown";
   rc_kind=Masc_tui_mcp.Resource_text source}) [original;"# Part two\r\nOriginal\tbytes\r"]
let loaded () =
  let state=Types.create_state ~workspace:"test" ~port:0 ~refresh_interval:0. () in
  let contents=parts () in
  state.view <- Types.Resources;
  state.resource_focus <- Types.Right_pane;
  state.resources_list <- Some [Catalog.Mcp {Masc_tui_mcp.uri="masc://anchor";
    name="anchor";title=None;description=None;mime_type=Some "text/markdown";size=None}];
  state.resource_content <- Some (key,contents);
  state.resource_diagrams <- Some (Diagrams.create ~mime_type:(Some "text/markdown")
    ~contents ~width:70 ~cell_pixels:(8,16) ~colors:None);
  state,contents
let request state = Diagrams.request (Option.get state.Types.resource_diagrams)
let count state = List.length (Doc.rows ~cols (Option.get (Doc.current state)))
let offset state = Position.offset ~count:(count state) ~height state.Types.resource_scroll
let anchor state = Option.get (Doc.capture_anchor ~cols ~height state)
let source state = Doc.source_position (anchor state)
let position = option (pair int int)
let source_rows state target =
  let saved=state.Types.resource_scroll in
  let found=List.init (count state) Fun.id |> List.filter (fun row ->
    state.resource_scroll <- Position.at row;
    Doc.source_position (anchor state)=Some target) in
  state.resource_scroll <- saved;
  found
let place state target =
  match source_rows state target with
  | row :: _ -> state.Types.resource_scroll <- Position.at row
  | [] -> fail "source block is absent"
let settle state source result =
  Doc.settle_diagram ~cols ~height state ~request:(request state) ~source result
let png = Base64.decode_exn "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lV8AAAAASUVORK5CYII="

let test_below_and_parts () =
  List.iter (fun target ->
    let state,contents=loaded () in
    place state target;
    settle state first_source (Ok png);
    check position "same original part/block after both repeated diagrams settle" (Some target) (source state);
    settle state second_source (Ok png);
    check position "same original part/block after progress disappears" (Some target) (source state);
    check bool "original response observation retained" true
      (match state.resource_content with Some(_,saved)->saved==contents | None->false))
    [1,after_start;2,0]
let test_inside_repeated () =
  List.iter (fun start ->
    let state,_=loaded () in
    let target=1,start in
    let before=source_rows state target in
    let first=List.hd before and extent=List.length before in
    let within=(extent-1)/2 in
    state.resource_scroll <- Position.at (first+within);
    settle state first_source (Ok png);
    check position "same occurrence, rather than first identical source" (Some target) (source state);
    let after=source_rows state target in
    let expected=List.hd after + within*(List.length after-1)/max 1 (extent-1) in
    check int "diagram retains fractional block progress" expected (offset state))
    [String.length prefix;repeated_start]
let test_failure_prefix () =
  let state,_=loaded () in
  place state (1,after_start);
  settle state first_source (Error "unavailable");
  check position "failure insertion keeps source" (Some(1,after_start)) (source state);
  settle state second_source (Error "also unavailable");
  check position "progress removal and second failure keep source" (Some(1,after_start)) (source state)
let test_explicit_edges () =
  let state,_=loaded () in
  settle state first_source (Ok png);
  check int "Home stays at exact top" 0 (offset state);
  state.resource_scroll <- Position.move ~count:(count state) ~height Last state.resource_scroll;
  settle state second_source (Error "unavailable");
  check bool "explicit End survives reflow" true (Position.is_end state.resource_scroll)
let test_stale_and_modes () =
  let state,_=loaded () in
  place state (1,after_start);
  let saved=state.resource_scroll in
  let old=request state in
  let fresh=Diagrams.create ~mime_type:(Some "text/markdown") ~contents:(parts ())
    ~width:70 ~cell_pixels:(8,16) ~colors:None in
  state.resource_diagrams <- Some fresh;
  Doc.settle_diagram ~cols ~height state ~request:old ~source:first_source (Ok png);
  check bool "stale result cannot scroll" true (state.resource_scroll==saved);
  check bool "stale result cannot settle new preparation" true (Option.get state.resource_diagrams==fresh);
  List.iter (fun mode ->
    let state,_=loaded () in
    state.resource_scroll <- Position.at 7;
    (match mode with `Source -> state.resource_presentation <- Catalog.Source
     | `Search -> state.search <- Some "First" | `List -> state.resource_focus <- Types.Left_pane);
    check bool "inactive anchor is not admitted" true (Option.is_none (Doc.capture_anchor ~cols ~height state));
    let saved=state.resource_scroll in
    settle state first_source (Ok png);
    check bool "mode owns existing scroll semantics" true (saved==state.resource_scroll))
    [`Source;`Search;`List]
let test_changed_observation () =
  let state,_=loaded () in
  place state (1,after_start);
  let captured=anchor state in
  state.resource_content <- Some(key,parts ());
  state.resource_scroll <- Position.at 7;
  let saved=state.resource_scroll in
  Doc.restore_anchor ~cols ~height state captured;
  check bool "equal bytes in a new observation cannot consume anchor" true (saved==state.resource_scroll)
let test_duplicate_completion () =
  let state,_=loaded () in
  place state (1,after_start);
  settle state first_source (Ok png);
  let saved_scroll=state.resource_scroll and saved_diagrams=state.resource_diagrams in
  settle state first_source (Error "late duplicate");
  check bool "a completed source cannot move the reader again" true (saved_scroll==state.resource_scroll);
  check bool "first completion keeps its cache snapshot" true (saved_diagrams==state.resource_diagrams)
let cases = ["ownership and reflow",[
  test_case "below repeated diagrams and multipart" `Quick test_below_and_parts;
  test_case "inside each repeated occurrence" `Quick test_inside_repeated;
  test_case "failure and progress chrome" `Quick test_failure_prefix;
  test_case "explicit top and End" `Quick test_explicit_edges;
  test_case "stale result and other modes" `Quick test_stale_and_modes;
  test_case "new observation" `Quick test_changed_observation;
  test_case "duplicate completion" `Quick test_duplicate_completion]]
