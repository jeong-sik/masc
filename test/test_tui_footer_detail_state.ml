(* A surface that owns a detail draws one footer for two states. Until the key
   table carried the state, each of those surfaces advertised exactly one key
   the dispatcher refuses in the state on screen: [Right / Enter] once a detail
   is already open, [[ / ]] while it is not. The table knew -- the help said
   "while a detail is open" -- but as prose, which no footer can read.

   Two halves are pinned here because either one alone leaves the bug
   reachable: the table has to scope the keys, and both renderers of every
   scoped surface have to say which state they are drawing. The second is an
   optional argument, so a renderer that omits it still compiles and silently
   goes back to advertising both. *)

open Alcotest
module Keys = Masc_tui_keys

(* Named so a failure says which surface, not just which assertion. *)
let detail_surfaces =
  [ ("Planning", Masc_tui_types.Planning)
  ; ("Schedules", Masc_tui_types.Schedules)
  ; ("Verification", Masc_tui_types.Verification)
  ; ("Harness", Masc_tui_types.Harness)
  ]

let contains haystack needle =
  let needle_length = String.length needle
  and haystack_length = String.length haystack in
  let rec scan index =
    if index + needle_length > haystack_length then false
    else if String.equal (String.sub haystack index needle_length) needle then
      true
    else scan (index + 1)
  in
  scan 0

let test_each_surface_scopes_a_key () =
  List.iter
    (fun (name, surface) ->
      check bool (name ^ " scopes at least one key to a state") true
        (Keys.has_detail_scoped_keys surface))
    detail_surfaces

let list_footer_refusals =
  [ ("Board", Masc_tui_types.Board, [ "[ / ]"; "z:"; "h/l" ])
  ; ("Fusion", Masc_tui_types.Fusion, [ "[ / ]" ])
  ; ("Resources", Masc_tui_types.Resources, [ "[ / ]" ])
  ; ("System_logs", Masc_tui_types.System_logs, [ "[ / ]" ])
  ]

let test_each_list_footer_names_no_key_it_refuses () =
  List.iter
    (fun (name, surface, keys) ->
      check bool (name ^ " scopes at least one key to a state") true
        (Keys.has_detail_scoped_keys surface);
      let list_hints = Keys.footer_hints ~detail_open:false surface in
      (* Scoping moved the keys, it did not delete them: a caller that names
         no state still reads them, which is what the cheat sheet does. *)
      let both = Keys.footer_hints surface in
      List.iter
        (fun key ->
          check bool (name ^ " list does not advertise " ^ key) false
            (contains list_hints key);
          check bool (name ^ " naming no state still reads " ^ key) true
            (contains both key))
        keys)
    list_footer_refusals

let test_every_scoped_surface_is_named () =
  let named =
    List.map (fun (_, surface, _) -> surface) list_footer_refusals
    @ List.map snd detail_surfaces
  in
  List.iter
    (fun (label, surface) ->
      if Keys.has_detail_scoped_keys surface then
        check bool (label ^ " scopes a key and is named here") true
          (List.exists (fun s -> s = surface) named))
    Keys.help_surfaces

let () =
  run "tui footer detail state"
    [ ( "table",
        [ test_case "each surface scopes a key" `Quick
            test_each_surface_scopes_a_key
        ; test_case "each list footer names no key it refuses" `Quick
            test_each_list_footer_names_no_key_it_refuses
        ; test_case "every scoped surface is named here" `Quick
            test_every_scoped_surface_is_named
        ] )
    ; ( "renderers",
        [] )
    ]
