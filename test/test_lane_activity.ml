(* Lane_activity: the spectator feed's push/cap/JSON logic, in isolation
   from any machine lane. *)

open Alcotest

let e ~at ~who ~action = { Lane_activity.at; who; action }

let test_push_is_newest_first () =
  let l = Lane_activity.push (e ~at:2. ~who:"b" ~action:"press b") [ e ~at:1. ~who:"a" ~action:"press a" ] in
  check (list string) "newest entry leads" [ "b"; "a" ] (List.map (fun x -> x.Lane_activity.who) l)
;;

let test_push_trims_to_cap () =
  let full =
    List.fold_left
      (fun acc n -> Lane_activity.push (e ~at:(float_of_int n) ~who:"k" ~action:"step") acc)
      [] (List.init (Lane_activity.cap + 5) Fun.id)
  in
  check int "never longer than cap" Lane_activity.cap (List.length full);
  (* The most recent [cap] pushes survive; earlier ones fell off the tail. *)
  check int "the newest entry is the last one pushed" (Lane_activity.cap + 4)
    (int_of_float (List.hd full).Lane_activity.at)
;;

(* [full] is built the way callers actually build one: fold [push] cap times
   over [], so it is genuinely newest-first, oldest ([at = 0.]) at the tail --
   not [List.init], which would hand [push] a list in the wrong order and
   make "the oldest is gone" true for the wrong reason. *)
let test_push_on_an_already_full_list_drops_exactly_one () =
  let full =
    List.fold_left
      (fun acc n -> Lane_activity.push (e ~at:(float_of_int n) ~who:"k" ~action:"step") acc)
      [] (List.init Lane_activity.cap Fun.id)
  in
  let l = Lane_activity.push (e ~at:99. ~who:"new" ~action:"press x") full in
  check int "stays at cap, not cap+1" Lane_activity.cap (List.length l);
  check bool "the oldest entry (at 0.) is gone" true
    (not (List.exists (fun x -> x.Lane_activity.at = 0.) l))
;;

let test_to_json_round_trips_the_fields () =
  let entry = e ~at:12.5 ~who:"liu-bei" ~action:"press a,b" in
  match Lane_activity.to_json entry with
  | `Assoc fields ->
    check bool "at" true (List.assoc_opt "at" fields = Some (`Float 12.5));
    check bool "who" true (List.assoc_opt "who" fields = Some (`String "liu-bei"));
    check bool "action" true (List.assoc_opt "action" fields = Some (`String "press a,b"))
  | _ -> fail "to_json did not return an object"
;;

let test_to_json_list_keeps_push_order () =
  let l = Lane_activity.push (e ~at:2. ~who:"b" ~action:"y") [ e ~at:1. ~who:"a" ~action:"x" ] in
  match Lane_activity.to_json_list l with
  | `List [ `Assoc first; `Assoc second ] ->
    check bool "first is the newest" true (List.assoc_opt "who" first = Some (`String "b"));
    check bool "second is the oldest" true (List.assoc_opt "who" second = Some (`String "a"))
  | _ -> fail "to_json_list did not return a two-element list"
;;

let () =
  run "lane-activity"
    [ ( "push"
      , [ test_case "newest first" `Quick test_push_is_newest_first
        ; test_case "trims to cap" `Quick test_push_trims_to_cap
        ; test_case "a full list drops exactly one" `Quick
            test_push_on_an_already_full_list_drops_exactly_one
        ] )
    ; ( "json"
      , [ test_case "to_json round-trips the fields" `Quick test_to_json_round_trips_the_fields
        ; test_case "to_json_list keeps push order" `Quick test_to_json_list_keeps_push_order
        ] )
    ]
;;
