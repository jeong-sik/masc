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
  (* RFC-AC-037: the first-event (TTFT/prefill) budget needs the same
     configured-vs-effective disambiguation as the idle knob. *)
  Alcotest.(check bool)
    "resolved config exposes first_event_timeout_sec"
    true
    (List.mem "first_event_timeout_sec" names);
  Alcotest.(check bool)
    "resolved config exposes body_timeout_override_sec"
    true
    (List.mem "body_timeout_override_sec" names);
  (* #27349: same disambiguation need as #25128 -- an operator must be able
     to tell "provider_call_deadline_sec unset" from "configured but not
     applied", not infer it from absence. *)
  Alcotest.(check bool)
    "resolved config exposes provider_call_deadline_sec"
    true
    (List.mem "provider_call_deadline_sec" names);
  (* RFC keeper-context-window-in-tokens: the one number that says how much
     a request carries must be readable with its source, so an operator can
     tell the compiled default from a declared window. *)
  Alcotest.(check bool)
    "resolved config exposes context_window_tokens"
    true
    (List.mem "context_window_tokens" names)

(* RFC keeper-context-window-in-tokens: the window is the operator's
   declaration or nothing. No figure is compiled in, so an unset environment
   resolves to [None], and a runtime.toml value reaches the reader through
   the boot-override layer like the other turn settings. *)
let test_context_window_is_declared_or_none () =
  Config_boot_overrides.reset_for_tests ();
  Rr.reset_for_tests ();
  Alcotest.(check (option int))
    "undeclared resolves to None, not a compiled figure"
    None
    (Rr.context_window_tokens ());
  Config_boot_overrides.set
    Masc.Env_config_keeper.KeeperContext.window_tokens_env_key
    "65536";
  Rr.reset_for_tests ();
  Alcotest.(check (option int))
    "a declared value resolves verbatim"
    (Some 65536)
    (Rr.context_window_tokens ());
  Config_boot_overrides.reset_for_tests ();
  Rr.reset_for_tests ()

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
        ; Alcotest.test_case "context window is declared or none" `Quick
            test_context_window_is_declared_or_none
        ; Alcotest.test_case "serializes as object" `Quick
            test_to_yojson_is_a_json_object
        ] )
    ]
