open Alcotest
module M = Masc.Keeper_sandbox_microvm
module B = Masc.Keeper_microvm_backend

let digest = "sha256:" ^ String.make 64 'a'
let reference = "docker.io/library/debian@" ^ digest

let row ?(name = reference) ?(target = digest) () =
  `Assoc [ "Image", `Assoc
    [ "Name", `String name
    ; "Target", `Assoc [ "digest", `String target ] ] ]

let classify ?(status = Unix.WEXITED 0) ?listing ?(image = reference) json =
  M.classify_image_probe_for B.Nerdctl_kata ~image
    ~inspect:(status, Yojson.Safe.to_string json, "") ~listing

let assert_present = function
  | M.Image_present -> ()
  | _ -> fail "present pinned native image was refused"

let assert_invalid = function
  | M.Image_probe_failed { phase = M.Image_inspect; _ } -> ()
  | _ -> fail "invalid native image evidence did not fail inspection"

let test_pinned_image_and_content_aliases () =
  check (list string) "uses native mode for digest references"
    [ "nerdctl"; "image"; "inspect"; "--mode"; "native"; reference ]
    (M.image_inspect_argv_for B.Nerdctl_kata ~image:reference);
  classify (`List [ row () ]) |> assert_present;
  classify (`List [ row (); row ~name:"local/proof:latest" () ]) |> assert_present;
  classify ~image:"local/proof:latest" (`List [ row ~name:"local/proof:latest" () ])
  |> assert_present

let test_wrong_content_or_malformed_records_are_refused () =
  List.iter (fun json -> classify json |> assert_invalid)
    [ `List [ row ~target:("sha256:" ^ String.make 64 'b') () ]
    ; `List [ row (); row ~target:("sha256:" ^ String.make 64 'b') () ]
    ; `List [ `Assoc [] ]
    ; `List [ `Assoc [ "Image", `Assoc [ "Name", `String reference ] ] ]
    ; `List [ row ~name:"" () ]
    ; `List [ row ~target:"" () ]
    ; `List [ `Assoc [ "Image", `Null; "Image", `Assoc [] ] ]
    ; `Assoc []
    ];
  M.classify_image_probe_for B.Nerdctl_kata ~image:reference
    ~inspect:(Unix.WEXITED 0, "not json", "") ~listing:None |> assert_invalid

let test_empty_and_unavailable_store_are_not_present () =
  (match classify (`List []) with
   | M.Image_missing -> ()
   | _ -> fail "empty native image result was not missing");
  (match classify ~status:(Unix.WEXITED 127) `Null with
   | M.Image_cli_unavailable -> ()
   | _ -> fail "missing nerdctl CLI was not preserved");
  (match classify ~status:(Unix.WEXITED 1)
           ~listing:(Unix.WEXITED 0, "", "") `Null with
   | M.Image_missing -> ()
   | _ -> fail "readable empty inventory did not establish missing image");
  (match classify ~status:(Unix.WEXITED 1)
           ~listing:(Unix.WEXITED 1, "", "daemon unavailable") `Null with
   | M.Image_probe_failed { phase = M.Image_list; _ } -> ()
   | _ -> fail "unreadable store was mistaken for an absent image")

let test_other_backends_keep_their_protocols () =
  List.iter (fun (backend, json) ->
    M.classify_image_probe_for backend ~image:"proof:local"
      ~inspect:(Unix.WEXITED 0, Yojson.Safe.to_string json, "") ~listing:None
    |> assert_present)
    [ B.Apple_container, `List [ `Assoc [] ]; B.Microsandbox, `Assoc [] ]

let () = run "keeper nerdctl image admission"
  [ "installed-image", [
      test_case "digest pin and tag aliases admit exact content" `Quick test_pinned_image_and_content_aliases;
      test_case "wrong content and malformed native evidence refuse" `Quick test_wrong_content_or_malformed_records_are_refused;
      test_case "absent image and unavailable store remain distinct" `Quick test_empty_and_unavailable_store_are_not_present;
      test_case "Apple and Microsandbox protocols stay intact" `Quick test_other_backends_keep_their_protocols
    ] ]
