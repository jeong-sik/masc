(** Pins the observability contract that the boot-time resolved-runtime-config
    log depends on (server_runtime_bootstrap): the serialized resolved config
    must expose the opt-in timeout knobs by name, so an operator can tell a
    configured-but-unapplied knob from an unset one at runtime. This is the
    surface that would have disambiguated #25128 (idle timeout configured yet
    never observed to fire). [masc] is re-exported by [masc_test_deps]. *)

module Rr = Masc.Keeper_runtime_resolved

let field_names json =
  match json with
  | `Assoc fields -> List.map fst fields
  | _ -> []

let test_resolved_config_exposes_timeout_knobs () =
  Rr.reset_for_tests ();
  Rr.init ();
  let json = Rr.to_yojson (Rr.current ()) in
  let names = field_names json in
  (* The boot log serializes exactly this value; assert the knobs the #25128
     diagnosis needs are present and named, whatever their resolved value. *)
  Alcotest.(check bool)
    "resolved config exposes stream_idle_timeout_sec"
    true
    (List.mem "stream_idle_timeout_sec" names);
  Alcotest.(check bool)
    "resolved config exposes body_timeout_override_sec"
    true
    (List.mem "body_timeout_override_sec" names)

let test_to_yojson_is_a_json_object () =
  Rr.reset_for_tests ();
  Rr.init ();
  match Rr.to_yojson (Rr.current ()) with
  | `Assoc _ -> ()
  | _ -> Alcotest.fail "resolved runtime config must serialize as a JSON object"

let () =
  Alcotest.run
    "keeper_runtime_resolved_observability"
    [ ( "resolved_config_surface"
      , [ Alcotest.test_case "exposes timeout knobs" `Quick
            test_resolved_config_exposes_timeout_knobs
        ; Alcotest.test_case "serializes as object" `Quick
            test_to_yojson_is_a_json_object
        ] )
    ]
