#use "lib/keeper/keeper_official_client_text_stream.ml";;
let checks = ref 0;;
let check label expected actual =
  if expected <> actual then failwith label;
  incr checks;
  Printf.printf "PASS %s\n" label;;
let t = create ~equal:Int.equal ();;
ignore (forward t ~message:(Some 0) "CHECKING\n");;
ignore (forward t ~message:(Some 1) "DO");;
check "raw multi-step suffix excludes inserted paragraphs" (Some "NE\n")
  (finish_response t ~final_text:"CHECKING\nDONE\n");;
let t2 = create ~equal:Int.equal ();;
ignore (forward t2 ~message:(Some 0) "Checking\n");;
check "different final starts a new paragraph" (Some "\nDone\n")
  (finish_response t2 ~final_text:"Done\n");;
let t3 = create ~equal:Int.equal ();;
ignore (forward t3 ~message:(Some 0) "AB");;
ignore (forward t3 ~message:(Some 1) "A");;
check "earlier final not duplicated by later commentary prefix" None
  (finish_response t3 ~final_text:"AB");;
for tool_mask = 0 to 15 do
  let t = create ~equal:Int.equal () in
  let raw = Buffer.create 32 in
  for message = 0 to 3 do
    if tool_mask land (1 lsl message) <> 0 then tool_row t;
    let text = Printf.sprintf "N%d\n" message in
    ignore (forward t ~message:(Some message) text);
    Buffer.add_string raw text
  done;
  check (Printf.sprintf "n..n+3 completed raw mask=%d" tool_mask) None
    (finish_response t ~final_text:(Buffer.contents raw));
  check (Printf.sprintf "n..n+3 remaining suffix mask=%d" tool_mask) (Some "TAIL")
    (finish_response t ~final_text:(Buffer.contents raw ^ "TAIL"));
  check (Printf.sprintf "n..n+3 already delivered earlier final mask=%d" tool_mask) None
    (finish_response t ~final_text:"N1\n")
done;;
(* Bounded n+m sweep; deterministic boundary patterns keep failures replayable. *)
let general_checks_before = !checks;;
for count = 1 to 128 do
  for pattern = 0 to 7 do
    let t = create ~equal:Int.equal () in
    let raw = Buffer.create (count * 8) in
    let expected_shown = Buffer.create (count * 8) in
    let actual_shown = Buffer.create (count * 8) in
    let messages = Array.init count (fun i -> Printf.sprintf "N%d\n" i) in
    for i = 0 to count - 1 do
      let tool = pattern = 1 || (pattern = 2 && i mod 2 = 0)
        || (pattern = 3 && i mod 3 = 0)
        || (pattern = 4 && i = count - 1)
        || (pattern = 5 && i = 0)
        || (pattern = 6 && i mod 7 = 0)
        || (pattern = 7 && (i * 17 + count) mod 11 < 5) in
      if tool then tool_row t;
      if i > 0 && not tool then Buffer.add_char expected_shown '\n';
      let text = messages.(i) in
      Buffer.add_string expected_shown text;
      Buffer.add_string raw text;
      (* Split every message into two deltas; same identity must not add breaks. *)
      Buffer.add_string actual_shown (forward t ~message:(Some i) (String.sub text 0 1));
      Buffer.add_string actual_shown (forward t ~message:(Some i)
        (String.sub text 1 (String.length text - 1)))
    done;
    let context = Printf.sprintf "count=%d pattern=%d" count pattern in
    let assert_case name expected actual =
      if expected <> actual then failwith (name ^ " " ^ context);
      incr checks in
    assert_case "display exact bytes" (Buffer.contents expected_shown) (Buffer.contents actual_shown);
    assert_case "complete raw" None (finish_response t ~final_text:(Buffer.contents raw));
    assert_case "remaining suffix" (Some "TAIL")
      (finish_response t ~final_text:(Buffer.contents raw ^ "TAIL"));
    assert_case "new final" (Some "\nFINAL") (finish_response t ~final_text:"FINAL");
    Array.iter (fun prior -> assert_case "every prior final once" None
      (finish_response t ~final_text:prior)) messages
  done
 done;;
Printf.printf "PASS bounded n+m: 1..128 messages, 8 boundary patterns, %d assertions\n"
  (!checks - general_checks_before);;
Printf.printf "TOTAL PASS %d\n" !checks;;
