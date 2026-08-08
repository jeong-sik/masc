(** [MASC_AGENT_TRANSPORT] carries a closed vocabulary.

    An unrecognized value used to become [Unknown_agent_transport raw].
    Masc_grpc_transport folded that into [Local] on the same arm as [None], so
    a typo and "operator did not set it" reached the runtime as the same
    state, with nothing reported. *)

open Alcotest

module T = Env_config.Transport

let spelling s = T.agent_transport_to_string (T.agent_transport_of_string s)

let accepted_spellings () =
  List.iter
    (fun (raw, expected) -> check string raw expected (spelling raw))
    [ "http", "http"
    ; "grpc", "grpc"
    ; "ws", "ws"
    ; "websocket", "ws"
    ; "webrtc", "webrtc"
    ; "local", "local"
    ; "  GRPC  ", "grpc"
    ]
;;

(* Whatever the operator typed, the value leaving the parser must be one the
   runtime knows. *)
let unknown_input_stays_in_vocabulary () =
  List.iter
    (fun raw ->
       check
         bool
         ("in vocabulary: " ^ raw)
         true
         (List.mem (spelling raw) [ "http"; "grpc"; "ws"; "webrtc"; "local" ]))
    [ "gprc"; "web-rtc"; "tcp"; ""; "http2" ]
;;

let unknown_reads_as_local () = check string "typo" "local" (spelling "gprc")

let () =
  run
    "agent_transport_vocabulary"
    [ ( "vocabulary"
      , [ test_case "accepted spellings map as documented" `Quick accepted_spellings
        ; test_case "unknown input stays in vocabulary" `Quick unknown_input_stays_in_vocabulary
        ; test_case "unknown input reads as local" `Quick unknown_reads_as_local
        ] )
    ]
;;
