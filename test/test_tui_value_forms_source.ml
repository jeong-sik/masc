(* A moment on a screen reads through Masc_tui_value, which adds the date
   once the day differs and keeps a server's UTC day apart from the
   operator's (RFC tui-one-screen-grammar §6.1, §10). The type system cannot
   hold that rule: the fields of a Unix.tm are readable anywhere. Forty-odd
   screens wrote their own "%02d:%02d" from them, and the Features status
   line drew yesterday's 20:29:21 under a screen clock that read 04:28. A
   check that looked for the clock alone let "%02d:00" hour labels in UTC
   sit under an "as of" in local time.

   So two forms stay inside the value module: a zero-padded number joined to
   the next by ':', '-' or '/', which is how a clock or a date is written,
   and a read of a Unix.tm calendar field, which is what a hand-written form
   is written from.

   The files read are the ones the generated [Tui_screen_sources] lists.
   Building this test copies them next to it, so a run by hand reads the
   sources as they are now, not as they were when the TUI was last built. *)

let value_module = "masc_tui_value.ml"

let calendar_fields =
  [ "tm_sec"; "tm_min"; "tm_hour"; "tm_mday"; "tm_mon"; "tm_year"; "tm_wday"; "tm_yday"; "tm_isdst" ]

let is_digit c = c >= '0' && c <= '9'
let is_ident c = c = '_' || c = '\'' || is_digit c || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

(* The end of a zero-padded or precision-padded integer conversion starting
   at the '%' at [i] ("%02d", "%04i", "%.2d"), or [None]. *)
let padded_conversion_end line i =
  let n = String.length line in
  let rec digits j = if j < n && is_digit line.[j] then digits (j + 1) else j in
  if i + 1 >= n then None
  else
    let after_pad =
      match line.[i + 1] with
      | '0' | '.' -> Some (digits (i + 2))
      | _ -> None
    in
    match after_pad with
    | Some j when j > i + 2 && j < n && (line.[j] = 'd' || line.[j] = 'i') -> Some (j + 1)
    | Some _ | None -> None

(* A clock or date joint: a padded number followed by ':', '-' or '/'. A
   length such as "%d:%02d" or "%dh%02dm" has no padded number before its
   joint, so it is not one. *)
let writes_a_joint line =
  let n = String.length line in
  let rec from i =
    if i >= n then false
    else if line.[i] <> '%' then from (i + 1)
    else
      match padded_conversion_end line i with
      | Some j when j < n && (line.[j] = ':' || line.[j] = '-' || line.[j] = '/') -> true
      | Some j -> from j
      | None -> from (i + 1)
  in
  from 0

let reads_a_calendar_field line =
  let n = String.length line in
  List.exists
    (fun field ->
      let m = String.length field in
      let rec from i =
        i + m <= n
        && ((String.sub line i m = field
             && (i = 0 || not (is_ident line.[i - 1]))
             && (i + m = n || not (is_ident line.[i + m])))
           || from (i + 1))
      in
      from 0)
    calendar_fields

let offending_lines text =
  String.split_on_char '\n' text
  |> List.mapi (fun index line -> index + 1, line)
  |> List.filter (fun (_, line) -> writes_a_joint line || reads_a_calendar_field line)

let screen_sources () =
  String.split_on_char ' ' Tui_screen_sources.paths
  |> List.map String.trim
  |> List.filter (fun path ->
         path <> "" && not (String.equal (Filename.basename path) value_module))
  |> List.sort String.compare

let read path = In_channel.with_open_bin path In_channel.input_all

let flagged line = offending_lines line <> []

(* The check must flag each form it exists for, or a check that matches
   nothing would pass every tree. *)
let test_the_old_forms_are_flagged () =
  List.iter
    (fun (what, line) -> Alcotest.(check bool) (what ^ " is flagged") true (flagged line))
    [ ("a clock", {|Printf.sprintf "%02d:%02d:%02d" a b c|})
    ; ("an hour label", {|Printf.sprintf "%02d:00" hour|})
    ; ("a date", {|Printf.sprintf "%04d-%02d-%02d" y m d|})
    ; ("a month and day", {|Printf.sprintf "%02d-%02d" m d|})
    ; ("a slashed date", {|Printf.sprintf "%02d/%02d %s" m d rest|})
    ; ("a precision-padded clock", {|Printf.sprintf "%.2d:%.2d" h m|})
    ; ("a calendar field read", {|let day = tm.Unix.tm_mday in|})
    ; ("a calendar field update", {|{ day with Unix.tm_hour = 0 }|})
    ];
  List.iter
    (fun (what, line) -> Alcotest.(check bool) (what ^ " is not flagged") false (flagged line))
    [ ("a track length", {|Printf.sprintf "%d:%02d" (total / 60) (total mod 60)|})
    ; ("a length in two units", {|Printf.sprintf "%dh%02dm" hours rest|})
    ; ("a fixed-point figure", {|Printf.sprintf "%d.%03d" whole fraction|})
    ; ("a numbered row", {|Printf.sprintf "#%02d · %s" index name|})
    ; ("a field whose name only starts like one", {|let tm_minutes = 3 in|})
    ]

(* The sources are there: an empty list would also have no offenders. *)
let minimum_screen_sources = 100

let test_no_screen_writes_its_own_calendar () =
  let sources = screen_sources () in
  Alcotest.(check bool)
    (Printf.sprintf "found %d screen sources" (List.length sources))
    true
    (List.length sources >= minimum_screen_sources);
  let offenders =
    List.concat_map
      (fun path ->
        offending_lines (read path)
        |> List.map (fun (line, text) ->
               Printf.sprintf "bin/%s:%d: %s" (Filename.basename path) line (String.trim text)))
      sources
  in
  Alcotest.(check (list string))
    "moments and days go through Masc_tui_value (Instant, Local_day, Local_hour, Utc_day)" []
    offenders

let () =
  Alcotest.run "tui_value_forms_source"
    [ ( "calendar forms"
      , [ Alcotest.test_case "the old forms are flagged" `Quick test_the_old_forms_are_flagged
        ; Alcotest.test_case "no screen writes its own calendar" `Quick
            test_no_screen_writes_its_own_calendar
        ] )
    ]
