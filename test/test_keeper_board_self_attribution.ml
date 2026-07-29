(* Regression for the self-trigger board post loop (PR #26388).

   A keeper's own Board_post_created must NOT be rendered as a pending board
   event in its observation. The live heartbeat path injects stimulus-derived
   events verbatim via the [Some] branch of [observe], and the stimulus
   renderer previously had no self-attribution gate — so the keeper re-observed
   its own freshly-created post as "1 new board activity" every turn and
   re-triggered a reactive post (loop; observed live as 21/22 self-posts in a
   15-min window). This test pins the gate at the SSOT renderer. The
   is_self_author predicate itself (RFC-0038 canonical fold of name/agent_name)
   is covered by existing identity tests; this test pins only the observation
   wiring: a self-authored Board_post_created yields [Ok None] before any board
   read, so no board fixture is required. *)

let test_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
         ; "trace_id", `String ("trace-" ^ name)
         ])
  with
  | Ok meta -> meta
  | Error msg -> Alcotest.failf "meta fixture failed: %s" msg
;;

(* A Board_post_created stimulus whose author equals meta.name (self). The gate
   must fire before any board read, so no board fixture is needed. *)
let self_post_created_stimulus ~author =
  let module K = Keeper_event_queue in
  let bs : K.board_stimulus =
    { kind = K.Post_created
    ; author
    ; title = "echo"
    ; content = "my own post"
    ; hearth = None
    ; updated_at = Some 42.0
    }
  in
  { K.post_id = "p-self"
  ; urgency = K.Normal
  ; arrived_at = 42.0
  ; payload = K.Board_signal bs
  }
;;

let test_self_post_created_echo_is_excluded () =
  let meta = test_meta "alpha" in
  (* author "alpha" == meta.name; is_self_author must hold via RFC-0038 fold. *)
  let stim = self_post_created_stimulus ~author:"alpha" in
  match Masc.Keeper_world_observation.pending_board_event_of_stimulus ~meta stim with
  | Ok None -> ()
  | Ok (Some _) ->
    Alcotest.fail
      "self-authored Board_post_created must be excluded from observation \
       (self-trigger loop regression)"
  | Error _ -> Alcotest.fail "self echo stimulus errored unexpectedly"
;;

(* Same signal but authored by the keeper's agent_name form must also be
   recognized as self (RFC-0038 folds name and agent_name to one canonical id). *)
let test_self_echo_via_agent_name_form () =
  let meta = test_meta "alpha" in
  let stim = self_post_created_stimulus ~author:"keeper-alpha-agent" in
  match Masc.Keeper_world_observation.pending_board_event_of_stimulus ~meta stim with
  | Ok None -> ()
  | Ok (Some _) ->
    Alcotest.fail
      "Board_post_created authored by the agent_name form must also be excluded \
       (RFC-0038 canonical fold regression)"
  | Error _ -> Alcotest.fail "self echo (agent_name form) stimulus errored unexpectedly"
;;

let () =
  Alcotest.run
    "keeper_board_self_attribution"
    [ ( "self_attribution"
      , [ ( "self post_created echo is excluded"
          , `Quick
          , test_self_post_created_echo_is_excluded )
        ; ( "self echo via agent_name form is excluded"
          , `Quick
          , test_self_echo_via_agent_name_form )
        ] )
    ]
;;
