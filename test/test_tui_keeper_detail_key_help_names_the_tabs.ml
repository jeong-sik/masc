(* The Config help said [p] walks five panes while the strip drew seven, and a
   test was written so a new pane moves the help with it
   (test_tui_config_key_help_matches_the_panes).

   The Keeper detail carried the same drift and no such test: [ / ] named four
   tabs -- Info / Settings / Secrets / GitHub -- while the strip drew nine.
   Sandbox is the second tab and was not among the four, so a reader who
   trusted [?] did not know it was there, nor Identity, Channels, Automation
   or Runs.

   The help is derived from the tab list now. This guard is what stops it
   being spelled by hand again. *)

let tabs_the_strip_draws =
  List.map Masc_tui_types.keeper_detail_tab_label Masc_tui_types.keeper_detail_tabs

let detail_bindings =
  Masc_tui_keys.for_surface (Masc_tui_types.Keepers Masc_tui_types.Keeper_detail)

let help_of key =
  List.find_opt
    (fun (b : Masc_tui_keys.binding) -> String.equal b.Masc_tui_keys.key key)
    detail_bindings
  |> Fun.flip Option.bind (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.help)

(* "detail tabs: A / B / C" -- the names are what follows the colon. *)
let tabs_the_help_names help =
  match String.index_opt help ':' with
  | None -> []
  | Some colon ->
    String.sub help (colon + 1) (String.length help - colon - 1)
    |> String.split_on_char '/'
    |> List.map String.trim
    |> List.filter (fun name -> not (String.equal name ""))

let test_the_tab_key_is_still_documented () =
  Alcotest.(check bool) "[ / ] has a help line" true
    (Option.is_some (help_of "[ / ]"))

let test_the_help_names_every_tab_the_strip_draws () =
  let help = Option.value (help_of "[ / ]") ~default:"" in
  Alcotest.(check (list string))
    "the help names the tabs the strip draws, in order" tabs_the_strip_draws
    (tabs_the_help_names help)

let () =
  Alcotest.run "tui_keeper_detail_key_help_names_the_tabs"
    [ ( "keeper detail tab help"
      , [ Alcotest.test_case "the tab key is still documented" `Quick
            test_the_tab_key_is_still_documented
        ; Alcotest.test_case "the help names every tab the strip draws" `Quick
            test_the_help_names_every_tab_the_strip_draws
        ] )
    ]
