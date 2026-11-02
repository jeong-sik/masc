(** How a consent URL reaches a browser.

    The URL an OAuth login produces is about nine hundred characters and
    carries [&] and [?] by construction. Both facts are why this module
    exists: a pane truncates the first, and a shell splits the second. *)

let check = Alcotest.check
let str = Alcotest.string

let test_the_url_is_quoted () =
  (* Unquoted, everything after the first [&] reaches the shell as its own
     command -- the browser would open a truncated URL and the rest would
     run. *)
  let url = "https://auth.example.com/authorize?a=1&b=2&c=3" in
  check str "one argument, quoted"
    ("open '" ^ url ^ "'")
    (Masc_tui_browser.command_for ~opener:"open" ~url)

let test_a_quote_in_the_url_cannot_close_the_quoting () =
  (* Asked of a real shell rather than of the string. A substring check
     matches the injected text even when it sits safely inside the quoting,
     which is what a first version of this test did -- it failed on a
     command that was correct. What matters is what the shell parses, so
     the shell is asked. *)
  let url = "https://e.com/?x='; echo INJECTED; echo '" in
  let quoted = Masc_tui_browser.command_for ~opener:"printf %s" ~url in
  let channel = Unix.open_process_in quoted in
  let seen = In_channel.input_all channel in
  ignore (Unix.close_process_in channel);
  check str "the shell sees exactly the URL, one argument" url seen

let test_both_openers_are_tried () =
  (* A machine with neither gets an error naming both. One name would leave
     an operator checking the wrong thing. *)
  check (Alcotest.list str) "macOS first, then freedesktop"
    [ "open"; "xdg-open" ] Masc_tui_browser.openers

let test_the_browser_gets_the_page_not_the_picture_or_the_title () =
  (* Three distinct strings, so the wrong pick is visible. The title is
     indented for the screen; handing it to a shell would open nothing. The
     picture is what just failed. The page is what the operator chose. *)
  let page_url = "https://e.com/post/1" in
  let picked =
    Masc_tui_browser.browser_url
      { Masc_tui_browser.title = "  A post about nothing";
        page_url;
        image_url = "https://cdn.e.com/preview/1.png" }
  in
  check str "page url, not image url, not title" page_url picked

let test_waiting_opener_does_not_repeat_an_attempt () =
  let directory = Filename.temp_dir "tui-opener-" "" in
  let opener = Filename.concat directory "open" in
  let fallback = Filename.concat directory "xdg-open" in
  let log = Filename.concat directory "opened" in
  let previous_path = Option.value ~default:"" (Sys.getenv_opt "PATH") in
  let script path text =
    Out_channel.with_open_text path (fun channel ->
      Out_channel.output_string channel ("#!/bin/sh\n" ^ text ^ "\n"));
    Unix.chmod path 0o700 in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "PATH" previous_path;
    List.iter (fun path -> if Sys.file_exists path then Sys.remove path) [opener;fallback;log];
    Unix.rmdir directory) (fun () ->
    Unix.putenv "PATH" directory;
    script opener "exit 3";
    script fallback (Printf.sprintf "printf '%%s' \"$1\" > %s" (Filename.quote log));
    let start url = match Masc_tui_browser.spawn_url url with
      | Ok started -> started | Error detail -> Alcotest.fail detail in
    let first, pid = start "image.png" in
    check Alcotest.bool "nonzero exit leaves the effect uncertain" true
      (match Masc_tui_browser.await_opener ~opener:first pid with
       | Masc_tui_browser.Uncertain _ -> true | Opened _ | Rejected _ -> false);
    check Alcotest.bool "nonzero exit does not start another opener" false (Sys.file_exists log);
    Sys.remove opener;
    let second, pid = start "image with spaces.png" in
    check Alcotest.bool "a missing executable advances before anything starts" true
      (Masc_tui_browser.await_opener ~opener:second pid = Masc_tui_browser.Opened "xdg-open");
    check str "the fallback receives one exact argument" "image with spaces.png"
      (In_channel.with_open_text log In_channel.input_all);
    Sys.remove log;
    script opener "kill -TERM $$";
    let first, pid = start "image.png" in
    check Alcotest.bool "a signal leaves the outcome uncertain" true
      (match Masc_tui_browser.await_opener ~opener:first pid with
       | Masc_tui_browser.Uncertain _ -> true
       | Opened _ | Rejected _ -> false);
    check Alcotest.bool "uncertain launch does not start another opener" false (Sys.file_exists log))

let () =
  Alcotest.run "tui_browser"
    [ ( "the command",
        [ Alcotest.test_case "the url is quoted" `Quick test_the_url_is_quoted;
          Alcotest.test_case "a quote in the url cannot close the quoting"
            `Quick test_a_quote_in_the_url_cannot_close_the_quoting;
          Alcotest.test_case "both openers are tried" `Quick
            test_both_openers_are_tried;
          Alcotest.test_case "the browser gets the page, not the picture or the title"
            `Quick test_the_browser_gets_the_page_not_the_picture_or_the_title;
          Alcotest.test_case "opener attempts do not repeat" `Quick
            test_waiting_opener_does_not_repeat_an_attempt;
        ] );
    ]
