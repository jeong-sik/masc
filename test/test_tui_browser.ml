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

let chosen_for uname =
  match Masc_tui_browser.kernel_of_uname uname with
  | Ok kernel ->
    "ok:" ^ Masc_tui_browser.opener_command (Masc_tui_browser.opener_for kernel)
  | Error reason -> "error:" ^ reason

let test_darwin_gets_open_and_only_open () =
  (* One kernel, one opener. xdg-open is never on macOS, so it is never a
     fallback there. *)
  check str "Darwin -> open" "ok:open" (chosen_for "Darwin\n")

let test_a_refusing_opener_runs_once_and_its_refusal_is_kept () =
  (* The shell is a counter here. A non-zero exit from the chosen opener is
     the answer the operator sees -- opener, status, URL -- not a reason to
     run a second opener. *)
  let url = "https://e.com/post/1?a=1&b=2" in
  let commands = ref [] in
  let run command =
    commands := command :: !commands;
    Unix.WEXITED 1
  in
  let outcome =
    Masc_tui_browser.open_url_with ~run ~kernel:Masc_tui_browser.Darwin url
  in
  check (Alcotest.result str str) "the refusal names opener, status and url"
    (Error ("open exited 1 for " ^ url))
    outcome;
  check (Alcotest.list str) "exactly one command ran, the Darwin opener's"
    [ "open '" ^ url ^ "'" ]
    !commands

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

let test_linux_gets_xdg_open () =
  check str "Linux -> xdg-open" "ok:xdg-open" (chosen_for "Linux")

let test_an_unknown_kernel_is_refused_by_name () =
  (* No guess. The refusal quotes the kernel so the operator can see what
     the machine said rather than which opener we assumed. *)
  check str "refused, quoting the kernel"
    "error:no link opener known for kernel \"FreeBSD\" (open on Darwin, xdg-open on Linux)"
    (chosen_for "FreeBSD")

let () =
  Alcotest.run "tui_browser"
    [ ( "the command",
        [ Alcotest.test_case "the url is quoted" `Quick test_the_url_is_quoted;
          Alcotest.test_case "a quote in the url cannot close the quoting"
            `Quick test_a_quote_in_the_url_cannot_close_the_quoting;
          Alcotest.test_case "darwin gets open and only open" `Quick
            test_darwin_gets_open_and_only_open;
          Alcotest.test_case "linux gets xdg-open" `Quick
            test_linux_gets_xdg_open;
          Alcotest.test_case "an unknown kernel is refused by name" `Quick
            test_an_unknown_kernel_is_refused_by_name;
          Alcotest.test_case "a refusing opener runs once and its refusal is kept"
            `Quick test_a_refusing_opener_runs_once_and_its_refusal_is_kept;
          Alcotest.test_case "the browser gets the page, not the picture or the title"
            `Quick test_the_browser_gets_the_page_not_the_picture_or_the_title;
        ] );
    ]
