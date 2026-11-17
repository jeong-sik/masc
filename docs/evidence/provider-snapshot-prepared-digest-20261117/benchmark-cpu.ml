module Before = Tool_blob_store_before
module After = Tool_blob_store_after

type old_payload = { payload_bytes : string; payload_sha256 : string }
let old_prepare payload_bytes =
  { payload_bytes; payload_sha256 = Agent_core_sha256.(digest_string payload_bytes |> to_hex) }

module Artifact_key = struct
  type t = string * string
  let compare (left_sha, left_mime) (right_sha, right_mime) =
    match String.compare left_sha right_sha with
    | 0 -> String.compare left_mime right_mime
    | order -> order
end
module Artifact_map = Map.Make (Artifact_key)
let sink value = ignore (Sys.opaque_identity value)
let mime = "application/json"
let measure name size round variant count f =
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let start = Mtime_clock.counter () in
  let cpu = Sys.time () in
  for i = 0 to count - 1 do f i done;
  let elapsed = Mtime.Span.to_float_ns (Mtime_clock.count start) /. 1000. in
  let cpu = (Sys.time () -. cpu) *. 1_000_000. in
  let allocated = Gc.allocated_bytes () -. allocated in
  Printf.printf "%s,%d,%d,%s,%d,%.3f,%.1f,%.3f\n%!"
    name size round variant count (elapsed /. float count) (allocated /. float count) (cpu /. float count)

let rec cleanup path =
  match Unix.lstat path with
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> cleanup (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path

let () =
  let root = Filename.temp_file "masc_prepared_blob_bench" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> cleanup root) (fun () ->
    Printf.printf "case,size,round,variant,count,us_per_op,allocated_bytes_per_op,cpu_us_per_op\n%!";
    List.iter (fun size ->
      let bytes = String.init size (fun i -> Char.chr (32 + i mod 90)) in
      let pure_count = if size < 10000 then 100 else 8 in
      for round = 1 to 5 do
        let base suffix =
          let path = Filename.concat root (Printf.sprintf "%d-%d-%s" size round suffix) in
          Unix.mkdir path 0o700; path in
        let before = Before.create ~base_path:(base "old") in
        let after = After.create ~base_path:(base "new") in
        let pair name count old_fn new_fn =
          let old () = measure name size round "before" count old_fn in
          let next () = measure name size round "after" count new_fn in
          if round mod 2 = 0 then (next (); old ()) else (old (); next ()) in
        pair "ordinary_address_control" pure_count
          (fun _ -> sink (Before.address before ~bytes ~mime))
          (fun _ -> sink (After.address after ~bytes ~mime));
        pair "prepare_then_address_map_miss" pure_count
          (fun _ -> let p = old_prepare bytes in sink (Before.address before ~bytes:p.payload_bytes ~mime))
          (fun _ -> let payload = After.prepare_payload ~bytes in sink (After.For_testing.address_prepared after ~payload ~mime));
        let sha256 = Agent_core_sha256.(digest_string bytes |> to_hex) in
        let reusable = Artifact_map.singleton (sha256,mime) size in
        pair "prepare_then_artifact_map_hit" pure_count
          (fun _ -> let p = old_prepare bytes in
            match Artifact_map.find_opt (p.payload_sha256,mime) reusable with
            | Some n when n = String.length p.payload_bytes -> sink n
            | Some _ | None -> failwith "map fixture miss")
          (fun _ -> let p = After.prepare_payload ~bytes in
            match Artifact_map.find_opt (After.prepared_sha256 p,mime) reusable with
            | Some n when n = String.length (After.prepared_bytes p) -> sink n
            | Some _ | None -> failwith "map fixture miss");
        let cold_count = 2 in
        let old_stores = Array.init cold_count (fun i -> Before.create ~base_path:(base (Printf.sprintf "cold-old-%d" i))) in
        let new_stores = Array.init cold_count (fun i -> After.create ~base_path:(base (Printf.sprintf "cold-new-%d" i))) in
        pair "prepare_then_strict_cold_publish" cold_count
          (fun i -> let p = old_prepare bytes in sink (Before.put_durable_reuse old_stores.(i) ~bytes:p.payload_bytes ~mime))
          (fun i -> let payload = After.prepare_payload ~bytes in sink (After.put_prepared_durable_reuse new_stores.(i) ~payload ~mime));
        sink (Before.put_durable_reuse before ~bytes ~mime);
        sink (After.put_prepared_durable_reuse after ~payload:(After.prepare_payload ~bytes) ~mime);
        pair "prepare_then_strict_memo_hit" 4
          (fun _ -> let p = old_prepare bytes in sink (Before.put_durable_reuse before ~bytes:p.payload_bytes ~mime))
          (fun _ -> let payload = After.prepare_payload ~bytes in sink (After.put_prepared_durable_reuse after ~payload ~mime))
      done)
      [4096;1048576;3200000])
