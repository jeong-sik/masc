(* RFC-0468 §3.2: the host-attached speaker of a User message.

   Pinned here:
   1. Codec totality: every speaker round-trips; an unknown kind, an extra
      field or a non-canonical Keeper id is Invalid, never a default.
   2. Classification: no entry is Absent (a message from before the speaker
      existed), two entries are Duplicate.
   3. The entry survives an AGENT_CORE checkpoint round trip unchanged.
   4. An Ask answer's speaker comes from its responder's surface. *)

open Alcotest

module S = Masc.Keeper_input_speaker

let speaker : S.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (Yojson.Safe.to_string (S.to_json t)))
    S.equal

let keeper_id name =
  match Masc.Keeper_identity.Keeper_id.of_string name with
  | Some id -> id
  | None -> fail "keeper id fixture"

let external_speaker =
  S.External
    { S.channel = "slack"; user_id = Some "U042"; user_name = Some "Kim Lee" }

let all_speakers =
  [ S.Person S.Owner
  ; S.Person (S.Keeper (keeper_id "beta"))
  ; S.Person external_speaker
  ; S.Person (S.External { S.channel = "discord"; user_id = None; user_name = None })
  ; S.Host_prompt (S.Autonomous_wake { answered_asks = [] })
  ; S.Host_prompt
      (S.Autonomous_wake
         { answered_asks = [ S.Owner; S.Keeper (keeper_id "beta"); external_speaker ] })
  ]

let test_json_round_trip () =
  List.iter
    (fun value ->
       match S.of_json (S.to_json value) with
       | Ok decoded -> check speaker "round trip" value decoded
       | Error detail -> fail detail)
    all_speakers

let test_invalid_json_is_rejected () =
  let rejected label json =
    match S.of_json json with
    | Ok _ -> failf "%s was accepted" label
    | Error _ -> ()
  in
  rejected "unknown kind" (`Assoc [ "kind", `String "operator" ]);
  rejected "extra field" (`Assoc [ "kind", `String "owner"; "note", `String "x" ]);
  rejected "non-canonical keeper id"
    (`Assoc [ "kind", `String "keeper"; "keeper_id", `String "Beta" ]);
  rejected "missing external user fields"
    (`Assoc [ "kind", `String "external"; "channel", `String "slack" ]);
  rejected "unknown host prompt"
    (`Assoc
        [ "kind", `String "host_prompt"
        ; "host_prompt", `String "scheduled_wake"
        ; "answered_asks", `List []
        ]);
  rejected "host prompt quoting a host prompt"
    (`Assoc
        [ "kind", `String "host_prompt"
        ; "host_prompt", `String "autonomous_wake"
        ; "answered_asks", `List [ S.to_json (S.Host_prompt (S.Autonomous_wake { answered_asks = [] })) ]
        ]);
  rejected "not an object" (`String "owner")

let classification_label = function
  | S.Absent -> "absent"
  | S.Present _ -> "present"
  | S.Invalid _ -> "invalid"
  | S.Duplicate -> "duplicate"

let test_classify () =
  let owner = S.Person S.Owner in
  check string "no entry" "absent" (classification_label (S.classify []));
  check string "other keys only" "absent"
    (classification_label (S.classify [ "agent_core.agent_run_boundary.v1", `Bool true ]));
  (match S.classify (S.metadata owner) with
   | S.Present decoded -> check speaker "stamped" owner decoded
   | other -> failf "expected present, got %s" (classification_label other));
  check string "two entries" "duplicate"
    (classification_label (S.classify (S.metadata owner @ S.metadata owner)));
  check string "undecodable payload" "invalid"
    (classification_label
       (S.classify [ Agent_core.Types.Input_speaker.entry (`String "owner") ]))

let test_checkpoint_round_trip () =
  let wake =
    S.Host_prompt (S.Autonomous_wake { answered_asks = [ S.Owner ] })
  in
  let stamped =
    Agent_core.Types.make_message ~metadata:(S.metadata wake) ~role:Agent_core.Types.User
      [ Agent_core.Types.Text "wake" ]
  in
  let checkpoint : Agent_core.Checkpoint.t =
    { (Masc.Keeper_context_runtime.checkpoint_of_context
         (Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"system"))
      with messages = [ stamped; Agent_core.Types.user_msg "before the speaker existed" ] }
  in
  match
    checkpoint |> Agent_core.Checkpoint.to_json |> Yojson.Safe.to_string
    |> Yojson.Safe.from_string |> Agent_core.Checkpoint.of_json
  with
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok reloaded ->
    (match reloaded.messages with
     | [ first; second ] ->
       check bool "stamped message is unchanged" true (first = stamped);
       (match S.classify first.metadata with
        | S.Present decoded -> check speaker "speaker survives" wake decoded
        | other -> failf "expected present, got %s" (classification_label other));
       check string "old message stays unknown" "absent"
         (classification_label (S.classify second.metadata))
     | messages -> failf "expected two messages, got %d" (List.length messages))

let test_ask_responder () =
  let responder surface =
    { Masc.Keeper_ask.surface; actor_id = Some "actor-1"; display_name = Some "Park" }
  in
  check bool "dashboard answer is the owner" true
    (S.equal (S.Person S.Owner)
       (S.Person (S.of_ask_responder (responder (Masc.Surface_ref.Dashboard { session_id = None })))));
  check bool "agent-surface answer is external, never a guessed Keeper" true
    (S.equal
       (S.Person
          (S.External { S.channel = "agent"; user_id = Some "actor-1"; user_name = Some "Park" }))
       (S.Person (S.of_ask_responder (responder Masc.Surface_ref.Agent))))

let () =
  run "keeper_input_speaker"
    [ ( "codec"
      , [ test_case "every speaker round-trips" `Quick test_json_round_trip
        ; test_case "invalid payloads are rejected" `Quick test_invalid_json_is_rejected
        ; test_case "classify" `Quick test_classify
        ] )
    ; ( "checkpoint"
      , [ test_case "the entry survives a checkpoint round trip" `Quick
            test_checkpoint_round_trip
        ] )
    ; ( "ask", [ test_case "responder surface decides the person" `Quick test_ask_responder ] )
    ]
