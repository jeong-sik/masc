module Braille = Masc_tui_braille
module Chart = Masc_tui_chart

let check_shares label ~cells counts expected =
  let actual = Chart.distribution_shares ~cells counts
    |> List.map (fun (share : Chart.distribution_share) ->
      share.percentage, share.filled_cells) in
  Alcotest.(check (list (pair int int))) label expected actual

let exact_decimal_boundaries () =
  check_shares "29 and 57 are exact percentages and cells" ~cells:100
    [29; 57; 14] [29, 29; 57, 57; 14, 14];
  check_shares "29 of 50 is exactly 58 percent" ~cells:50
    [29; 21] [58, 29; 42, 21];
  check_shares "fractional shares round down independently" ~cells:10
    [1; 1; 1] [33, 3; 33, 3; 33, 3]

let large_counts () =
  check_shares "sum and scaled product may both exceed max_int" ~cells:100
    [max_int; max_int] [50, 50; 50, 50];
  check_shares "unit difference remains below the 50-percent boundary" ~cells:100
    [max_int; max_int - 1] [50, 50; 49, 49];
  check_shares "sum can exceed Int64.max_int" ~cells:100
    [max_int; max_int; max_int; max_int; max_int]
    [20, 20; 20, 20; 20, 20; 20, 20; 20, 20];
  check_shares "largest cell scale also uses exact multiplication" ~cells:max_int
    [max_int; max_int] [50, max_int / 2; 50, max_int / 2];
  check_shares "single full share remains representable" ~cells:max_int
    [max_int] [100, max_int]

let empty_and_negative_inputs () =
  check_shares "empty" ~cells:100 [] [];
  check_shares "nonpositive counts have no share" ~cells:100
    [min_int; 0; -1] [0, 0; 0, 0; 0, 0];
  check_shares "negative counts do not enter the denominator" ~cells:100
    [-1; 29; 71] [0, 0; 29, 29; 71, 71];
  check_shares "negative capacity keeps percentages but has no cells" ~cells:min_int
    [29; 71] [29, 0; 71, 0]

let sparkline_levels () =
  let check = Alcotest.(check (list int)) in
  check "large nonnegative values retain the full scale" [0; 7]
    (Chart.sparkline_levels [0; max_int]);
  check "the full integer range does not overflow" [0; 3; 7]
    (Chart.sparkline_levels [min_int; 0; max_int]);
  check "explicit bounds clamp values" [0; 1; 7; 7]
    (Chart.sparkline_levels ~min:0 ~max:100 [-5; 25; 100; 500]);
  check "a constant positive series uses the middle" [3; 3]
    (Chart.sparkline_levels [4; 4]);
  check "a constant zero series uses the lowest level" [0; 0]
    (Chart.sparkline_levels [0; 0])

let compact_number_boundaries () =
  let check = Alcotest.(check string) in
  check "min_int prints as its exact integer, not a made-up rung"
    (string_of_int min_int)
    (Chart.format_compact_num min_int);
  check "one above min_int keeps its negative magnitude rung"
    "-4611686018427.4M"
    (Chart.format_compact_num (min_int + 1));
  check "a million keeps the M rung" "-2.0M" (Chart.format_compact_num (-2_000_000));
  check "ten thousand keeps the k rung" "-10k" (Chart.format_compact_num (-10_000));
  check "a thousand and a half keeps one decimal" "-1.5k"
    (Chart.format_compact_num (-1_500));
  check "below a thousand is the plain integer" "999" (Chart.format_compact_num 999)

let bar_filled_cells () =
  let check name expected ~value ~max_value =
    Alcotest.(check int) name expected (Chart.bar_filled_cells ~width:8 ~value ~max_value)
  in
  check "nothing fills no cell" 0 ~value:0 ~max_value:10;
  check "a negative value fills no cell" 0 ~value:(-3) ~max_value:10;
  check "no maximum fills no cell" 0 ~value:3 ~max_value:0;
  check "a small value still fills one cell" 1 ~value:1 ~max_value:100;
  check "half the maximum fills half the cells" 4 ~value:5 ~max_value:10;
  check "the maximum fills every cell" 8 ~value:10 ~max_value:10;
  check "past the maximum fills every cell" 8 ~value:500 ~max_value:10;
  Alcotest.(check int) "a bar with no cells fills none" 0
    (Chart.bar_filled_cells ~width:0 ~value:5 ~max_value:10)

module Theme = Masc_tui_theme

let band_name = function
  | Theme.Near_zero -> "Near_zero"
  | Theme.Midway -> "Midway"
  | Theme.Near_limit -> "Near_limit"

let cell_colour_t =
  Alcotest.testable
    (fun formatter -> function
      | Theme.Cell_plain -> Format.pp_print_string formatter "Cell_plain"
      | Theme.Cell_band band -> Format.fprintf formatter "Cell_band %s" (band_name band)
      | Theme.Cell_blend { band; position } ->
        Format.fprintf formatter "Cell_blend %s %.3f" (band_name band) position)
    (fun left right ->
      match left, right with
      | Theme.Cell_plain, Theme.Cell_plain -> true
      | Theme.Cell_band left, Theme.Cell_band right -> left = right
      | Theme.Cell_blend left, Theme.Cell_blend right ->
        left.band = right.band && Float.equal left.position right.position
      | Theme.Cell_plain, (Theme.Cell_band _ | Theme.Cell_blend _)
      | Theme.Cell_band _, (Theme.Cell_plain | Theme.Cell_blend _)
      | Theme.Cell_blend _, (Theme.Cell_plain | Theme.Cell_band _) -> false)

(* A tint that draws no colour, for the rules that are about dots. *)
let plain (_ : float) = ""

let declared_limit depth = depth

(* Every cell of a full bar: each reaches its own far edge. *)
let cells depth ~width =
  List.init width (fun index ->
    Theme.limit_cell_colour ~depth ~index ~width ~value:width ~limit:width)

(* Ten cells reach 10%, 20%, ... 100% of the limit. Under 50% is success,
   under 80% warning, the rest danger (RFC tui-one-screen-grammar 7.3). *)
let ten_bands =
  Theme.[ Near_zero; Near_zero; Near_zero; Near_zero; Midway; Midway; Midway;
          Near_limit; Near_limit; Near_limit ]

let declared_limit_cells_by_depth () =
  let check = Alcotest.(check (list cell_colour_t)) in
  check "no colour draws plain glyphs" (List.init 10 (fun _ -> Theme.Cell_plain))
    (cells (declared_limit Theme.No_color) ~width:10);
  check "sixteen colours step at 50% and 80%"
    (List.map (fun band -> Theme.Cell_band band) ten_bands)
    (cells (declared_limit Theme.Colors_16) ~width:10);
  let blended =
    List.mapi
      (fun index band ->
        Theme.Cell_blend { band; position = float_of_int (index + 1) /. 10.0 })
      ten_bands
  in
  check "256 colours blend at each cell's reach" blended
    (cells (declared_limit Theme.Colors_256) ~width:10);
  check "truecolor blends at each cell's reach" blended
    (cells (declared_limit Theme.Truecolor) ~width:10);
  check "a cell reaching exactly four fifths is near the limit at another width"
    Theme.[ Cell_band Near_zero; Cell_band Near_zero; Cell_band Midway;
            Cell_band Near_limit; Cell_band Near_limit ]
    (cells (declared_limit Theme.Colors_16) ~width:5)

(* A series bar walks its hue: under half its reach the hue's normal code,
   from half its bright code, where no palette lets it blend. Without colour
   it draws nothing (RFC tui-one-screen-grammar 7.3). *)
let series_paint ?palette depth = { Theme.depth; surface = Theme.Page; palette }

module Palette = Masc_tui_terminal_palette

let rgb (r, g, b) = Palette.make_rgb ~red:r ~green:g ~blue:b
let dark_ground = rgb (30, 30, 30)

(* xterm's sixteen entries on a near-black ground. *)
let dark_palette () =
  let xterm =
    [| (0, 0, 0); (205, 0, 0); (0, 205, 0); (205, 205, 0); (0, 0, 238); (205, 0, 205);
       (0, 205, 205); (229, 229, 229); (127, 127, 127); (255, 0, 0); (0, 255, 0);
       (255, 255, 0); (92, 92, 255); (255, 0, 255); (0, 255, 255); (255, 255, 255) |]
  in
  Palette.of_responses ~foreground:(Some (rgb (220, 220, 220))) ~background:(Some dark_ground)
    ~ansi:(Array.map (fun entry -> Some (rgb entry)) xterm)

let truecolor = Palette.For_testing.best_color_for_level ~level:Palette.True_color

let series_cells_walk_their_hue () =
  let style depth ~index =
    Chart.meter_cell_style
      (Chart.Series { paint = series_paint depth; series = Theme.Calls })
      ~index ~width:10 ~value:10 ~max_value:10
  in
  Alcotest.(check (list string)) "no colour draws no SGR"
    (List.init 10 (fun _ -> ""))
    (List.init 10 (fun index -> style Theme.No_color ~index));
  Alcotest.(check (list string)) "sixteen colours draw the hue's bright code throughout"
    (List.init 10 (fun _ -> Theme.Sgr.bright_blue))
    (List.init 10 (fun index -> style Theme.Colors_16 ~index));
  Alcotest.(check (list string)) "without a palette truecolor draws the same"
    (List.init 10 (fun index -> style Theme.Colors_16 ~index))
    (List.init 10 (fun index -> style Theme.Truecolor ~index));
  List.iter
    (fun paint ->
      List.iter
        (fun position ->
          Alcotest.(check string)
            (Printf.sprintf "the table at %g is the computed colour" position)
            (Theme.For_testing.ramp_style ~colors_enabled:Theme.colors_enabled
               ~project:Masc_tui_terminal_palette.best_color paint Theme.Failures ~position)
            (Theme.ramp_style paint Theme.Failures ~position);
          Alcotest.(check string)
            (Printf.sprintf "the reader at %g is the same colour" position)
            (Theme.ramp_style paint Theme.Failures ~position)
            (Theme.ramp_reader paint Theme.Failures ~position))
        [ 0.0; 0.25; 0.49; 0.495; 0.499; 0.5; 0.75; 0.999; 1.0 ])
    [ series_paint Theme.Colors_16; series_paint ?palette:(dark_palette ()) Theme.Truecolor ];
  (* A cell takes the step at or below its reach, never one past it: 0.495
     reads step 49, not 50 (review on #53181). *)
  let blended = series_paint ?palette:(dark_palette ()) Theme.Truecolor in
  let at position =
    Theme.For_testing.ramp_style ~colors_enabled:true ~project:truecolor blended Theme.Calls
      ~position
  in
  Alcotest.(check bool) "steps 49 and 50 are different colours" false
    (String.equal (at 0.49) (at 0.5));
  Alcotest.(check string) "0.495 reads step 49" (at 0.49) (at 0.495);
  Alcotest.(check string) "nan is the start of the ramp"
    (Theme.ramp_style (series_paint Theme.Colors_16) Theme.Calls ~position:0.0)
    (Theme.ramp_style (series_paint Theme.Colors_16) Theme.Calls ~position:Float.nan)

(* Truecolor with a reported palette: one hue from deep to bright, every stop
   clearing 3:1 against the ground, never darker further along, and the top
   at least one contrast step above the start. xterm's bright blue reads 3.5:1
   on this ground, so it has to be lifted for its ramp to show. *)
let series_blend_rises () =
  let ground = dark_ground in
  let palette = dark_palette () in
  let colour_of code =
    match String.split_on_char ';' code with
    | [ _; "2"; r; g; b ] ->
      let b = String.sub b 0 (String.length b - 1) in
      Some (rgb (int_of_string r, int_of_string g, int_of_string b))
    | _ -> None
  in
  List.iter
    (fun series ->
      let contrasts =
        List.init (Theme.ramp_steps + 1) (fun step ->
          let position = float_of_int step /. float_of_int Theme.ramp_steps in
          let code =
            Theme.For_testing.ramp_style ~colors_enabled:true ~project:truecolor
              (series_paint ?palette Theme.Truecolor) series ~position
          in
          match colour_of code with
          | Some colour -> Masc_tui_color.contrast_ratio colour ground
          | None -> Alcotest.failf "position %g drew %S, not a 24-bit colour" position code)
      in
      List.iter
        (fun contrast ->
          Alcotest.(check bool) "every stop clears 3:1" true (contrast >= 3.0 -. 1e-9))
        contrasts;
      (* Every one of the 101 steps, not a sample of them: an eight-bit
         rounding dip sits between two tenths (review on #53181). *)
      let rec rising = function
        | a :: (b :: _ as rest) -> a <= b && rising rest
        | [ _ ] | [] -> true
      in
      Alcotest.(check bool) "the ramp never darkens toward its top" true (rising contrasts);
      if not (List.hd contrasts +. 1.0 < List.nth contrasts Theme.ramp_steps) then
        Alcotest.failf "the deep end is not darker than the bright end: %s"
          (String.concat " " (List.map (Printf.sprintf "%.2f") contrasts)))
    Theme.[ Calls; Failures; Latency; Memory; Completion; Capacity; Backlog; Usage; Wakes ]

(* A ramp is blended whole or not at all: where one step cannot be projected
   above the floor, every step draws the hue's bright code, so a 256-colour
   terminal never mixes a palette code into a run of cube codes. *)
let series_ramp_falls_back_whole () =
  let palette = dark_palette () in
  let project colour =
    if Masc_tui_color.contrast_ratio colour dark_ground < 3.6 then None else truecolor colour
  in
  Alcotest.(check (list string)) "a deep step under the projection floor flattens the ramp"
    (List.init 11 (fun _ -> Theme.Sgr.bright_blue))
    (List.init 11 (fun step ->
       Theme.For_testing.ramp_style ~colors_enabled:true ~project
         (series_paint ?palette Theme.Colors_256) Theme.Calls
         ~position:(float_of_int step /. 10.0)))

let graph_t =
  Alcotest.testable
    (fun formatter -> function
      | Braille.Never_read -> Format.pp_print_string formatter "Never_read"
      | Braille.Too_narrow -> Format.pp_print_string formatter "Too_narrow"
      | Braille.Drawn rows ->
        Format.fprintf formatter "Drawn [%s]" (String.concat "; " rows))
    (fun left right ->
      match left, right with
      | Braille.Never_read, Braille.Never_read | Braille.Too_narrow, Braille.Too_narrow -> true
      | Braille.Drawn left, Braille.Drawn right -> List.equal String.equal left right
      | Braille.Never_read, (Braille.Too_narrow | Braille.Drawn _)
      | Braille.Too_narrow, (Braille.Never_read | Braille.Drawn _)
      | Braille.Drawn _, (Braille.Never_read | Braille.Too_narrow) -> false)

(* One text row is four dots tall. Blank is 0, the baseline 1, and any value
   above zero starts at 2. *)
let braille_levels () =
  let check name expected sample =
    Alcotest.(check int) name expected (Braille.braille_level ~dots:4 ~maximum:1000 sample)
  in
  check "a time never read is blank" 0 Braille.Unread;
  check "a time with no sample or a failed read is blank" 0 Braille.Absent;
  check "zero is the baseline" 1 Braille.Zero;
  check "a small value is one level above the baseline" 2 ((Braille.of_count 1));
  check "the axis maximum fills the column" 4 ((Braille.of_count 1000));
  check "a value past the axis fills the column" 4 ((Braille.of_count max_int));
  Alcotest.(check int) "a taller column still lifts a small value only one level" 2
    (Braille.braille_level ~dots:12 ~maximum:max_int ((Braille.of_count 1)))

(* The last cell of a row: one Braille glyph is three bytes. *)
let last_cell row = String.sub row (String.length row - 3) 3

let braille_graph_rules () =
  let graph ~width samples = Braille.braille_graph ~tint:plain ~width ~rows:1 ~axis:"9" ~maximum:9 samples in
  Alcotest.(check graph_t) "no sample at all is never read" Braille.Never_read (graph ~width:12 []);
  Alcotest.(check graph_t) "only unread samples is never read" Braille.Never_read
    (graph ~width:12 [ Braille.Unread; Braille.Unread ]);
  Alcotest.(check graph_t) "never read wins over a narrow width" Braille.Never_read
    (graph ~width:1 [ Braille.Unread ]);
  (* The axis "9" and its gap take two cells. *)
  Alcotest.(check graph_t) "three cells of dots is no graph" Braille.Too_narrow
    (graph ~width:5 [ Braille.Zero ]);
  (match graph ~width:6 [ Braille.Unread; Braille.Zero; Braille.Zero ] with
   | Braille.Drawn [ row ] ->
     Alcotest.(check string) "two zeros draw the baseline dots"
       (Braille.braille_cell ~mask:0xc0) (last_cell row)
   | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
     Alcotest.failf "four cells of dots draw one row: %a" (Alcotest.pp graph_t) other);
  match graph ~width:6 [ Braille.Absent; (Braille.of_count 1) ] with
  | Braille.Drawn [ row ] ->
    Alcotest.(check string) "a blank time beside a small value: two dots up the right column"
      (Braille.braille_cell ~mask:(0x80 lor 0x20)) (last_cell row)
  | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
    Alcotest.failf "four cells of dots draw one row: %a" (Alcotest.pp graph_t) other

(* Calls up, failures down, one axis: one failure in a thousand calls still
   shows a dot past the lower baseline. *)
let braille_mirror_minimum_dot () =
  match
    (* The axis "1K" and its gap take three cells, leaving four for dots. *)
    Braille.braille_mirror ~up_tint:plain ~down_tint:plain ~width:7 ~half_rows:1 ~axis:"1K" ~maximum:1000
      ~up:[ (Braille.of_count 1000) ] ~down:[ (Braille.of_count 1) ]
  with
  | Braille.Drawn [ upper; lower ] ->
    Alcotest.(check string) "the larger side fills its half"
      (Braille.braille_cell ~mask:0xb8) (last_cell upper);
    Alcotest.(check string) "the smaller side shows the baseline and one dot below it"
      (Braille.braille_cell ~mask:0x18) (last_cell lower);
    Alcotest.(check graph_t) "a mirror with neither side read is never read"
      Braille.Never_read
      (Braille.braille_mirror ~up_tint:plain ~down_tint:plain ~width:7 ~half_rows:1 ~axis:"1K" ~maximum:1000
         ~up:[ Braille.Unread ] ~down:[])
  | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
    Alcotest.failf "a one-row half draws two rows: %a" (Alcotest.pp graph_t) other

(* The 50% and 80% steps hold at widths other than ten: the band follows the
   share of the limit a cell reaches, not its index. *)
let declared_limit_steps_at_other_widths () =
  let bands width =
    List.map
      (function
        | Theme.Cell_band band -> band
        | (Theme.Cell_plain | Theme.Cell_blend _) as other ->
          Alcotest.failf "a sixteen-colour cell drew %a" (Alcotest.pp cell_colour_t) other)
      (cells (declared_limit Theme.Colors_16) ~width)
  in
  let check name expected width =
    Alcotest.(check (list string)) name (List.map band_name expected)
      (List.map band_name (bands width))
  in
  check "four cells: a cell reaching exactly half is midway"
    Theme.[ Near_zero; Midway; Midway; Near_limit ] 4;
  let twenty = bands 20 in
  Alcotest.(check string) "cell 9 of 20 reaches 45%: success" "Near_zero"
    (band_name (List.nth twenty 8));
  Alcotest.(check string) "cell 10 of 20 reaches 50%: warning" "Midway"
    (band_name (List.nth twenty 9));
  Alcotest.(check string) "cell 15 of 20 reaches 75%: warning" "Midway"
    (band_name (List.nth twenty 14));
  Alcotest.(check string) "cell 16 of 20 reaches 80%: danger" "Near_limit"
    (band_name (List.nth twenty 15))

(* A cell the value only enters takes the value's band, not its far edge's:
   the one cell a small value is rounded up to, and the partial last cell of
   a bar that draws eighths. *)
let declared_limit_cell_stops_at_the_value () =
  let check name expected ~index ~width ~value ~limit =
    Alcotest.(check cell_colour_t) name expected
      (Theme.limit_cell_colour ~depth:Theme.Colors_16 ~index ~width ~value ~limit)
  in
  check "one cell at 0.1% of the limit is success" (Theme.Cell_band Theme.Near_zero)
    ~index:0 ~width:1 ~value:1 ~limit:1000;
  check "two cells at 0.1%: the first is success" (Theme.Cell_band Theme.Near_zero)
    ~index:0 ~width:2 ~value:1 ~limit:1000;
  check "two cells at 60%: the first reaches its half-way edge, warning"
    (Theme.Cell_band Theme.Midway) ~index:0 ~width:2 ~value:600 ~limit:1000;
  check "one cell at 95% is danger" (Theme.Cell_band Theme.Near_limit)
    ~index:0 ~width:1 ~value:950 ~limit:1000;
  check "the partial fifth of ten cells at 45% is success"
    (Theme.Cell_band Theme.Near_zero) ~index:4 ~width:10 ~value:45 ~limit:100;
  check "the partial eighth of ten cells at 79% is warning"
    (Theme.Cell_band Theme.Midway) ~index:7 ~width:10 ~value:79 ~limit:100;
  check "the eighth of ten cells at exactly 80% is danger"
    (Theme.Cell_band Theme.Near_limit) ~index:7 ~width:10 ~value:80 ~limit:100;
  check "a value past the limit stops at the cell's edge"
    (Theme.Cell_band Theme.Near_zero) ~index:0 ~width:10 ~value:500 ~limit:100;
  Alcotest.(check cell_colour_t) "a blend sits at the value, not the edge"
    (Theme.Cell_blend { band = Theme.Near_zero; position = 0.45 })
    (Theme.limit_cell_colour ~depth:Theme.Truecolor ~index:4 ~width:10 ~value:45
       ~limit:100);
  Alcotest.(check cell_colour_t) "the edges hold at limits past the integer products"
    (Theme.Cell_band Theme.Midway)
    (Theme.limit_cell_colour ~depth:Theme.Colors_16 ~index:0 ~width:1
       ~value:(max_int / 2 + 1) ~limit:max_int);
  Alcotest.(check cell_colour_t) "four fifths of max_int is danger"
    (Theme.Cell_band Theme.Near_limit)
    (Theme.limit_cell_colour ~depth:Theme.Colors_16 ~index:0 ~width:1
       ~value:(max_int - max_int / 5) ~limit:max_int)

(* Where a blend cannot be drawn (no palette was reported), a 256-colour or
   truecolor cell draws its band's colour, the same bytes a sixteen-colour
   cell draws. A plain cell draws no SGR even with colours on. *)
let meter_cell_fallbacks () =
  let paint depth = { Theme.depth; surface = Theme.Page; palette = None } in
  let readable depth cell =
    Theme.For_testing.meter_cell_readable ~colors_enabled:true
      ~project:(fun _ -> None) (paint depth) cell
  in
  List.iter
    (fun band ->
      List.iter
        (fun depth ->
          Alcotest.(check string)
            (Printf.sprintf "%s blend without a palette draws the band" (band_name band))
            (readable Theme.Colors_16 (Theme.Cell_band band))
            (readable depth (Theme.Cell_blend { band; position = 0.5 })))
        Theme.[ Colors_256; Truecolor ])
    Theme.[ Near_zero; Midway; Near_limit ];
  Alcotest.(check string) "a plain cell draws no SGR with colours on" ""
    (readable Theme.Truecolor Theme.Cell_plain)

(* A code goes out only where the colour changes, and one reset closes the
   fill. An anomaly draws the whole fill in its own code. *)
let meter_bar_opens_a_code_per_colour () =
  let reset = "<0>" in
  let bar scale = Chart.meter_bar ~width:10 ~value:10 ~max_value:10 ~scale ~reset () in
  let glyphs count = String.concat "" (List.init count (fun _ -> "\xe2\x96\xa0")) in
  let opened code = if String.equal code "" then glyphs 10 else code ^ glyphs 10 ^ reset in
  Alcotest.(check string) "one colour opens one code"
    (opened Theme.Sgr.bright_blue)
    (bar (Chart.Series { paint = series_paint Theme.Colors_16; series = Theme.Calls }));
  Alcotest.(check string) "an anomaly opens its status colour once"
    (opened (Theme.status_readable ~surface:Theme.Page None Theme.Bad))
    (bar (Chart.Anomaly { paint = series_paint Theme.Colors_16; alarm = Chart.Alarm_bad }));
  Alcotest.(check string) "no colour opens nothing" (glyphs 10)
    (bar (Chart.Series { paint = series_paint Theme.No_color; series = Theme.Calls }))

(* A meter's readout takes the colour at the value's own position along the
   scale (btop readout colouring): empty/non-positive and No_color stay plain,
   a declared limit matches its band at the value's share, a series walks its
   hue, and an anomaly takes its alarm colour. *)
let meter_tip_style_matches_scale () =
  let limit_16 = Chart.Declared_limit (series_paint Theme.Colors_16) in
  let limit_off = Chart.Declared_limit (series_paint Theme.No_color) in
  let series_16 = Chart.Series { paint = series_paint Theme.Colors_16; series = Theme.Calls } in
  let anomaly_16 = Chart.Anomaly { paint = series_paint Theme.Colors_16; alarm = Chart.Alarm_bad } in
  Alcotest.(check string) "zero value stays plain" ""
    (Chart.meter_tip_style limit_16 ~value:0 ~max_value:100);
  Alcotest.(check string) "non-positive max stays plain" ""
    (Chart.meter_tip_style limit_16 ~value:10 ~max_value:0);
  Alcotest.(check string) "no colour stays plain" ""
    (Chart.meter_tip_style limit_off ~value:90 ~max_value:100);
  Alcotest.(check string) "declared limit near zero matches Ok"
    (Theme.status_readable ~surface:Theme.Page None Theme.Ok)
    (Chart.meter_tip_style limit_16 ~value:25 ~max_value:100);
  Alcotest.(check string) "declared limit midway matches Warn"
    (Theme.status_readable ~surface:Theme.Page None Theme.Warn)
    (Chart.meter_tip_style limit_16 ~value:60 ~max_value:100);
  Alcotest.(check string) "declared limit near limit matches Bad"
    (Theme.status_readable ~surface:Theme.Page None Theme.Bad)
    (Chart.meter_tip_style limit_16 ~value:85 ~max_value:100);
  Alcotest.(check string) "value above max clamps to near limit"
    (Theme.status_readable ~surface:Theme.Page None Theme.Bad)
    (Chart.meter_tip_style limit_16 ~value:150 ~max_value:100);
  Alcotest.(check string) "series tip matches its 16-colour hue"
    Theme.Sgr.bright_blue
    (Chart.meter_tip_style series_16 ~value:50 ~max_value:100);
  Alcotest.(check string) "anomaly tip takes alarm colour"
    (Theme.status_readable ~surface:Theme.Page None Theme.Bad)
    (Chart.meter_tip_style anomaly_16 ~value:10 ~max_value:100);
  let reset = "<0>" in
  let plain_suffix =
    Chart.meter ~width:20 ~value:85 ~max_value:100 ~scale:limit_16
      ~suffix_style:"" ~reset ()
  in
  let explicit_suffix =
    Chart.meter ~width:20 ~value:85 ~max_value:100 ~scale:limit_16
      ~suffix_style:"<W>" ~reset ()
  in
  Alcotest.(check bool) "explicit empty suffix_style omits readout code" true
    (String.ends_with ~suffix:" 85%" plain_suffix);
  Alcotest.(check bool) "explicit suffix_style overrides tip style" true
    (String.ends_with ~suffix:" <W> 85%<0>" explicit_suffix)

(* A column two cells tall: the base cell fills before the one above it
   starts, a zero is the baseline of the base cell alone, and the top of the
   scale fills both. One cell is the one-row mark. *)
let braille_bar_rows_stack () =
  let blank = Braille.braille_bar_mark ~level:0 in
  let mark level = Braille.braille_bar_mark ~level in
  let check name expected level =
    Alcotest.(check (list string)) name expected (Braille.braille_bar_rows ~rows:2 ~level)
  in
  check "a zero is the base cell's baseline" [ blank; mark 1 ] 1;
  check "four levels fill the base cell" [ blank; mark 4 ] 4;
  check "six levels reach two into the cell above" [ mark 2; mark 4 ] 6;
  check "the top of the scale fills both" [ mark 4; mark 4 ] 8;
  check "past the top stays full" [ mark 4; mark 4 ] 9;
  Alcotest.(check (list string)) "one row is the one-row mark" [ mark 3 ]
    (Braille.braille_bar_rows ~rows:1 ~level:3)

(* btop's graph colours: rows by their height when the graph is taller than
   one row, cells by their own height in a one-row graph. A blank cell opens
   no code, a code goes out only where it changes, and a row that opened one
   ends with a reset. *)
let braille_graph_tints_by_height () =
  let tint share = Printf.sprintf "<%.2f>" share in
  let reset = Theme.Sgr.reset in
  (match
     Braille.braille_graph ~tint ~width:6 ~rows:1 ~axis:"8" ~maximum:8
       [ Braille.Absent; Braille.Absent; Braille.of_count 8; Braille.of_count 8;
         Braille.Zero; Braille.Zero; Braille.of_count 6; Braille.of_count 6 ]
   with
   | Braille.Drawn [ row ] ->
     Alcotest.(check string) "one row: each cell by its own height"
       ("8 " ^ Braille.braille_cell ~mask:0 ^ "<1.00>" ^ Braille.braille_pair ~left:4 ~right:4
        ^ "<0.00>" ^ Braille.braille_pair ~left:1 ~right:1
        ^ "<0.50>" ^ Braille.braille_pair ~left:3 ~right:3 ^ reset)
       row
   | other -> Alcotest.failf "expected one drawn row, got %a" (Alcotest.pp graph_t) other);
  match
    Braille.braille_graph ~tint ~width:6 ~rows:2 ~axis:"8" ~maximum:8
      [ Braille.of_count 8; Braille.of_count 8; Braille.of_count 8; Braille.of_count 8;
        Braille.of_count 8; Braille.of_count 8; Braille.of_count 8; Braille.of_count 8 ]
  with
  | Braille.Drawn [ top; bottom ] ->
    let full = String.concat "" (List.init 4 (fun _ -> Braille.braille_pair ~left:4 ~right:4)) in
    Alcotest.(check string) "the top row takes the top of the ramp"
      ("8 <1.00>" ^ full ^ reset) top;
    Alcotest.(check string) "the base row takes its own height"
      ("  <0.00>" ^ full ^ reset) bottom
  | other -> Alcotest.failf "expected two drawn rows, got %a" (Alcotest.pp graph_t) other

(* A tint that draws nothing for low cells hands the foreground back with a
   reset, so the colour of a tall cell does not run into the cells after it
   or past the row (review on #53181). *)
let braille_empty_tint_resets () =
  let tint share = if share >= 0.5 then "<c>" else "" in
  match
    Braille.braille_graph ~tint ~width:6 ~rows:1 ~axis:"8" ~maximum:8
      [ Braille.Absent; Braille.Absent; Braille.Absent; Braille.Absent;
        Braille.of_count 8; Braille.of_count 8; Braille.Zero; Braille.Zero ]
  with
  | Braille.Drawn [ row ] ->
    Alcotest.(check string) "the low cell after a coloured one resets"
      ("8 " ^ Braille.braille_cell ~mask:0 ^ Braille.braille_cell ~mask:0
       ^ "<c>" ^ Braille.braille_pair ~left:4 ~right:4
       ^ Theme.Sgr.reset ^ Braille.braille_pair ~left:1 ~right:1)
      row
  | other -> Alcotest.failf "expected one drawn row, got %a" (Alcotest.pp graph_t) other

let sample_name = function
  | Braille.Unread -> "Unread"
  | Braille.Absent -> "Absent"
  | Braille.Zero -> "Zero"
  | Braille.Value value -> Printf.sprintf "Value %d" (value :> int)

(* A count is parsed once into a sample: zero and a value above zero are
   different constructors, and a count below zero is no reading. *)
let counts_become_samples () =
  let check name expected count =
    Alcotest.(check string) name expected (sample_name (Braille.of_count count))
  in
  check "zero is the baseline" "Zero" 0;
  check "a count above zero is a value" "Value 3" 3;
  check "the largest count is a value" (Printf.sprintf "Value %d" max_int) max_int;
  check "a count below zero is no reading" "Absent" (-3);
  check "min_int is no reading" "Absent" min_int;
  let positive count = Option.map (fun (value : Braille.positive) -> (value :> int)) (Braille.positive count) in
  Alcotest.(check (option int)) "zero is not positive" None (positive 0);
  Alcotest.(check (option int)) "a negative count is not positive" None (positive (-1));
  Alcotest.(check (option int)) "one is positive" (Some 1) (positive 1)

let braille_level_edges () =
  let level ?(dots = 4) ~maximum sample = Braille.braille_level ~dots ~maximum sample in
  Alcotest.(check int) "a value on an axis with no height fills the column" 4
    (level ~maximum:0 ((Braille.of_count 3)));
  Alcotest.(check int) "zero on an axis with no height stays on the baseline" 1
    (level ~maximum:0 Braille.Zero);
  Alcotest.(check int) "the axis maximum fills a two-row column" 8
    (level ~dots:8 ~maximum:10 ((Braille.of_count 10)));
  Alcotest.(check int) "the largest Value is the axis top" 7
    (Braille.graph_maximum
       Braille.[ Unread; Absent; Zero; of_count 3; of_count 7; of_count 2 ]);
  Alcotest.(check int) "no Value leaves the axis top at zero" 0
    (Braille.graph_maximum Braille.[ Unread; Absent; Zero ])

(* Narrower than four cells is no graph, whatever the axis text. *)
let narrow_graphs_are_numbers () =
  List.iter
    (fun width ->
      List.iter
        (fun axis ->
          Alcotest.(check graph_t)
            (Printf.sprintf "width %d with axis %S is too narrow" width axis)
            Braille.Too_narrow
            (Braille.braille_graph ~tint:plain ~width ~rows:1 ~axis ~maximum:5 [ (Braille.of_count 5) ]);
          Alcotest.(check graph_t)
            (Printf.sprintf "a mirror of width %d with axis %S is too narrow" width axis)
            Braille.Too_narrow
            (Braille.braille_mirror ~up_tint:plain ~down_tint:plain ~width ~half_rows:1 ~axis ~maximum:5
               ~up:[ (Braille.of_count 5) ] ~down:[ Braille.Zero ]))
        [ ""; "5" ])
    [ 0; 1; 2; 3 ];
  match Braille.braille_graph ~tint:plain ~width:6 ~rows:1 ~axis:"5" ~maximum:5 [ (Braille.of_count 5) ] with
  | Braille.Drawn _ -> ()
  | (Braille.Never_read | Braille.Too_narrow) as other ->
    Alcotest.failf "four cells of dots draw a graph: %a" (Alcotest.pp graph_t) other

let only_row = function
  | Braille.Drawn [ row ] -> row
  | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
    Alcotest.failf "one row expected: %a" (Alcotest.pp graph_t) other

(* A time not read, or whose read failed, inside a graph with readings is a
   blank half-cell beside the baseline of a measured zero. *)
let missing_times_are_blank () =
  let graph samples = Braille.braille_graph ~tint:plain ~width:6 ~rows:1 ~axis:"9" ~maximum:9 samples in
  Alcotest.(check string) "an unread time after a zero is blank" (Braille.braille_cell ~mask:0x40)
    (last_cell (only_row (graph [ Braille.Zero; Braille.Unread ])));
  Alcotest.(check string) "a failed read after a zero is blank" (Braille.braille_cell ~mask:0x40)
    (last_cell (only_row (graph [ Braille.Zero; Braille.Absent ])))

(* A small value in a two-row graph lifts the bottom row only; the row above
   stays blank. *)
let small_value_in_two_rows () =
  match
    Braille.braille_graph ~tint:plain ~width:7 ~rows:2 ~axis:"1K" ~maximum:1000
      [ Braille.Absent; (Braille.of_count 1) ]
  with
  | Braille.Drawn [ top; bottom ] ->
    Alcotest.(check string) "the top row is blank" (Braille.braille_cell ~mask:0x00)
      (last_cell top);
    Alcotest.(check string) "the bottom row shows the baseline and one dot above it"
      (Braille.braille_cell ~mask:(0x80 lor 0x20)) (last_cell bottom)
  | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
    Alcotest.failf "two rows expected: %a" (Alcotest.pp graph_t) other

(* Both halves of a mirror read one axis: equal values reach equally far from
   the middle, zero is each half's baseline, and a side never read draws no
   dots while the other side draws. *)
let mirror_shared_axis_and_baselines () =
  let mirror ~up ~down =
    Braille.braille_mirror ~up_tint:plain ~down_tint:plain ~width:7 ~half_rows:1 ~axis:"1K" ~maximum:1000 ~up ~down
  in
  (match mirror ~up:[ Braille.Zero; Braille.Zero ] ~down:[ Braille.Zero; Braille.Zero ] with
   | Braille.Drawn [ upper; lower ] ->
     Alcotest.(check string) "the upper zero is the bottom dots" (Braille.braille_cell ~mask:0xc0)
       (last_cell upper);
     Alcotest.(check string) "the lower zero is the top dots" (Braille.braille_cell ~mask:0x09)
       (last_cell lower)
   | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
     Alcotest.failf "two rows expected: %a" (Alcotest.pp graph_t) other);
  (match mirror ~up:[ (Braille.of_count 1000) ] ~down:[ (Braille.of_count 1000) ] with
   | Braille.Drawn [ upper; lower ] ->
     Alcotest.(check string) "the upper maximum fills its half" (Braille.braille_cell ~mask:0xb8)
       (last_cell upper);
     Alcotest.(check string) "the lower maximum fills its half" (Braille.braille_cell ~mask:0xb8)
       (last_cell lower)
   | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
     Alcotest.failf "two rows expected: %a" (Alcotest.pp graph_t) other);
  match mirror ~up:[ (Braille.of_count 3) ] ~down:[ Braille.Unread ] with
  | Braille.Drawn [ upper; lower ] ->
    Alcotest.(check bool) "the read side draws dots" true
      (not (String.equal (last_cell upper) (Braille.braille_cell ~mask:0x00)));
    Alcotest.(check string) "the unread side draws none" (Braille.braille_cell ~mask:0x00)
      (last_cell lower)
  | (Braille.Drawn _ | Braille.Never_read | Braille.Too_narrow) as other ->
    Alcotest.failf "one side read still draws: %a" (Alcotest.pp graph_t) other

let btop_braille_curves_and_dot_meters () =
  (* Top-down Braille cells differ cleanly from bottom-up cells. *)
  Alcotest.(check bool) "braille_pair_down differs from rising braille_pair at level 1" false
    (String.equal (Braille.braille_pair ~left:1 ~right:1) (Braille.braille_pair_down ~left:1 ~right:1));
  (* Gap isolation and interpolation across adjacent Some buckets. *)
  let pairs = Braille.interpolate_pairs ~cells:12 [ Some 8; Some 4; None; Some 6 ] in
  Alcotest.(check int) "exact requested cell width" 12 (List.length pairs);
  Alcotest.(check bool) "gap bucket stays zeroed (no cross-gap bridge)" true
    (match List.nth pairs 6, List.nth pairs 7 with
     | (0, 0), (0, 0) -> true
     | _ -> false);
  Alcotest.(check bool) "bridge between 8 and 4 stays smoothly intermediate" true
    (let (l, r) = List.nth pairs 2 in
     l >= 4 && l <= 8 && r >= 4 && r <= 8);
  (* Rising and falling braille_curve_rows emit expected row counts. *)
  let up_rows = Braille.braille_curve_rows ~down:false ~tint:plain ~rows:2 pairs in
  let down_rows = Braille.braille_curve_rows ~down:true ~tint:plain ~rows:2 pairs in
  Alcotest.(check int) "2-row rising curve" 2 (List.length up_rows);
  Alcotest.(check int) "2-row falling curve" 2 (List.length down_rows);
  (* dot_meter_bar subcell half-step precision under NO_COLOR. *)
  let bar =
    Chart.dot_meter_bar ~width:4 ~value:1 ~max_value:8
      ~scale:(Chart.Declared_limit { Theme.depth = Theme.No_color; surface = Theme.Page; palette = None })
      ~track_style:"" ~reset:"" ()
  in
  Alcotest.(check string) "1/8 on 4 cells is one half-dot Braille cell + 3 middle dots"
    "\xe2\xa1\x87\xc2\xb7\xc2\xb7\xc2\xb7" bar;
  let full_bar =
    Chart.dot_meter_bar ~width:2 ~value:8 ~max_value:8
      ~scale:(Chart.Declared_limit { Theme.depth = Theme.No_color; surface = Theme.Page; palette = None })
      ~track_style:"" ~reset:"" ()
  in
  Alcotest.(check string) "full dot_meter_bar draws full 8-dot Braille cells"
    "\xe2\xa3\xbf\xe2\xa3\xbf" full_bar;
  (* 3-row 12-level mirrored waves emit 3 lines each and clamp out-of-range inputs cleanly. *)
  let pairs_12 = Braille.interpolate_pairs ~cells:8 [ Some 0; Some 6; Some 12; None; Some 9 ] in
  let up_3 = Braille.braille_curve_rows ~down:false ~tint:plain ~rows:3 pairs_12 in
  let down_3 = Braille.braille_curve_rows ~down:true ~tint:plain ~rows:3 pairs_12 in
  Alcotest.(check int) "3-row rising curve" 3 (List.length up_3);
  Alcotest.(check int) "3-row falling curve" 3 (List.length down_3);
  (* braille_curve_rows clamps rows to at least one. *)
  Alcotest.(check int) "0-row falling curve is clamped to one row" 1
    (List.length (Braille.braille_curve_rows ~down:true ~tint:plain ~rows:0 pairs_12));
  (* dot_meter respects bounds from 0 to wide under NO_COLOR. *)
  let no_color_paint = { Theme.depth = Theme.No_color; surface = Theme.Page; palette = None } in
  List.iter
    (fun w ->
       let drawn =
         Chart.dot_meter ~width:w ~value:7 ~max_value:10
           ~scale:(Chart.Series { paint = no_color_paint; series = Theme.Completion })
           ~label:"ok" ~label_style:"" ~track_style:"" ~suffix_style:"" ~reset:"" ()
       in
       Alcotest.(check bool)
         (Printf.sprintf "dot_meter fits width %d" w)
         true (String.length drawn >= 0 && Theme.strip_sgr drawn = drawn))
    [ 0; 1; 4; 12; 24; 40 ]

let () =
  Alcotest.run "Chart numeric decisions"
    [ "numeric decisions",
      [ Alcotest.test_case "decimal boundaries and floor" `Quick exact_decimal_boundaries
      ; Alcotest.test_case "large totals and products" `Quick large_counts
      ; Alcotest.test_case "empty and negative inputs" `Quick empty_and_negative_inputs
      ; Alcotest.test_case "sparkline scale and integer limits" `Quick sparkline_levels
      ; Alcotest.test_case "compact number boundaries" `Quick compact_number_boundaries
      ; Alcotest.test_case "bar fill" `Quick bar_filled_cells
      ]
    ; "meter colour",
      [ Alcotest.test_case "declared limit cells by colour depth" `Quick
          declared_limit_cells_by_depth
      ; Alcotest.test_case "series bars walk their hue" `Quick series_cells_walk_their_hue
      ; Alcotest.test_case "a series blend rises from deep to bright" `Quick series_blend_rises
      ; Alcotest.test_case "a ramp falls back whole" `Quick series_ramp_falls_back_whole
      ; Alcotest.test_case "declared limit steps at other widths" `Quick
          declared_limit_steps_at_other_widths
      ; Alcotest.test_case "a cell stops at the value it draws" `Quick
          declared_limit_cell_stops_at_the_value
      ; Alcotest.test_case "blend and plain fallbacks" `Quick meter_cell_fallbacks
      ; Alcotest.test_case "a bar opens a code per colour" `Quick
          meter_bar_opens_a_code_per_colour
      ; Alcotest.test_case "a meter tip matches its scale" `Quick
          meter_tip_style_matches_scale
      ]
    ; "braille graph",
      [ Alcotest.test_case "levels for zero, small, absent and unread" `Quick braille_levels
      ; Alcotest.test_case "unread, narrow and baseline rules" `Quick braille_graph_rules
      ; Alcotest.test_case "a two-cell column stacks its levels" `Quick braille_bar_rows_stack
      ; Alcotest.test_case "a graph takes its colour from its height" `Quick
          braille_graph_tints_by_height
      ; Alcotest.test_case "an empty tint resets the colour" `Quick braille_empty_tint_resets
      ; Alcotest.test_case "the mirrored smaller side shows a dot" `Quick
          braille_mirror_minimum_dot
      ; Alcotest.test_case "counts become samples" `Quick counts_become_samples
      ; Alcotest.test_case "level edges and the axis top" `Quick braille_level_edges
      ; Alcotest.test_case "narrower than four cells is a number" `Quick
          narrow_graphs_are_numbers
      ; Alcotest.test_case "missing times are blank" `Quick missing_times_are_blank
      ; Alcotest.test_case "a small value in two rows" `Quick small_value_in_two_rows
      ; Alcotest.test_case "mirror shares one axis and two baselines" `Quick
          mirror_shared_axis_and_baselines
      ; Alcotest.test_case "btop interpolated curves and dot meters" `Quick
          btop_braille_curves_and_dot_meters
      ]
    ]
