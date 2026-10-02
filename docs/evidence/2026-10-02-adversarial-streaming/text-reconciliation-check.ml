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
Printf.printf "TOTAL PASS %d\n" !checks;;
