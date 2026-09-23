open Alcotest
module Unbind = Masc_tui_connector_unbind
module Reading = Masc.Tui_decode

(* Connectors read through the same decoder the TUI reads them through, then
   given names the way the loader gives them. *)
let snapshot () =
  let binding channel keeper =
    `Assoc [ ("channel_id", `String channel); ("keeper_name", `String keeper) ]
  in
  let connector id bindings =
    `Assoc
      [ ("connector_id", `String id)
      ; ("display_name", `String (String.capitalize_ascii id))
      ; ("status", `String "connected")
      ; ("available", `Bool true)
      ; ("connected", `Bool true)
      ; ("configured_bindings", `List bindings)
      ]
  in
  let json =
    `Assoc
      [ ( "connectors"
        , `List
            [ connector "discord"
                [ binding "111" "sangsu"; binding "222" "other"
                ; binding "333" "sangsu" ]
            ; connector "slack" [ binding "C9" "sangsu" ]
            ] )
      ; ("total", `Int 2)
      ; ("active_count", `Int 2)
      ]
  in
  match Reading.decode_connector_snapshot json with
  | Error reason -> fail reason
  | Ok snapshot ->
      let named (connector : Reading.connector) =
        let page =
          { Reading.cnp_connector_id = connector.cn_id
          ; cnp_kind = Reading.Connector_channel_name
          ; cnp_mapping_scope = "workspace"
          ; cnp_current_workspace_id = None
          ; cnp_path = "names"
          ; cnp_after_id = None
          ; cnp_next_after_id = None
          ; cnp_total = 1
          ; cnp_has_more = false
          ; cnp_mappings =
              [ { Reading.cnm_kind = Reading.Connector_channel_name
                ; cnm_id = "111"
                ; cnm_name = "general"
                } ]
          }
        in
        Reading.connector_with_name_pages connector ~pages:[ page ] ~error:None
      in
      List.map named snapshot.cs_connectors

let test_targets_are_the_keepers_bindings_on_every_transport () =
  let targets = Unbind.targets ~keeper_name:"sangsu" (snapshot ()) in
  check (list string) "every sangsu binding, none of the others"
    [ "discord/111"; "discord/333"; "slack/C9" ]
    (List.map
       (fun (t : Unbind.target) -> t.connector_id ^ "/" ^ t.channel_id)
       targets);
  check bool "each carries the owner it is conditional on" true
    (List.for_all
       (fun (t : Unbind.target) -> String.equal t.keeper_name "sangsu")
       targets)

let test_labels_name_the_channel_or_say_the_name_is_unknown () =
  let labels =
    List.map Unbind.target_label
      (Unbind.targets ~keeper_name:"sangsu" (snapshot ()))
  in
  check (list string) "known name with id, unknown name said so"
    [ "general (111)"; "333 (name unknown)"; "C9 (name unknown)" ]
    labels;
  check bool "a line break in a name does not reach the terminal" false
    (String.contains
       (Unbind.channel_label ~channel_id:"1" ~channel_name:(Some "a\nb"))
       '\n')

let test_statuses_split_rebound_and_gone_from_failure () =
  let outcome status = Unbind.outcome_of_status ~status ~refusal:"why" in
  check bool "2xx removed" true (outcome 200 = Unbind.Removed);
  check bool "409 rebound" true (outcome 409 = Unbind.Rebound);
  check bool "404 keeps the server's words, not a claim of already gone" true
    (outcome 404 = Unbind.Not_found "why");
  check bool "500 failed with the refusal" true
    (outcome 500 = Unbind.Failed "why");
  check bool "401 failed with the refusal" true
    (outcome 401 = Unbind.Failed "why")

let test_a_partial_result_is_not_reported_as_whole () =
  let targets = Unbind.targets ~keeper_name:"sangsu" (snapshot ()) in
  let results =
    List.combine targets
      [ Unbind.Failed "HTTP 500"; Unbind.Rebound; Unbind.Removed ]
  in
  check string "the summary counts each kind and names the failures"
    "unbind all of sangsu: 1 removed, 1 kept, 0 not found, 1 failed -- \
     general (111)"
    (Unbind.summary ~keeper_name:"sangsu" results);
  check bool "a failure is flagged" true (Unbind.any_failed results);
  check (list string) "one line per binding, failures last"
    [ "unbind Slack C9 (name unknown): removed"
    ; "unbind Discord 333 (name unknown): kept: now bound to another Keeper"
    ; "unbind Discord general (111): FAILED: HTTP 500"
    ]
    (List.map Unbind.outcome_line (Unbind.report_order results))

let test_arm_prompt_names_every_channel () =
  let targets = Unbind.targets ~keeper_name:"sangsu" (snapshot ()) in
  check string "count, keeper and each label"
    "unbind all armed: press U again to remove 3 bindings of sangsu: general \
     (111), 333 (name unknown), C9 (name unknown)"
    (Unbind.arm_prompt ~keeper_name:"sangsu" ~confirm_key:"U" ~unreadable:[]
       targets)

(* A transport whose binding store the server could not read has unknown
   bindings. It cannot be a target, and the prompts must not read as if it
   held none. *)
let test_an_unreadable_transport_is_named () =
  let json =
    `Assoc
      [ ( "connectors"
        , `List
            [ `Assoc
                [ ("connector_id", `String "slack")
                ; ("display_name", `String "Slack")
                ; ("status", `String "connected")
                ; ("available", `Bool true)
                ; ("connected", `Bool true)
                ; ("binding_store_read_ok", `Bool false)
                ; ("configured_bindings", `List [])
                ] ] )
      ; ("total", `Int 1)
      ; ("active_count", `Int 1)
      ]
  in
  match Reading.decode_connector_snapshot json with
  | Error reason -> fail reason
  | Ok snapshot ->
      let unreadable = Unbind.unreadable_transports snapshot.cs_connectors in
      check (list string) "the unreadable transport" [ "Slack" ] unreadable;
      check string "no readable binding is not called none"
        "unbind all: sangsu has no channel bindings; not included, binding \
         list unreadable: Slack"
        (Unbind.nothing_to_unbind ~keeper_name:"sangsu" ~unreadable)

let test_offer_leads_with_the_key () =
  let targets = Unbind.targets ~keeper_name:"sangsu" (snapshot ()) in
  check string "key first, then the channels"
    "U: also unbind sangsu's 3 channels, or any other key to keep them -- \
     general (111), 333 (name unknown), C9 (name unknown); not included, \
     binding list unreadable: Teams"
    (Unbind.offer_prompt ~keeper_name:"sangsu" ~confirm_key:"U"
       ~unreadable:[ "Teams" ] targets)

let () =
  run "masc_tui_connector_unbind"
    [ ( "unbind all"
      , [ test_case "targets span transports" `Quick
            test_targets_are_the_keepers_bindings_on_every_transport
        ; test_case "labels" `Quick
            test_labels_name_the_channel_or_say_the_name_is_unknown
        ; test_case "statuses" `Quick
            test_statuses_split_rebound_and_gone_from_failure
        ; test_case "partial result" `Quick
            test_a_partial_result_is_not_reported_as_whole
        ; test_case "arm prompt" `Quick test_arm_prompt_names_every_channel
        ; test_case "unreadable transport" `Quick
            test_an_unreadable_transport_is_named
        ; test_case "pause offer" `Quick test_offer_leads_with_the_key
        ] )
    ]
