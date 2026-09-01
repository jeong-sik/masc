(** Which rows are quoted, and how many layers there are allowed to be.

    Shading says belonging: a tool's output and a recalled memory are text the
    Keeper did not write, so they are quoted rather than said. The Keeper's own
    reply, its reasoning, and the operator's message are prose, whatever colour
    their status gives them.

    These check the rows [visible_rows] actually returns rather than the
    classifier on its own — a classifier that is right while nothing calls it
    proves nothing about the pane.

    The layer count is the other half. [shade] is a closed sum, so a fourth
    tint cannot be added without every renderer answering for it; that is the
    property, and the test that says so is the [match] below, which stops
    compiling the moment a variant appears. *)

open Alcotest
module Layout = Masc_tui_message_layout

let entry style body : Layout.entry =
  { style
  ; timestamp = "01:41:00"
  ; timeline_bucket = None
  ; role_label = "LABEL"
  (* No speaker mark on this fixture: the shade layers are what it is about,
     and a mark would only widen the label. #30744 added the field while this
     file was in flight, so it arrived without one. *)
  ; role_label_mark_cells = 0
  ; request_label = ""
  ; body
  ; markdown_source = Layout.Markdown_streaming
  }
;;

let shades_of style =
  Layout.visible_rows ~inner_width:60 ~height:20 [ entry style "quoted body" ]
  |> List.filter_map (fun (row : Layout.row) ->
       match row.kind with
       | Layout.Body -> Some row.shade
       | Layout.Metadata _ | Layout.Viewport_gap _ -> None)
;;

let is_quoted = function Layout.Shade_quoted -> true | Layout.Shade_none -> false

let test_tool_output_is_quoted () =
  List.iter
    (fun (name, style) ->
       let shades = shades_of style in
       check bool (name ^ ": has body rows") true (shades <> []);
       check
         bool
         (name ^ ": the Keeper did not write this, so it is quoted")
         true
         (List.for_all is_quoted shades))
    [ ("tool", Layout.Tool); ("status", Layout.Status) ]
;;

let test_the_keepers_own_words_are_not_quoted () =
  List.iter
    (fun (name, style) ->
       let shades = shades_of style in
       check bool (name ^ ": has body rows") true (shades <> []);
       check
         bool
         (name ^ ": said, not quoted")
         false
         (List.exists is_quoted shades))
    [ ("keeper", Layout.Keeper)
    ; ("user", Layout.User)
    ; ("error", Layout.Error)
    ; ("thinking", Layout.Thinking)
    ]
;;

(* The origin banner frames the message; it is not part of what is quoted. *)
let test_metadata_rows_are_never_quoted () =
  let rows =
    Layout.visible_rows ~origin:Layout.Origin_row ~inner_width:60 ~height:20
      [ entry Layout.Tool "quoted body" ]
  in
  let metadata_shades =
    List.filter_map
      (fun (row : Layout.row) ->
         match row.kind with
         | Layout.Metadata _ -> Some row.shade
         | Layout.Body | Layout.Viewport_gap _ -> None)
      rows
  in
  check bool "there is a metadata row to check" true (metadata_shades <> []);
  check
    bool
    "the frame around a quotation is not itself quoted"
    false
    (List.exists is_quoted metadata_shades)
;;

(* Three steps is the ceiling a terminal background can hold before the eye
   stops reading them as an order. This match is what enforces it: a fourth
   variant makes this file stop compiling, which is the whole reason [shade] is
   a closed sum rather than an int or a string. *)
let test_the_layers_are_closed () =
  let describe : Layout.shade -> string = function
    | Layout.Shade_none -> "prose"
    | Layout.Shade_quoted -> "quoted"
  in
  check string "prose" "prose" (describe Layout.Shade_none);
  check string "quoted" "quoted" (describe Layout.Shade_quoted)
;;

let () =
  run
    "tui shade layers"
    [ ( "belonging"
      , [ test_case "tool output is quoted" `Quick test_tool_output_is_quoted
        ; test_case
            "the keeper's own words are not"
            `Quick
            test_the_keepers_own_words_are_not_quoted
        ; test_case "metadata is never quoted" `Quick test_metadata_rows_are_never_quoted
        ; test_case "the layers are closed" `Quick test_the_layers_are_closed
        ] )
    ]
;;
