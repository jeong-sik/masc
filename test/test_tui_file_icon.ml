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

let glyph =
  []

let legend =
  []

let () =
  Alcotest.run "tui_file_icon"
    [ ("kind_of_name", kind_of_name)
    ; ("plain_fallbacks", plain_fallbacks)
    ; ("glyph", glyph)
    ; ("legend", legend)
    ]
