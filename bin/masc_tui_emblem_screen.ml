type drawn =
  | Moving
  | Still
  | Absent

let backdrop snapshot =
  match Masc_tui_terminal_palette.snapshot_palette snapshot with
  | Some palette -> Masc_tui_imp_emblem.Known palette
  | None -> (
      match Masc_tui_terminal_palette.snapshot_theme_mode snapshot with
      | Some mode -> Masc_tui_imp_emblem.Page mode
      | None -> Masc_tui_imp_emblem.Unknown)

let moves ~colors_enabled (backdrop : Masc_tui_imp_emblem.backdrop) =
  colors_enabled
  &&
  match backdrop with
  | Known _ | Page _ -> true
  | Unknown -> false

let pose ~moving ~elapsed =
  if not moving then Masc_tui_imp_emblem.settled
  else
    match
      Masc_tui_imp_emblem.turning
        (Float.max 0.0 elapsed /. Masc_tui_imp_emblem.loop_seconds)
    with
    | Some pose -> pose
    (* [turning] refuses only a phase that is not finite, and the only way to
       get one here is an elapsed time that is not: nothing to turn by, so
       the imp is held. *)
    | None -> Masc_tui_imp_emblem.settled

(* Stdlib.Lazy: forced only on the render path, which runs on the main loop's
   one fiber, and from tests that run without Eio. *)
let renderer = lazy (Masc_tui_imp_emblem.create ())

let centred ~cols line =
  let width = Masc_tui_message_layout.display_width line in
  if width >= cols then Masc_tui_message_layout.fit_width line cols
  else String.make ((cols - width) / 2) ' ' ^ line

(* The blank row between the imp and its caption. *)
let caption_gap_rows = 1

let rows ~cols ~rows ~caption ~elapsed ~colors_enabled ~backdrop =
  let caption_rows = List.length caption in
  let emblem_rows =
    match caption with
    | [] -> rows
    | _ :: _ -> rows - caption_rows - caption_gap_rows
  in
  let drawn, emblem =
    match Masc_tui_imp_emblem.fit ~cols ~rows:emblem_rows with
    | None -> (Absent, [])
    | Some size ->
        let moving = moves ~colors_enabled backdrop in
        let frame =
          Masc_tui_imp_emblem.frame (Lazy.force renderer) size
            (pose ~moving ~elapsed)
            (Masc_tui_imp_emblem.lighting backdrop)
        in
        ( (if moving then Moving else Still)
        , List.map (centred ~cols)
            (Masc_tui_imp_emblem.lines ~ink:Masc_tui_imp_emblem.stdout_ink frame) )
  in
  let block =
    match emblem, caption with
    | [], _ | _, [] -> emblem @ List.map (centred ~cols) caption
    | _ :: _, _ :: _ ->
        emblem
        @ List.init caption_gap_rows (fun _ -> "")
        @ List.map (centred ~cols) caption
  in
  let top = Int.max 0 ((rows - List.length block) / 2) in
  let body = List.init top (fun _ -> "") @ block in
  (drawn, List.filteri (fun index _ -> index < Int.max 0 rows) body)

type keeper_count =
  | Keepers_read of int
  | Keepers_unreadable
  | Keepers_unread

let about_facts ~theme keepers =
  let count =
    match keepers with
    | Keepers_read count -> string_of_int count
    | Keepers_unreadable -> "unavailable"
    | Keepers_unread -> "not loaded"
  in
  Printf.sprintf "Theme: %s  \xc2\xb7  Keepers: %s" theme count

let last_drawn = ref Absent
let begin_frame () = last_drawn := Absent
let drawn () = !last_drawn

let body ~cols ~rows:height ~caption ~elapsed =
  let drawn, lines =
    rows ~cols ~rows:height ~caption ~elapsed
      ~colors_enabled:Masc_tui_theme.colors_enabled
      ~backdrop:(backdrop (Masc_tui_terminal_palette.snapshot ()))
  in
  last_drawn := drawn;
  lines
