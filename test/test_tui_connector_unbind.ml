open Alcotest
module Unbind = Masc_tui_connector_unbind

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
                [ binding "111" "unbind-fixture-keeper"; binding "222" "other"
                ; binding "333" "unbind-fixture-keeper" ]
            ; connector "slack" [ binding "C9" "unbind-fixture-keeper" ]
            ] )
      ; ("total", `Int 2)
      ; ("active_count", `Int 2)
      ]
  in
  match Masc.Tui_decode_connectors.decode_connector_snapshot json with
  | Error reason -> fail reason
  | Ok snapshot ->
      let named (connector : Masc.Tui_decode_connectors.connector) =
        let page =
          { Masc.Tui_decode_connectors.cnp_connector_id = connector.cn_id
          ; cnp_kind = Masc.Tui_decode_connectors.Connector_channel_name
          ; cnp_mapping_scope = "workspace"
          ; cnp_current_workspace_id = None
          ; cnp_path = "names"
          ; cnp_after_id = None
          ; cnp_next_after_id = None
          ; cnp_total = 1
          ; cnp_has_more = false
          ; cnp_mappings =
              [ { Masc.Tui_decode_connectors.cnm_kind = Masc.Tui_decode_connectors.Connector_channel_name
                ; cnm_id = "111"
                ; cnm_name = "general"
                } ]
          }
        in
        Masc.Tui_decode_connectors.connector_with_name_pages connector ~pages:[ page ] ~error:None
      in
      List.map named snapshot.cs_connectors

let test_targets_are_the_keepers_bindings_on_every_transport () =
  let targets = Unbind.targets ~keeper_name:"unbind-fixture-keeper" (snapshot ()) in
  check (list string) "every unbind-fixture-keeper binding, none of the others"
    [ "discord/111"; "discord/333"; "slack/C9" ]
    (List.map
       (fun (t : Unbind.target) -> t.connector_id ^ "/" ^ t.channel_id)
       targets);
  check bool "each carries the owner it is conditional on" true
    (List.for_all
       (fun (t : Unbind.target) -> String.equal t.keeper_name "unbind-fixture-keeper")
       targets)

let test_labels_name_the_channel_or_say_the_name_is_unknown () =
  let labels =
    List.map Unbind.target_label
      (Unbind.targets ~keeper_name:"unbind-fixture-keeper" (snapshot ()))
  in
  check (list string) "known name with id, unknown name said so"
    [ "general (111)"; "333 (name not reported)"; "C9 (name not reported)" ]
    labels;
  check bool "a line break in a name does not reach the terminal" false
    (String.contains
       (Unbind.channel_label ~ko:false ~channel_id:"1" ~channel_name:(Some "a\nb"))
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
  match Masc.Tui_decode_connectors.decode_connector_snapshot json with
  | Error reason -> fail reason
  | Ok snapshot ->
      let unreadable = Unbind.unreadable_transports snapshot.cs_connectors in
      check (list string) "the unreadable transport" [ "Slack" ] unreadable;
      check string "no readable binding is not called none"
        "unbind all: unbind-fixture-keeper has no channel bindings; not included, binding \
         list unreadable: Slack"
        (Unbind.nothing_to_unbind ~keeper_name:"unbind-fixture-keeper" ~unreadable)

let offer_reading =
  testable
    (fun formatter reading ->
       Format.pp_print_string formatter
         (match reading with
          | Unbind.Offer_waits -> "Offer_waits"
          | Unbind.Offer_accepted -> "Offer_accepted"
          | Unbind.Offer_dropped -> "Offer_dropped"))
    ( = )

(* The offer was made while frame 4 was the last one presented. *)
let offer_at_frame_4 () =
  { Unbind.offer_keeper = "unbind-fixture-keeper"
  ; offer_targets = Unbind.targets ~keeper_name:"unbind-fixture-keeper" (snapshot ())
  ; offered_at = 4
  }

let test_offer_is_not_the_runtime_picker_key () =
  (* #38191 review: on the Keeper list [U] opens the runtime picker, and an
     operator who pauses and then picks another runtime must not lose the
     Keeper's channels. *)
  check bool "the offer key is not unbind-all's U" false
    (String.equal Unbind.offer_key Unbind.unbind_all_key);
  check offer_reading "U after the offer was drawn drops it"
    Unbind.Offer_dropped
    (Unbind.read_offer_input (offer_at_frame_4 ()) ~frames_presented:5
       ~input_seen:true ~key:(Some "U"))

let test_offer_takes_its_key_only_after_it_was_drawn () =
  let offer = offer_at_frame_4 () in
  check offer_reading "its key, read after a later frame, takes it"
    Unbind.Offer_accepted
    (Unbind.read_offer_input offer ~frames_presented:5 ~input_seen:true
       ~key:(Some Unbind.offer_key));
  check offer_reading "its key, read before the offer reached the screen"
    Unbind.Offer_dropped
    (Unbind.read_offer_input offer ~frames_presented:4 ~input_seen:true
       ~key:(Some Unbind.offer_key));
  check offer_reading "a mouse report or paste drops it" Unbind.Offer_dropped
    (Unbind.read_offer_input offer ~frames_presented:5 ~input_seen:true
       ~key:None);
  check offer_reading "a turn that read nothing leaves it" Unbind.Offer_waits
    (Unbind.read_offer_input offer ~frames_presented:9 ~input_seen:false
       ~key:None)

let next_press =
  testable
    (fun formatter press ->
       let ids targets =
         String.concat ", "
           (List.map
              (fun (t : Unbind.target) -> t.connector_id ^ "/" ^ t.channel_id)
              targets)
       in
       Format.pp_print_string formatter
         (match press with
          | Unbind.Nothing_bound -> "Nothing_bound"
          | Unbind.Asks targets -> "Asks [" ^ ids targets ^ "]"
          | Unbind.Sends targets -> "Sends [" ^ ids targets ^ "]"))
    ( = )

(* The fixture Keeper's list with its first binding missing: what an arm made
   before that binding was bound holds. *)
let all_but_first targets =
  match targets with
  | _ :: rest -> rest
  | [] -> fail "the fixture Keeper holds bindings"

let test_second_press_sends_only_the_list_it_named () =
  let keeper_name = "unbind-fixture-keeper" in
  let targets = Unbind.targets ~keeper_name (snapshot ()) in
  check next_press "nothing named: the press names the list" (Unbind.Asks targets)
    (Unbind.next_press ~named:None ~keeper_name targets);
  check next_press "named this list for this Keeper: the press sends it"
    (Unbind.Sends targets)
    (Unbind.next_press ~named:(Some (keeper_name, targets)) ~keeper_name targets);
  check next_press "named for another Keeper: names this Keeper's list"
    (Unbind.Asks targets)
    (Unbind.next_press ~named:(Some ("other", targets)) ~keeper_name targets);
  check next_press "a binding appeared since: names the new list, sends nothing"
    (Unbind.Asks targets)
    (Unbind.next_press
       ~named:(Some (keeper_name, all_but_first targets))
       ~keeper_name targets);
  check next_press "no binding left" Unbind.Nothing_bound
    (Unbind.next_press ~named:(Some (keeper_name, targets)) ~keeper_name [])

(* Every binding on every transport as the Channels tab marks it: the key
   that removes it, or "-". *)
let marks confirmation connectors =
  List.concat_map
    (fun (connector : Masc.Tui_decode_connectors.connector) ->
       List.map
         (fun (binding : Masc.Tui_decode_connectors.connector_binding) ->
            let mark =
              match Unbind.row_mark confirmation connector binding with
              | Unbind.Will_unbind key -> key
              | Unbind.Not_targeted -> "-"
            in
            connector.cn_id ^ "/" ^ binding.cb_channel_id ^ ":" ^ mark)
         connector.cn_bindings)
    connectors

let test_marked_rows_are_the_ones_the_key_sends () =
  let keeper_name = "unbind-fixture-keeper" in
  let connectors = snapshot () in
  let targets = Unbind.targets ~keeper_name connectors in
  let marks_for ~armed ~offer =
    marks (Unbind.confirmation ~armed ~offer ~keeper_name targets) connectors
  in
  let marked_by key =
    [ "discord/111:" ^ key; "discord/222:-"; "discord/333:" ^ key; "slack/C9:" ^ key ]
  in
  let unmarked = [ "discord/111:-"; "discord/222:-"; "discord/333:-"; "slack/C9:-" ] in
  check (list string)
    "armed for this Keeper: each of its bindings on every transport, not the other Keeper's"
    (marked_by Unbind.unbind_all_key)
    (marks_for ~armed:(Some (keeper_name, targets)) ~offer:None);
  check (list string) "the pause offer marks the same bindings with its own key"
    (marked_by Unbind.offer_key)
    (marks_for ~armed:None ~offer:(Some (offer_at_frame_4 ())));
  check (list string) "nothing armed or offered" unmarked
    (marks_for ~armed:None ~offer:None);
  check (list string) "armed for another Keeper" unmarked
    (marks_for
       ~armed:(Some ("other", Unbind.targets ~keeper_name:"other" connectors))
       ~offer:None);
  check (list string) "armed with a list the snapshot no longer holds: U asks again"
    unmarked
    (marks_for ~armed:(Some (keeper_name, all_but_first targets)) ~offer:None)

let () =
  run "masc_tui_connector_unbind"
    [ ( "unbind all"
      , [ test_case "targets span transports" `Quick
            test_targets_are_the_keepers_bindings_on_every_transport
        ; test_case "labels" `Quick
            test_labels_name_the_channel_or_say_the_name_is_unknown
        ; test_case "statuses" `Quick
            test_statuses_split_rebound_and_gone_from_failure
        ; test_case "unreadable transport" `Quick
            test_an_unreadable_transport_is_named
        ; test_case "offer key is not U" `Quick
            test_offer_is_not_the_runtime_picker_key
        ; test_case "offer takes a key read after it was drawn" `Quick
            test_offer_takes_its_key_only_after_it_was_drawn
        ; test_case "second press sends only the list it named" `Quick
            test_second_press_sends_only_the_list_it_named
        ; test_case "marked rows are the ones the key sends" `Quick
            test_marked_rows_are_the_ones_the_key_sends
        ;] )
    ]
