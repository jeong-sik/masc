(** The publication order of [Tool_shard_types.voice_tools].

    Everything else this suite held was a copy. The declarations live in
    [config/tools/*.toml], [Tool_shard_types.voice_tools] is those files decoded, and the expected
    descriptions and schemas were literals read off that same list before the
    move -- one producer compared against a hand-written snapshot of itself.
    Those cases are gone.

    Order is not in the TOML. It is the order of the OCaml list above, and
    #34379 is the open question about what changed it, so it stays. *)

open Alcotest

let expected =
  [ "keeper_voice_speak"
  ; "keeper_voice_listen"
  ; "keeper_voice_agent"
  ; "keeper_voice_sessions"
  ; "keeper_voice_session_start"
  ; "keeper_voice_session_end"
  ]
;;

let published = Tool_shard_types.voice_tools

let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_shard_types.voice_tools in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let () =
  run
    "voice_tool_toml_parity"
    [ ( "order"
      , [ test_case "the published order is unchanged" `Quick
            test_the_published_order_is_unchanged
        ] )
    ]
;;
