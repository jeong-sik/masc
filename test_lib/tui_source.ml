(* The TUI's drawing source, for the suites that read it rather than link it.

   Everything under bin/ is the masc_tui executable, which no test links
   (task-550), so a rule about what the surfaces draw is checked by reading
   their source. Two suites had written this scan out identically -- the
   no-value mark's and the duration spelling's -- and a third would have
   written it again. *)

let root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists root -> root
  | Some _ | None -> Sys.getcwd ()
;;

(* The module every drawing suite anchors on: it holds the marks and the
   palette the surfaces draw through, so a scan that does not reach it read
   the wrong directory. *)
let theme = "bin/masc_tui_theme.ml"

(* Read the directory rather than list the files: a module added to the
   drawing is in scope the day it lands, and a list named by hand answers a
   new surface by growing instead of by changing. *)
let drawing_modules () =
  let prefix = "masc_tui_" in
  Sys.readdir (Filename.concat (root ()) "bin")
  |> Array.to_list
  |> List.filter (fun name ->
         String.starts_with ~prefix name && Filename.check_suffix name ".ml")
  |> List.sort String.compare
  |> List.map (fun name -> Filename.concat "bin" name)
;;
