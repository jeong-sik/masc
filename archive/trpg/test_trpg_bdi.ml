open Masc_mcp

(* ---- helpers ---- *)
let float_eq ~eps a b = Float.abs (a -. b) < eps

let check_float msg ~eps expected actual =
  Alcotest.(check bool) msg true (float_eq ~eps expected actual)

let string_contains_s haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if String.sub haystack i nlen = needle then found := true
    done;
    !found

(* ---- empty state ---- *)
let test_empty () =
  let bdi = Trpg_bdi.empty ~actor_id:"hero-1" in
  let json = Trpg_bdi.to_yojson bdi in
  let actor =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "actor_id" fields with
       | Some (`String s) -> s
       | _ -> "missing")
    | _ -> "bad-json"
  in
  Alcotest.(check string) "actor_id preserved" "hero-1" actor

(* ---- update_belief + decay ---- *)
let test_belief_decay () =
  let bdi =
    Trpg_bdi.empty ~actor_id:"a"
    |> Trpg_bdi.update_belief ~subject:"dragon" ~content:"sleeps in cave"
         ~confidence:1.0 ~turn:0
  in
  (* Decay at turn 10: confidence = 1.0 * 0.95^10 ~= 0.5987 *)
  let bdi2 = Trpg_bdi.decay_beliefs ~current_turn:10 bdi in
  let json = Trpg_bdi.to_yojson bdi2 in
  (* Extract first belief confidence *)
  let conf =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "beliefs" fields with
       | Some (`List ((`Assoc b) :: _)) ->
         (match List.assoc_opt "confidence" b with
          | Some (`Float f) -> f
          | _ -> -1.0)
       | _ -> -1.0)
    | _ -> -1.0
  in
  check_float "decayed confidence ~0.5987" ~eps:0.01 0.5987 conf

(* ---- update_desire ---- *)
let test_desire () =
  let bdi =
    Trpg_bdi.empty ~actor_id:"a"
    |> Trpg_bdi.update_desire ~goal:"find treasure" ~priority:0.8
         ~category:"quest"
  in
  let json = Trpg_bdi.to_yojson bdi in
  let has_desire =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "desires" fields with
       | Some (`List (_ :: _)) -> true
       | _ -> false)
    | _ -> false
  in
  Alcotest.(check bool) "has desire" true has_desire

(* ---- prune_beliefs ---- *)
let test_prune () =
  let bdi =
    Trpg_bdi.empty ~actor_id:"a"
    |> Trpg_bdi.update_belief ~subject:"old" ~content:"forgotten"
         ~confidence:0.05 ~turn:0
    |> Trpg_bdi.update_belief ~subject:"fresh" ~content:"known"
         ~confidence:0.9 ~turn:5
  in
  let pruned = Trpg_bdi.prune_beliefs ~threshold:0.1 bdi in
  let json = Trpg_bdi.to_yojson pruned in
  let belief_count =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "beliefs" fields with
       | Some (`List l) -> List.length l
       | _ -> -1)
    | _ -> -1
  in
  Alcotest.(check int) "only fresh belief remains" 1 belief_count

(* ---- to_prompt_fragment ---- *)
let test_prompt_fragment () =
  let bdi =
    Trpg_bdi.empty ~actor_id:"a"
    |> Trpg_bdi.update_belief ~subject:"goblin" ~content:"guards the door"
         ~confidence:0.8 ~turn:1
    |> Trpg_bdi.update_desire ~goal:"escape" ~priority:0.9 ~category:"survival"
  in
  let frag = Trpg_bdi.to_prompt_fragment ~max_len:2000 bdi in
  Alcotest.(check bool) "fragment non-empty" true (String.length frag > 0);
  (* Should mention goblin or escape *)
  let has_content =
    let s = String.lowercase_ascii frag in
    string_contains_s s "goblin" || string_contains_s s "escape"
  in
  Alcotest.(check bool) "fragment has relevant content" true has_content

(* ---- JSON roundtrip ---- *)
let test_json_roundtrip () =
  let bdi =
    Trpg_bdi.empty ~actor_id:"rt-1"
    |> Trpg_bdi.update_belief ~subject:"s" ~content:"c" ~confidence:0.7 ~turn:3
    |> Trpg_bdi.update_desire ~goal:"g" ~priority:0.5 ~category:"social"
  in
  let json = Trpg_bdi.to_yojson bdi in
  match Trpg_bdi.of_yojson json with
  | Ok bdi2 ->
    let json2 = Trpg_bdi.to_yojson bdi2 in
    let s1 = Yojson.Safe.to_string json in
    let s2 = Yojson.Safe.to_string json2 in
    Alcotest.(check string) "roundtrip matches" s1 s2
  | Error e -> Alcotest.fail ("of_yojson failed: " ^ e)

(* ---- load/save with temp dir ---- *)
let test_load_save () =
  let tmp = Filename.temp_dir "trpg_bdi_test" "" in
  (* load from missing file -> empty state *)
  let bdi0 = Trpg_bdi.load ~room_dir:tmp ~actor_id:"test-actor" in
  let j0 = Trpg_bdi.to_yojson bdi0 in
  (match j0 with
   | `Assoc fields ->
     (match List.assoc_opt "actor_id" fields with
      | Some (`String s) ->
        Alcotest.(check string) "loaded actor_id" "test-actor" s
      | _ -> Alcotest.fail "missing actor_id in loaded state")
   | _ -> Alcotest.fail "bad json from load");
  (* save then reload *)
  let bdi1 =
    bdi0
    |> Trpg_bdi.update_belief ~subject:"test" ~content:"data"
         ~confidence:0.9 ~turn:1
  in
  (match Trpg_bdi.save ~room_dir:tmp bdi1 with
   | Ok () -> ()
   | Error e -> Alcotest.fail ("save failed: " ^ e));
  let bdi2 = Trpg_bdi.load ~room_dir:tmp ~actor_id:"test-actor" in
  let s1 = Yojson.Safe.to_string (Trpg_bdi.to_yojson bdi1) in
  let s2 = Yojson.Safe.to_string (Trpg_bdi.to_yojson bdi2) in
  Alcotest.(check string) "save/load roundtrip" s1 s2;
  (* cleanup *)
  (try Sys.remove (Filename.concat tmp "bdi_test-actor.json") with _ -> ());
  (try Unix.rmdir tmp with _ -> ())

let () =
  Alcotest.run "trpg_bdi"
    [
      ( "core",
        [
          Alcotest.test_case "empty state" `Quick test_empty;
          Alcotest.test_case "belief decay" `Quick test_belief_decay;
          Alcotest.test_case "desire" `Quick test_desire;
          Alcotest.test_case "prune beliefs" `Quick test_prune;
          Alcotest.test_case "prompt fragment" `Quick test_prompt_fragment;
          Alcotest.test_case "json roundtrip" `Quick test_json_roundtrip;
          Alcotest.test_case "load/save" `Quick test_load_save;
        ] );
    ]
