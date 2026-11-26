open Masc_tui_core
open Masc_tui_term

let string_contains ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec scan i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else scan (i + 1)
    in
    scan 0

(* ---- (a) Wide CJK overwrite safety, control stripping, and Glyph widths ---- *)
let test_wide_cjk_overwrite () =
  let grid = Cell_grid.create ~cols:8 ~rows:2 in
  let st = Style.default in
  (* Draw right border at col 7 *)
  Cell_grid.put_glyph grid ~x:7 ~y:0 ~style:st Glyph.Box_v;
  (* Draw 3 Korean wide chars across cols 0..5 ("가나다") *)
  let advanced = Cell_grid.put_text grid ~x:0 ~y:0 ~style:st "가나다" in
  Alcotest.(check int) "korean advanced 6 cols" 6 advanced;
  Alcotest.(check bool) "col 0 is 가" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:0 ~y:0).glyph (Cell_grid.Utf8 "가"));
  Alcotest.(check bool) "col 1 is Continuation" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:1 ~y:0).glyph Cell_grid.Continuation);
  Alcotest.(check int) "col 0 width 2" 2 (Cell_grid.get grid ~x:0 ~y:0).width;
  Alcotest.(check int) "col 1 width 0" 0 (Cell_grid.get grid ~x:1 ~y:0).width;

  (* Overwrite lead half at col 2 ('나') with ASCII 'X': col 3 must blank! *)
  Cell_grid.put_ascii grid ~x:2 ~y:0 ~style:st 'X';
  Alcotest.(check bool) "col 2 is X" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:2 ~y:0).glyph (Cell_grid.Ascii 'X'));
  Alcotest.(check bool) "col 3 cleaned to Empty" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:3 ~y:0).glyph Cell_grid.Empty);
  Alcotest.(check int) "col 3 width restored to 1" 1 (Cell_grid.get grid ~x:3 ~y:0).width;

  (* Overwrite continuation half at col 1 (second half of '가') with ASCII 'Y': col 0 must blank! *)
  Cell_grid.put_ascii grid ~x:1 ~y:0 ~style:st 'Y';
  Alcotest.(check bool) "col 0 cleaned to Empty" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:0 ~y:0).glyph Cell_grid.Empty);
  Alcotest.(check bool) "col 1 is Y" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:1 ~y:0).glyph (Cell_grid.Ascii 'Y'));

  (* Overwrite spanning boundary: place '가나' at cols 0..3, then place '다' at col 1..2 -> cols 0 and 3 both blank *)
  Cell_grid.clear grid;
  Cell_grid.put_glyph grid ~x:7 ~y:0 ~style:st Glyph.Box_v;
  ignore (Cell_grid.put_text grid ~x:0 ~y:0 ~style:st "가나" : int);
  ignore (Cell_grid.put_text grid ~x:1 ~y:0 ~style:st "다" : int);
  Alcotest.(check bool) "left orphan col 0 blanked" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:0 ~y:0).glyph Cell_grid.Empty);
  Alcotest.(check bool) "col 1 is 다" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:1 ~y:0).glyph (Cell_grid.Utf8 "다"));
  Alcotest.(check bool) "col 2 is Continuation" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:2 ~y:0).glyph Cell_grid.Continuation);
  Alcotest.(check bool) "right orphan col 3 blanked" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:3 ~y:0).glyph Cell_grid.Empty);

  (* Wide glyph at rightmost clip column must clip to 1-cell ellipsis without breaking border at col 7
     AND report exact 1-column advance (never overshooting clip_right). *)
  let clip = Rect.make ~x:0 ~y:0 ~w:7 ~h:1 in
  let adv_right = Cell_grid.put_text ~clip grid ~x:6 ~y:0 ~style:st "한" in
  Alcotest.(check int) "right-clipped wide advance = 1" 1 adv_right;
  Alcotest.(check bool) "col 6 clipped to ellipsis" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:6 ~y:0).glyph (Cell_grid.Utf8 "…"));
  Alcotest.(check bool) "right border at col 7 intact" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:7 ~y:0).glyph (Cell_grid.Utf8 "│"));

  (* Wide glyph straddling left clip boundary (cx = clip.x - 1) must blank clip.x
     and clean any pre-existing Continuation at clip.x, leaving zero stale cells. *)
  Cell_grid.clear grid;
  ignore (Cell_grid.put_text grid ~x:0 ~y:0 ~style:st "가나" : int);
  let left_clip = Rect.make ~x:1 ~y:0 ~w:5 ~h:1 in
  let adv_left = Cell_grid.put_text ~clip:left_clip grid ~x:0 ~y:0 ~style:st "한A" in
  Alcotest.(check int) "left-straddle advance" 3 adv_left;
  Alcotest.(check bool) "col 0 (left of clip) cleaned from orphaned wide lead" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:0 ~y:0).glyph Cell_grid.Empty);
  Alcotest.(check bool) "col 1 (clip.x) blanked cleanly" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:1 ~y:0).glyph Cell_grid.Empty);
  Alcotest.(check bool) "col 2 receives A" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:2 ~y:0).glyph (Cell_grid.Ascii 'A'));
  Alcotest.(check bool) "col 3 orphaned Continuation of 나 cleaned" true
    (Cell_grid.glyph_equal (Cell_grid.get grid ~x:3 ~y:0).glyph Cell_grid.Empty)

let test_grapheme_sanitize_and_glyphs () =
  (* Terminal escape & bidi override stripping *)
  Alcotest.(check string) "strip ANSI CSI" "hello"
    (Grapheme.sanitize_controls "\x1b[31mhel\x1b[0mlo\x07");
  Alcotest.(check string) "strip RLO bidi control" "safe"
    (Grapheme.sanitize_controls "sa\xe2\x80\xaefe");
  (* iter_clusters & segment offsets always index the sanitized string *)
  let collected = ref [] in
  Grapheme.iter_clusters "\x1b[31m한\x1b[0mA"
    (fun ~text ~start_offset ~end_offset ~cell_width ->
      collected :=
        (String.sub text start_offset (end_offset - start_offset), cell_width)
        :: !collected);
  Alcotest.(check (list (pair string int))) "iter_clusters slices sanitized text"
    [ ("한", 2); ("A", 1) ] (List.rev !collected);
  let seg_text, seg_spans = Grapheme.segment "\x1b[31m한\x1b[0mA" in
  Alcotest.(check string) "segment sanitized text" "한A" seg_text;
  Alcotest.(check (list (pair string int))) "segment spans match sanitized text"
    [ ("한", 2); ("A", 1) ]
    (List.map
       (fun (c : Grapheme.cluster) ->
         (String.sub seg_text c.start_offset (c.end_offset - c.start_offset), c.cell_width))
       seg_spans);
  Alcotest.(check int) "korean display width" 6 (Grapheme.display_width "한국어");
  Alcotest.(check string) "truncate korean" "한…"
    (Grapheme.truncate_to_width ~max_width:3 "한국어");
  (* Every closed Glyph.t must be strictly width 1 *)
  Alcotest.(check string) "Left_rail UTF-8" "▎" (Glyph.to_utf8 Glyph.Left_rail);
  Alcotest.(check string) "Ai_spark UTF-8" "✦" (Glyph.to_utf8 Glyph.Ai_spark);
  Alcotest.(check string) "Flow_down UTF-8" "↓" (Glyph.to_utf8 Glyph.Flow_down);
  Alcotest.(check bool) "Left_rail in Glyph.all" true
    (List.exists (fun g -> String.equal (Glyph.to_utf8 g) "▎") Glyph.all);
  List.iter
    (fun g ->
      let u = Glyph.to_utf8 g in
      let a = Glyph.to_ascii_fallback g in
      Alcotest.(check int) ("utf8 glyph width 1: " ^ u) 1 (Grapheme.display_width u);
      Alcotest.(check int) ("ascii glyph width 1: " ^ a) 1 (Grapheme.display_width a))
    Glyph.all

(* ---- (b) 256-entry Braille LUT UTF-8 validity ---- *)
let test_braille_lut () =
  Alcotest.(check int) "256 entries" 256 (Array.length Cell_grid.braille_lut);
  for mask = 0 to 255 do
    let s = Cell_grid.braille_lut.(mask) in
    Alcotest.(check bool) "valid utf8" true (String.is_valid_utf_8 s);
    Alcotest.(check int) "3 bytes" 3 (String.length s);
    let dec = String.get_utf_8_uchar s 0 in
    Alcotest.(check bool) "scalar valid" true (Uchar.utf_decode_is_valid dec);
    Alcotest.(check int) "exact codepoint U+2800+mask" (0x2800 + mask)
      (Uchar.to_int (Uchar.utf_decode_uchar dec));
    Alcotest.(check int) "display width 1" 1 (Grapheme.display_width s);
    Alcotest.(check bool) "braille_utf8 masks zero-alloc" true
      (Cell_grid.braille_utf8 (mask + 256) == s)
  done

(* ---- (c) Presenter differential CSI 2026 emission & zero-dirty 2nd frame ---- *)
let test_presenter_diff_and_csi2026 () =
  let presenter =
    Presenter.create ~cols:20 ~rows:4 ~capabilities:Presenter.default_capabilities
  in
  let style_hi =
    Style.make ~fg:(Color.of_rgb Theme.default.text_primary)
      ~bg:(Color.of_rgb Theme.default.surface_0) ~attrs:Attr.bold ()
  in
  let draw_frame1 g =
    Cell_grid.clear g;
    ignore (Cell_grid.put_text g ~x:0 ~y:0 ~style:style_hi "MASC 펄스" : int);
    Cell_grid.put_braille g ~x:0 ~y:1 ~style:Style.default 0xFF
  in
  (* Frame 1: full repaint wrapped in CSI 2026 *)
  draw_frame1 (Presenter.back_grid presenter);
  let chunks1 = ref [] in
  let stats1 =
    Presenter.present_back presenter ~cursor:Presenter.hidden_cursor
      ~write:(fun s -> chunks1 := s :: !chunks1)
  in
  let out1 = String.concat "" (List.rev !chunks1) in
  Alcotest.(check bool) "frame1 full_repaint" true stats1.full_repaint;
  Alcotest.(check bool) "frame1 dirty_cells > 0" true (stats1.dirty_cells > 0);
  Alcotest.(check bool) "frame1 bytes > 0" true (stats1.bytes_emitted > 0);
  Alcotest.(check bool) "starts with CSI 2026 begin" true
    (String.starts_with ~prefix:"\x1b[?2026h" out1);
  Alcotest.(check bool) "ends with CSI 2026 end" true
    (String.ends_with ~suffix:"\x1b[?2026l" out1);
  Alcotest.(check bool) "contains text" true (string_contains ~needle:"MASC 펄스" out1);
  Alcotest.(check bool) "contains full braille" true
    (string_contains ~needle:Cell_grid.braille_lut.(0xFF) out1);
  Alcotest.(check bool) "never emits SGR dim" false
    (string_contains ~needle:"\x1b[2m" out1);

  (* Frame 2: identical content -> 0 dirty cells, 0 bytes emitted *)
  draw_frame1 (Presenter.back_grid presenter);
  let called2 = ref false in
  let stats2 =
    Presenter.present_back presenter ~cursor:Presenter.hidden_cursor
      ~write:(fun _ -> called2 := true)
  in
  Alcotest.(check bool) "frame2 write skipped" false !called2;
  Alcotest.(check int) "frame2 0 dirty cells" 0 stats2.dirty_cells;
  Alcotest.(check int) "frame2 0 dirty runs" 0 stats2.dirty_runs;
  Alcotest.(check int) "frame2 0 bytes" 0 stats2.bytes_emitted;

  (* Frame 3: two dirty cells bridged across 2 clean cells coalesce into 1 run *)
  draw_frame1 (Presenter.back_grid presenter);
  Cell_grid.put_ascii (Presenter.back_grid presenter) ~x:2 ~y:2 ~style:Style.default 'A';
  Cell_grid.put_ascii (Presenter.back_grid presenter) ~x:5 ~y:2 ~style:Style.default 'B';
  let chunks3 = ref [] in
  let stats3 =
    Presenter.present_back presenter ~cursor:Presenter.hidden_cursor
      ~write:(fun s -> chunks3 := s :: !chunks3)
  in
  let out3 = String.concat "" (List.rev !chunks3) in
  Alcotest.(check bool) "frame3 differential" false stats3.full_repaint;
  Alcotest.(check int) "frame3 2 dirty cells" 2 stats3.dirty_cells;
  Alcotest.(check int) "frame3 bridged into 1 run" 1 stats3.dirty_runs;
  Alcotest.(check bool) "frame3 contains A  B" true (string_contains ~needle:"A  B" out3);

  (* Frame 4: clearing row 2 emits trailing EL0 \x1b[K *)
  draw_frame1 (Presenter.back_grid presenter);
  let chunks4 = ref [] in
  let _stats4 =
    Presenter.present_back presenter ~cursor:Presenter.hidden_cursor
      ~write:(fun s -> chunks4 := s :: !chunks4)
  in
  let out4 = String.concat "" (List.rev !chunks4) in
  Alcotest.(check bool) "frame4 uses EL0 trailing clear" true
    (string_contains ~needle:"\x1b[K" out4)

(* ---- (d) Kitty CSI u + legacy escape + SGR mouse + paste + Korean input ---- *)
let check_single_key label expected seq =
  let dec = Input_decoder.create () in
  let events = Input_decoder.feed_string dec seq in
  match events with
  | [ Input_decoder.Key ev ] ->
      Alcotest.(check bool) label true (Input_decoder.equal_key_event expected ev)
  | _ -> Alcotest.failf "%s: unexpected event count %d" label (List.length events)

let test_input_decoder () =
  let open Input_decoder in
  let mk ?(ctrl = false) ?(alt = false) ?(shift = false) key =
    { key; mods = { ctrl; alt; shift } }
  in
  (* Kitty CSI u chords *)
  check_single_key "Shift+Enter CSI u" (mk ~shift:true Enter) "\x1b[13;2u";
  check_single_key "Alt+Enter CSI u" (mk ~alt:true Enter) "\x1b[13;3u";
  check_single_key "Ctrl+1 CSI u" (mk ~ctrl:true (Char "1")) "\x1b[49;5u";
  check_single_key "Ctrl+6 CSI u" (mk ~ctrl:true (Char "6")) "\x1b[54;5u";
  check_single_key "Ctrl+, CSI u" (mk ~ctrl:true (Char ",")) "\x1b[44;5u";
  check_single_key "Alt+1 CSI u" (mk ~alt:true (Char "1")) "\x1b[49;3u";
  check_single_key "Alt+6 CSI u" (mk ~alt:true (Char "6")) "\x1b[54;3u";
  check_single_key "Alt+j CSI u" (mk ~alt:true (Char "j")) "\x1b[106;3u";
  check_single_key "Alt+Y CSI u" (mk ~alt:true (Char "y")) "\x1b[89;3u";
  check_single_key "Alt+n CSI u" (mk ~alt:true (Char "n")) "\x1b[110;3u";
  check_single_key "Alt+v CSI u" (mk ~alt:true (Char "v")) "\x1b[118;3u";
  check_single_key "Alt+i CSI u" (mk ~alt:true (Char "i")) "\x1b[105;3u";

  (* Kitty CSI u shifted punctuation & modifier preservation *)
  check_single_key "Kitty ? shifted subparam" (mk (Char "?")) "\x1b[47:63;2u";
  check_single_key "Kitty : shifted subparam" (mk (Char ":")) "\x1b[59:58;2u";
  check_single_key "Kitty Ctrl+Shift+Q preserves shift"
    (mk ~ctrl:true ~shift:true (Char "q")) "\x1b[113;6u";

  (* Modified SS3 & rxvt SS3 *)
  check_single_key "SS3 Shift+F1 (ESC O 2 P)" (mk ~shift:true (Function 1)) "\x1bO2P";
  check_single_key "rxvt SS3 Ctrl+Up (ESC O a)" (mk ~ctrl:true Up) "\x1bOa";

  (* Kitty release event must be ignored cleanly *)
  let dec_rel = create () in
  Alcotest.(check int) "kitty release ignored" 0
    (List.length (feed_string dec_rel "\x1b[13;2:3u"));

  (* Kitty PUA functional/modifier keys must NOT leak into Char text *)
  List.iter
    (fun (label, seq) ->
      let dec_pua = create () in
      match feed_string dec_pua seq with
      | [ Unknown_escape ] -> ()
      | _ -> Alcotest.failf "%s: expected Unknown_escape" label)
    [
      ("CapsLock PUA 57358", "\x1b[57358u");
      ("F13 PUA 57376", "\x1b[57376u");
      ("Left Shift PUA 57441", "\x1b[57441u");
    ];
  check_single_key "KP_Enter PUA 57414" (mk Enter) "\x1b[57414u";

  (* CPR responses (ESC [ row ; col R) must NOT trigger phantom F3 *)
  List.iter
    (fun seq ->
      let dec_cpr = create () in
      match feed_string dec_cpr seq with
      | [ Unknown_escape ] -> ()
      | _ -> Alcotest.failf "CPR %S must decode as Unknown_escape, not F3" seq)
    [ "\x1b[24;1R"; "\x1b[12;5R" ];
  check_single_key "Ctrl+F3 still decodes" (mk ~ctrl:true (Function 3)) "\x1b[1;5R";

  (* Mid-CSI ESC must abort cleanly and start the new escape sequence without leaking 'A' *)
  let dec_mid = create () in
  (match feed_string dec_mid "\x1b[1\x1b[A" with
   | [ Unknown_escape; Key ev ] ->
       Alcotest.(check bool) "mid-CSI ESC recovers Up arrow" true
         (equal_key_event (mk Up) ev)
   | _ -> Alcotest.fail "expected [Unknown_escape; Key Up] on mid-CSI ESC");

  (* xterm modifyOtherKeys *)
  check_single_key "Shift+Enter modifyOtherKeys" (mk ~shift:true Enter) "\x1b[27;2;13~";
  check_single_key "Ctrl+, modifyOtherKeys" (mk ~ctrl:true (Char ",")) "\x1b[27;5;44~";

  (* F1..F10 across SS3, tilde, and Kitty PUA *)
  check_single_key "F1 SS3" (mk (Function 1)) "\x1bOP";
  check_single_key "F4 SS3" (mk (Function 4)) "\x1bOS";
  check_single_key "F5 tilde" (mk (Function 5)) "\x1b[15~";
  check_single_key "F8 tilde" (mk (Function 8)) "\x1b[19~";
  check_single_key "F10 tilde" (mk (Function 10)) "\x1b[21~";
  check_single_key "F1 Kitty PUA" (mk (Function 1)) "\x1b[57364u";
  check_single_key "F10 Kitty PUA" (mk (Function 10)) "\x1b[57373u";

  (* Legacy CSI, Ctrl, Meta/Alt, standalone Esc *)
  check_single_key "Up arrow" (mk Up) "\x1b[A";
  check_single_key "Shift+Tab" (mk ~shift:true Tab) "\x1b[Z";
  check_single_key "Ctrl+k raw" (mk ~ctrl:true (Char "k")) "\x0b";
  check_single_key "Alt+Enter legacy" (mk ~alt:true Enter) "\x1b\r";
  check_single_key "Alt+j legacy" (mk ~alt:true (Char "j")) "\x1bj";

  let dec_esc = create () in
  Alcotest.(check int) "esc pending" 0 (List.length (feed dec_esc '\x1b'));
  (match idle dec_esc with
   | [ Key ev ] -> Alcotest.(check bool) "idle flushes Escape" true (equal_key_event (mk Escape) ev)
   | _ -> Alcotest.fail "expected Escape on idle");

  (* SGR Mouse *)
  let dec_m = create () in
  (match feed_string dec_m "\x1b[<64;12;5M\x1b[<0;3;4M\x1b[<0;3;4m" with
   | [ Mouse m1; Mouse m2; Mouse m3 ] ->
       Alcotest.(check bool) "wheel up" true
         (equal_mouse_event (Wheel { dir = Wheel_up; col = 12; row = 5 }) m1);
       Alcotest.(check bool) "left press" true
         (equal_mouse_event (Left_press { col = 3; row = 4 }) m2);
       Alcotest.(check bool) "left release" true
         (equal_mouse_event (Left_release { col = 3; row = 4 }) m3)
   | _ -> Alcotest.fail "expected 3 SGR mouse events");

  (* Bracketed paste CRLF normalization *)
  let dec_p = create () in
  (match feed_string dec_p "\x1b[200~line1\r\nline2\x1b[201~" with
   | [ Paste p ] ->
       Alcotest.(check bool) "paste normalized" true
         (equal_paste_event { text = "line1\nline2"; dropped_bytes = 0 } p)
   | _ -> Alcotest.fail "expected bracketed paste");

  (* Incremental UTF-8 Korean + IME mapping *)
  let dec_ko = create () in
  let han = "한" in
  Alcotest.(check int) "byte 0 pending" 0 (List.length (feed dec_ko han.[0]));
  Alcotest.(check int) "byte 1 pending" 0 (List.length (feed dec_ko han.[1]));
  (match feed dec_ko han.[2] with
   | [ Key ev ] ->
       Alcotest.(check bool) "korean scalar decoded" true
         (equal_key_event (mk (Char "한")) ev)
   | _ -> Alcotest.fail "expected Korean scalar");
  Alcotest.(check (option (list string))) "IME 한 -> gks"
    (Some [ "g"; "k"; "s" ]) (Ime.latin_keys "한");
  Alcotest.(check (option string)) "IME ㄱ -> r" (Some "r")
    (Ime.single_latin_key "ㄱ")

(* ---- (e) Every preset keeps its own text floors (Theme.text_floors) and >= 4.5:1 for status, accent and gradients across ALL 4 surfaces ---- *)
let test_theme_contrast () =
  (* v2.5 Midnight calm-selection and exact token invariants *)
  let mid = Theme.of_preset Theme.Midnight in
  Alcotest.(check int) "Midnight calm selection_bg (#1D2C42, not #1D4ED8)"
    0x1D2C42 mid.selection_bg;
  Alcotest.(check int) "Midnight border_subtle (#232D3D)" 0x232D3D mid.border_subtle;
  Alcotest.(check int) "Midnight text_bright (#F3F6FA)" 0xF3F6FA mid.text_bright;
  Alcotest.(check int) "Midnight status_ai Violet (#C084FC)" 0xC084FC mid.status_ai;
  (* Floors became per-preset data; the original four keep the values they had,
     and the down-tone presets still hold WCAG 2.1 AAA (7:1) for body text. *)
  List.iter
    (fun preset ->
      let f = Theme.text_floors preset in
      Alcotest.(check (list (float 0.0)))
        (Theme.preset_name preset ^ " text floors")
        [ 12.0; 9.0; 6.5; Theme.min_text_contrast; 12.0 ]
        [ f.Theme.bright; f.Theme.primary; f.Theme.secondary; f.Theme.muted;
          f.Theme.selection ])
    Theme.[ Midnight; Arcade_hi; Paper_light; Mono ];
  List.iter
    (fun preset ->
      Alcotest.(check bool)
        (Theme.preset_name preset ^ " body text floor is WCAG AAA") true
        ((Theme.text_floors preset).Theme.primary >= 7.0))
    Theme.[ Muted; Muted_warm; Muted_green; Muted_dusk; Muted_graphite ];
  (* The named palettes only have to clear AA, so a published color that clears
     it is shown as published. The background and the brightest text are the
     anchors: changing either makes the preset a different palette. *)
  List.iter
    (fun (preset, background, brightest) ->
      let name = Theme.preset_name preset in
      let f = Theme.text_floors preset in
      Alcotest.(check (list (float 0.0)))
        (name ^ " text floors are AA")
        (List.init 5 (fun _ -> Theme.min_text_contrast))
        [ f.Theme.bright; f.Theme.primary; f.Theme.secondary; f.Theme.muted;
          f.Theme.selection ];
      let th = Theme.of_preset preset in
      Alcotest.(check int) (name ^ " background is the published one")
        background th.surface_0;
      Alcotest.(check int) (name ^ " brightest text is the published one")
        brightest th.text_bright)
    Theme.
      [
        (Solarized_dark, 0x002B36, 0xEEE8D5) (* base03, base2 *);
        (Nord, 0x2E3440, 0xECEFF4) (* nord0, nord6 *);
        (Dracula, 0x282A36, 0xF8F8F2) (* Background, Foreground *);
        (Gruvbox_dark, 0x282828, 0xFBF1C7) (* dark0, light0 *);
        (Catppuccin_mocha, 0x1E1E2E, 0xCDD6F4) (* base, text *);
      ];
  (* preset_index is numbered by hand, and equal_preset compares it. *)
  List.iter
    (fun a ->
      List.iter
        (fun b ->
          Alcotest.(check bool)
            (Printf.sprintf "equal_preset %s %s follows the name"
               (Theme.preset_name a) (Theme.preset_name b))
            (String.equal (Theme.preset_name a) (Theme.preset_name b))
            (Theme.equal_preset a b))
        Theme.all_presets)
    Theme.all_presets;
  List.iter
    (fun preset ->
      let th = Theme.of_preset preset in
      let pname = Theme.preset_name preset in
      let floors = Theme.text_floors preset in
      Alcotest.(check bool) (pname ^ ": saved name reloads to the same preset") true
        (match Theme.preset_of_name pname with
         | Some back -> Theme.equal_preset back preset
         | None -> false);
      let surfaces =
        [
          ("surface_0", th.surface_0);
          ("surface_1", th.surface_1);
          ("surface_2", th.surface_2);
          ("selection_bg", th.selection_bg);
        ]
      in
      let fgs =
        [
          ("text_bright", th.text_bright, floors.Theme.bright);
          ("text_primary", th.text_primary, floors.Theme.primary);
          ("text_secondary", th.text_secondary, floors.Theme.secondary);
          ("text_muted", th.text_muted, floors.Theme.muted);
          ("selection_fg", th.selection_fg, floors.Theme.selection);
          ("status_ok", th.status_ok, Theme.min_text_contrast);
          ("status_active", th.status_active, Theme.min_text_contrast);
          ("status_attention", th.status_attention, Theme.min_text_contrast);
          ("status_critical", th.status_critical, Theme.min_text_contrast);
          ("status_ai", th.status_ai, Theme.min_text_contrast);
          ("status_historical", th.status_historical, Theme.min_text_contrast);
          ("accent", th.accent, Theme.min_text_contrast);
        ]
      in
      List.iter
        (fun (sname, bg) ->
          List.iter
            (fun (fname, fg, floor) ->
              let cr = Theme.contrast_ratio fg bg in
              if cr < floor then
                Alcotest.failf "%s: %s on %s contrast %.2f < %.2f"
                  pname fname sname cr floor)
            fgs)
        surfaces;
      List.iter
        (fun gkind ->
          let lut = Theme.gradient_lut th gkind in
          Alcotest.(check int) "64-entry gradient LUT" 64 (Array.length lut);
          Array.iteri
            (fun idx stop ->
              let cr_card = Theme.contrast_ratio stop th.surface_1 in
              if cr_card < Theme.min_text_contrast then
                Alcotest.failf "%s: gradient stop %d on surface_1 contrast %.2f < 4.5"
                  pname idx cr_card;
              let cr_sel = Theme.contrast_ratio stop th.selection_bg in
              if cr_sel < Theme.min_text_contrast then
                Alcotest.failf "%s: gradient stop %d on selection_bg contrast %.2f < 4.5"
                  pname idx cr_sel)
            lut)
        Theme.all_gradients)
    Theme.all_presets;
  (* Downscale range checks *)
  let idx256 = Color.rgb_to_ansi256 0x38BDF8 in
  let idx16 = Color.rgb_to_ansi16 0x38BDF8 in
  Alcotest.(check bool) "ansi256 in 16..255" true (idx256 >= 16 && idx256 <= 255);
  Alcotest.(check bool) "ansi16 in 0..15" true (idx16 >= 0 && idx16 <= 15)

(* ---- (f) Observed / Format_val never collapse Unreported/Absent to 0, plus core contracts ---- *)
let test_observed_and_format_val () =
  let t0 = Clock.Mono.of_ns 1_000_000_000L in
  let unrep : float Observed.t = Observed.unreported in
  let abs_v : float Observed.t = Observed.absent in
  let load_v : float Observed.t = Observed.loading ~since_ns:t0 in
  let fail_v : float Observed.t =
    Observed.failed ~reason:"timeout" ~retryable:true ~at:t0
  in
  let present_v = Observed.value ~observed_at:t0 95.7 in
  Alcotest.(check (option (float 0.001))) "Unreported to_option is None" None
    (Observed.to_option unrep);
  Alcotest.(check (option (float 0.001))) "Absent to_option is None" None
    (Observed.to_option abs_v);
  let en_unrep = Format_val.format_observed Format_val.Usd unrep ~lang:Say.Lang_en in
  let ko_unrep = Format_val.format_observed Format_val.Usd unrep ~lang:Say.Lang_ko in
  let en_abs = Format_val.format_observed Format_val.Count abs_v ~lang:Say.Lang_en in
  let en_load = Format_val.format_observed Format_val.Count load_v ~lang:Say.Lang_en in
  let en_fail = Format_val.format_observed Format_val.Count fail_v ~lang:Say.Lang_en in
  Alcotest.(check string) "Unreported EN" "? Unreported" en_unrep;
  Alcotest.(check string) "Unreported KO" "? 미보고" ko_unrep;
  Alcotest.(check string) "Absent never 0" "—" en_abs;
  Alcotest.(check bool) "Unreported never $0.00" false (String.equal en_unrep "$0.00");
  Alcotest.(check bool) "Absent never 0" false (String.equal en_abs "0");
  Alcotest.(check bool) "Loading never 0" false (String.equal en_load "0");
  Alcotest.(check bool) "Failed never 0" false (String.equal en_fail "0");
  Alcotest.(check string) "Present Percent" "95.7%"
    (Format_val.format_observed Format_val.Percent present_v ~lang:Say.Lang_en);
  Alcotest.(check string) "Stale tagged with △" "△ 95.7%"
    (Format_val.format_observed Format_val.Percent (Observed.mark_stale present_v) ~lang:Say.Lang_en);

  (* Explicit $0 Sub / $0 Exhausted / ? Unreported *)
  Alcotest.(check string) "$0 Sub EN" "$0 Sub"
    (Format_val.format_cost Format_val.Subscription_zero ~lang:Say.Lang_en);
  Alcotest.(check string) "$0 Exhausted EN" "$0 Exhausted"
    (Format_val.format_cost Format_val.Exhausted_zero ~lang:Say.Lang_en);
  Alcotest.(check string) "? Unreported EN" "? Unreported"
    (Format_val.format_cost Format_val.Unreported ~lang:Say.Lang_en);
  Alcotest.(check string) "Amount USD" "$40.95"
    (Format_val.format_cost (Format_val.Amount 40.95) ~lang:Say.Lang_en);
  Alcotest.(check string) "Compact count" "38.7k"
    (Format_val.format_value Format_val.Count 38_700.);
  Alcotest.(check string) "Candles" "12.400 C"
    (Format_val.format_value Format_val.Candles 12.4);

  (* Exit_reason wire contract *)
  Alcotest.(check string) "SIGTERM wire line"
    "[masc-tui] exit: normal (signal SIGTERM)"
    (Exit_reason.wire_line (Exit_reason.Terminate "SIGTERM"));
  Alcotest.(check string) "Exception wire line"
    "[masc-tui] exit: abnormal (exception boom)"
    (Exit_reason.wire_line (Exit_reason.Exception "boom"));

  (* Nav converged counts *)
  Alcotest.(check int) "6 workspaces" 6 (List.length Nav.all_workspaces);
  Alcotest.(check int) "6 work tabs" 6 (List.length Nav.all_work_tabs);
  Alcotest.(check int) "4 knowledge tabs" 4 (List.length Nav.all_knowledge_tabs);
  Alcotest.(check int) "33 unified menu items" 33 (List.length Nav.all_menu_items);
  List.iteri
    (fun idx (it : Nav.menu_item) ->
      Alcotest.(check int)
        (Printf.sprintf "menu_item_index round-trip #%d" idx)
        idx (Nav.menu_item_index it.target))
    Nav.all_menu_items;
  Alcotest.(check int) "7 runtime tabs" 7 (List.length Nav.all_runtime_tabs);
  Alcotest.(check int) "4 infra tabs" 4 (List.length Nav.all_infra_tabs);
  Alcotest.(check int) "6 keeper tabs" 6 (List.length Nav.all_keeper_tabs);
  Alcotest.(check int) "7 settings tabs" 7 (List.length Nav.all_settings_tabs);
  Alcotest.(check bool) "strict workspace_of_index 0 = None" true
    (Option.is_none (Nav.workspace_of_index 0));
  Alcotest.(check bool) "strict workspace_of_index 7 = None" true
    (Option.is_none (Nav.workspace_of_index 7))

let test_hit_map_probe_clipboard () =
  (* Hit_map painter's order *)
  let hm =
    Cell_grid.Hit_map.empty
    |> Cell_grid.Hit_map.add ~rect:(Rect.make ~x:0 ~y:0 ~w:20 ~h:10) ~target:`Panel
    |> Cell_grid.Hit_map.add ~rect:(Rect.make ~x:5 ~y:2 ~w:6 ~h:4) ~target:`Modal
  in
  Alcotest.(check bool) "modal wins overlap" true
    (Cell_grid.Hit_map.hit_test hm ~x:6 ~y:3 = Some `Modal);
  Alcotest.(check bool) "panel outside modal" true
    (Cell_grid.Hit_map.hit_test hm ~x:1 ~y:1 = Some `Panel);
  Alcotest.(check bool) "outside all is None" true
    (Cell_grid.Hit_map.hit_test hm ~x:25 ~y:1 = None);

  (* Probe filters OSC 10/11 + CSI 16t + Kitty graphics while preserving user replay *)
  let stream =
    "a\x1b[6;18;9t\x1b]10;rgb:eeee/f0f0/ffff\x1b\\\x1b]11;rgb:0000/0000/0808\x1b\\\x1b_Gi=31;OK\x1b\\b"
  in
  let res = Probe.decode ~palette_requested:true stream in
  Alcotest.(check string) "user bytes replayed in order" "ab" res.replay;
  Alcotest.(check bool) "palette observed" true (Option.is_some res.palette);
  Alcotest.(check bool) "cell_pixels observed" true (res.cell_pixels = Some (9, 18));
  Alcotest.(check bool) "graphics supported" true
    (Option.equal Probe.equal_graphics_reply res.graphics (Some Probe.Graphics_supported));

  (* Clipboard OSC 52 *)
  Alcotest.(check string) "OSC 52 direct" "\x1b]52;c;aGk=\x1b\\"
    (Clipboard.osc52_sequence "hi");
  Alcotest.(check bool) "OSC 52 tmux wrapped" true
    (String.starts_with ~prefix:"\x1bPtmux;" (Clipboard.osc52_sequence ~in_tmux:true "hi"));

  (* Terminal_out enter/leave sequences toggle DECSET 1004 focus reporting and
     reset DECSCUSR cursor shape before showing cursor *)
  let enter_kitty =
    Terminal_out.enter_screen_seq ~keyboard:Terminal_out.Kitty ~mouse:false
      ~bracketed_paste:true
  in
  Alcotest.(check bool) "enter enables CSI ?1004h focus reporting" true
    (string_contains ~needle:"\x1b[?1004h" enter_kitty);
  let leave = Terminal_out.leave_screen_seq ~keyboard:Terminal_out.Kitty in
  Alcotest.(check bool) "leave pops Kitty keyboard" true
    (String.starts_with ~prefix:"\x1b[<u" leave);
  Alcotest.(check bool) "leave disables CSI ?1004l focus reporting" true
    (string_contains ~needle:"\x1b[?1004l" leave);
  Alcotest.(check bool) "leave resets DECSCUSR before show-cursor" true
    (string_contains ~needle:"\x1b[0 q\x1b[?25h" leave);
  let keyboard = Terminal_out.Xterm in
  Alcotest.(check bool) "tmux uses modifyOtherKeys mode 2" true
    (string_contains ~needle:"\x1b[>4;2m"
       (Terminal_out.enter_screen_seq ~keyboard ~mouse:false ~bracketed_paste:true));
  Alcotest.(check bool) "tmux clears modifyOtherKeys on release" true
    (String.starts_with ~prefix:"\x1b[>4;0m"
       (Terminal_out.leave_screen_seq ~keyboard));

  (* Health 3-channel predicates *)
  let attn = Health.Pending_ask { ask_id = "a1"; keeper = "k1" } in
  Alcotest.(check bool) "Needs_attention requires human action" true
    (Health.requires_human_action (Health.Needs_attention attn));
  Alcotest.(check bool) "Healthy does not require human action" false
    (Health.requires_human_action Health.Healthy);
  Alcotest.(check bool) "Reconnecting is not live transport" false
    (Health.is_transport_live
       (Health.Reconnecting
          { last_live_ns = None; attempt = 1; reason = Health.Timeout }))

(* ---- (f) Terminal_out non-blocking >64 KB EAGAIN write integrity ---- *)
let test_terminal_out_nonblock_pipe_large_frame () =
  let safe_close fd =
    match Unix.close fd with () -> () | exception Unix.Unix_error _ -> ()
  in
  let rd, wr = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      safe_close rd;
      safe_close wr)
    (fun () ->
      Unix.set_nonblock wr;
      (* Build an ~80 KB CSI 2026 frame containing multi-byte Korean UTF-8 *)
      let unit_row =
        "\x1b[38;2;96;165;250m작업·파이프라인·키퍼·샌드박스 0123456789ABCDEF\x1b[0m\r\n"
      in
      let buf = Buffer.create 84_000 in
      Buffer.add_string buf "\x1b[?2026h";
      while Buffer.length buf < 80 * 1024 do
        Buffer.add_string buf unit_row
      done;
      Buffer.add_string buf "\x1b[?2026l";
      let payload = Buffer.contents buf in
      let received = Buffer.create (String.length payload) in
      let reader_err = ref None in
      let reader =
        Thread.create
          (fun () ->
            let scratch = Bytes.create 2048 in
            let rec drain () =
              match Unix.read rd scratch 0 (Bytes.length scratch) with
              | 0 -> ()
              | n ->
                  Buffer.add_subbytes received scratch 0 n;
                  Thread.delay 0.0005;
                  drain ()
              | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain ()
              | exception Unix.Unix_error (err, _, _) ->
                  reader_err := Some (Unix.error_message err)
            in
            drain ())
          ()
      in
      let progress_calls = ref 0 in
      let res =
        Terminal_out.write_all_fd ~stall_limit_s:5.0
          ~on_progress:(fun () -> incr progress_calls)
          wr payload
      in
      safe_close wr;
      Thread.join reader;
      (match !reader_err with
      | None -> ()
      | Some msg -> Alcotest.fail ("reader error: " ^ msg));
      (match res with
      | Ok () -> ()
      | Error err ->
          Alcotest.failf "write_all_fd failed on non-blocking pipe: %s"
            (Unix.error_message err));
      let got = Buffer.contents received in
      Alcotest.(check int) "100% of >64KB payload bytes received"
        (String.length payload) (String.length got);
      Alcotest.(check bool) "payload byte-for-byte identical" true
        (String.equal payload got);
      Alcotest.(check bool) "chunked writes occurred across EAGAIN" true
        (!progress_calls >= 2));

  (* Verify stalled non-blocking pipe aborts cleanly within stall_limit_s *)
  let rd2, wr2 = Unix.pipe () in
  Fun.protect
    ~finally:(fun () ->
      safe_close rd2;
      safe_close wr2)
    (fun () ->
      Unix.set_nonblock wr2;
      let huge = String.make (256 * 1024) 'x' in
      match Terminal_out.write_all_fd ~stall_limit_s:0.08 wr2 huge with
      | Error Unix.EAGAIN -> ()
      | Error err ->
          Alcotest.failf "expected EAGAIN stall error, got %s"
            (Unix.error_message err)
      | Ok () -> Alcotest.fail "expected stall error on unread pipe");

  (* Non-finite or <=0 stall_limit_s clamps cleanly across partial writes *)
  List.iter
    (fun bad_limit ->
      let rd3, wr3 = Unix.pipe () in
      Fun.protect
        ~finally:(fun () ->
          safe_close rd3;
          safe_close wr3)
        (fun () ->
          Unix.set_nonblock wr3;
          let msg = "clamped-limit-ok" in
          (match Terminal_out.write_all_fd ~stall_limit_s:bad_limit wr3 msg with
          | Ok () -> ()
          | Error err ->
              Alcotest.failf "expected clamped limit Ok, got %s"
                (Unix.error_message err));
          safe_close wr3;
          let buf = Bytes.create 64 in
          let n = Unix.read rd3 buf 0 (Bytes.length buf) in
          Alcotest.(check string) "clamped write payload intact" msg
            (Bytes.sub_string buf 0 n)))
    [ Float.nan; Float.neg_infinity; -1.0; 0.0 ]

let () =
  Alcotest.run "masc_tui_v2_core_term"
    [
      ( "cell_grid_and_grapheme",
        [
          Alcotest.test_case "wide CJK overwrite partner cleanup" `Quick test_wide_cjk_overwrite;
          Alcotest.test_case "control stripping & glyph width-1" `Quick test_grapheme_sanitize_and_glyphs;
          Alcotest.test_case "256-entry Braille LUT UTF-8 validity" `Quick test_braille_lut;
        ] );
      ( "presenter",
        [
          Alcotest.test_case "CSI 2026 diff & 0-dirty 2nd frame" `Quick test_presenter_diff_and_csi2026;
        ] );
      ( "terminal_out",
        [
          Alcotest.test_case "non-blocking >64KB pipe EAGAIN integrity & stall bound"
            `Quick test_terminal_out_nonblock_pipe_large_frame;
        ] );
      ( "input_decoder",
        [
          Alcotest.test_case "Kitty CSI u + legacy + mouse + paste + Korean" `Quick test_input_decoder;
        ] );
      ( "theme",
        [
          Alcotest.test_case "WCAG/Oklab >= 4.5:1 across all presets" `Quick test_theme_contrast;
        ] );
      ( "core_contracts",
        [
          Alcotest.test_case "Observed / Format_val / Exit_reason / Nav" `Quick test_observed_and_format_val;
          Alcotest.test_case "Hit_map / Probe / Clipboard / Health" `Quick test_hit_map_probe_clipboard;
        ] );
    ]
