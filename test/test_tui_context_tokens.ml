(* The context inspector reads every size in tokens. The window a request
   has to fit is sized in tokens and the provider counts tokens; bytes are
   what masc could measure before dispatch. So each composition row carries
   an estimated token figure, the serialized request band leads with the
   provider's own count, and the bytes stand once under the rows beside the
   sentence that names where the ratio came from: this turn's own wire body
   over its per-request count, else the median of the page, else the fleet
   figure. *)

let record ?(tokens = Some 18_000) ~wire ~scope () : Turn_record.t =
  { execution_ids = []
  ; keeper = "alpha"
  ; agent_name = "alpha-agent"
  ; turn_kind = Turn_record.Autonomous
  ; trace_id = "trace-1780648779957-00000"
  ; absolute_turn = 4071
  ; turn_ref =
      Ids.Turn_ref.make ~trace_id:"trace-1780648779957-00000" ~absolute_turn:4071
  ; blocks = []
  ; input_components =
      Some
        [ { component = Turn_record.Tool_schemas; bytes = 8192 }
        ; { component = Turn_record.Message_user; bytes = 256 }
        ]
  ; tool_surface_ref = None
  ; runtime_profile = "ollama_cloud.deepseek-v4-flash"
  ; selected_model = Some "deepseek-v4-flash"
  ; finish_reason = Some "completed"
  ; context_window = Some 131072
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = None
  ; ttfrc_ms = None
  ; request_wire_observation =
      Option.map
        (fun body_bytes ->
          { Turn_record.runtime_profile = "ollama_cloud.deepseek-v4-flash"
          ; body_bytes
          })
        wire
  ; model_input_window = None
  ; response_observed_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
  ; usage =
      { input_tokens = tokens
      ; output_tokens = Some 412
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope
      }
  ; turn_output_tokens = None
  ; ts = 1781200000.5
  }

let per_request = Runtime_usage_scope.Per_request

let test_this_turn_outranks_the_page () =
  let turn = record ~wire:(Some 560_513) ~scope:per_request () in
  let other = record ~tokens:(Some 100_000) ~wire:(Some 300_000) ~scope:per_request () in
  match Masc_tui_token_scale.of_turn ~rows:[ turn; other ] turn with
  | { Masc_tui_token_scale.basis = This_turn { wire_bytes = 560_513; tokens = 18_000 }; _ } -> ()
  | { basis = This_turn _ | Keeper_page _ | Fleet_measured _; _ } ->
      Alcotest.fail "the record's own body and count set the scale"

let () =
  Alcotest.run "tui_context_tokens"
    [ ( "composition"
      , [] )
    ; ( "serialized request"
      , [] )
    ; ( "history reach"
      , [] )
    ; ( "token scale"
      , [ Alcotest.test_case "this turn outranks the page" `Quick
            test_this_turn_outranks_the_page
        ] )
    ]
