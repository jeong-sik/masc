module Before = struct
type read_operation = Read_file
type read_error = Io_error of {operation:read_operation;path:string;detail:string}
type recent_entry = Parsed of Yojson.Safe.t | Malformed_json of {path:string;line_number:int option;detail:string}
let recent_entry_of_line ~path ?line_number line =
  match Yojson.Safe.from_string line with
  | json -> Parsed json
  | exception Yojson.Json_error detail ->
    Malformed_json { path; line_number; detail }
;;

let appended_read_changed path =
  Io_error { operation = Read_file; path;
             detail = "dated files changed during incremental read" }
;;

let fold_captured_entries_result channel ~path ~from ~until ~init ~f =
  let rec drive acc boundary position fragment =
    if position >= until then Ok (acc, boundary)
    else
      let chunk = Bytes.create (min 65536 (until - position)) in
      let read =
        match input channel chunk 0 (Bytes.length chunk) with
        | 0 -> Error (appended_read_changed path)
        | length -> Ok length
        | exception Sys_error detail ->
          Error (Io_error { operation = Read_file; path; detail })
      in
      match read with
      | Error _ as error -> error
      | Ok length ->
        let value = ref acc in
        let next_boundary = ref boundary in
        for index = 0 to length - 1 do
          match Bytes.get chunk index with
          | '\n' ->
            let line = Buffer.contents fragment in
            Buffer.clear fragment;
            next_boundary := position + index + 1;
            if String.trim line <> "" then
              value := f !value (recent_entry_of_line ~path line)
          | character -> Buffer.add_char fragment character
        done;
        drive !value !next_boundary (position + length) fragment
  in
  let seek =
    match seek_in channel from with
    | () -> Ok ()
    | exception Sys_error detail ->
      Error (Io_error { operation = Read_file; path; detail })
  in
  match seek with
  | Error _ as error -> error
  | Ok () -> drive init from from (Buffer.create 256)
;;


end;;
module After = struct
type read_operation = Read_file
type read_error = Io_error of {operation:read_operation;path:string;detail:string}
type recent_entry = Parsed of Yojson.Safe.t | Malformed_json of {path:string;line_number:int option;detail:string}
let recent_entry_of_line ~path ?line_number line =
  match Yojson.Safe.from_string line with
  | json -> Parsed json
  | exception Yojson.Json_error detail ->
    Malformed_json { path; line_number; detail }
;;

let appended_read_changed path =
  Io_error { operation = Read_file; path;
             detail = "dated files changed during incremental read" }
;;

let fold_captured_entries_result channel ~path ~from ~until ~init ~f =
  let rec drive acc boundary position fragment =
    if position >= until then Ok (acc, boundary)
    else
      let chunk = Bytes.create (min 65536 (until - position)) in
      let read =
        match input channel chunk 0 (Bytes.length chunk) with
        | 0 -> Error (appended_read_changed path)
        | length -> Ok length
        | exception Sys_error detail ->
          Error (Io_error { operation = Read_file; path; detail })
      in
      match read with
      | Error _ as error -> error
      | Ok length ->
        let value = ref acc in
        let next_boundary = ref boundary in
        (* Copy complete spans rather than calling [Buffer.add_char] for
           every byte. Only [length] bytes were read: [Bytes.create] leaves
           the rest unspecified, including possible newline bytes. *)
        let rec consume start =
          if start < length then begin
            let index =
              match Bytes.index_from chunk start '\n' with
              | index -> min index length
              | exception Not_found -> length
            in
            if index < length then begin
              let line =
                if Buffer.length fragment = 0 then
                  Bytes.sub_string chunk start (index - start)
                else begin
                  Buffer.add_subbytes fragment chunk start (index - start);
                  let line = Buffer.contents fragment in
                  Buffer.clear fragment;
                  line
                end
              in
              next_boundary := position + index + 1;
              if String.trim line <> "" then
                value := f !value (recent_entry_of_line ~path line);
              consume (index + 1)
            end else
              Buffer.add_subbytes fragment chunk start (length - start)
          end
        in
        consume 0;
        drive !value !next_boundary (position + length) fragment
  in
  let seek =
    match seek_in channel from with
    | () -> Ok ()
    | exception Sys_error detail ->
      Error (Io_error { operation = Read_file; path; detail })
  in
  match seek with
  | Error _ as error -> error
  | Ok () -> drive init from from (Buffer.create 256)
;;


end;;

let path = Filename.temp_file "masc-jsonl-span" ".jsonl";;
let put text = Out_channel.with_open_bin path (fun ch -> output_string ch text);;
let before ~from ~until = In_channel.with_open_bin path (fun ch ->
 Before.fold_captured_entries_result ch ~path ~from ~until ~init:[]
 ~f:(fun rows -> function Before.Parsed j -> (true,j)::rows | Before.Malformed_json _ -> (false,`Null)::rows));;
let after ~from ~until = In_channel.with_open_bin path (fun ch ->
 After.fold_captured_entries_result ch ~path ~from ~until ~init:[]
 ~f:(fun rows -> function After.Parsed j -> (true,j)::rows | After.Malformed_json _ -> (false,`Null)::rows));;
let large = Yojson.Safe.to_string (`Assoc ["text",`String (String.concat "" (List.init 24000 (fun _ -> "한글")))]) ^ "\n";;
let fixtures = ["";"\n \t\r\n";"{}\nmalformed\r\n{}";large ^ "malformed\n{\"i\":2}\n";String.make 65535 ' ' ^ "{}\n"];;
let cases = ref 0;;
List.iter (fun text -> put text;
 List.iter (fun until ->
  let a=before ~from:0 ~until and b=after ~from:0 ~until in
  (match a,b with
  | Ok a,Ok b -> if a<>b then failwith "reader semantic mismatch"
  | Error _,_ | _,Error _ -> failwith "unexpected fixture read error");
  incr cases) (List.sort_uniq Int.compare [0;min 1 (String.length text);min 65535 (String.length text);min 65536 (String.length text);min 65537 (String.length text);String.length text])) fixtures;;
put ("{}\n" ^ large ^ "malformed\n");;
(match before ~from:3 ~until:(3+String.length large+10), after ~from:3 ~until:(3+String.length large+10) with
 | Ok a,Ok b when a=b -> incr cases
 | _ -> failwith "nonzero start mismatch");;
let callback_before () = In_channel.with_open_bin path (fun ch -> Before.fold_captured_entries_result ch ~path ~from:0 ~until:3 ~init:() ~f:(fun () _ -> raise Not_found));;
let callback_after () = In_channel.with_open_bin path (fun ch -> After.fold_captured_entries_result ch ~path ~from:0 ~until:3 ~init:() ~f:(fun () _ -> raise Not_found));;
(match callback_before () with _ -> failwith "before swallowed callback" | exception Not_found -> incr cases);;
(match callback_after () with _ -> failwith "after swallowed callback" | exception Not_found -> incr cases);;
let measure lane f =
 Gc.full_major ();
 let alloc=Gc.allocated_bytes () and cpu=Sys.time () and wall=Unix.gettimeofday () in
 let count=f () in
 `Assoc ["lane",`String lane;"rows",`Int count;"wall_ms",`Float ((Unix.gettimeofday ()-.wall)*.1000.);"cpu_ms",`Float ((Sys.time ()-.cpu)*.1000.);"allocated_bytes",`Float (Gc.allocated_bytes ()-.alloc)];;
let counts_before n = In_channel.with_open_bin path (fun ch ->
 match Before.fold_captured_entries_result ch ~path ~from:0 ~until:n ~init:0 ~f:(fun k _ -> k+1) with Ok(k,_) -> k | Error _ -> failwith "before read");;
let counts_after n = In_channel.with_open_bin path (fun ch ->
 match After.fold_captured_entries_result ch ~path ~from:0 ~until:n ~init:0 ~f:(fun k _ -> k+1) with Ok(k,_) -> k | Error _ -> failwith "after read");;
let samples=ref [];;
List.iter (fun (name,row,count) ->
 let text=String.concat "" (List.init count (fun _ -> row)) in put text;
 for round=0 to 5 do
  let run lane f = let sample=measure lane (fun () -> f (String.length text)) in
   samples := (`Assoc ["fixture",`String name;"bytes",`Int (String.length text);"round",`Int round;"sample",sample])::!samples in
  if round mod 2=0 then (run "before" counts_before;run "after" counts_after)
  else (run "after" counts_after;run "before" counts_before)
 done)
 ["short", "{\"i\":1}\n",50000;
  "one_kib",Yojson.Safe.to_string (`Assoc ["text",`String(String.make 1000 'x')]) ^ "\n",4096;
  "large_utf8",large,30];;
Yojson.Safe.to_channel stdout (`Assoc ["runtime",`String Sys.ocaml_version;"execution",`String "Standalone OCaml native probe; extracted reader bodies and actual Yojson decoder; not full module/server";"equivalence_cases",`Int !cases;"samples",`List(List.rev !samples)]);;
print_newline ();;Sys.remove path;;
