(** Tests for capabilities wiring. *)

open Alcotest
open Llm_provider

let test_effective_disable_parallel_tool_use () =
  let effective =
    Capabilities.effective_disable_parallel_tool_use ~supports_parallel_tool_calls:false
  in
  check
    bool
    "explicit caller disable wins without tools"
    true
    (effective ~caller_disabled:true ~tools_present:false);
  check
    bool
    "capability disables when tools are present"
    true
    (effective ~caller_disabled:false ~tools_present:true);
  check
    bool
    "no tools does not force disable"
    false
    (effective ~caller_disabled:false ~tools_present:false);
  check
    bool
    "parallel-capable model stays enabled"
    false
    (Capabilities.effective_disable_parallel_tool_use
       ~caller_disabled:false
       ~supports_parallel_tool_calls:true
       ~tools_present:true)
;;

(* ── Suite ───────────────────────────────────────────── *)

let () =
  run
    "Capabilities_Wiring"
    [ ( "filter"
      , [ test_case
            "effective parallel tool disable"
            `Quick
            test_effective_disable_parallel_tool_use
        ] )
    ]
;;
