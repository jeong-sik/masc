(* RFC replayed-tool-results-carry-their-time, D2 and D3. The v5 context codec
   writes when a Tool message's results entered the conversation as
   [result_time], and their age only when it renders a session start. *)

open Alcotest
module Codec = Masc.Keeper_official_client_context_codec
module Appended_at = Agent_core.Types.Tool_results_appended_at

(* 2026-11-14T08:06:49.25Z, when the result replayed on 11-14 was appended. *)
let appended_at = 1_794_643_609.25

(* 14,399.3 s later. The age rounds to 14,399 s, which reads as 3h59m. *)
let started_at = appended_at +. 14_399.3

let tool ~metadata =
  Agent_core.Types.make_message
    ~metadata
    ~role:Agent_core.Types.Tool
    [ Agent_core.Types.ToolResult
        { tool_use_id = "call_1"
        ; content = "lane down"
        ; outcome = Agent_core.Types.Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ]
;;

let stamped = tool ~metadata:[ Appended_at.entry ~appended_at ]
let json = testable Yojson.Safe.pp Yojson.Safe.equal

let field name rendering message =
  match Codec.message_to_json rendering message with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> fail "an encoded message is not an object"
;;

let recorded = [ "state", `String "recorded"; "appended_at", `String "2026-11-14T08:06:49Z" ]

let test_a_recorded_time_and_its_age () =
  check
    (option json)
    "canonical source: the time and no age"
    (Some (`Assoc recorded))
    (field "result_time" Codec.Canonical_source stamped);
  check
    (option json)
    "session start: the time and its age then"
    (Some
       (`Assoc
           (recorded
            @ [ "age_at_session_start", `String "3h59m"; "age_seconds", `Int 14_399 ])))
    (field "result_time" (Codec.Session_start { started_at }) stamped);
  check
    (option json)
    "a start before the append reads as no age, not a negative one"
    (Some (`Assoc (recorded @ [ "age_at_session_start", `String "0s"; "age_seconds", `Int 0 ])))
    (field "result_time" (Codec.Session_start { started_at = appended_at -. 5. }) stamped)
;;

let test_the_other_states () =
  let check_state label expected metadata =
    List.iter
      (fun rendering ->
         check
           (option json)
           label
           (Some (`Assoc [ "state", `String expected ]))
           (field "result_time" rendering (tool ~metadata)))
      [ Codec.Canonical_source; Codec.Session_start { started_at } ]
  in
  check_state "no stamp is unrecorded" "unrecorded" [];
  check_state
    "a stamp that is not a float is shown as broken"
    "invalid"
    [ Appended_at.key, `String "2026-11-14T08:06:49Z" ];
  check_state
    "two stamps are shown as broken"
    "duplicate"
    [ Appended_at.entry ~appended_at; Appended_at.entry ~appended_at ];
  check
    (option json)
    "only a Tool message carries result_time"
    None
    (field
       "result_time"
       (Codec.Session_start { started_at })
       (Agent_core.Types.make_message ~role:Agent_core.Types.Assistant [ Text "done" ]))
;;

let test_the_raw_key_stays_out () =
  List.iter
    (fun rendering ->
       check (option json) "metadata" (Some (`Assoc [])) (field "metadata" rendering stamped))
    [ Codec.Canonical_source; Codec.Session_start { started_at } ]
;;

(* A stored session is compared against this digest. The other digest test
   uses messages that render alike either way, so it cannot tell which text
   the digest covers; a recorded Tool message can. *)
let test_the_digest_is_of_the_canonical_text () =
  let spelled rendering =
    `Assoc [ "system_prompt", `String "p"; "messages", `List [ Codec.to_json rendering stamped ] ]
    |> Yojson.Safe.to_string
    |> Agent_core_sha256.digest_string
    |> Agent_core_sha256.to_hex
  in
  let digest = Codec.canonical_source_sha256 ~system_prompt:"p" ~messages:[ stamped ] ~rest:[] in
  check string "the canonical source" (spelled Codec.Canonical_source) digest;
  check
    bool
    "not a session start"
    false
    (String.equal digest (spelled (Codec.Session_start { started_at })))
;;

let test_the_host_start_encoding_is_the_codec's () =
  check
    string
    "encode_start_message"
    (Codec.encode (Codec.Session_start { started_at }) stamped)
    (Masc.Keeper_official_client_host.encode_start_message ~started_at stamped);
  check
    string
    "encode_history_message"
    (Codec.encode Codec.Canonical_source stamped)
    (Masc.Keeper_official_client_host.encode_history_message stamped)
;;

let () =
  run
    "official client result time"
    [ ( "result_time"
      , [ test_case "a recorded time and its age" `Quick test_a_recorded_time_and_its_age
        ; test_case "the other states" `Quick test_the_other_states
        ; test_case "the raw key stays out" `Quick test_the_raw_key_stays_out
        ; test_case
            "the digest is of the canonical text"
            `Quick
            test_the_digest_is_of_the_canonical_text
        ; test_case
            "the host start encoding is the codec's"
            `Quick
            test_the_host_start_encoding_is_the_codec's
        ] )
    ]
;;
