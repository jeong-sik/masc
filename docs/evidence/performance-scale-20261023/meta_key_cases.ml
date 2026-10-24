let normalize detail = function
  | Ok fields -> Ok fields
  | Error error -> Error (detail error)

let before json =
  Before.validate_current_object json |> normalize Before.validation_error_detail

let after json =
  After.validate_current_object json |> normalize After.validation_error_detail

let checked = ref 0
let equivalent json =
  incr checked;
  if before json <> after json then
    failwith ("key-validation changed for " ^ Yojson.Safe.to_string json)

let fields = match fixture with `Assoc fields -> fields | _ -> failwith "fixture object"

let () =
  equivalent fixture;
  equivalent (`Assoc (List.rev fields));
  List.iter (fun (key, value) ->
    equivalent (`Assoc (List.remove_assoc key fields));
    equivalent (`Assoc ((key, value) :: fields));
    equivalent (`Assoc (fields @ [key, value]))) fields;
  List.iter equivalent [`Null; `Bool false; `Int 1; `String ""; `List []];
  equivalent (`Assoc ["outside_b", `Null; "outside_a", `Null]);
  equivalent (`Assoc ["outside_b", `Null; "outside_a", `Null; "outside_a", `Bool true]);
  let random = Random.State.make [|2026; 10; 23|] in
  for _ = 1 to 5000 do
    let shuffled = Array.of_list fields in
    for i = Array.length shuffled - 1 downto 1 do
      let j = Random.State.int random (i + 1) in
      let previous = shuffled.(i) in
      shuffled.(i) <- shuffled.(j);
      shuffled.(j) <- previous
    done;
    let selected = Array.to_list shuffled
      |> List.filter (fun _ -> Random.State.int random 5 <> 0) in
    let selected =
      if Random.State.bool random then ("outside_b", `Null) :: selected else selected in
    let selected =
      if Random.State.bool random then selected @ ["outside_a", `Null] else selected in
    let selected =
      if selected <> [] && Random.State.bool random then
        selected @ [List.nth selected (Random.State.int random (List.length selected))]
      else selected in
    equivalent (`Assoc selected)
  done;
  Printf.eprintf "Exact before/after results agree: %d cases\n%!" !checked

let measure implementation documents =
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let started = Mtime_clock.counter () in
  let passed = Array.fold_left (fun count json ->
    match implementation json with
    | Ok _ -> count + 1
    | Error _ -> failwith "benchmark fixture rejected") 0 documents in
  let elapsed_ms = Mtime.Span.to_float_ns (Mtime_clock.count started) /. 1_000_000. in
  let allocated_bytes = Gc.allocated_bytes () -. allocated in
  assert (passed = Array.length documents);
  elapsed_ms, allocated_bytes

let () =
  Printf.printf "documents,round,implementation,elapsed_ms,allocated_bytes\n%!";
  List.iter (fun count ->
    let documents = Array.init count (fun i ->
      `Assoc (List.map (fun (key, value) ->
        key, if key = "name" then `String (Printf.sprintf "probe-%04d" i) else value) fields)) in
    for round = 1 to 9 do
      let order = if round mod 2 = 1 then ["before", before; "after", after]
        else ["after", after; "before", before] in
      List.iter (fun (label, implementation) ->
        let ms, bytes = measure implementation documents in
        Printf.printf "%d,%d,%s,%.6f,%.0f\n%!" count round label ms bytes) order
    done) [35; 350; 3500]
