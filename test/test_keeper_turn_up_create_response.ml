open Alcotest
open Masc

let envelope ?(sandbox_profile = Keeper_types_profile.Micro_vm)
    ?(network_mode = Keeper_types_profile.Network_none) () =
  Keeper_turn_up_create.create_response_json
    ~name:"pr-updater"
    ~trace_id:"trace-1"
    ~instructions:"manage open PRs on github.com"
    ~proactive_enabled:true
    ~max_context_override:None
    ~sandbox_profile
    ~network_mode
    ~agent_core_env:[]
;;

let field key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_field key json =
  match field key json with
  | Some (`String value) -> value
  | Some other -> failf "%s: expected a string, got %s" key (Yojson.Safe.to_string other)
  | None -> failf "%s: absent from the create envelope" key
;;

(* The incident this closes: a keeper was created through masc_keeper_up with
   instructions that name GitHub, took microvm's default of no network, and
   said nothing about it. The block first surfaced two hours later, inside the
   guest, as a credential error. *)
let test_envelope_names_the_isolation_the_keeper_landed_on () =
  let json = envelope () in
  check string "sandbox_profile" "microvm" (string_field "sandbox_profile" json);
  check string "network_mode" "none" (string_field "network_mode" json)
;;

(* network_mode is dashboard-owned and stays undeclared on the MCP contract
   (test_tool_input_validation pins that). So the envelope is a report, not an
   echo: it must follow the meta, whatever the meta says. *)
let test_envelope_follows_the_meta_not_a_default () =
  let json =
    envelope ~sandbox_profile:Keeper_types_profile.Remote_ssh
      ~network_mode:Keeper_types_profile.Network_inherit ()
  in
  check string "sandbox_profile" "remote_ssh" (string_field "sandbox_profile" json);
  check string "network_mode" "inherit" (string_field "network_mode" json)
;;

(* The fields the envelope already carried stay carried: adding a report must
   not narrow what a caller could already read. *)
let test_envelope_keeps_its_existing_fields () =
  let json = envelope () in
  check string "name" "pr-updater" (string_field "name" json);
  check string "agent_name" "pr-updater" (string_field "agent_name" json);
  check string "trace_id" "trace-1" (string_field "trace_id" json);
  check string "instructions" "manage open PRs on github.com"
    (string_field "instructions" json);
  check bool "proactive_enabled present" true
    (Option.is_some (field "proactive_enabled" json));
  check bool "max_context_override present" true
    (Option.is_some (field "max_context_override" json));
  check bool "agent_core_env present" true
    (Option.is_some (field "agent_core_env" json))
;;

let () =
  run
    "keeper_turn_up_create_response"
    [ ( "isolation"
      , [ test_case "envelope names the isolation the keeper landed on" `Quick
            test_envelope_names_the_isolation_the_keeper_landed_on
        ; test_case "envelope follows the meta, not a default" `Quick
            test_envelope_follows_the_meta_not_a_default
        ; test_case "envelope keeps its existing fields" `Quick
            test_envelope_keeps_its_existing_fields
        ] )
    ]
;;
