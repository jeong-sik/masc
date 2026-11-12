(* The reading of the login of a page (Account_page_reading) over pages
   written by hand: each case is one way a page can hold, close or lack a
   login. Two suites read the pages of the account server through this
   reading (test_server_login_http, test_server_accounts), and a reading that
   takes a wrong page for a right one would let both of them pass. *)

module P = Account_page_reading

let start = "/auth/github/start"
let form inner = Printf.sprintf {|<form method="post" action="%s">%s</form>|} start inner
let closed_button = {|<button disabled aria-describedby="why">Go</button>|}
let note = {|<p id="why">This server has no login.</p>|}

let cases =
  [ "a submit button", form "<button>Go</button>", Ok P.Open
  ; "a type of submit in any case", form {|<button type="SUBMIT">Go</button>|}, Ok P.Open
  ; "disabled with no value", form closed_button ^ note, Ok P.Closed
  ; "disabled with an empty value", form {|<button disabled="" aria-describedby="why">Go</button>|} ^ note, Ok P.Closed
  ; ( "disabled with its name as the value"
    , form {|<button disabled="disabled" aria-describedby="why">Go</button>|} ^ note
    , Ok P.Closed )
  ; ( "disabled in upper case, unquoted, after the other attributes"
    , form {|<button aria-describedby=why class=x DISABLED>Go</button>|} ^ note
    , Ok P.Closed )
  ; ( "a button in a disabled fieldset"
    , form {|<fieldset disabled><button aria-describedby="why">Go</button></fieldset>|} ^ note
    , Ok P.Closed )
  ; ( "a description in two elements"
    , form {|<button disabled aria-describedby="more why">Go</button>|} ^ {|<p id="more"></p>|} ^ note
    , Ok P.Closed )
  ; "no form", "<button>Go</button>", Error P.No_form
  ; "a form to another route", {|<form method="post" action="/elsewhere"><button>Go</button></form>|}, Error P.No_form
  ; "a form that does not post", Printf.sprintf {|<form action="%s"><button>Go</button></form>|} start, Error P.No_form
  ; "two forms", form "<button>Go</button>" ^ form "<button>Go</button>", Error (P.Several_forms 2)
  ; "an element that is no button", form {|<div id="go">Go</div>|}, Error P.No_submit_button
  ; ( "a disabled element that is no button"
    , form {|<div id="go" disabled aria-describedby="why">Go</div>|} ^ note
    , Error P.No_submit_button )
  ; "a button that submits nothing", form {|<button type="button">Go</button>|}, Error P.No_submit_button
  ; "a button that resets", form {|<button type="reset">Go</button>|}, Error P.No_submit_button
  ; "a button outside the form", form "" ^ "<button>Go</button>", Error P.No_submit_button
  ; "a button that posts elsewhere", form {|<button formaction="/elsewhere">Go</button>|}, Error P.No_submit_button
  ; "a button of another form", form {|<button form="other">Go</button>|}, Error P.No_submit_button
  ; "a button of another namespace", form "<svg><button>Go</button></svg>", Error P.No_submit_button
  ; "two submit buttons", form "<button>Go</button><button>Go</button>", Error (P.Several_submit_buttons 2)
  ; "a form in a hidden element", "<div hidden>" ^ form "<button>Go</button>" ^ "</div>", Error P.Not_rendered
  ; "a hidden button", form "<button hidden>Go</button>", Error P.Not_rendered
  ; "disabled with no description", form "<button disabled>Go</button>", Error P.No_description
  ; ( "disabled with a description list of spaces"
    , form {|<button disabled aria-describedby=" ">Go</button>|} ^ note
    , Error P.No_description )
  ; "a description that is not in the page", form closed_button, Error (P.Description_missing "why")
  ; ( "a hidden description"
    , form closed_button ^ {|<p id="why" hidden>This server has no login.</p>|}
    , Error (P.Description_hidden "why") )
  ; ( "a description in a hidden element"
    , form closed_button ^ "<div hidden>" ^ note ^ "</div>"
    , Error (P.Description_hidden "why") )
  ; "a description with no text", form closed_button ^ {|<p id="why"> </p>|}, Error P.Description_blank
  ]
;;

let reads (name, page, expected) =
  Alcotest.test_case name `Quick (fun () -> Alcotest.check P.outcome name expected (P.login ~start page))
;;

let () = Alcotest.run "account_page_reading" [ "login", List.map reads cases ]
