(* Where a surface stands is a value it hands to the title row, and only the
   function that draws zone 2 turns it into text (RFC tui-one-screen-grammar,
   section 2).

   The compiler holds most of that. [Masc_tui_value.Position.t] is private, so
   a surface builds one only through [row], [window] or [partial]. The text
   form lives in [Masc_tui_render_prim] and is not exported. The footer takes
   no position, and the helpers that wrote "[rows a-b/n]" into a body are
   gone, so a call to one does not compile.

   What a type cannot stop is checked here, over the TUI's sources:

   - A range spelled by hand. Before the first check 70 lines wrote one: 53
     calls to three string helpers, 9 through two wrappers, and 8 [Printf]
     ranges. The check now sees every integer conversion with its flags and
     width ([%i], [%3d]), and a range joined with [^] as well as one written
     in a format. The one function that draws zone 2 is the only place a
     range is built.
   - A surface that windows its rows and hands nothing. A definition that
     draws a title row and cuts a window out of its rows ([Rows.of_list], a
     [Paged_by_cursor] or [Self_scrolled] body) must hand a position.
     Before this check fifteen did not (QA round R6a): their readers saw
     rows go missing with nothing saying where they were.

   A selected row written as [N/M] is not checked: a ratio ([20/27], RFC
   section 6.3) is spelled the same way, and only a typed ratio would tell
   the two apart. *)

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

let contains text needle =
  let n = String.length needle and m = String.length text in
  let rec at i = i + n <= m && (String.sub text i n = needle || at (i + 1)) in
  at 0

(* -- A range spelled by hand ------------------------------------------- *)

let is_digit c = c >= '0' && c <= '9'

(* The end of a [Printf] conversion that writes a number or a string at [i]:
   [%d], [%i], [%u], [%s], with any flags, width and precision. *)
let conversion_at text i =
  let m = String.length text in
  if i >= m || text.[i] <> '%' then None
  else
    let rec skip j pred = if j < m && pred text.[j] then skip (j + 1) pred else j in
    let j = skip (i + 1) (fun c -> c = '-' || c = '0' || c = '+' || c = ' ' || c = '#') in
    let j = skip j is_digit in
    let j = if j < m && text.[j] = '.' then skip (j + 1) is_digit else j in
    if j < m && (text.[j] = 'd' || text.[j] = 'i' || text.[j] = 'u' || text.[j] = 's')
    then Some (j + 1)
    else None

let literal_at text i literal =
  let n = String.length literal in
  if i + n <= String.length text && String.sub text i n = literal then Some (i + n) else None

let first_of text i literals =
  List.find_map (fun literal -> literal_at text i literal) literals

let dashes = [ "-"; "\xe2\x80\x93"; "\\xe2\\x80\\x93" ]
let joins = [ " / "; "/"; " of " ]

(* number, dash, number, join, number *)
let format_range_at text i =
  let ( let* ) = Option.bind in
  let* i = conversion_at text i in
  let* i = first_of text i dashes in
  let* i = conversion_at text i in
  let* i = first_of text i joins in
  conversion_at text i

let writes_format_range line =
  let rec from i =
    i < String.length line && (Option.is_some (format_range_at line i) || from (i + 1))
  in
  from 0

(* The same range joined with [^]: a dash piece and a slash piece on one
   line. *)
let joined_pieces pieces = List.map (fun piece -> "^ \"" ^ piece ^ "\" ^") pieces

let writes_joined_range line =
  List.exists (contains line) (joined_pieces dashes)
  && List.exists (contains line) (joined_pieces [ "/"; " / " ])

let writes_range line = writes_format_range line || writes_joined_range line

(* -- Top-level definitions ---------------------------------------------- *)

(* The source with comments blanked, so a word in a comment is not code. A
   string's contents are kept: a quote inside a string does not open a
   comment, and a comment opener inside a string does not either. *)
let without_comments text =
  let m = String.length text in
  let out = Bytes.of_string text in
  let rec code i =
    if i >= m then ()
    else if text.[i] = '"' then string (i + 1)
    else if i + 1 < m && text.[i] = '(' && text.[i + 1] = '*' then comment (i + 2) 1 i
    else code (i + 1)
  and string i =
    if i >= m then ()
    else if text.[i] = '\\' then string (i + 2)
    else if text.[i] = '"' then code (i + 1)
    else string (i + 1)
  and comment i depth start =
    if i >= m then blank start m
    else if i + 1 < m && text.[i] = '(' && text.[i + 1] = '*' then comment (i + 2) (depth + 1) start
    else if i + 1 < m && text.[i] = '*' && text.[i + 1] = ')' then
      if depth = 1 then (blank start (i + 2); code (i + 2))
      else comment (i + 2) (depth - 1) start
    else comment (i + 1) depth start
  and blank from until =
    for k = from to until - 1 do
      if text.[k] <> '\n' then Bytes.set out k ' '
    done
  in
  code 0;
  Bytes.to_string out

let starts_definition line =
  List.exists
    (fun keyword -> String.starts_with ~prefix:keyword line)
    [ "let "; "and "; "module "; "type "; "open "; "include "; "exception " ]

(* Each top-level definition as its first line number, its name and its
   text. *)
let definitions text =
  let lines = String.split_on_char '\n' text |> List.mapi (fun index line -> (index + 1, line)) in
  let close acc = function None -> acc | Some (number, head, body) -> (number, head, String.concat "\n" (List.rev body)) :: acc in
  let acc, open_ =
    List.fold_left
      (fun (acc, current) (number, line) ->
        if starts_definition line then (close acc current, Some (number, line, [ line ]))
        else
          match current with
          | None -> (acc, None)
          | Some (start, head, body) -> (acc, Some (start, head, line :: body)))
      ([], None) lines
  in
  List.rev (close acc open_)

(* The one function that turns a position into text. *)
let draws_zone_two_text head = String.starts_with ~prefix:"let position_text " head

(* -- A window with no position ------------------------------------------ *)

let draws_title_row body =
  List.exists (contains body)
    [ "surface_chrome "; "here_row "; "titled_row "; "zone_two_title "
    ; "pane_surface_header "; "config_pane_title " ]

let windows_rows body =
  List.exists (contains body) [ "Rows.of_list"; "Paged_by_cursor"; "Self_scrolled" ]

(* [~position:] with anything but [None] after it. *)
let passes_a_position body =
  let needle = "~position:" in
  let n = String.length needle and m = String.length body in
  let rec from i =
    if i + n > m then false
    else if String.sub body i n = needle then
      let rest = String.sub body (i + n) (min 4 (m - i - n)) in
      (not (String.equal rest "None")) || from (i + n)
    else from (i + 1)
  in
  from 0

let hands_a_position body =
  passes_a_position body
  || List.exists (contains body)
       [ "Position.row"; "Position.window"; "Position.partial"; "Scrolled {"
       ; "c.position"; "hand_position" ]

(* -- What the sources hold ---------------------------------------------- *)

let sources () =
  List.map (fun name -> (name, read (Filename.concat bin_dir name))) (tui_sources ())

let found_ranges () =
  List.concat_map
    (fun (name, text) ->
      definitions text
      |> List.filter (fun (_, head, _) -> not (draws_zone_two_text head))
      |> List.concat_map (fun (start, _, body) ->
             String.split_on_char '\n' body
             |> List.mapi (fun offset line -> (start + offset, line))
             |> List.filter (fun (_, line) -> writes_range line)
             |> List.map (fun (number, line) ->
                    Printf.sprintf "%s:%d writes a range: %s" name number (String.trim line))))
    (sources ())

let found_windows_without_position () =
  List.concat_map
    (fun (name, text) ->
      definitions (without_comments text)
      |> List.filter_map (fun (number, head, body) ->
             if draws_title_row body && windows_rows body && not (hands_a_position body)
             then Some (Printf.sprintf "%s:%d windows rows and hands no position: %s" name number head)
             else None))
    (sources ())

(* -- Tests --------------------------------------------------------------- *)

let test_no_surface_spells_a_range () =
  check bool "the TUI sources were read" true (List.length (tui_sources ()) > 50);
  check (list string) "no TUI source writes a position range by hand" [] (found_ranges ())

let test_every_window_hands_a_position () =
  check (list string) "every surface that windows its rows hands a position" []
    (found_windows_without_position ())

(* The checks must see the forms they forbid, or an empty result proves
   nothing. *)
let test_the_range_check_sees_each_form () =
  List.iter
    (fun line -> check bool ("the check sees " ^ line) true (writes_range line))
    [ {|Printf.sprintf "%d-%d/%d" first last total|}
    ; {|Printf.sprintf "%d–%d/%d" first last total|}
    ; {|Printf.sprintf "  %d–%d / %d · " first last total|}
    ; {|Printf.sprintf "[newest rows %d-%d of %d]" first last total|}
    ; {|Printf.sprintf "history %s-%s of %s" first last total|}
    ; {|Printf.sprintf "%d\xe2\x80\x93%d/%d" first last total|}
    ; {|Printf.sprintf "%i-%i/%i" first last total|}
    ; {|Printf.sprintf "%3d-%3d/%d" first last total|}
    ; {|string_of_int (scroll + 1) ^ "-" ^ string_of_int last ^ "/" ^ string_of_int shown|}
    ; {|grouped first ^ "\xe2\x80\x93" ^ grouped last ^ "/" ^ grouped total|} ];
  List.iter
    (fun line -> check bool ("the check passes " ^ line) false (writes_range line))
    [ {|Printf.sprintf "%d/%d running" running total|}
    ; {|Printf.sprintf "%02d:%02d" hour minute|}
    ; {|"https://" ^ host ^ "/" ^ path|} ]

let test_the_window_check_sees_a_window_without_a_position () =
  let surface hand =
    String.concat "\n"
      [ "let render_probe state ="
      ; "  let window = Rows.of_list ~first ~height rows in"
      ; "  box_line buf cols (here_row ~cols state ~path:[] ~readings:[] ~position:" ^ hand ^ ");"
      ; "  ignore window" ]
  in
  let flagged text =
    definitions (without_comments text)
    |> List.exists (fun (_, _, body) ->
           draws_title_row body && windows_rows body && not (hands_a_position body))
  in
  check bool "a window under a title with no position is flagged" true (flagged (surface "None"));
  check bool "a window whose title takes its position passes" false
    (flagged (surface "(Rows_position.of_window window)"));
  check bool "a word in a comment is not a window" false
    (flagged
       "let render_probe state =\n  (* Rows.of_list *)\n  here_row ~cols state ~path:[] ~readings:[] ~position:None")

let () =
  run "tui_position_source"
    [ ( "position",
        [ test_case "no surface spells a range" `Quick test_no_surface_spells_a_range
        ; test_case "every window hands a position" `Quick test_every_window_hands_a_position
        ; test_case "the range check sees each form" `Quick test_the_range_check_sees_each_form
        ; test_case "the window check sees a window without a position" `Quick
            test_the_window_check_sees_a_window_without_a_position ] ) ]
