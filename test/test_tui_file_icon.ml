(* The Code tree's file-type marks: the extension a name carries decides its
   kind, and each kind draws a distinct one-column plain-unicode glyph. The
   renderer colours the glyph; that mapping is exercised by the TUI's own
   tests, so this pins the pure part -- extension to kind, kind to glyph. *)

module F = Masc_tui_file_icon

let kind_name = function
  | F.Code -> "Code"
  | F.Data -> "Data"
  | F.Prose -> "Prose"
  | F.Script -> "Script"
  | F.Web -> "Web"
  | F.Media -> "Media"
  | F.Plain -> "Plain"

let kind = Alcotest.testable (fun ppf k -> Format.pp_print_string ppf (kind_name k)) ( = )

let case name expected =
  Alcotest.test_case name `Quick (fun () ->
      Alcotest.check kind name expected (F.kind_of_name name))

let kind_of_name =
  [ case "main.ml" F.Code
  ; case "masc_tui_file_icon.mli" F.Code
  ; case "app.ts" F.Code
  ; case "component.tsx" F.Code
  ; case "script.py" F.Code
  ; case "lib.rs" F.Code
  ; case "runtime.toml" F.Data
  ; case "release.json" F.Data
  ; case "config.yaml" F.Data
  ; case "README.md" F.Prose
  ; case "notes.txt" F.Prose
  ; case "start-masc.sh" F.Script
  ; case ".zshrc.zsh" F.Script
  ; case "index.html" F.Web
  ; case "theme.css" F.Web
  ; case "diagram.svg" F.Media
  ; case "shot.PNG" F.Media (* extension is lowercased before matching *)
  ; case "local.env" F.Data (* a real trailing .env extension reads as config *)
  ]

(* Names with nothing to read an extension from all fall to [Plain]: an
   extensionless tool file, a dotfile whose only dot leads the name (so it has
   no trailing extension), and the empty string. *)
let plain_fallbacks =
  [ case "Makefile" F.Plain
  ; case "Dockerfile" F.Plain
  ; case "LICENSE" F.Plain
  ; case ".gitignore" F.Plain
  ; case ".env" F.Plain (* leading dot only: a dotfile, not an ".env" extension *)
  ; case "" F.Plain
  ; case "no-extension-here" F.Plain
  ]

(* The module's own list, not a second copy of it here: a kind this file
   forgot would quietly stop being checked. *)
let all_kinds = F.kinds

let glyphs_distinct () =
  let glyphs = List.map F.glyph all_kinds in
  let unique = List.sort_uniq String.compare glyphs in
  Alcotest.(check int)
    "every kind has its own glyph"
    (List.length all_kinds)
    (List.length unique);
  List.iter
    (fun k ->
      Alcotest.(check bool)
        (kind_name k ^ " glyph is non-empty")
        true
        (String.length (F.glyph k) > 0))
    all_kinds

let glyph =
  [ Alcotest.test_case "glyphs are distinct and non-empty" `Quick glyphs_distinct ]

(* The tree draws the mark and then the file name, and the name says the
   extension the mark was read from, not what the mark means. The words here
   are the only place that says it, and the help sheet prints them -- so a
   word that is blank, or one shared by two marks, leaves a reader unable to
   tell those files apart. *)
let legend_words_say_one_thing_each () =
  List.iter
    (fun (mark, word) ->
      Alcotest.(check bool)
        (Printf.sprintf "the mark %S has a word" mark)
        true
        (String.length (String.trim word) > 0))
    F.legend;
  let words = List.map snd F.legend in
  Alcotest.(check int)
    "no two marks are given the same word"
    (List.length words)
    (List.length (List.sort_uniq String.compare words))

let legend_covers_every_kind () =
  let explained = List.map fst F.legend in
  List.iter
    (fun k ->
      Alcotest.(check bool)
        (kind_name k ^ " has a legend row")
        true
        (List.mem (F.glyph k) explained))
    all_kinds

let legend =
  [ Alcotest.test_case "every mark has its own word" `Quick
      legend_words_say_one_thing_each
  ; Alcotest.test_case "the legend covers every kind" `Quick
      legend_covers_every_kind
  ]

let () =
  Alcotest.run "tui_file_icon"
    [ ("kind_of_name", kind_of_name)
    ; ("plain_fallbacks", plain_fallbacks)
    ; ("glyph", glyph)
    ; ("legend", legend)
    ]
