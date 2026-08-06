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

let () =
  run
    "trailing_slash_rules"
    [ ( "url"
      , [ test_case "strips every trailing slash" `Quick
            test_url_strips_every_trailing_slash
        ; test_case "is idempotent" `Quick test_url_is_idempotent
        ] )
    ; ("path", [ test_case "keeps its root" `Quick test_path_keeps_its_root ])
    ]
