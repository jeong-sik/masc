(** The browser lane retains one page's wrapped rows.

    Object analysis puts up to 200 nodes into the view, and every frame plus
    every keystroke re-wrapped all of them: the scroll handler asked for the
    row count and the frame asked for the rows. Two tests, one per direction
    -- reading the same page reuses, and a changed input replaces. *)

module Layout = Masc_tui_browser_lane_layout

let node index : Masc.Browser_scene.node =
  { node_id = Printf.sprintf "node-%03d" index
  ; kind = Text
  ; tag = "p"
  ; text = Printf.sprintf "line %d 한글 본문" index
  ; rects = [ { x = 0.; y = float_of_int index; width = 100.; height = 16. } ]
  ; color = "rgb(0, 0, 0)"
  ; font_size = 14.
  ; font_weight = "400"
  ; white_space = "normal"
  ; source_context = Masc.Browser_source_context.Unmapped
  }
;;

let nodes = List.init 200 node

let source : Layout.source =
  { content = Layout.Scene nodes; scene_cursor = 0; columns = 100 }
;;

(* A stand-in for browser_lane_page_layout: one row per node, and the cursor
   marks one of them, so the rows depend on every field of the source. *)
let render (source : Layout.source) () =
  match source.content with
  | Layout.Scene nodes ->
    List.mapi
      (fun index (node : Masc.Browser_scene.node) ->
         Printf.sprintf
           "[%s%d cols=%d] %s"
           (if index = source.scene_cursor then ">" else "")
           (index + 1)
           source.columns
           node.text)
      nodes, Some source.scene_cursor
  | Layout.Page text -> [ text ], None
  | Layout.Empty -> [], None
;;

(* Scrolling moves the viewport; a check tick that finds the page unchanged
   rebuilds the view without changing it. Neither is a new layout. *)
let test_reading_one_page_lays_it_out_once () =
  let cache = Layout.create () in
  let renders = ref 0 in
  let get source =
    Layout.get cache ~source ~render:(fun () ->
      incr renders;
      render source ())
  in
  let first = get source in
  for _ = 1 to 200 do
    ignore (get source)
  done;
  Alcotest.(check int) "one layout across scrolling" 1 !renders;
  (* A refresh decodes the scene again, so the nodes are equal records at new
     addresses. Equal rows must not be re-wrapped. *)
  let decoded_again =
    List.map (fun (n : Masc.Browser_scene.node) -> { n with text = n.text }) nodes
  in
  ignore (get { source with content = Layout.Scene decoded_again });
  Alcotest.(check int) "an equal refresh reuses the wrapping" 1 !renders;
  Alcotest.(check int) "every node retained" 200 (Layout.count first);
  Alcotest.(check string)
    "the last row is reachable"
    (List.nth (fst (render source ())) 199)
    (Layout.line first 199)
;;

(* Each of these changes what a row says, so each has to re-render, and the
   rows that come back have to be the changed ones. *)
let test_a_changed_input_replaces_the_rows () =
  let edited =
    List.mapi
      (fun index (n : Masc.Browser_scene.node) ->
         if index = 199 then { n with text = "edited tail" } else n)
      nodes
  in
  let cases =
    [ "an edited node", { source with content = Layout.Scene edited }
    ; ( "an appended node"
      , { source with content = Layout.Scene (nodes @ [ node 200 ]) } )
    ; "a moved cursor", { source with scene_cursor = 3 }
    ; "a resize", { source with columns = 40 }
    ; "the page text behind the scene", { source with content = Layout.Page "raw text" }
    ; "no page at all", { source with content = Layout.Empty }
    ]
  in
  List.iter
    (fun (label, changed) ->
       let cache = Layout.create () in
       ignore (Layout.get cache ~source ~render:(render source));
       let renders = ref 0 in
       let rows =
         Layout.get cache ~source:changed ~render:(fun () ->
           incr renders;
           render changed ())
       in
       Alcotest.(check int) label 1 !renders;
       List.iteri
         (fun index expected ->
            Alcotest.(check string) (label ^ " row") expected (Layout.line rows index))
         (fst (render changed ())))
    cases
;;

(* One page is retained, so a second page evicts the first. Without this the
   cache would grow with every tab the operator reads. *)
let test_only_one_page_is_retained () =
  let cache = Layout.create () in
  let other = { source with content = Layout.Page "another page" } in
  ignore (Layout.get cache ~source ~render:(render source));
  ignore (Layout.get cache ~source:other ~render:(render other));
  let renders = ref 0 in
  ignore
    (Layout.get cache ~source ~render:(fun () ->
       incr renders;
       render source ()));
  Alcotest.(check int) "the first page was evicted" 1 !renders
;;

let () =
  Alcotest.run
    "Browser lane page layout"
    [ ( "retention"
      , [ Alcotest.test_case "200 nodes scroll without re-layout" `Quick
            test_reading_one_page_lays_it_out_once
        ; Alcotest.test_case "every layout input invalidates" `Quick
            test_a_changed_input_replaces_the_rows
        ; Alcotest.test_case "one page retained" `Quick test_only_one_page_is_retained
        ] )
    ]
;;
