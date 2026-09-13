(* The Config help said [p] walks five panes. The strip draws seven, and has
   for a while: presets and voice were added without the help following. A
   reader who trusts the help does not know the voice pane exists, which is the
   pane the setup wizard opens from.

   So the count is taken from the strip itself rather than restated here: the
   strip calls its [name] helper once per pane, and the help row lists them
   separated by "/". A new pane moves the first number and this fails until the
   help row moves too. *)

let render = "bin/masc_tui_render_prim.ml"

let panes_the_strip_draws () =
  Ast_grep.count_calls_in_value_binding ~module_path:render
    ~binding_name:"config_pane_strip" ~callee:"name"

let config_bindings = Masc_tui_keys.for_surface Masc_tui_types.Config

let binding_for key =
  List.find_opt
    (fun (b : Masc_tui_keys.binding) -> String.equal b.Masc_tui_keys.key key)
    config_bindings

let panes_the_help_names () =
  match binding_for "p" with
  | None -> []
  | Some b ->
    String.split_on_char '/' b.Masc_tui_keys.label
    |> List.map String.trim
    |> List.filter (fun part -> not (String.equal part ""))

let test_the_help_names_every_pane_the_strip_draws () =
  let drawn = panes_the_strip_draws () in
  Alcotest.(check bool) "the strip draws panes at all" true (drawn > 0);
  Alcotest.(check int)
    "the p row names one pane per pane the strip draws" drawn
    (List.length (panes_the_help_names ()))

(* The wizard is reached by [e] on the voice pane. Naming the pane is what makes
   that reachable from the help rather than by accident. *)
let test_the_voice_pane_is_named () =
  Alcotest.(check bool)
    "the p row names the voice pane" true
    (List.exists (String.equal "voice") (panes_the_help_names ()))

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec walk i = i + n <= h && (String.equal (String.sub haystack i n) needle || walk (i + 1)) in
  n = 0 || walk 0

(* [e] means something different on every pane, so its help is the only place a
   reader learns that on voice it opens a wizard rather than an editor. *)
let test_e_says_what_it_does_on_the_voice_pane () =
  match binding_for "e" with
  | None -> Alcotest.fail "Config has no e binding"
  | Some b ->
    let help = Option.value b.Masc_tui_keys.help ~default:"" in
    Alcotest.(check bool) "the e help mentions the voice pane" true
      (contains ~needle:"voice" help)

let () =
  Alcotest.run
    "masc_tui_config_key_help"
    [ ( "the pane list"
      , [ Alcotest.test_case "the help names every pane the strip draws" `Quick
            test_the_help_names_every_pane_the_strip_draws
        ; Alcotest.test_case "the voice pane is named" `Quick
            test_the_voice_pane_is_named
        ] )
    ; ( "what e does"
      , [ Alcotest.test_case "e says what it does on the voice pane" `Quick
            test_e_says_what_it_does_on_the_voice_pane
        ] )
    ]
