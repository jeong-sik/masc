open Alcotest
open Masc

(* Two RPC refusals look the same on the wire but mean different things to
   the session store. The handshake's account/read runs before
   thread/resume and turn/start, so its refusal touched no session and the
   claim settles as a pre-dispatch failure -- the prior settlement stands.
   A thread/resume refusal is the opposite: that resume really was refused,
   and the next turn starts fresh. (#47706) *)

let recovery classification label expected =
  check string label
    (Keeper_official_client_session_store.recovery_failure_to_string expected)
    (Keeper_official_client_session_store.recovery_failure_to_string classification)

let account_read_refusal_is_pre_dispatch () =
  recovery
    (Keeper_codex_runtime.recovery_failure_of_client_error
       (Runtime_codex_app_server.Account_read_failed
          { code = Some (-32000)
          ; message = "account lookup failed"
          ; data = None
          }))
    "an account/read refusal settles the claim pre-dispatch"
    Keeper_official_client_session_store.Pre_dispatch_failed

let thread_resume_refusal_stays_protocol_failed () =
  recovery
    (Keeper_codex_runtime.recovery_failure_of_client_error
       (Runtime_codex_app_server.Rpc_error
          { method_ = "thread/resume"
          ; code = Some (-32000)
          ; message = "thread not found"
          ; data = None
          }))
    "a thread/resume refusal stays protocol-failed"
    Keeper_official_client_session_store.Protocol_failed

let () =
  run "Codex account read recovery"
    [ ( "recovery classification"
      , [ test_case "an account/read refusal settles pre-dispatch" `Quick
            account_read_refusal_is_pre_dispatch
        ; test_case "a thread/resume refusal stays protocol-failed" `Quick
            thread_resume_refusal_stays_protocol_failed
        ] )
    ]
