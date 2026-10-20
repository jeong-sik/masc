let digest ?buf messages =
  let module Hash = Digestif.SHA256 in
  let rec feed ctx = function
    | [] -> Hash.feed_string ctx "]" |> Hash.get |> Hash.to_hex
    | message :: rest ->
      let encoded = Yojson.Safe.to_string ?buf message in
      let ctx = Hash.feed_string ctx encoded in
      let ctx = match rest with [] -> ctx | _ :: _ -> Hash.feed_string ctx "," in
      feed ctx rest in
  feed (Hash.feed_string (Hash.init ()) "[") messages
let run name f =
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  let started = Unix.gettimeofday () in
  let result = f () in
  let elapsed = Unix.gettimeofday () -. started in
  let allocated = Gc.allocated_bytes () -. before in
  Printf.printf "%s seconds=%.6f allocated_bytes=%.0f digest=%s\n%!" name elapsed allocated result;
  result
let () =
  let doc = Yojson.Safe.from_file Sys.argv.(1) in
  let messages = Yojson.Safe.Util.(doc |> member "messages" |> to_list) in
  Printf.printf "messages=%d input_file_bytes=%d\n%!" (List.length messages) (Unix.stat Sys.argv.(1)).Unix.st_size;
  for round = 1 to 3 do
    let before () = run (Printf.sprintf "before-%d" round) (fun () -> digest messages) in
    let after () = run (Printf.sprintf "after-%d" round) (fun () -> digest ~buf:(Buffer.create 256) messages) in
    let a,b = if round mod 2 = 0 then let b=after () in before (),b else let a=before () in a,after () in
    if not (String.equal a b) then failwith "digest changed"
  done
