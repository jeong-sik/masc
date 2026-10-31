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
  let paths = int_of_string Sys.argv.(3) and calls = int_of_string Sys.argv.(4) in
  let json=Yojson.Safe.from_file Sys.argv.(5) in
  let expected=Yojson.Safe.to_string json ^ "\n" in
  let names=Array.init paths (fun i -> Filename.concat dir (string_of_int i ^ ".jsonl")) in
  let append = match mode with
    | "cached" -> (fun p line -> Fd_cache.with_writer p (fun oc -> output_string oc line; flush oc))
    | "fresh" -> fresh
    | _ -> invalid_arg "mode"
  in
  Gc.full_major ();
  let allocated=Gc.allocated_bytes () and c=cpu () and t=now () in
  for i=0 to calls-1 do append names.(i mod paths) (Yojson.Safe.to_string json ^ "\n") done;
  let wall=Int64.sub (now ()) t and used_cpu=cpu () -. c in
  let allocated=Gc.allocated_bytes () -. allocated in
  Fd_cache.close_all ();
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
  Yojson.Safe.to_channel stdout (`Assoc ["mode",`String mode;"paths",`Int paths;"calls",`Int calls;
    "wall_us",`Float (us wall);"cpu_us",`Float (used_cpu *. 1e6);"allocated_bytes",`Float allocated;
    "encoded_row_bytes",`Int (String.length expected);"validated_rows",`Int !rows;"validated_bytes",`Int !bytes;
    "files",`List (Array.to_list files)]);
  print_newline ();
  Array.iter Sys.remove names
