(* The Overview says the transport is under pressure with one Attention item
   and says nothing while the queue is steady; the readings are on Metrics. *)

open Alcotest
module Types = Masc_tui_types

let reading pressure : Masc.Tui_decode.transport_health =
  { Masc.Tui_decode.th_primary_path = Masc.Transport_metrics.Sse
  ; th_queue_pressure = pressure
  ; th_sse_sessions = 1
  ; th_websocket_sessions = Some 0
  ; th_grpc_port = None
  ; th_events_dropped = 0
  }

let severity_of pressure =
  Option.map
    (fun (item : Types.attention_item) -> item.Types.ai_severity)
    (Masc_tui_render_prim.transport_attention_item (Some (reading pressure)))

let test_only_pressure_raises_an_item () =
  check bool "no reading, no item" true
    (Option.is_none (Masc_tui_render_prim.transport_attention_item None));
  check bool "a steady queue, no item" true
    (Option.is_none (severity_of Masc.Transport_metrics.Steady));
  check bool "watch is a warning" true
    (severity_of Masc.Transport_metrics.Watch = Some Types.Attention_warning);
  check bool "high is bad" true
    (severity_of Masc.Transport_metrics.High = Some Types.Attention_bad)

let test_the_item_names_the_pressure_and_where_to_read_it () =
  match
    Masc_tui_render_prim.transport_attention_item
      (Some (reading Masc.Transport_metrics.High))
  with
  | Some item ->
      check string "summary" "transport queue pressure high (m: Metrics)"
        item.Types.ai_summary;
      (match item.Types.ai_target with
       | Types.Attention_other { target_type; target_id = None } ->
           check string "not a Keeper's item" "transport" target_type
       | Types.Attention_other { target_id = Some _; _ }
       | Types.Attention_keeper _ ->
           fail "the transport item names no Keeper and no id")
  | None -> fail "a high queue raises an item"

let () =
  run "tui_overview_transport_item"
    [ ( "transport"
      , [ test_case "only pressure raises an item" `Quick
            test_only_pressure_raises_an_item
        ; test_case "the item names the pressure and where to read it" `Quick
            test_the_item_names_the_pressure_and_where_to_read_it
        ] )
    ]
