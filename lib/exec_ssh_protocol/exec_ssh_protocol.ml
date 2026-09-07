(* Protocol codec for the Phase 1 SSH remote execution lane.
   See the .mli — it is the SSOT contract for the wire format.
   Spec: docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md §4.2. *)

(* Every wire major this build reads and writes, closed. v2 is v3 without
   [mode] and means [Effect], so a shim and a server one release apart keep
   talking: the newer side reads the other's probe and speaks the older
   version to it. Retiring v2 is deleting [V2] here; the compiler then
   points at every arm that spoke it. *)
type major =
  | V2
  | V3

type mode =
  | Effect
  | Observe
  | Guest_local

type request =
  { v : major
  ; argv : string list
  ; env : (string * string) list
  ; cwd : string
  ; remote_root : string
  ; timeout_sec : float
  ; stdin_len : int64
  ; mode : mode
  }

type trailer =
  { v : major
  ; exit : int option
  ; signal : int option
  ; timed_out : bool
  ; shim_error : string option
  }

type probe =
  { name : string
  ; version : string
  ; capabilities : string list
  ; release : string option
  }

let newest = V3
let majors = [ V2; V3 ]

let int_of_major = function
  | V2 -> 2
  | V3 -> 3

let major_of_int = function
  | 2 -> Some V2
  | 3 -> Some V3
  | _ -> None

let protocol_version = int_of_major newest

let majors_text () =
  String.concat ", " (List.map (fun m -> "v" ^ string_of_int (int_of_major m)) majors)

(* The numeric prefix of a dotted version: "3.0.0" -> 3. *)
let major_int_of_version s =
  let n = String.length s in
  let rec stop i =
    if i < n && s.[i] >= '0' && s.[i] <= '9' then stop (i + 1) else i
  in
  let e = stop 0 in
  if e = 0 then None else int_of_string_opt (String.sub s 0 e)

let major_of_probe (p : probe) : (major, string) result =
  match major_int_of_version p.version with
  | None -> Error (Printf.sprintf "the shim's version %S has no numeric major" p.version)
  | Some n ->
    (match major_of_int n with
     | Some major -> Ok major
     | None ->
       Error
         (Printf.sprintf "the shim speaks v%d and this build speaks %s" n (majors_text ())))

let observe_capability = "observe"
let default_scratch_root = "/tmp"

let mode_to_string = function
  | Effect -> "effect"
  | Observe -> "observe"
  | Guest_local -> "guest_local"

let mode_of_string = function
  | "effect" -> Some Effect
  | "observe" -> Some Observe
  | "guest_local" -> Some Guest_local
  | _ -> None

let shim_config_env_var = "MASC_EXEC_SHIM_CONFIG"

let trailer_wrapper_key = "masc_exec_result"

let rs = '\x1e'

let transport_error fmt =
  Printf.ksprintf (fun m -> Error ("remote_ssh_transport_error: " ^ m)) fmt

let version_error fmt =
  Printf.ksprintf (fun m -> Error ("remote_ssh_version_error: " ^ m)) fmt

(* --- small result helpers --- *)

let ( >>= ) = Result.bind

let ( let* ) = Result.bind

let b64_encode s = Base64.encode_string s

let b64_decode ~what s =
  match Base64.decode s with
  | Ok d -> Ok d
  | Error (`Msg m) -> transport_error "base64 decode of %s: %s" what m

(* --- request frame --- *)

(* The [mode] field is v3's addition; a v2 frame has no such field, and a
   v2 shim would refuse one it did not expect. Every other field is the
   same in both majors. *)
let json_of_request (r : request) : Yojson.Safe.t =
  `Assoc
    ([ "v", `Int (int_of_major r.v)
     ; "argv", `List (List.map (fun a -> `String (b64_encode a)) r.argv)
     ; ( "env"
       , `List
           (List.map
              (fun (k, v) -> `List [ `String (b64_encode k); `String (b64_encode v) ])
              r.env) )
     ; "cwd", `String (b64_encode r.cwd)
     ; "remote_root", `String (b64_encode r.remote_root)
     ; "timeout_sec", `Float r.timeout_sec
     ; "stdin_len", `Intlit (Int64.to_string r.stdin_len)
     ]
     @ (match r.v with
        | V2 -> []
        | V3 -> [ "mode", `String (mode_to_string r.mode) ]))

(* A v2 shim has no box to build, so a v2 frame has no box to ask for. *)
let asks_a_box_of_v2 (r : request) =
  match r.v, r.mode with
  | V2, (Observe | Guest_local) -> true
  | V2, Effect | V3, (Effect | Observe | Guest_local) -> false

let encode_request (r : request) ~stdin : (string, string) result =
  let stdin_bytes = String.length stdin in
  match classify_float r.timeout_sec with
  | FP_nan | FP_infinite ->
    transport_error "request timeout_sec is not finite (%F)" r.timeout_sec
  | _ ->
    if asks_a_box_of_v2 r then
      version_error
        "a v2 frame cannot ask for the %s box: the endpoint's shim speaks v2 and runs \
         every request unboxed"
        (mode_to_string r.mode)
    else if r.stdin_len <> Int64.of_int stdin_bytes then
      transport_error
        "request stdin_len (%Ld) does not match the stdin payload (%d bytes)"
        r.stdin_len stdin_bytes
    else begin
      let json = Yojson.Safe.to_string (json_of_request r) in
      let json_len = String.length json in
      let frame = Bytes.create (8 + json_len + stdin_bytes) in
      (* 8-byte big-endian length: json_len + stdin_len *)
      let rec put i v =
        if i >= 0 then begin
          Bytes.set frame i (Char.chr (Int64.to_int (Int64.logand v 0xffL)));
          put (i - 1) (Int64.shift_right_logical v 8)
        end
      in
      put 7 (Int64.of_int (json_len + stdin_bytes));
      Bytes.blit_string json 0 frame 8 json_len;
      Bytes.blit_string stdin 0 frame (8 + json_len) stdin_bytes;
      Ok (Bytes.unsafe_to_string frame)
    end

(* Byte index just past the end of the JSON value starting at [start],
   or [None] if the value is unterminated.  Tracks string state (with
   backslash escapes) and {}/[] nesting.  Exact for any frame this
   module emits: base64 payloads contain no quotes or backslashes, and
   the remaining fields are numbers.  Hand-rolled instead of a JSON
   streaming parser because the raw stdin bytes immediately follow the
   JSON and a parser with token lookahead could choke on them. *)
let json_value_end s ~start : int option =
  let n = String.length s in
  let rec scan i depth in_str =
    if i >= n then None
    else begin
      match s.[i], in_str with
      | '\\', true -> if i + 1 < n then scan (i + 2) depth true else None
      | '"', true -> scan (i + 1) depth false
      | _, true -> scan (i + 1) depth true
      | '"', false -> scan (i + 1) depth true
      | ('{' | '['), false -> scan (i + 1) (depth + 1) false
      | ('}' | ']'), false ->
        if depth = 1 then Some (i + 1) else scan (i + 1) (depth - 1) false
      | _, false -> scan (i + 1) depth false
    end
  in
  if start < n && (s.[start] = '{' || s.[start] = '[') then scan start 0 false
  else None

let parse_json ~what s : (Yojson.Safe.t, string) result =
  match Yojson.Safe.from_string s with
  | json -> Ok json
  | exception Yojson.Json_error m ->
    transport_error "invalid %s JSON: %s" what m

let member ~what name fields =
  match List.assoc_opt name fields with
  | Some v -> Ok v
  | None -> transport_error "%s JSON missing field %S" what name

let expect_assoc ~what : Yojson.Safe.t -> ((string * Yojson.Safe.t) list, string) result =
  function
  | `Assoc fields -> Ok fields
  | _ -> transport_error "%s JSON is not an object" what

let expect_int ~what name : Yojson.Safe.t -> (int, string) result = function
  | `Int i -> Ok i
  | _ -> transport_error "%s field %S is not an int" what name

let expect_int64 ~what name : Yojson.Safe.t -> (int64, string) result = function
  | `Int i -> Ok (Int64.of_int i)
  | `Intlit s ->
    (match Int64.of_string_opt s with
     | Some i -> Ok i
     | None -> transport_error "%s field %S is not an int64" what name)
  | _ -> transport_error "%s field %S is not an int64" what name

let expect_float ~what name : Yojson.Safe.t -> (float, string) result = function
  | `Float f -> Ok f
  | `Int i -> Ok (Float.of_int i)
  | _ -> transport_error "%s field %S is not a float" what name

let expect_string ~what name : Yojson.Safe.t -> (string, string) result = function
  | `String s -> Ok s
  | _ -> transport_error "%s field %S is not a string" what name

let expect_string_list ~what name : Yojson.Safe.t -> (string list, string) result =
  function
  | `List l ->
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: tl -> go (s :: acc) tl
      | _ -> transport_error "%s field %S is not a string list" what name
    in
    go [] l
  | _ -> transport_error "%s field %S is not a string list" what name

let expect_b64_list ~what name json : (string list, string) result =
  let* l = expect_string_list ~what name json in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | s :: tl ->
      (match b64_decode ~what:name s with
       | Ok d -> go (d :: acc) tl
       | Error _ as e -> e)
  in
  go [] l

let expect_opt_int ~what name : Yojson.Safe.t -> (int option, string) result = function
  | `Null -> Ok None
  | `Int i -> Ok (Some i)
  | _ -> transport_error "%s field %S is not an int or null" what name

let expect_opt_string ~what name : Yojson.Safe.t -> (string option, string) result =
  function
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | _ -> transport_error "%s field %S is not a string or null" what name

let expect_bool ~what name : Yojson.Safe.t -> (bool, string) result = function
  | `Bool b -> Ok b
  | _ -> transport_error "%s field %S is not a bool" what name

let check_version ~what v =
  match major_of_int v with
  | Some major -> Ok major
  | None -> version_error "%s carries v=%d, this build speaks %s" what v (majors_text ())

let request_of_json (json : Yojson.Safe.t) : (request, string) result =
  let what = "request" in
  let* fields = expect_assoc ~what json in
  let* v = member ~what "v" fields >>= expect_int ~what "v" >>= check_version ~what in
  let* argv = member ~what "argv" fields >>= expect_b64_list ~what "argv" in
  let* env_json = member ~what "env" fields in
  let* env =
    match env_json with
    | `List pairs ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | `List [ `String k; `String v ] :: tl ->
          (match b64_decode ~what:"env name" k, b64_decode ~what:"env value" v with
           | Ok k, Ok v -> go ((k, v) :: acc) tl
           | (Error _ as e), _ | _, (Error _ as e) -> e)
        | _ -> transport_error "request field %S is not a list of name/value pairs" "env"
      in
      go [] pairs
    | _ -> transport_error "request field %S is not a list" "env"
  in
  let* cwd_json = member ~what "cwd" fields >>= expect_string ~what "cwd" in
  let* cwd = b64_decode ~what:"cwd" cwd_json in
  let* remote_root_json =
    member ~what "remote_root" fields >>= expect_string ~what "remote_root"
  in
  let* remote_root = b64_decode ~what:"remote_root" remote_root_json in
  let* timeout_sec = member ~what "timeout_sec" fields >>= expect_float ~what "timeout_sec" in
  let* stdin_len = member ~what "stdin_len" fields >>= expect_int64 ~what "stdin_len" in
  (* v2 has no [mode] and means [Effect]; a v2 frame that carries one is a
     frame from a build that does not know what v2 is, refused by name. v3
     requires it. *)
  let* mode =
    match v, List.assoc_opt "mode" fields with
    | V2, None -> Ok Effect
    | V2, Some _ ->
      version_error "request carries v=2 and a mode field; a v2 frame has no box to ask for"
    | V3, None -> transport_error "request field %S is missing" "mode"
    | V3, Some json ->
      let* mode_text = expect_string ~what "mode" json in
      (match mode_of_string mode_text with
       | Some mode -> Ok mode
       | None ->
         transport_error
           "request field %S is %S; this build speaks effect, observe, guest_local"
           "mode" mode_text)
  in
  (match classify_float timeout_sec with
   | FP_nan | FP_infinite ->
     transport_error "request timeout_sec is not finite (%F)" timeout_sec
   | _ ->
     if Int64.compare stdin_len 0L < 0 then
       transport_error "request stdin_len is negative (%Ld)" stdin_len
     else
       Ok { v; argv; env; cwd; remote_root; timeout_sec; stdin_len; mode })

let decode_request (frame : string) : (request * string, string) result =
  let n = String.length frame in
  if n < 8 then
    transport_error "frame is %d bytes, shorter than the 8-byte length prefix" n
  else begin
    let declared = ref 0L in
    for i = 0 to 7 do
      declared :=
        Int64.logor (Int64.shift_left !declared 8) (Int64.of_int (Char.code frame.[i]))
    done;
    let payload = n - 8 in
    if Int64.compare !declared 0L < 0 || !declared <> Int64.of_int payload then
      transport_error
        "length prefix declares %Ld bytes but the frame carries %d payload bytes"
        !declared payload
    else begin
      match json_value_end frame ~start:8 with
      | None -> transport_error "unterminated request JSON"
      | Some jend ->
        let* json = parse_json ~what:"request" (String.sub frame 8 (jend - 8)) in
        let* r = request_of_json json in
        let stdin = String.sub frame jend (n - jend) in
        let actual = Int64.of_int (String.length stdin) in
        if r.stdin_len <> actual then
          transport_error
            "stdin_len mismatch: JSON declares %Ld bytes but the frame carries %Ld \
             (refusing a truncated read)"
            r.stdin_len actual
        else
          Ok (r, stdin)
    end
  end

(* --- result trailer --- *)

let opt_json to_json = function
  | None -> `Null
  | Some x -> to_json x

let render_trailer (t : trailer) : string =
  let body =
    `Assoc
      [ "v", `Int (int_of_major t.v)
      ; "exit", opt_json (fun i -> `Int i) t.exit
      ; "signal", opt_json (fun i -> `Int i) t.signal
      ; "timed_out", `Bool t.timed_out
      ; "shim_error", opt_json (fun s -> `String s) t.shim_error
      ]
  in
  Printf.sprintf "%c%s%c" rs
    (Yojson.Safe.to_string (`Assoc [ trailer_wrapper_key, body ]))
    rs

let trailer_of_json (json : Yojson.Safe.t) : (trailer, string) result =
  let what = "trailer" in
  let* fields = expect_assoc ~what json in
  let* wrapped = member ~what trailer_wrapper_key fields >>= expect_assoc ~what in
  let* v = member ~what "v" wrapped >>= expect_int ~what "v" >>= check_version ~what in
  let* exit = member ~what "exit" wrapped >>= expect_opt_int ~what "exit" in
  let* signal = member ~what "signal" wrapped >>= expect_opt_int ~what "signal" in
  let* timed_out = member ~what "timed_out" wrapped >>= expect_bool ~what "timed_out" in
  let* shim_error =
    member ~what "shim_error" wrapped >>= expect_opt_string ~what "shim_error"
  in
  let set_count =
    (if exit = None then 0 else 1)
    + (if signal = None then 0 else 1)
    + (if shim_error = None then 0 else 1)
  in
  if set_count > 1 then
    transport_error
      "malformed trailer: exit/signal/shim_error are mutually exclusive"
  else if set_count = 0 && not timed_out then
    transport_error
      "malformed trailer: no exit, signal or shim_error and timed_out is false"
  else
    Ok { v; exit; signal; timed_out; shim_error }

let parse_trailer (tail : string) : (trailer, string) result =
  match String.rindex_opt tail rs with
  | None -> transport_error "no trailer delimiter in the stderr tail"
  | Some j ->
    if j = 0 then
      transport_error "lone trailer delimiter at byte 0, no opening delimiter"
    else begin
      match String.rindex_from_opt tail (j - 1) rs with
      | None -> transport_error "only one trailer delimiter in the stderr tail"
      | Some i ->
        let* json = parse_json ~what:"trailer" (String.sub tail (i + 1) (j - i - 1)) in
        trailer_of_json json
    end

(* --- shim probe --- *)

let render_probe (p : probe) : string =
  Yojson.Safe.to_string
    (`Assoc
      ([ "name", `String p.name
       ; "version", `String p.version
       ; "capabilities", `List (List.map (fun c -> `String c) p.capabilities)
       ]
       @
       match p.release with
       | None -> []
       | Some release -> [ "release", `String release ]))

let parse_probe (s : string) : (probe, string) result =
  let what = "probe" in
  let* json = parse_json ~what s in
  let* fields = expect_assoc ~what json in
  let* name = member ~what "name" fields >>= expect_string ~what "name" in
  let* version = member ~what "version" fields >>= expect_string ~what "version" in
  let* capabilities =
    member ~what "capabilities" fields >>= expect_string_list ~what "capabilities"
  in
  let release =
    match List.assoc_opt "release" fields with
    | Some (`String release) when release <> "" -> Some release
    | Some _ | None -> None
  in
  Ok { name; version; capabilities; release }

