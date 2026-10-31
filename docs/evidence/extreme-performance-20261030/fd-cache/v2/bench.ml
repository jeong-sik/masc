let us ns = Int64.to_float ns /. 1000.
let now () = Mtime_clock.elapsed_ns ()
let cpu () = let t=Unix.times () in t.Unix.tms_utime +. t.Unix.tms_stime
let fresh path line =
  let oc = open_out_gen [Open_append;Open_creat;Open_wronly] 0o644 path in
  match output_string oc line; flush oc with
  | () -> close_out oc
  | exception e -> close_out_noerr oc; raise e
let () =
  let mode = Sys.argv.(1) and dir=Sys.argv.(2) in
  let workers=int_of_string Sys.argv.(6) in
  let paths = int_of_string Sys.argv.(3) and calls = int_of_string Sys.argv.(4) in
  let json=Yojson.Safe.from_file Sys.argv.(5) in
  let expected=Yojson.Safe.to_string json ^ "\n" in
  let names=Array.init paths (fun i -> Filename.concat dir (string_of_int i ^ ".jsonl")) in
  let append = match mode with
    | "cached" -> (fun p line -> Fd_cache.with_writer p (fun oc -> output_string oc line; flush oc))
    | "split" -> (fun p line -> Fd_cache_split.with_writer p (fun oc -> output_string oc line; flush oc))
    | _ -> invalid_arg "mode"
  in
  if calls mod workers <> 0 then invalid_arg "uneven workers";
  let locks=Array.init paths (fun _ -> Mutex.create ()) in
  let start=Atomic.make false and release=Atomic.make false and finished=Atomic.make 0 in
  let outcomes=Array.init workers (fun _ -> Atomic.make None) in
  Gc.full_major ();
  let domains=Array.init workers (fun worker -> Domain.spawn (fun () ->
    while not (Atomic.get start) do Thread.delay 0.0001 done;
    let before=Gc.allocated_bytes () in
    let result=match
      for local=0 to (calls / workers)-1 do
        let index=(local * workers + worker) mod paths in
        Mutex.protect locks.(index) (fun () ->
          append names.(index) (Yojson.Safe.to_string json ^ "\n"))
      done
    with
    | () -> Ok (Gc.allocated_bytes () -. before)
    | exception e -> Error (e,Printexc.get_raw_backtrace ())
    in
    Atomic.set outcomes.(worker) (Some result);
    ignore (Atomic.fetch_and_add finished 1 : int);
    (* Keep every worker alive until all local counter samples are captured,
       so terminated-domain allocation counters cannot be adopted by peers. *)
    while not (Atomic.get release) do Thread.delay 0.0001 done)) in
  let c=cpu () and t=now () in
  Atomic.set start true;
  while Atomic.get finished <> workers do Thread.delay 0.0001 done;
  let wall=Int64.sub (now ()) t and used_cpu=cpu () -. c in
  let allocated=Array.fold_left (fun total outcome ->
    match Atomic.get outcome with
    | Some (Ok value) -> total +. value
    | Some (Error _) | None -> total) 0. outcomes in
  Atomic.set release true;
  Array.iter Domain.join domains;
  Array.iter (fun outcome -> match Atomic.get outcome with
    | Some (Ok _) -> ()
    | Some (Error (e,bt)) -> Printexc.raise_with_backtrace e bt
    | None -> failwith "worker omitted outcome") outcomes;
  Fd_cache.close_all (); Fd_cache_split.close_all ();
  let rows=ref 0 and bytes=ref 0 in
  let files=Array.mapi (fun i path ->
    let ic=open_in_bin path in
    let len=in_channel_length ic in
    let content=really_input_string ic len in close_in ic;
    let count=(calls / paths)+(if i<calls mod paths then 1 else 0) in
    if len <> count * String.length expected then failwith "row-byte count";
    for j=0 to count-1 do
      if String.sub content (j * String.length expected) (String.length expected) <> expected then failwith "readback bytes"
    done;
    rows := !rows + count; bytes := !bytes + len;
    `Assoc ["path_index",`Int i;"rows",`Int count;"bytes",`Int len;"md5",`String (Digest.to_hex (Digest.string content))]) names in
  if !rows<>calls then failwith "readback rows";
  Yojson.Safe.to_channel stdout (`Assoc ["mode",`String mode;"worker_domains",`Int workers;"paths",`Int paths;"calls",`Int calls;
    "wall_us",`Float (us wall);"cpu_us",`Float (used_cpu *. 1e6);"allocated_bytes",`Float allocated;
    "encoded_row_bytes",`Int (String.length expected);"validated_rows",`Int !rows;"validated_bytes",`Int !bytes;
    "files",`List (Array.to_list files)]);
  print_newline ();
  Array.iter Sys.remove names
