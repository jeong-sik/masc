let encode_uint (n : int) : string =
  let buf = Buffer.create 8 in
  let rec loop num =
    if num < 128 then Buffer.add_char buf (Char.chr num)
    else begin
      Buffer.add_char buf (Char.chr ((num land 0x7f) lor 0x80));
      loop (num lsr 7)
    end
  in
  loop n;
  Buffer.contents buf

let decode_uint (str : string) ~pos : int * int =
  let rec loop acc shift p =
    if p >= String.length str then failwith "decode_uint: out of bounds";
    let b = Char.code str.[p] in
    let acc' = acc lor ((b land 0x7f) lsl shift) in
    if b < 128 then (acc', p + 1)
    else loop acc' (shift + 7) (p + 1)
  in
  loop 0 0 pos
