(* A moment on a screen reads through Masc_tui_value.Instant, which adds the
   date once the day differs (RFC tui-one-screen-grammar §6.1, §10). The
   type system cannot hold that rule: the fields of a Unix.tm are readable
   anywhere. Forty-odd screens wrote their own "%02d:%02d" from them, and the
   Features status line drew yesterday's 20:29:21 under a screen clock that
   read 04:28. This check keeps that form inside the value module.

   It reads the sources dune copies next to the test (the stanza's deps), so
   it runs where the built TUI's sources are. *)

let value_module = "masc_tui_value.ml"

(* Two zero-padded fields joined by a colon: hours and minutes. A length
   such as "%d:%02d" (minutes and seconds of a track) is not a clock and has
   no zero-padded head. *)
let clock_forms = [ "%02d:%02d"; "%02i:%02i"; "%.2d:%.2d" ]

let contains ~needle text =
  let n = String.length needle and m = String.length text in
  let rec from i = i + n <= m && (String.sub text i n = needle || from (i + 1)) in
  from 0

let offending_lines text =
  String.split_on_char '\n' text
  |> List.mapi (fun index line -> index + 1, line)
  |> List.filter (fun (_, line) ->
         List.exists (fun needle -> contains ~needle line) clock_forms)

let source_dir = Filename.concat Filename.parent_dir_name "bin"

let screen_sources () =
  Sys.readdir source_dir |> Array.to_list
  |> List.filter (fun name ->
         String.starts_with ~prefix:"masc_tui" name
         && Filename.check_suffix name ".ml"
         && not (String.equal name value_module))
  |> List.sort String.compare

let read path = In_channel.with_open_bin path In_channel.input_all

(* The check itself must flag the form it exists for, or a check that
   matches nothing would pass every tree. *)
let test_the_old_form_is_flagged () =
  let old_line =
    {|  Printf.sprintf "%02d:%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec|}
  in
  Alcotest.(check (list int)) "a hand-written clock is flagged" [ 2 ]
    (List.map fst (offending_lines ("let clock tm =\n" ^ old_line)));
  Alcotest.(check (list int)) "a track length is not a clock" []
    (List.map fst (offending_lines {|Printf.sprintf "%d:%02d" (total / 60) (total mod 60)|}))

(* The sources are there: an empty directory would also have no offenders. *)
let minimum_screen_sources = 100

let test_no_screen_writes_its_own_clock () =
  let sources = screen_sources () in
  Alcotest.(check bool)
    (Printf.sprintf "found %d screen sources in %s" (List.length sources) source_dir)
    true
    (List.length sources >= minimum_screen_sources);
  let offenders =
    List.concat_map
      (fun name ->
        offending_lines (read (Filename.concat source_dir name))
        |> List.map (fun (line, text) -> Printf.sprintf "bin/%s:%d: %s" name line (String.trim text)))
      sources
  in
  Alcotest.(check (list string))
    "moments go through Masc_tui_value.Instant (detail_text, cell_text)" [] offenders

let () =
  Alcotest.run "tui_value_forms_source"
    [ ( "clock forms"
      , [ Alcotest.test_case "the old form is flagged" `Quick test_the_old_form_is_flagged
        ; Alcotest.test_case "no screen writes its own clock" `Quick
            test_no_screen_writes_its_own_clock
        ] )
    ]
