(* Minimal PNG encoder: 8-bit truecolour, filter 0, deflate "stored"
   blocks. Runtime providers take an image block as PNG, not raw RGB, so
   the MSX lane encodes its frame buffers here. Stored blocks keep this
   free of a compression dependency -- a 512x212 frame lands at ~332 KB,
   and the provider re-encodes on its side anyway. *)

let signature = "\x89PNG\r\n\x1a\n"

(* CRC-32 (IEEE 802.3, reflected) as PNG chunks require. *)
let crc_table =
  let t = Array.make 256 0l in
  for n = 0 to 255 do
    let c = ref (Int32.of_int n) in
    for _ = 0 to 7 do
      if Int32.logand !c 1l <> 0l then
        c := Int32.logxor (Int32.shift_right_logical !c 1) 0xEDB88320l
      else c := Int32.shift_right_logical !c 1
    done;
    t.(n) <- !c
  done;
  t

let crc32 data =
  let c = ref 0xFFFFFFFFl in
  for i = 0 to String.length data - 1 do
    let idx = Int32.to_int (Int32.logand !c 0xFFl) lxor Char.code data.[i] in
    c := Int32.logxor (Int32.shift_right_logical !c 8) crc_table.(idx)
  done;
  Int32.logand (Int32.lognot !c) 0xFFFFFFFFl

let adler32 data =
  let a = ref 1l and b = ref 0l in
  for i = 0 to String.length data - 1 do
    a := Int32.rem (Int32.add !a (Int32.of_int (Char.code data.[i]))) 65521l;
    b := Int32.rem (Int32.add !b !a) 65521l
  done;
  Int32.logor (Int32.shift_left !b 16) (Int32.logand !a 0xFFFFl)

let add_be4 b v =
  Buffer.add_char b (Char.chr ((v lsr 24) land 0xff));
  Buffer.add_char b (Char.chr ((v lsr 16) land 0xff));
  Buffer.add_char b (Char.chr ((v lsr 8) land 0xff));
  Buffer.add_char b (Char.chr (v land 0xff))

(* One PNG chunk: 4-byte big-endian length, type, data, CRC over type+data. *)
let chunk typ data =
  let body = Buffer.create (8 + String.length data) in
  Buffer.add_string body typ;
  Buffer.add_string body data;
  let crc = Int32.to_int (crc32 (Buffer.contents body)) land 0xFFFFFFFF in
  let out = Buffer.create (16 + String.length data) in
  add_be4 out (String.length data);
  Buffer.add_string out typ;
  Buffer.add_string out data;
  add_be4 out crc;
  Buffer.contents out

(* A zlib stream whose deflate payload is stored (uncompressed) blocks:
   5 bytes of block header per at most 65535 bytes of data. *)
let zlib_stored data =
  let n = String.length data in
  let out = Buffer.create (n + (n / 65535 + 2) * 5 + 16) in
  Buffer.add_char out '\x78';
  Buffer.add_char out '\x01';
  let pos = ref 0 in
  let final = ref (n = 0) in
  while not !final do
    let take = min 65535 (n - !pos) in
    final := (!pos + take >= n);
    Buffer.add_char out (Char.chr (if !final then 1 else 0));
    Buffer.add_char out (Char.chr (take land 0xff));
    Buffer.add_char out (Char.chr ((take lsr 8) land 0xff));
    let nlen = lnot take in
    Buffer.add_char out (Char.chr (nlen land 0xff));
    Buffer.add_char out (Char.chr ((nlen lsr 8) land 0xff));
    Buffer.add_substring out data !pos take;
    pos := !pos + take
  done;
  let a = Int32.to_int (adler32 data) land 0xFFFFFFFF in
  Buffer.add_char out (Char.chr ((a lsr 24) land 0xff));
  Buffer.add_char out (Char.chr ((a lsr 16) land 0xff));
  Buffer.add_char out (Char.chr ((a lsr 8) land 0xff));
  Buffer.add_char out (Char.chr (a land 0xff));
  Buffer.contents out

(* Encode a width*height RGB buffer (3 bytes per pixel, row-major) as PNG.
   Raises Invalid_argument when the buffer does not match the dimensions. *)
let encode ~width ~height ~rgb =
  if width <= 0 || height <= 0 then
    invalid_arg "Msx_png.encode: dimensions must be positive";
  if String.length rgb <> width * height * 3 then
    invalid_arg
      (Printf.sprintf "Msx_png.encode: buffer is %d bytes, %dx%d needs %d"
         (String.length rgb) width height (width * height * 3));
  let stride = width * 3 in
  let raw = Buffer.create (height * (stride + 1)) in
  for y = 0 to height - 1 do
    Buffer.add_char raw '\000';
    Buffer.add_substring raw rgb (y * stride) stride
  done;
  let ihdr = Bytes.create 13 in
  Bytes.set ihdr 0 (Char.chr ((width lsr 24) land 0xff));
  Bytes.set ihdr 1 (Char.chr ((width lsr 16) land 0xff));
  Bytes.set ihdr 2 (Char.chr ((width lsr 8) land 0xff));
  Bytes.set ihdr 3 (Char.chr (width land 0xff));
  Bytes.set ihdr 4 (Char.chr ((height lsr 24) land 0xff));
  Bytes.set ihdr 5 (Char.chr ((height lsr 16) land 0xff));
  Bytes.set ihdr 6 (Char.chr ((height lsr 8) land 0xff));
  Bytes.set ihdr 7 (Char.chr (height land 0xff));
  (* bit depth 8, colour type 2 (truecolour), then compression, filter
     method and interlace -- all zero, the only defined values. *)
  Bytes.set ihdr 8 '\x08';
  Bytes.set ihdr 9 '\x02';
  Bytes.set ihdr 10 '\x00';
  Bytes.set ihdr 11 '\x00';
  Bytes.set ihdr 12 '\x00';
  String.concat ""
    [ signature
    ; chunk "IHDR" (Bytes.to_string ihdr)
    ; chunk "IDAT" (zlib_stored (Buffer.contents raw))
    ; chunk "IEND" "" ]
