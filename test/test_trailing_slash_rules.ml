(** Trailing-slash trimming has two rules, and they must not be folded
    into one.

    URL-shaped values lose every trailing ['/'], so ["/"] becomes [""].
    Paths keep their root, because ["/"] there names a directory and ["")
    names nothing.

    Four copies of the URL rule existed before this suite (in
    [Masc_network_defaults], [Env_config_core], [Transport_read_model]
    and [Tool_local_runtime_probe]); two of them were byte-identical. The
    copies are gone, and these cases are what made collapsing them safe:
    they pin the behaviour the survivor has to keep, including the empty
    and all-slash inputs where the two rules visibly disagree. *)

open Alcotest

let url = Masc_network_defaults.trim_trailing_slashes
let path = Env_config_core.strip_path_trailing_slashes

(* Every input the two rules can disagree on, plus the ordinary ones. *)
let inputs =
  [ ""; "/"; "//"; "///"; "////////"
  ; "a"; "a/"; "a//"; "/a"; "//a"; "/a/"
  ; "http://x"; "http://x/"; "http://x//"
  ; "a/b/c"; "a/b/c///"
  ]

let test_url_strips_every_trailing_slash () =
  List.iter
    (fun (input, expected) ->
      check string (Printf.sprintf "url %S" input) expected (url input))
    [ "", ""
    ; "/", ""
    ; "///", ""
    ; "////////", ""
    ; "a", "a"
    ; "a/", "a"
    ; "a//", "a"
    ; "/a", "/a"
    ; "/a/", "/a"
    ; "http://x/", "http://x"
    ; "http://x//", "http://x"
    ; "a/b/c///", "a/b/c"
    ]

(* The reason the two functions stay separate. Fold them together and a
   filesystem root turns into the empty string. *)
let test_path_keeps_its_root () =
  check string "path root survives" "/" (path "/");
  check string "path multi-slash root survives" "/" (path "///");
  check string "path strips below the root" "/a" (path "/a//");
  check string "url disagrees on the root" "" (url "/")

let test_url_is_idempotent () =
  List.iter
    (fun input ->
      let once = url input in
      check string (Printf.sprintf "idempotent %S" input) once (url once))
    inputs

(* One answer to "is this loopback". The SSOT compared against 127.0.0.1 alone
   while its own doc said "any IPv4/IPv6 loopback address", so 127.0.0.2 and
   systemd-resolved's 127.0.0.53 read as remote here and as loopback in the
   two OAuth checks that carried their own octet test. It decides whether a
   dev token may be minted and whether strict HTTP auth turns itself on, so
   the three disagreeing about the same host was the defect (#27576). *)
let test_loopback_covers_rfc1122 () =
  List.iter
    (fun host ->
      check bool (Printf.sprintf "%S is loopback" host) true
        (Masc_network_defaults.is_loopback_host host))
    [ "127.0.0.1"
    ; "127.0.0.2"
    ; "127.0.0.53"
    ; "127.255.255.254"
    ; "::1"
      (* The same address arriving over a dual-stack socket. Every
         implementation missed it. *)
    ; "::ffff:127.0.0.1"
    ; "localhost"
    ; "  LocalHost  "
    ]
;;

let test_loopback_stops_at_the_prefix () =
  List.iter
    (fun host ->
      check bool (Printf.sprintf "%S is not loopback" host) false
        (Masc_network_defaults.is_loopback_host host))
    [ "126.255.255.255"
    ; "128.0.0.1"
    ; "10.0.0.1"
      (* Unspecified, not loopback — is_unspecified_host answers that one. *)
    ; "0.0.0.0"
      (* A prefix match on the string would take this; parsing refuses it. *)
    ; "127.invalid"
    ]
;;

let () =
  run
    "trailing_slash_rules"
    [ ( "url"
      , [ test_case "strips every trailing slash" `Quick
            test_url_strips_every_trailing_slash
        ; test_case "is idempotent" `Quick test_url_is_idempotent
        ] )
    ; ("path", [ test_case "keeps its root" `Quick test_path_keeps_its_root ])
    ; ( "loopback"
      , [ test_case "covers RFC 1122 127.0.0.0/8 and the mapped form" `Quick
            test_loopback_covers_rfc1122
        ; test_case "stops at the prefix boundary" `Quick
            test_loopback_stops_at_the_prefix
        ] )
    ]
