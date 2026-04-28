type t = string

let initialized = ref false

let init_random () =
  if not !initialized then begin
    Random.self_init ();
    initialized := true
  end

let hex_byte n = Printf.sprintf "%02x" (n land 0xFF)

let generate () =
  init_random ();
  let now_ms = Int64.of_float (Unix.gettimeofday () *. 1000.0) in
  let ts48 = Int64.logand now_ms 0xFFFFFFFFFFFFL in
  let byte_at shift =
    Int64.to_int (Int64.shift_right_logical ts48 shift) land 0xFF
  in
  let b0 = byte_at 40 in
  let b1 = byte_at 32 in
  let b2 = byte_at 24 in
  let b3 = byte_at 16 in
  let b4 = byte_at 8 in
  let b5 = byte_at 0 in
  let rand_12 = Random.int 0x1000 in
  let b6 = 0x70 lor ((rand_12 lsr 8) land 0x0F) in
  let b7 = rand_12 land 0xFF in
  let rand_14 = Random.int 0x4000 in
  let b8 = 0x80 lor ((rand_14 lsr 8) land 0x3F) in
  let b9 = rand_14 land 0xFF in
  let r1 = Random.int 0x1000000 in
  let r2 = Random.int 0x1000000 in
  let b10 = (r1 lsr 16) land 0xFF in
  let b11 = (r1 lsr 8) land 0xFF in
  let b12 = r1 land 0xFF in
  let b13 = (r2 lsr 16) land 0xFF in
  let b14 = (r2 lsr 8) land 0xFF in
  let b15 = r2 land 0xFF in
  Printf.sprintf "%s%s%s%s-%s%s-%s%s-%s%s-%s%s%s%s%s%s"
    (hex_byte b0) (hex_byte b1) (hex_byte b2) (hex_byte b3)
    (hex_byte b4) (hex_byte b5)
    (hex_byte b6) (hex_byte b7)
    (hex_byte b8) (hex_byte b9)
    (hex_byte b10) (hex_byte b11) (hex_byte b12)
    (hex_byte b13) (hex_byte b14) (hex_byte b15)

let is_hex c =
  (c >= '0' && c <= '9')
  || (c >= 'a' && c <= 'f')
  || (c >= 'A' && c <= 'F')

let of_string s =
  if String.length s <> 36 then
    Error (Printf.sprintf "Artifact_id.of_string: expected 36 chars, got %d"
             (String.length s))
  else if s.[8] <> '-' || s.[13] <> '-' || s.[18] <> '-' || s.[23] <> '-' then
    Error "Artifact_id.of_string: missing dashes at expected positions"
  else if s.[14] <> '7' then
    Error (Printf.sprintf "Artifact_id.of_string: expected version '7', got %c"
             s.[14])
  else
    let v = Char.lowercase_ascii s.[19] in
    if v <> '8' && v <> '9' && v <> 'a' && v <> 'b' then
      Error (Printf.sprintf "Artifact_id.of_string: invalid variant nibble %c" v)
    else begin
      let valid = ref true in
      for i = 0 to 35 do
        if i <> 8 && i <> 13 && i <> 18 && i <> 23 && not (is_hex s.[i]) then
          valid := false
      done;
      if !valid then Ok (String.lowercase_ascii s)
      else Error "Artifact_id.of_string: non-hex character in body"
    end

let to_string t = t

let compare = String.compare

let equal = String.equal

let to_json t = `String t

let of_json = function
  | `String s -> of_string s
  | _ -> Error "Artifact_id.of_json: expected string"
