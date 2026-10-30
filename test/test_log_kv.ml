(* A log line is read by people and by models, and both pay per token. A field
   the producer did not measure is left out rather than rendered as [-]: every
   turn of a lane that never reports a cache carried [cache_n=-] and
   [prompt_n=-] (2026-09-09). [0] and [false] are values and stay. *)

let render = Log.Kv.render

let test_absent_fields_are_omitted () =
  Alcotest.(check string)
    "None is dropped and order is kept"
    "turn=3 tokens=10"
    (render [ Log.Kv.int "turn" 3; Log.Kv.opt "cache_n" None; Log.Kv.int "tokens" 10 ])
;;

let test_zero_and_false_are_values () =
  Alcotest.(check string)
    "0 and false render"
    "n=0 present=false"
    (render [ Log.Kv.int "n" 0; Log.Kv.bool "present" false ])
;;

let test_opt_map_renders_a_present_value () =
  Alcotest.(check string)
    "Some goes through the renderer"
    "tok_s=12.3"
    (render [ Log.Kv.opt_map "tok_s" (Printf.sprintf "%.1f") (Some 12.34) ])
;;

let test_opt_map_omits_an_absent_value () =
  Alcotest.(check string)
    "None never reaches the renderer"
    "a=x"
    (render [ Log.Kv.str "a" "x"; Log.Kv.opt_map "tok_s" (Printf.sprintf "%.1f") None ])
;;

let test_all_absent_renders_empty () =
  Alcotest.(check string) "" "" (render [ Log.Kv.opt "a" None; Log.Kv.opt "b" None ])
;;

let () =
  Alcotest.run
    "log_kv"
    [ ( "render"
      , [ Alcotest.test_case "absent fields are omitted" `Quick test_absent_fields_are_omitted
        ; Alcotest.test_case "zero and false are values" `Quick test_zero_and_false_are_values
        ; Alcotest.test_case
            "opt_map renders a present value"
            `Quick
            test_opt_map_renders_a_present_value
        ; Alcotest.test_case
            "opt_map omits an absent value"
            `Quick
            test_opt_map_omits_an_absent_value
        ; Alcotest.test_case "all absent renders empty" `Quick test_all_absent_renders_empty
        ] )
    ]
;;
