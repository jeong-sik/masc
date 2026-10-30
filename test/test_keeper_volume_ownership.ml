(* Workspace-scoped ownership markers for Apple Keeper volumes.

   These tests pin the interpreter only: bytes in, ownership verdict out. No
   volume, image, or CLI is touched, so they run anywhere. The runtime-side
   probe (inspect + reading the marker off the volume image) is a later
   layer; its contract is exactly [interpret_marker_bytes] below. *)

module Kvo = Masc.Keeper_volume_ownership

let ownership_case =
  let open Alcotest in
  let t =
    of_pp (fun ppf -> function
      | Kvo.Owned_by_this_workspace -> Fmt.string ppf "Owned_by_this_workspace"
      | Kvo.Unverified reason ->
        Fmt.pf ppf "Unverified(%s)" (Kvo.unverified_to_string reason)
      | Kvo.Owned_by_another_workspace { Kvo.recorded } ->
        Fmt.pf ppf "Owned_by_another_workspace(%s)" recorded)
  in
  (t, fun a b -> Fmt.str "%a" t a = Fmt.str "%a" t b)
;;

let marker_json base_path =
  Printf.sprintf {|{"base_path":"%s","written_at":1.79e9,"schema":1}|} base_path
;;

let test_marker_roundtrip_preserves_the_workspace () =
  let marker = { Kvo.base_path = "/w/alpha"; written_at = 1.79e9 } in
  let json = Kvo.marker_to_yojson marker in
  (match Kvo.marker_of_yojson json with
   | Ok parsed ->
     Alcotest.(check string) "base path survives" marker.base_path parsed.base_path;
     Alcotest.(check float) "timestamp survives" marker.written_at parsed.written_at
   | Error detail -> Alcotest.failf "roundtrip rejected its own output: %s" detail)
;;

let test_a_marker_naming_this_workspace_answers_owned () =
  let probed = "/w/alpha" in
  let verdict = Kvo.interpret_marker_bytes ~probed_base_path:probed (marker_json probed) in
  Alcotest.(check ownership_case) "same base path is owned"
    Kvo.Owned_by_this_workspace verdict
;;

let test_a_marker_naming_another_workspace_is_not_owned () =
  let verdict =
    Kvo.interpret_marker_bytes ~probed_base_path:"/w/alpha" (marker_json "/w/beta")
  in
  Alcotest.(check ownership_case)
    "a different base path belongs to the other workspace"
    (Kvo.Owned_by_another_workspace { recorded = "/w/beta" })
    verdict
;;

let test_malformed_marker_bytes_stay_unverified () =
  let bytes = {|{"schema":1,"base_path":""}|} in
  let verdict = Kvo.interpret_marker_bytes ~probed_base_path:"/w/alpha" bytes in
  (match verdict with
   | Kvo.Unverified (Kvo.Marker_unreadable _) -> ()
   | other ->
     Alcotest.failf "an empty base path must be unreadable, got: %s"
       (match other with
        | Kvo.Owned_by_this_workspace -> "owned"
        | _ -> "other"))
;;

let test_not_json_at_all_is_unverified_not_a_guess () =
  let verdict = Kvo.interpret_marker_bytes ~probed_base_path:"/w/alpha" "not json \x00\x01" in
  (match verdict with
   | Kvo.Unverified (Kvo.Marker_unreadable _) -> ()
   | _ -> Alcotest.fail "garbage bytes must never answer owned or another-workspace")
;;

let test_a_missing_marker_is_a_legacy_volume () =
  Alcotest.(check ownership_case)
    "no marker means the owner is unknown, not this workspace"
    (Kvo.Unverified Kvo.Unmarked)
    (Kvo.interpret_marker_absent ())
;;

let test_the_marker_path_is_at_the_volume_root () =
  Alcotest.(check string)
    "the marker lives at the guest-visible root"
    ".masc-volume-owner"
    Kvo.marker_path
;;

let () =
  let open Alcotest in
  run "Keeper volume ownership"
    [ ( "interpreter"
      , [ test_case "marker roundtrip" `Quick test_marker_roundtrip_preserves_the_workspace
        ; test_case "this workspace's marker answers owned" `Quick
            test_a_marker_naming_this_workspace_answers_owned
        ; test_case "another workspace's marker is not owned" `Quick
            test_a_marker_naming_another_workspace_is_not_owned
        ; test_case "malformed marker stays unverified" `Quick
            test_malformed_marker_bytes_stay_unverified
        ; test_case "garbage bytes never guess" `Quick
            test_not_json_at_all_is_unverified_not_a_guess
        ; test_case "missing marker is a legacy volume" `Quick
            test_a_missing_marker_is_a_legacy_volume
        ; test_case "marker path is at the volume root" `Quick
            test_the_marker_path_is_at_the_volume_root
        ] )
    ]
;;
