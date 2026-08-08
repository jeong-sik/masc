(** Property-based tests using QCheck.
    Tests round-trip properties, commutativity, and invariants. *)

open Agent_sdk
open Types

(* --- Generators --- *)

let model_gen =
  QCheck.Gen.oneof
    [ QCheck.Gen.return "claude-opus-4-6"
    ; QCheck.Gen.return "claude-sonnet-4-6"
    ; QCheck.Gen.return "claude-opus-4-5"
    ; QCheck.Gen.return "claude-sonnet-4"
    ; QCheck.Gen.return "claude-haiku-4-5"
    ; QCheck.Gen.return "claude-3-7-sonnet"
    ; QCheck.Gen.string_printable
    ]
;;

let role_gen = QCheck.Gen.oneof [ QCheck.Gen.return User; QCheck.Gen.return Assistant ]

let param_type_gen =
  QCheck.Gen.oneof
    [ QCheck.Gen.return String
    ; QCheck.Gen.return Integer
    ; QCheck.Gen.return Number
    ; QCheck.Gen.return Boolean
    ; QCheck.Gen.return Array
    ; QCheck.Gen.return Object
    ]
;;

let api_usage_gen =
  QCheck.Gen.(
    let* input_tokens = int_range 0 100_000 in
    let* output_tokens = int_range 0 100_000 in
    let* cache_creation_input_tokens = int_range 0 10_000 in
    let* cache_read_input_tokens = int_range 0 10_000 in
    return
      { input_tokens
      ; output_tokens
      ; cache_creation_input_tokens
      ; cache_read_input_tokens
      ; cost_usd = None
      })
;;

(* --- Properties --- *)

(* model yojson round-trip: to_yojson -> of_yojson = identity *)
let test_model_roundtrip =
  QCheck.Test.make
    ~count:200
    ~name:"model yojson round-trip"
    (QCheck.make model_gen ~print:show_model)
    (fun m ->
       match model_of_yojson (model_to_yojson m) with
       | Ok m' -> m = m'
       | Error _ -> false)
;;

(* role yojson round-trip *)
let test_role_roundtrip =
  QCheck.Test.make
    ~count:50
    ~name:"role yojson round-trip"
    (QCheck.make role_gen ~print:show_role)
    (fun r ->
       match role_of_yojson (role_to_yojson r) with
       | Ok r' -> r = r'
       | Error _ -> false)
;;

(* param_type yojson round-trip *)
let test_param_type_roundtrip =
  QCheck.Test.make
    ~count:50
    ~name:"param_type yojson round-trip"
    (QCheck.make param_type_gen ~print:show_param_type)
    (fun p ->
       match param_type_of_yojson (param_type_to_yojson p) with
       | Ok p' -> p = p'
       | Error _ -> false)
;;

(* Unknown model: model_to_string returns the string unchanged *)
let test_custom_model_identity =
  QCheck.Test.make
    ~count:200
    ~name:"unknown model_to_string identity"
    QCheck.string_printable
    (fun s -> model_to_string s = s)
;;

(* add_usage commutativity: order of accumulation yields same totals *)
let test_usage_commutativity =
  QCheck.Test.make
    ~count:200
    ~name:"add_usage commutativity"
    (QCheck.make
       QCheck.Gen.(pair api_usage_gen api_usage_gen)
       ~print:(fun (a, b) ->
         Printf.sprintf "(%s, %s)" (show_api_usage a) (show_api_usage b)))
    (fun (a, b) ->
       let s_ab = add_usage (add_usage empty_usage a) b in
       let s_ba = add_usage (add_usage empty_usage b) a in
       s_ab.total_input_tokens = s_ba.total_input_tokens
       && s_ab.total_output_tokens = s_ba.total_output_tokens
       && s_ab.total_cache_creation_input_tokens = s_ba.total_cache_creation_input_tokens
       && s_ab.total_cache_read_input_tokens = s_ba.total_cache_read_input_tokens
       && s_ab.api_calls = s_ba.api_calls)
;;

(* add_usage: api_calls always increments by 1 per add *)
let test_usage_api_calls_increment =
  QCheck.Test.make
    ~count:200
    ~name:"add_usage increments api_calls"
    (QCheck.make api_usage_gen ~print:show_api_usage)
    (fun u ->
       let s = add_usage empty_usage u in
       s.api_calls = 1)
;;

(* stop_reason round-trip for known reasons *)
let test_known_stop_reasons_stable =
  QCheck.Test.make
    ~count:50
    ~name:"known stop_reason strings are stable"
    (QCheck.make
       (QCheck.Gen.oneof
          [ QCheck.Gen.return "end_turn"
          ; QCheck.Gen.return "tool_use"
          ; QCheck.Gen.return "max_tokens"
          ; QCheck.Gen.return "stop_sequence"
          ]))
    (fun s ->
       match stop_reason_of_string s with
       | Unknown _ -> false
       | _ -> true)
;;

(* --- Runner --- *)

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ test_model_roundtrip
      ; test_role_roundtrip
      ; test_param_type_roundtrip
      ; test_custom_model_identity
      ; test_usage_commutativity
      ; test_usage_api_calls_increment
      ; test_known_stop_reasons_stable
      ]
  in
  Alcotest.run "property" [ "round-trip", suite ]
;;
