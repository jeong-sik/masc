(* The exact lines /collab leaves in the chat pane. The QR is content, not
   chrome: the test reads that a block drawing is present and stable, not
   its pixels — decoding it back is a scanner's job. *)

open Alcotest
module D = Masc.Tui_decode
module Text = Masc_tui_collab_text

let session ~base_url ~resumed : D.collab_host_session =
  { D.chs_keeper = "imp"
  ; chs_room_id = "room"
  ; chs_view_link = "masc://v"
  ; chs_control_link = "masc://c"
  ; chs_web_link = base_url ^ "/#w"
  ; chs_control_web_link = base_url ^ "/#c"
  ; chs_base_url = base_url
  ; chs_resumed = resumed
  }
;;

let is_qr_row line =
  String.length line > 0
  && (String.contains line '\226'
     || (String.length line > 1 && line.[0] = ' ' && line.[1] = ' '))
;;

let test_hosted_card_carries_links_and_qr () =
  let lines = Text.hosted_lines (session ~base_url:"https://relay.test:8443" ~resumed:false) in
  check string "headline" "sharing imp — hand someone a link, they're in"
    (List.nth lines 0);
  check string "view terminal" "view (terminal):    masc://v" (List.nth lines 1);
  check string "control terminal" "control (terminal): masc://c" (List.nth lines 2);
  check string "view browser"
    "view (browser):     https://relay.test:8443/#w" (List.nth lines 3);
  check string "control browser"
    "control (browser):  https://relay.test:8443/#c" (List.nth lines 4);
  (* A public base earns no loopback warning: the QR caption follows the
     links after one blank line. *)
  check string "blank before caption" "" (List.nth lines 5);
  check string "caption" "scan to join in a browser:" (List.nth lines 6);
  let qr = List.filteri (fun i _ -> i >= 7) lines in
  check bool "qr is drawn" true (List.length qr > 10);
  check bool "qr rows are block drawings" true (List.for_all is_qr_row qr);
  (* The drawing is deterministic: the same link scans the same. *)
  check (list string) "stable qr" qr
    (List.filteri
       (fun i _ -> i >= 7)
       (Text.hosted_lines (session ~base_url:"https://relay.test:8443" ~resumed:false)))
;;

let test_hosted_card_warns_on_loopback_and_names_resume () =
  let lines = Text.hosted_lines (session ~base_url:"http://127.0.0.1:1777" ~resumed:true) in
  check string "resume headline"
    "sharing imp — resumed the live room (no second room minted)"
    (List.nth lines 0);
  check bool "loopback warned" true
    (List.exists
       (fun line ->
         String.length line >= 4 && String.sub line 0 4 = "note")
       lines);
  List.iter
    (fun base ->
      let card = Text.hosted_lines (session ~base_url:base ~resumed:false) in
      check bool ("warned for " ^ base) true
        (List.exists
           (fun line -> String.length line >= 4 && String.sub line 0 4 = "note")
           card))
    [ "http://localhost:1777"
    ; "http://localhost"
    ; "http://localhost.:1777"
    ; "http://LOCALHOST:1777"
    ; "https://[::1]:1777"
    ; "https://[::ffff:127.0.0.1]:1777"
    ; "http://0.0.0.0:1777"
    ; "http://0x7f.0.0.1:1777"
    ; "http://2130706433:1777"
    ; "http://0177.0.0.1:1777"
    ];
  List.iter
    (fun base ->
      let card = Text.hosted_lines (session ~base_url:base ~resumed:false) in
      check bool ("quiet for " ^ base) false
        (List.exists
           (fun line -> String.length line >= 4 && String.sub line 0 4 = "note")
           card))
    [ "https://relay.test"
    ; "http://10.9.8.7:1777"
    ; "https://notlocalhost.test"
    ; "http://128.0.0.1:1777"
    ; "http://[::2]:1777"
    ; "http://127.0.0.2.evil.test:1777"
    ]
;;

let contains_sub needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i =
    i + n <= h && (String.sub haystack i n = needle || scan (i + 1))
  in
  scan 0
;;

let qr_of lines =
  let rec drop_until_caption = function
    | [] -> []
    | line :: rest ->
      if String.equal line "scan to join in a browser:" then rest else drop_until_caption rest
  in
  drop_until_caption lines
;;

let test_view_card_carries_no_control_link () =
  let s = session ~base_url:"https://relay.test" ~resumed:false in
  let lines = Text.hosted_view_lines s in
  check string "headline" "sharing imp — view links only" (List.nth lines 0);
  check string "view terminal" "view (terminal): masc://v" (List.nth lines 1);
  check string "view browser" "view (browser):  https://relay.test/#w" (List.nth lines 2);
  (* A word ban would still pass a swapped link value or a control QR:
     the control link values must be absent and the QR must be the view
     link's own drawing. *)
  List.iter
    (fun secret ->
      check bool ("absent " ^ secret) false
        (List.exists (contains_sub secret) lines))
    [ "masc://c"; "https://relay.test/#c" ];
  check (list string) "qr is the view link qr" (qr_of (Text.hosted_lines s)) (qr_of lines)
;;

let test_stopped_lines_name_count () =
  check (list string) "none" [ "not sharing imp — nothing to stop" ]
    (Text.stopped_lines { D.csr_keeper = "imp"; csr_stopped = 0 });
  check (list string) "one" [ "stopped sharing imp" ]
    (Text.stopped_lines { D.csr_keeper = "imp"; csr_stopped = 1 });
  check (list string) "many" [ "stopped sharing imp (3 rooms)" ]
    (Text.stopped_lines { D.csr_keeper = "imp"; csr_stopped = 3 })
;;

let () =
  run
    "tui-collab-text"
    [ ( "card",
        [ test_case "hosted carries links and qr" `Quick
            test_hosted_card_carries_links_and_qr
        ; test_case "loopback warning and resume" `Quick
            test_hosted_card_warns_on_loopback_and_names_resume
        ; test_case "view card carries no control" `Quick
            test_view_card_carries_no_control_link
        ; test_case "stopped names count" `Quick test_stopped_lines_name_count
        ] )
    ]
;;
