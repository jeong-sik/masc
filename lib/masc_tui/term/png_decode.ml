type rgba_image = {
  width : int;
  height : int;
  rgba : bytes;
}

let default_max_pixels = 4 * 1024 * 1024

let u16_be s off =
  (Char.code s.[off] lsl 8) lor Char.code s.[off + 1]

let u16_le s off =
  Char.code s.[off] lor (Char.code s.[off + 1] lsl 8)

let u24_le s off =
  Char.code s.[off]
  lor (Char.code s.[off + 1] lsl 8)
  lor (Char.code s.[off + 2] lsl 16)

let starts_at ~off ~prefix s =
  let plen = String.length prefix in
  off >= 0 && off + plen <= String.length s
  && String.sub s off plen = prefix

let gif_dimensions bytes =
  if
    String.length bytes >= 10
    && (starts_at ~off:0 ~prefix:"GIF87a" bytes
       || starts_at ~off:0 ~prefix:"GIF89a" bytes)
  then
    let w = u16_le bytes 6 in
    let h = u16_le bytes 8 in
    if w > 0 && h > 0 then Some (w, h) else None
  else None

let jpeg_dimensions bytes =
  let len = String.length bytes in
  if len < 4 || Char.code bytes.[0] <> 0xFF || Char.code bytes.[1] <> 0xD8 then
    None
  else
    let rec scan i =
      if i + 1 >= len then None
      else if Char.code bytes.[i] <> 0xFF then None
      else
        let rec skip_ff j =
          if j < len && Char.code bytes.[j] = 0xFF then skip_ff (j + 1)
          else j
        in
        let m_idx = skip_ff (i + 1) in
        if m_idx >= len then None
        else
          let marker = Char.code bytes.[m_idx] in
          match marker with
          | 0xD8 | 0x01 -> scan (m_idx + 1)
          | 0xD9 | 0xDA -> None
          | m when m >= 0xD0 && m <= 0xD7 -> scan (m_idx + 1)
          | 0xC0 | 0xC1 | 0xC2 | 0xC3 | 0xC5 | 0xC6 | 0xC7 | 0xC9 | 0xCA
          | 0xCB | 0xCD | 0xCE | 0xCF ->
              if m_idx + 7 < len then
                let h = u16_be bytes (m_idx + 4) in
                let w = u16_be bytes (m_idx + 6) in
                if w > 0 && h > 0 then Some (w, h) else None
              else None
          | _ ->
              if m_idx + 2 >= len then None
              else
                let seg_len = u16_be bytes (m_idx + 1) in
                if seg_len < 2 then None
                else scan (m_idx + 1 + seg_len)
    in
    scan 2

let webp_dimensions bytes =
  let len = String.length bytes in
  if
    len < 24
    || not (starts_at ~off:0 ~prefix:"RIFF" bytes)
    || not (starts_at ~off:8 ~prefix:"WEBP" bytes)
  then None
  else
    let chunk = String.sub bytes 12 4 in
    match chunk with
    | "VP8X" when len >= 30 ->
        let w = u24_le bytes 24 + 1 in
        let h = u24_le bytes 27 + 1 in
        if w > 0 && h > 0 then Some (w, h) else None
    | "VP8L" when len >= 25 && Char.code bytes.[20] = 0x2F ->
        let b0 = Char.code bytes.[21] in
        let b1 = Char.code bytes.[22] in
        let b2 = Char.code bytes.[23] in
        let b3 = Char.code bytes.[24] in
        let w = (b0 lor ((b1 land 0x3F) lsl 8)) + 1 in
        let h = (((b1 lsr 6) lor (b2 lsl 2) lor ((b3 land 0x0F) lsl 10)) + 1) in
        if w > 0 && h > 0 then Some (w, h) else None
    | "VP8 " when len >= 30 ->
        if
          Char.code bytes.[23] = 0x9D
          && Char.code bytes.[24] = 0x01
          && Char.code bytes.[25] = 0x2A
        then
          let w = u16_le bytes 26 land 0x3FFF in
          let h = u16_le bytes 28 land 0x3FFF in
          if w > 0 && h > 0 then Some (w, h) else None
        else None
    | _ -> None

let image_dimensions bytes =
  match Rgb_png.header_dimensions bytes with
  | Some _ as d -> d
  | None -> (
      match jpeg_dimensions bytes with
      | Some _ as d -> d
      | None -> (
          match gif_dimensions bytes with
          | Some _ as d -> d
          | None -> webp_dimensions bytes))

(* --- Pure-OCaml PNG RGBA Decoder --- *)

let paeth a b c =
  let p = a + b - c in
  let pa = abs (p - a) in
  let pb = abs (p - b) in
  let pc = abs (p - c) in
  if pa <= pb && pa <= pc then a
  else if pb <= pc then b
  else c

let inflate_bounded ~max_output compressed =
  let input = De.bigstring_create De.io_buffer_size in
  let output = De.bigstring_create De.io_buffer_size in
  let allocate bits = De.make_window ~bits in
  let out_buf = Buffer.create (Int.min max_output 65536) in
  let pos = ref 0 in
  let clen = String.length compressed in
  let overflow = ref false in
  let refill buf =
    let avail = clen - !pos in
    let take = Int.min (Bigstringaf.length buf) avail in
    if take > 0 then begin
      Bigstringaf.blit_from_string compressed ~src_off:!pos buf ~dst_off:0
        ~len:take;
      pos := !pos + take
    end;
    take
  in
  let flush buf len =
    if Buffer.length out_buf + len > max_output then overflow := true
    else Buffer.add_string out_buf (Bigstringaf.substring buf ~off:0 ~len)
  in
  match Zl.Higher.uncompress ~allocate ~refill ~flush input output with
  | Ok () ->
      if !overflow then Error "PNG IDAT exceeds expected decompressed size"
      else Ok (Buffer.contents out_buf)
  | Error (`Msg msg) -> Error ("PNG zlib inflate failed: " ^ msg)

let unfilter_scanlines ~height ~row_bytes ~bpp raw =
  let expected = height * (1 + row_bytes) in
  if String.length raw < expected then
    Error
      (Printf.sprintf "truncated PNG scanline stream (got %d, expected %d)"
         (String.length raw) expected)
  else
    let out = Bytes.create (height * row_bytes) in
    let rec do_row y =
      if y >= height then Ok out
      else
        let src_off = y * (1 + row_bytes) in
        let dst_off = y * row_bytes in
        let prev_off = (y - 1) * row_bytes in
        let filter = Char.code raw.[src_off] in
        if filter < 0 || filter > 4 then
          Error (Printf.sprintf "unsupported PNG filter type %d" filter)
        else begin
          for x = 0 to row_bytes - 1 do
            let raw_b = Char.code raw.[src_off + 1 + x] in
            let a =
              if x >= bpp then Char.code (Bytes.get out (dst_off + x - bpp))
              else 0
            in
            let b =
              if y > 0 then Char.code (Bytes.get out (prev_off + x)) else 0
            in
            let c =
              if x >= bpp && y > 0 then
                Char.code (Bytes.get out (prev_off + x - bpp))
              else 0
            in
            let v =
              match filter with
              | 0 -> raw_b
              | 1 -> (raw_b + a) land 0xFF
              | 2 -> (raw_b + b) land 0xFF
              | 3 -> (raw_b + ((a + b) lsr 1)) land 0xFF
              | 4 -> (raw_b + paeth a b c) land 0xFF
              | _ -> raw_b
            in
            Bytes.set out (dst_off + x) (Char.chr v)
          done;
          do_row (y + 1)
        end
    in
    do_row 0

let decode_rgba ?(max_pixels = default_max_pixels) bytes =
  let len = String.length bytes in
  if len < 33 || not (String.starts_with ~prefix:Rgb_png.signature bytes) then
    Error "not a valid PNG byte stream"
  else
    let ihdr_w = ref 0 in
    let ihdr_h = ref 0 in
    let bit_depth = ref 0 in
    let color_type = ref (-1) in
    let compression = ref 0 in
    let filter_method = ref 0 in
    let interlace = ref 0 in
    let saw_ihdr = ref false in
    let saw_iend = ref false in
    let palette = ref None in
    let trns = ref None in
    let idat_buf = Buffer.create (Int.min len 65536) in
    let rec parse_chunks off =
      if !saw_iend || off + 12 > len then Ok ()
      else
        let chunk_len = Int32.to_int (String.get_int32_be bytes off) in
        if chunk_len < 0 || off + 12 + chunk_len > len then
          Error "malformed PNG chunk length"
        else
          let kind = String.sub bytes (off + 4) 4 in
          let data_off = off + 8 in
          let next_off = off + 12 + chunk_len in
          match kind with
          | "IHDR" ->
              if chunk_len <> 13 then Error "invalid IHDR chunk length"
              else begin
                ihdr_w := Int32.to_int (String.get_int32_be bytes data_off);
                ihdr_h := Int32.to_int (String.get_int32_be bytes (data_off + 4));
                bit_depth := Char.code bytes.[data_off + 8];
                color_type := Char.code bytes.[data_off + 9];
                compression := Char.code bytes.[data_off + 10];
                filter_method := Char.code bytes.[data_off + 11];
                interlace := Char.code bytes.[data_off + 12];
                saw_ihdr := true;
                parse_chunks next_off
              end
          | "PLTE" ->
              palette := Some (String.sub bytes data_off chunk_len);
              parse_chunks next_off
          | "tRNS" ->
              trns := Some (String.sub bytes data_off chunk_len);
              parse_chunks next_off
          | "IDAT" ->
              Buffer.add_substring idat_buf bytes data_off chunk_len;
              parse_chunks next_off
          | "IEND" ->
              saw_iend := true;
              Ok ()
          | _ -> parse_chunks next_off
    in
    match parse_chunks 8 with
    | Error _ as err -> err
    | Ok () ->
        let width = !ihdr_w in
        let height = !ihdr_h in
        if not !saw_ihdr then Error "missing PNG IHDR chunk"
        else if width <= 0 || height <= 0 then Error "non-positive PNG dimensions"
        else if width > max_pixels || height > max_pixels / width then
          Error
            (Printf.sprintf "PNG %dx%d exceeds pixel cap (%d)" width height
               max_pixels)
        else if !compression <> 0 || !filter_method <> 0 then
          Error "unsupported PNG compression or filter method"
        else if !interlace <> 0 then
          Error "interlaced PNG is not supported"
        else if not (!bit_depth = 8 || !bit_depth = 16) then
          Error (Printf.sprintf "unsupported PNG bit depth %d" !bit_depth)
        else
          let channels_res =
            match !color_type with
            | 0 -> Ok 1
            | 2 -> Ok 3
            | 3 ->
                if !bit_depth <> 8 then
                  Error "indexed PNG requires 8-bit depth"
                else Ok 1
            | 4 -> Ok 2
            | 6 -> Ok 4
            | other -> Error (Printf.sprintf "unsupported PNG color type %d" other)
          in
          match channels_res with
          | Error _ as err -> err
          | Ok channels -> (
              let bytes_per_sample = !bit_depth / 8 in
              let bpp = channels * bytes_per_sample in
              let row_bytes = width * bpp in
              let expected_inflated = height * (1 + row_bytes) in
              match
                inflate_bounded ~max_output:(expected_inflated + 1024)
                  (Buffer.contents idat_buf)
              with
              | Error _ as err -> err
              | Ok inflated -> (
                  match unfilter_scanlines ~height ~row_bytes ~bpp inflated with
                  | Error _ as err -> err
                  | Ok scanlines ->
                      let rgba = Bytes.create (width * height * 4) in
                      let set_px idx r g b a =
                        let o = idx * 4 in
                        Bytes.set rgba o (Char.chr r);
                        Bytes.set rgba (o + 1) (Char.chr g);
                        Bytes.set rgba (o + 2) (Char.chr b);
                        Bytes.set rgba (o + 3) (Char.chr a)
                      in
                      let get_s off = Char.code (Bytes.get scanlines off) in
                      let total_px = width * height in
                      let ok =
                        match !color_type with
                        | 6 ->
                            for i = 0 to total_px - 1 do
                              let s = i * bpp in
                              set_px i (get_s s)
                                (get_s (s + bytes_per_sample))
                                (get_s (s + (2 * bytes_per_sample)))
                                (get_s (s + (3 * bytes_per_sample)))
                            done;
                            Ok ()
                        | 2 ->
                            for i = 0 to total_px - 1 do
                              let s = i * bpp in
                              set_px i (get_s s)
                                (get_s (s + bytes_per_sample))
                                (get_s (s + (2 * bytes_per_sample)))
                                255
                            done;
                            Ok ()
                        | 0 ->
                            for i = 0 to total_px - 1 do
                              let v = get_s (i * bpp) in
                              set_px i v v v 255
                            done;
                            Ok ()
                        | 4 ->
                            for i = 0 to total_px - 1 do
                              let s = i * bpp in
                              let v = get_s s in
                              let a = get_s (s + bytes_per_sample) in
                              set_px i v v v a
                            done;
                            Ok ()
                        | 3 -> (
                            match !palette with
                            | None -> Error "indexed PNG missing PLTE chunk"
                            | Some plte ->
                                let plte_entries = String.length plte / 3 in
                                let trns_s = !trns in
                                for i = 0 to total_px - 1 do
                                  let idx = get_s i in
                                  if idx < plte_entries then
                                    let po = idx * 3 in
                                    let r = Char.code plte.[po] in
                                    let g = Char.code plte.[po + 1] in
                                    let b = Char.code plte.[po + 2] in
                                    let a =
                                      match trns_s with
                                      | Some ts when idx < String.length ts ->
                                          Char.code ts.[idx]
                                      | Some _ | None -> 255
                                    in
                                    set_px i r g b a
                                  else set_px i 0 0 0 255
                                done;
                                Ok ())
                        | _ -> Error "unsupported PNG color type"
                      in
                      Result.map (fun () -> { width; height; rgba }) ok))
