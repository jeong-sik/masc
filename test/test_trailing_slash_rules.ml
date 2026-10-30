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

(* The advertised-host fold takes the two wildcards and the two loopback
   spellings that some clients resolve to an IPv6-only socket. It is
   deliberately narrower than [is_loopback_host], which accepts all of
   127.0.0.0/8. Asserting that the two disagree on that range is the point:
   widening the fold has to delete a test rather than slip past one, because
   the difference is invisible at 127.0.0.1 -- the fold's own answer. *)
let test_advertised_host_folds_what_cannot_be_dialled () =
  List.iter
    (fun host ->
      check string
        (Printf.sprintf "%S is dialled as loopback" host)
        Masc_network_defaults.masc_http_default_host
        (Masc_network_defaults.normalize_advertised_host host))
    [ "0.0.0.0"; "::"; "  0.0.0.0  "; "localhost"; "LocalHost"; "::1" ]
;;

let test_advertised_host_keeps_the_rest_of_the_range () =
  List.iter
    (fun host ->
      check bool
        (Printf.sprintf "%S is loopback" host)
        true
        (Masc_network_defaults.is_loopback_host host);
      check string
        (Printf.sprintf "%S is still dialled as written" host)
        host
        (Masc_network_defaults.normalize_advertised_host host))
    [ "127.0.1.1"; "127.255.255.254"; "::ffff:127.0.0.1" ]
;;

let test_advertised_host_leaves_a_remote_name_alone () =
  check string "a remote host is not rewritten" "masc.crying.pictures"
    (Masc_network_defaults.normalize_advertised_host "  masc.crying.pictures  ")
;;

let test_base_url_folds_a_wildcard_authority () =
  check string "a URL naming every interface is not one to dial"
    "http://127.0.0.1:4318"
    (Masc_network_defaults.normalize_loopback_base_url "http://0.0.0.0:4318/")
;;

let test_base_url_leaves_a_dialable_url_untouched () =
  check string "no rewrite means no re-serialization"
    "http://127.0.1.1:8935/api"
    (Masc_network_defaults.normalize_loopback_base_url
       "http://127.0.1.1:8935/api/")
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
    ; ( "advertised host"
      , [ test_case "folds what cannot be dialled" `Quick
            test_advertised_host_folds_what_cannot_be_dialled
        ; test_case "keeps the rest of 127.0.0.0/8" `Quick
            test_advertised_host_keeps_the_rest_of_the_range
        ; test_case "leaves a remote name alone" `Quick
            test_advertised_host_leaves_a_remote_name_alone
        ; test_case "folds a wildcard base URL" `Quick
            test_base_url_folds_a_wildcard_authority
        ; test_case "leaves a dialable base URL untouched" `Quick
            test_base_url_leaves_a_dialable_url_untouched
        ] )
    ]
