module String_map = Set_util.StringMap

type row =
  | Blank
  | Accepted of {
      post : Board_types.post;
      diagnostics : Board_content_json.diagnostic list;
    }
  | Rejected of {
      error : Board_types.posts_row_error;
      diagnostics : Board_content_json.diagnostic list;
    }

module Snapshot_bytes_cache = struct
  module Bytes_key = struct
    type t = string

    let equal (a : string) (b : string) = a == b

    let hash (s : string) =
      let len = String.length s in
      if len = 0 then 0
      else if len <= 64 then Hashtbl.hash s
      else begin
        let h = ref len in
        for i = len - 64 to len - 1 do
          h := (!h * 31) + Char.code (String.unsafe_get s i)
        done;
        !h
      end
  end

  module Table = Ephemeron.K1.Make (Bytes_key)

  type 'a t = {
    mu : Stdlib.Mutex.t;
    table : 'a Table.t;
  }

  let create size = { mu = Stdlib.Mutex.create (); table = Table.create size }

  let find_opt cache key =
    Stdlib.Mutex.protect cache.mu (fun () -> Table.find_opt cache.table key)

  let replace cache key value =
    Stdlib.Mutex.protect cache.mu (fun () -> Table.replace cache.table key value)
end

type slice = {
  offset : int;
  length : int;
}

type posts_index = {
  by_id : Board_types.post String_map.t;
  slices : slice String_map.t;
  covered_bytes : int;
}

let posts_cache : posts_index Snapshot_bytes_cache.t =
  Snapshot_bytes_cache.create 8

let is_whitespace = function
  | ' ' | '\012' | '\n' | '\r' | '\t' -> true
  | _ -> false

let rec slice_has_content_unchecked s idx stop =
  idx < stop
  && (not (is_whitespace (String.unsafe_get s idx))
      || slice_has_content_unchecked s (idx + 1) stop)

let slice_has_content s ~start ~stop =
  if start < 0 || stop > String.length s then
    invalid_arg "Board_posts_rows.slice_has_content";
  slice_has_content_unchecked s start stop

let is_canonical_slice bytes ~start ~stop ~has_newline =
  has_newline
  && stop > start
  && Char.equal (String.unsafe_get bytes start) '{'
  && Char.equal (String.unsafe_get bytes (stop - 1)) '}'

let iter_lines_with_offsets bytes f =
  let len = String.length bytes in
  let rec loop line_number pos =
    if pos > len then ()
    else if pos = len then
      (* Match [String.split_on_char '\n']: empty string produces one blank
         line, trailing '\n' ends cleanly without a non-empty trailing row. *)
      ()
    else
      match String.index_from_opt bytes pos '\n' with
      | Some nl ->
        f ~line_number ~start:pos ~stop:nl ~has_newline:true;
        loop (line_number + 1) (nl + 1)
      | None ->
        f ~line_number ~start:pos ~stop:len ~has_newline:false
  in
  loop 1 0

let decode ~line text =
  if not (slice_has_content text ~start:0 ~stop:(String.length text)) then Blank
  else
    match Yojson.Safe.from_string text with
    | json ->
      let decoded = Board_content_json.post_of_yojson json in
      (match decoded.value with
       | Some post -> Accepted { post; diagnostics = decoded.diagnostics }
       | None -> Rejected {
           error = Board_types.Invalid_posts_row { line };
           diagnostics = decoded.diagnostics;
         })
    | exception Yojson.Json_error detail ->
      Rejected {
        error = Board_types.Invalid_posts_json { line; detail };
        diagnostics = [];
      }

let register_snapshot ~bytes ~by_id ~slices ~covered_bytes =
  Snapshot_bytes_cache.replace posts_cache bytes { by_id; slices; covered_bytes }

let register_append ~before_bytes ~after_bytes ~offset ~length (post : Board_types.post) =
  match Snapshot_bytes_cache.find_opt posts_cache before_bytes with
  | None -> ()
  | Some prev ->
    let id = Board_types.Post_id.to_string post.id in
    let prev_slice_len =
      match String_map.find_opt id prev.slices with
      | Some s -> s.length
      | None -> 0
    in
    let by_id = String_map.add id post prev.by_id in
    let slices =
      if is_canonical_slice after_bytes ~start:offset ~stop:(offset + length - 1) ~has_newline:true
      then String_map.add id { offset; length } prev.slices
      else String_map.remove id prev.slices
    in
    let covered_bytes =
      if is_canonical_slice after_bytes ~start:offset ~stop:(offset + length - 1) ~has_newline:true
      then prev.covered_bytes - prev_slice_len + length
      else prev.covered_bytes - prev_slice_len
    in
    Snapshot_bytes_cache.replace posts_cache after_bytes { by_id; slices; covered_bytes }

let parse_snapshot_index bytes =
  let by_id = ref String_map.empty in
  let slices = ref String_map.empty in
  let covered = ref 0 in
  let rejected = ref false in
  let exception Bad_row in
  (try
     iter_lines_with_offsets bytes (fun ~line_number ~start ~stop ~has_newline ->
       if slice_has_content bytes ~start ~stop then begin
         let text = String.sub bytes start (stop - start) in
         match decode ~line:line_number text with
         | Blank -> ()
         | Rejected _ ->
           rejected := true;
           raise_notrace Bad_row
         | Accepted { post; _ } ->
           let id = Board_types.Post_id.to_string post.id in
           by_id := String_map.add id post !by_id;
           let prev_len =
             match String_map.find_opt id !slices with
             | Some s -> s.length
             | None -> 0
           in
           if is_canonical_slice bytes ~start ~stop ~has_newline then begin
             let length = stop - start + 1 in
             slices := String_map.add id { offset = start; length } !slices;
             covered := !covered - prev_len + length
           end else begin
             slices := String_map.remove id !slices;
             covered := !covered - prev_len
           end
       end)
   with Bad_row -> ());
  if !rejected then Error (Board_types.Io_error "Board data is unavailable.")
  else
    let index = { by_id = !by_id; slices = !slices; covered_bytes = !covered } in
    Snapshot_bytes_cache.replace posts_cache bytes index;
    Ok index

let get_index (snapshot : Fs_compat.private_jsonl_snapshot) =
  match Snapshot_bytes_cache.find_opt posts_cache snapshot.bytes with
  | Some index -> Ok index
  | None -> parse_snapshot_index snapshot.bytes

let all_in_snapshot snapshot =
  match get_index snapshot with
  | Ok index -> Ok index.by_id
  | Error _ as error -> error

let latest ~post_id snapshot =
  match get_index snapshot with
  | Error _ as error -> error
  | Ok index ->
    (match String_map.find_opt post_id index.by_id with
     | Some post -> Ok post
     | None -> Error (Board_types.Post_not_found post_id))

type planned_post_row =
  | Reuse_slice of { key : string; post : Board_types.post; offset : int; length : int }
  | Fresh_line of { key : string; post : Board_types.post; line : string }

let render_snapshot ?replacement ~base_bytes (table : (string, Board_types.post) Hashtbl.t) =
  let index_opt = Snapshot_bytes_cache.find_opt posts_cache base_bytes in
  let replacement_id =
    Option.map (fun (p : Board_types.post) -> Board_types.Post_id.to_string p.id) replacement
  in
  let unchanged_fast_path =
    match replacement, index_opt with
    | None, Some idx
      when idx.covered_bytes = String.length base_bytes
           && Hashtbl.length table = String_map.cardinal idx.by_id ->
      let all_match = ref true in
      Hashtbl.iter
        (fun key post ->
           if !all_match then
             match String_map.find_opt key idx.by_id with
             | Some prev when prev == post -> ()
             | Some _ | None -> all_match := false)
        table;
      !all_match
    | None, _ | Some _, _ -> false
  in
  if unchanged_fast_path then base_bytes
  else
    let total_len, rows_rev =
      Hashtbl.fold
        (fun key (stored_post : Board_types.post) (total, acc) ->
           let post =
             match replacement, replacement_id with
             | Some r, Some rid when String.equal key rid -> r
             | Some _, (Some _ | None) | None, (Some _ | None) -> stored_post
           in
           let planned =
             match index_opt with
             | Some idx ->
               (match String_map.find_opt key idx.by_id, String_map.find_opt key idx.slices with
                | Some prev, Some { offset; length } when prev == post ->
                  Reuse_slice { key; post; offset; length }
                | _ ->
                  let line = Yojson.Safe.to_string (Board_content_json.post_to_yojson post) ^ "\n" in
                  Fresh_line { key; post; line })
             | None ->
               let line = Yojson.Safe.to_string (Board_content_json.post_to_yojson post) ^ "\n" in
               Fresh_line { key; post; line }
           in
           let row_len =
             match planned with
             | Reuse_slice { length; _ } -> length
             | Fresh_line { line; _ } -> String.length line
           in
           total + row_len, planned :: acc)
        table
        (0, [])
    in
    if total_len = 0 then begin
      register_snapshot ~bytes:"" ~by_id:String_map.empty ~slices:String_map.empty ~covered_bytes:0;
      ""
    end else begin
      let out = Bytes.create total_len in
      let by_id = ref String_map.empty in
      let slices = ref String_map.empty in
      let rec blit dst = function
        | [] -> ()
        | Reuse_slice { key; post; offset; length } :: rest ->
          let start = dst - length in
          Bytes.blit_string base_bytes offset out start length;
          by_id := String_map.add key post !by_id;
          slices := String_map.add key { offset = start; length } !slices;
          blit start rest
        | Fresh_line { key; post; line } :: rest ->
          let length = String.length line in
          let start = dst - length in
          Bytes.blit_string line 0 out start length;
          by_id := String_map.add key post !by_id;
          slices := String_map.add key { offset = start; length } !slices;
          blit start rest
      in
      blit total_len rows_rev;
      let bytes = Bytes.unsafe_to_string out in
      register_snapshot ~bytes ~by_id:!by_id ~slices:!slices ~covered_bytes:total_len;
      bytes
    end
