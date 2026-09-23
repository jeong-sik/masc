(* A destination the palette offers by name is a section the sheet names that
   way. Both lists are hand-kept and neither reads the other, so they drift:
   the Schedules surface was filed under "Keeper detail / Automation" -- a
   Keeper detail tab that has no keys of its own and no route to this screen
   -- while its title bar said "MASC Schedules" and the palette said "go
   Schedules". A reader who typed the name and pressed [?] found this
   screen's keys under the name of a screen they were not on. (That title
   has since become "MASC Keepers / Schedules", so that the screen names the
   parent its tab strip highlights -- #36421. The drift described here is
   what this test guards, and it is quoted as it stood.)

   A label may carry the path: "Planning / Goals" is the Planning surface on
   its first tab, and "Config / Runtime / Clients" is three deep. So the name
   has to be one of the label's segments, not the whole label. *)

let state () =
  Masc_tui_types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()

(* Every "go <name>" the palette offers that lands on a surface. *)
let palette_destinations () =
  Masc_tui_types.palette_entries (state ())
  |> List.filter_map (fun (label, action) ->
    match action with
    | Masc_tui_types.Palette_goto surface
      when String.length label > 3 && String.sub label 0 3 = "go " ->
      Some (String.sub label 3 (String.length label - 3), surface)
    | _ -> None)

let segments label =
  String.split_on_char '/' label |> List.map String.trim

let section_for surface =
  List.find_opt
    (fun (_, section_surface) -> section_surface = surface)
    Masc_tui_keys.help_surfaces

let test_the_palette_offers_names_the_sheet_uses () =
  let destinations = palette_destinations () in
  Alcotest.(check bool) "the palette offers destinations at all" true
    (destinations <> []);
  List.iter
    (fun (name, surface) ->
      match section_for surface with
      (* A surface with no section of its own is a different gap and not this
         guard's: several sub-modes fold into a parent's section on purpose. *)
      | None -> ()
      | Some (label, _) ->
        Alcotest.(check bool)
          (Printf.sprintf "\"go %s\" is named %S on the sheet" name label)
          true
          (List.mem name (segments label)))
    destinations

let () =
  Alcotest.run "tui_sheet_names_every_palette_destination"
    [ ( "sheet sections"
      , [ Alcotest.test_case "the palette offers names the sheet uses" `Quick
            test_the_palette_offers_names_the_sheet_uses
        ] )
    ]
