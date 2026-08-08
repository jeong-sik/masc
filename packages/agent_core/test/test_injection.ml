(** Tests for context injection hooks. *)

open Alcotest
open Agent_sdk

(* Test injection type construction *)
let test_injection_type () =
  let inj : Hooks.injection =
    { context_updates = [ "key1", `String "value1"; "key2", `Int 42 ]
    ; extra_messages =
        [ Types.
            { role = User
            ; content = [ Text "injected observation" ]
            ; name = None
            ; tool_call_id = None
            ; metadata = []
            }
        ]
    }
  in
  check int "2 context updates" 2 (List.length inj.context_updates);
  check int "1 extra message" 1 (List.length inj.extra_messages)
;;

let test_empty_injection () =
  let inj : Hooks.injection = { context_updates = []; extra_messages = [] } in
  check int "no updates" 0 (List.length inj.context_updates);
  check int "no messages" 0 (List.length inj.extra_messages)
;;

(* Test injector function type *)
let test_injector_returns_some () =
  let injector : Hooks.context_injector =
    fun ~tool_name ~input:_ ~output:_ ->
    if tool_name = "bash"
    then
      Some
        { Hooks.context_updates = [ "last_bash_cwd", `String "/tmp" ]
        ; extra_messages = []
        }
    else None
  in
  (match
     injector
       ~tool_name:"bash"
       ~input:`Null
       ~output:(Ok { Types.content = "ok"; _meta = None })
   with
   | Some inj -> check int "1 update" 1 (List.length inj.context_updates)
   | None -> fail "expected Some");
  match
    injector
      ~tool_name:"calc"
      ~input:`Null
      ~output:(Ok { Types.content = "42"; _meta = None })
  with
  | Some _ -> fail "expected None for calc"
  | None -> ()
;;

let test_injector_with_extra_messages () =
  let injector : Hooks.context_injector =
    fun ~tool_name:_ ~input:_ ~output:_ ->
    Some
      { Hooks.context_updates = []
      ; extra_messages =
          [ Types.
              { role = User
              ; content = [ Text "[system] git status: clean" ]
              ; name = None
              ; tool_call_id = None
              ; metadata = []
              }
          ]
      }
  in
  match
    injector
      ~tool_name:"any"
      ~input:`Null
      ~output:(Ok { Types.content = ""; _meta = None })
  with
  | Some inj -> check int "1 extra message" 1 (List.length inj.extra_messages)
  | None -> fail "expected Some"
;;

(* Test context updates applied correctly *)
let test_context_updates_applied () =
  let ctx = Context.create_sync () in
  let updates = [ "key1", `String "v1"; "key2", `Bool true ] in
  List.iter (fun (k, v) -> Context.set ctx k v) updates;
  (match Context.get ctx "key1" with
   | Some (`String "v1") -> ()
   | _ -> fail "key1 not set");
  match Context.get ctx "key2" with
  | Some (`Bool true) -> ()
  | _ -> fail "key2 not set"
;;

let () =
  run
    "injection"
    [ ( "type"
      , [ test_case "injection construction" `Quick test_injection_type
        ; test_case "empty injection" `Quick test_empty_injection
        ] )
    ; ( "injector"
      , [ test_case "returns Some for matching tool" `Quick test_injector_returns_some
        ; test_case "extra messages" `Quick test_injector_with_extra_messages
        ] )
    ; "context", [ test_case "updates applied" `Quick test_context_updates_applied ]
    ]
;;
