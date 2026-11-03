open Alcotest

module Reading = Masc_tui_approval_value_reading

let test_owner () =
  let scope = ref () in
  let fields =
    [ "duplicate", `String "\027"
    ; "duplicate", `String "\\x1B"
    ; "number", `Float 0.
    ] in
  let reading = Reading.create ~scope ~gate_id:"gate-a" ~fields ~restore_scroll:7 in
  check bool "string values are available" true (Reading.has_strings fields);
  check bool "non-string inputs offer no string reading" false
    (Reading.has_strings [ "number", `Int 3; "nested", `List [ `String "x" ] ]);
  let matches ~scope ~gate_id fields = Reading.matches reading ~scope ~gate_id ~fields in
  check bool "same retained input" true (matches ~scope ~gate_id:"gate-a" fields);
  let refreshed = List.map (fun (key, value) -> key, value) fields in
  check bool "same decoded input after refresh" true (matches ~scope ~gate_id:"gate-a" refreshed);
  check bool "different workspace read authority" false
    (matches ~scope:(ref ()) ~gate_id:"gate-a" refreshed);
  check bool "different Gate" false (matches ~scope ~gate_id:"gate-b" refreshed);
  check bool "different float spelling" false
    (matches ~scope ~gate_id:"gate-a"
       [ "duplicate", `String "\027"; "duplicate", `String "\\x1B"; "number", `Float (-0.) ]);
  check bool "different duplicate order" false
    (matches ~scope ~gate_id:"gate-a"
       [ "duplicate", `String "\\x1B"; "duplicate", `String "\027"; "number", `Float 0. ]);
  check int "normal reading scroll is retained" 7 (Reading.restore_scroll reading)

let () =
  run "Gate value reading ownership" [ "ownership", [ test_case "source and scope" `Quick test_owner ] ]
