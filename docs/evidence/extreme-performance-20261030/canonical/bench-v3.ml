let fields count = List.init count (fun i -> Printf.sprintf "key-%04d" i, `String (String.make 24 'x'))
let sorted count = `Assoc (fields count)
let reversed count = `Assoc (List.rev (fields count))
let nested count = `Assoc ["peers", `List (List.init count (fun i ->
  `Assoc ["identity", `String (string_of_int i); "request", sorted 12; "state", `String "queued"]))]
let nearly_sorted count =
  let prefix = fields (count - 2) in
  `Assoc (prefix @ ["last-z", `Null; "last-a", `Null])
let rejected count = `Assoc (fields count @ ["key-0000", `Float nan])
let long_prefix count = List.map (fun (key, value) -> String.make 500 'x' ^ key, value) (fields count)
let long_nearly count = match List.rev (long_prefix count) with
  | a :: b :: rest -> `Assoc (List.rev rest @ [a; b])
  | fields -> `Assoc fields
let early_failure count = `Assoc (("key-0000", `Float nan) :: List.tl (fields count))
let cases = ["long-prefix-sorted-300", `Assoc (long_prefix 300), 300;
  "long-prefix-nearly-300", long_nearly 300, 300;
  "early-child-error-300", early_failure 300, 1000;"nearly-sorted-300", nearly_sorted 300, 300; "rejected-300", rejected 300, 1000;"sorted-3", sorted 3, 15000; "sorted-30", sorted 30, 4000;
  "sorted-300", sorted 300, 500; "reversed-30", reversed 30, 3000;
  "reversed-300", reversed 300, 300; "nested-30", nested 30, 300;
  "nested-300", nested 300, 30]
let outcome f json = match f json with
  | Ok value -> "ok:" ^ Yojson.Safe.to_string value
  | Error message -> "error:" ^ message
  | exception exn -> "exception:" ^ Printexc.to_string exn
let checked = ref 0
let outcomes = Hashtbl.create 8
let category text =
  if String.starts_with ~prefix:"ok:" text then "accepted"
  else if String.starts_with ~prefix:"error:" text then text
  else "exception"
let fixed = [
  "duplicate before non-finite child", `Assoc ["a", `Float nan; "b", `Int 2; "a", `Int 1], "error:duplicate object member";
  "unsorted child error order", `Assoc ["z", `Float nan; "a", `Intlit "invalid"], "error:non-finite JSON number";
  "sorted child error order", `Assoc ["a", `Float nan; "z", `Intlit "invalid"], "error:non-finite JSON number";
  "nested duplicate", `Assoc ["a", `Assoc ["x", `Int 1; "x", `Int 2]], "error:duplicate object member"]
let check json =
  incr checked;
  let before = outcome Before.canonical json in
  let after = outcome After.canonical json in
  let key = category before in
  Hashtbl.replace outcomes key (1 + Option.value ~default:0 (Hashtbl.find_opt outcomes key));
  if before <> after then
    failwith ("different outcome at case " ^ string_of_int !checked)
let rng = Random.State.make [|4537|]
let rec generated depth =
  if depth = 0 then match Random.State.int rng 8 with
    | 0 -> `Float nan | 1 -> `Float infinity | 2 -> `Float (-0.)
    | 3 -> `Intlit "123456789012345678901234567890"
    | 4 -> `Intlit "invalid" | 5 -> `Null | 6 -> `Bool true | _ -> `Int 42
  else match Random.State.int rng 3 with
    | 0 -> `List (List.init (Random.State.int rng 5) (fun _ -> generated (depth - 1)))
    | 1 -> `Assoc (List.init (Random.State.int rng 7) (fun _ ->
        string_of_int (Random.State.int rng 5), generated (depth - 1)))
    | _ -> generated 0
let cpu () = let t = Unix.times () in t.Unix.tms_utime +. t.Unix.tms_stime
let sample label f name input iterations round =
  Gc.full_major ();
  let bytes = Gc.allocated_bytes () in
  let c = cpu () in
  let start = Mtime_clock.now () in
  for _ = 1 to iterations do ignore (Sys.opaque_identity (f (Sys.opaque_identity input))) done;
  let wall_ns = Mtime.Span.to_float_ns (Mtime.span start (Mtime_clock.now ())) in
  let cpu_ns = (cpu () -. c) *. 1e9 in
  let bytes = Gc.allocated_bytes () -. bytes in
  let row = `Assoc ["variant", `String label; "case", `String name; "round", `Int round;
    "iterations", `Int iterations; "wall_ns_per_call", `Float (wall_ns /. float iterations);
    "cpu_ns_per_call", `Float (cpu_ns /. float iterations);
    "allocated_bytes_per_call", `Float (bytes /. float iterations)] in
  print_endline (Yojson.Safe.to_string row)
let () =
  List.iter (fun (_, json, _) -> check json) cases;
  List.iter check [
    `Assoc ["a", `Float nan; "b", `Int 2; "a", `Int 1];
    `Assoc ["z", `Float nan; "a", `Intlit "invalid"];
    `Assoc ["a", `Float nan; "z", `Intlit "invalid"];
    `Assoc ["a", `Assoc ["x", `Int 1; "x", `Int 2]]];
  for _ = 1 to 25000 do check (generated 3) done;
  let expected = List.map (fun (name, json, want) ->
    let actual = outcome After.canonical json in
    if actual <> want then failwith ("unexpected fixed outcome: " ^ name);
    `Assoc ["name", `String name; "expected", `String want; "actual", `String actual]) fixed in
  print_endline (Yojson.Safe.to_string (`Assoc ["behavioral_cases", `Int !checked;
    "all_identical", `Bool true; "outcome_counts", `Assoc (Hashtbl.fold (fun k v xs -> (k, `Int v) :: xs) outcomes []);
    "fixed_negative_outcomes", `List expected]));
  List.iter (fun (name, input, iterations) ->
    for round = 1 to 12 do
      let order = if round mod 2 = 0 then ["after", After.canonical; "before", Before.canonical]
        else ["before", Before.canonical; "after", After.canonical] in
      List.iter (fun (label, f) -> sample label f name input (iterations * 10) round) order
    done) cases
