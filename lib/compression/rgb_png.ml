(* PNG RGB8, non-interlaced, filter None. Compression and checksums belong to
   decompress/checkseum, already used by the transport codecs.
   https://www.w3.org/TR/png-3/ *)
let add_u32 buffer value =
  let bytes = Bytes.create 4 in
  Bytes.set_int32_be bytes 0 value;
  Buffer.add_bytes buffer bytes

let chunk buffer kind payload =
  add_u32 buffer (Int32.of_int (String.length payload));
  Buffer.add_string buffer kind;
  Buffer.add_string buffer payload;
  let crc = Checkseum.Crc32.digest_string kind 0 4 Checkseum.Crc32.default in
  let crc = Checkseum.Crc32.digest_string payload 0 (String.length payload) crc in
  add_u32 buffer (Checkseum.Crc32.to_int32 crc)

let compress data =
  let input = De.bigstring_create De.io_buffer_size in
  let output = De.bigstring_create De.io_buffer_size in
  let w = De.Lz77.make_window ~bits:15 in
  let q = De.Queue.create 0x1000 in
  let encoded = Buffer.create (String.length data / 4) in
  let consumed = ref 0 in
  let refill buffer =
    let len = min (Bigstringaf.length buffer) (String.length data - !consumed) in
    Bigstringaf.blit_from_string data ~src_off:!consumed buffer ~dst_off:0 ~len;
    consumed := !consumed + len;
    len
  in
  let flush buffer len =
    Buffer.add_string encoded (Bigstringaf.substring buffer ~off:0 ~len)
  in
  Zl.Higher.compress ~w ~q ~refill ~flush input output;
  Buffer.contents encoded

let encode ~width ~height ~rgb =
  (* Validate before arithmetic/allocation; each encoded row adds one filter
     byte, and PNG dimensions use positive 31-bit integers. *)
  if width <= 0 || height <= 0 || width > 0x7fffffff || height > 0x7fffffff
     || width > (Sys.max_string_length - 1) / 3
  then Error "invalid PNG dimensions"
  else
    let stride = width * 3 in
    if height > Sys.max_string_length / (stride + 1)
       || String.length rgb <> stride * height
    then Error "RGB byte length does not match PNG dimensions"
    else
      let scanlines = Bytes.make ((stride + 1) * height) '\000' in
      for row = 0 to height - 1 do
        Bytes.blit_string rgb (row * stride) scanlines ((row * (stride + 1)) + 1) stride
      done;
      let header = Bytes.make 13 '\000' in
      Bytes.set_int32_be header 0 (Int32.of_int width);
      Bytes.set_int32_be header 4 (Int32.of_int height);
      Bytes.set header 8 '\008';
      Bytes.set header 9 '\002';
      let output = Buffer.create 1024 in
      Buffer.add_string output "\137PNG\r\n\026\n";
      chunk output "IHDR" (Bytes.to_string header);
      chunk output "IDAT" (compress (Bytes.to_string scanlines));
      chunk output "IEND" "";
      Ok (Buffer.contents output)
