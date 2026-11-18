(* Where a surface stands is a value it hands to the title row, and only the
   function that draws zone 2 turns it into text (RFC tui-one-screen-grammar,
   section 2).

   The compiler holds most of that. [Masc_tui_value.Position.t] is private, so
   a surface builds one only through [row], [window] or [partial]. The text
   form lives in [Masc_tui_render_prim] and is not exported. The footer takes
   no position, and the helpers that wrote "[rows a-b/n]" into a body are
   gone, so a call to one does not compile.

   What a type cannot stop is a surface spelling a range itself with
   [Printf]. Before this check 70 lines of the TUI wrote a position as text:
   53 calls to three string helpers in [Masc_tui_scroll], 9 calls through two
   wrappers of them, and 8 [Printf] ranges in 5 spellings. The helpers are
   gone. This scans the TUI's sources for the range formats. A new one fails
   here and names its file and line. *)

open Alcotest

(* [DUNE_SOURCEROOT] is the checkout under [dune test]. Run straight from
   [_build/default/test], the sources dune copied for the build sit in
   [_build/default/bin], next to this executable's directory. *)
let bin_dir =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists (Filename.concat root "bin") ->
      Filename.concat root "bin"
  | Some _ | None ->
      Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "bin"

let tui_sources () =
  Sys.readdir bin_dir |> Array.to_list
  |> List.filter (fun name ->
         String.starts_with ~prefix:"masc_tui" name
         && Filename.check_suffix name ".ml")
  |> List.sort String.compare

let read path = In_channel.with_open_bin path In_channel.input_all

(* A range is two numbers joined by a hyphen or an en dash, then the whole
   after a slash or "of". The en dash appears in source both as the UTF-8
   bytes and as their escape. *)
let range_formats =
  let numbers = [ "%d"; "%s" ] in
  let dashes = [ "-"; "\xe2\x80\x93"; "\\xe2\\x80\\x93" ] in
  let joins = [ "/"; " / "; " of " ] in
  List.concat_map
    (fun number ->
      List.concat_map
        (fun dash ->
          List.map (fun join -> number ^ dash ^ number ^ join ^ number) joins)
        dashes)
    numbers

let contains line needle =
  let n = String.length needle and m = String.length line in
  let rec at i = i + n <= m && (String.sub line i n = needle || at (i + 1)) in
  at 0

let found () =
  List.concat_map
    (fun name ->
      read (Filename.concat bin_dir name)
      |> String.split_on_char '\n'
      |> List.mapi (fun index line -> (index + 1, line))
      |> List.filter_map (fun (number, line) ->
             List.find_opt (contains line) range_formats
             |> Option.map (fun format ->
                    Printf.sprintf "%s:%d writes %S" name number format)))
    (tui_sources ())

let test_no_surface_spells_a_range () =
  check bool "the TUI sources were read" true (List.length (tui_sources ()) > 50);
  check (list string) "no TUI source writes a position range by hand" [] (found ())

(* The check must see the forms it forbids, or an empty result proves
   nothing. *)
let test_the_check_sees_each_old_form () =
  List.iter
    (fun line ->
      check bool ("the check sees " ^ line) true
        (List.exists (contains line) range_formats))
    [ {|Printf.sprintf "%d-%d/%d" first last total|}
    ; {|Printf.sprintf "%d–%d/%d" first last total|}
    ; {|Printf.sprintf "  %d–%d / %d · " first last total|}
    ; {|Printf.sprintf "[newest rows %d-%d of %d]" first last total|}
    ; {|Printf.sprintf "history %s-%s of %s" first last total|}
    ; {|Printf.sprintf "%d\xe2\x80\x93%d/%d" first last total|} ]

let () =
  run "tui_position_source"
    [ ( "position",
        [ test_case "no surface spells a range" `Quick test_no_surface_spells_a_range
        ; test_case "the check sees each old form" `Quick test_the_check_sees_each_old_form ] ) ]
