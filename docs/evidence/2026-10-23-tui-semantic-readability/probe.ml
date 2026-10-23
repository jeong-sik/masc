module P = Masc_tui_terminal_palette
module C = Masc_tui_color
module T = Masc_tui_theme

let rgb hex =
  let offset = if String.length hex = 7 then 1 else 0 in
  let byte at = int_of_string ("0x" ^ String.sub hex (offset + at) 2) in
  P.make_rgb ~red:(byte 0) ~green:(byte 2) ~blue:(byte 4)

let indexed_rgb index =
  if index >= 232 then
    let x = 8 + (index - 232) * 10 in P.make_rgb ~red:x ~green:x ~blue:x
  else
    let n = index - 16 in
    let level = function 0 -> 0 | n -> 55 + 40 * n in
    P.make_rgb ~red:(level (n / 36)) ~green:(level (n / 6 mod 6))
      ~blue:(level (n mod 6))

let emitted_rgb foreground code =
  if code = "\027[39m" then foreground
  else if String.starts_with ~prefix:"\027[38;2;" code then
    Scanf.sscanf code "\027[38;2;%d;%d;%dm" (fun red green blue ->
      P.make_rgb ~red ~green ~blue)
  else Scanf.sscanf code "\027[38;5;%dm" indexed_rgb

let emit ~enabled ~level palette =
  T.For_testing.recede ~colors_enabled:enabled ~default_foreground:"\027[39m"
    ~project:(P.For_testing.best_color_for_level ~level) palette

let () =
  if Array.length Sys.argv > 1 && Sys.argv.(1) = "--no-color-env" then (
    assert (not T.colors_enabled);
    assert (T.recede None = "");
    print_endline "PASS: actual NO_COLOR startup policy and production recede token";
    exit 0)

let () =
  let input = open_in "themes.tsv" in
  let rec loop count =
    match input_line input with
    | line ->
      (match String.split_on_char '\t' line with
      | [name; fg; bg] ->
        let fg = rgb fg and bg = rgb bg in
        let palette = P.of_responses ~foreground:(Some fg) ~background:(Some bg)
            ~ansi:(Array.make P.ansi_slot_count None) in
        List.iter (fun (label, level) ->
          let code = emit ~enabled:true ~level palette in
          let ratio = C.contrast_ratio (emitted_rgb fg code) bg in
          if C.contrast_ratio fg bg >= 4.5 then assert (ratio >= 4.5)
          else assert (code = "\027[39m");
          assert (emit ~enabled:false ~level palette = "");
          assert (emit ~enabled:true ~level None = "\027[39m");
          Printf.printf "%s\t%s\t%.9f\t%s\n" name label ratio
            (if code = "\027[39m" then "default-foreground" else "projected")
        ) ["truecolor", P.True_color; "ansi256", P.Ansi256;
           "ansi16", P.Ansi16; "unknown", P.Unknown]
      | _ -> failwith "invalid palette fixture");
      loop (count + 1)
    | exception End_of_file -> close_in input;
      Printf.eprintf "PASS: %d palettes; 4 colour depths; NO_COLOR and missing-palette cases\n" count
  in loop 0
