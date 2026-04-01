(** Encryption Module - AES-256-GCM for MASC data protection *)

(* GCM compatibility - see gcm_compat.ml for version handling *)
module GCM = Gcm_compat

(** Encryption configuration *)
type config = {
  enabled: bool;
  key_source: [`Env of string | `File of string | `Direct of string];
  version: int;
}

(** Default configuration - encryption disabled by default for backward compatibility *)
let default_config = {
  enabled = false;
  key_source = `Env "MASC_ENCRYPTION_KEY";
  version = 1;
}

(** Encrypted envelope format *)
type envelope = {
  encrypted: bool;
  version: int;
  nonce: string;    (* base64 encoded *)
  ciphertext: string; (* base64 encoded *)
  adata: string;    (* associated data identifier *)
}

(** Error types *)
type encryption_error =
  | KeyNotFound of string
  | InvalidKeyLength of int
  | InvalidHexFormat of string
  | DecryptionFailed
  | InvalidEnvelope of string
  | RngNotInitialized

let show_encryption_error = function
  | KeyNotFound s -> Printf.sprintf "KeyNotFound: %s" s
  | InvalidKeyLength n -> Printf.sprintf "InvalidKeyLength: expected 32, got %d" n
  | InvalidHexFormat s -> Printf.sprintf "InvalidHexFormat: %s" s
  | DecryptionFailed -> "DecryptionFailed: authentication tag mismatch"
  | InvalidEnvelope s -> Printf.sprintf "InvalidEnvelope: %s" s
  | RngNotInitialized -> "RngNotInitialized: call initialize() first"

(** RNG initialization state *)
let rng_initialized = ref false

(** Initialize the RNG - must be called before encryption operations *)
let initialize () =
  if not !rng_initialized then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true
  end

(** Base64 encoding/decoding *)
let base64_encode cs =
  Base64.encode_string (Cstruct.to_string cs)

let base64_decode s =
  match Base64.decode s with
  | Ok decoded -> Some (Cstruct.of_string decoded)
  | Error _ -> None

(** Decode hex string to raw bytes. Returns Error on invalid input.
    Does not include input content in error messages to avoid leaking
    key material through diagnostics/logs. *)
let decode_hex_key content : (string, encryption_error) result =
  let content = String.trim content in
  let len = String.length content in
  if len <> 64 then
    Error (InvalidHexFormat
      (Printf.sprintf "hex key must be exactly 64 characters, got %d" len))
  else
    let buf = Buffer.create 32 in
    let err = ref None in
    let i = ref 0 in
    while !i < 32 && Option.is_none !err do
      let hex = String.sub content (!i * 2) 2 in
      (match int_of_string_opt ("0x" ^ hex) with
       | Some v when v >= 0 && v <= 255 ->
           Buffer.add_char buf (Char.chr v)
       | _ ->
           err := Some (InvalidHexFormat
             (Printf.sprintf "invalid hex byte at position %d" (!i * 2))));
      incr i
    done;
    match !err with
    | Some e -> Error e
    | None -> Ok (Buffer.contents buf)

(** Load encryption key from configured source *)
let load_key config : (GCM.key, encryption_error) result =
  let key_result = match config.key_source with
    | `Env var_name ->
        (match Sys.getenv_opt var_name with
         | Some v -> Ok (Some v)
         | None -> Ok None)
    | `File path ->
        if Sys.file_exists path then
          (match decode_hex_key (Fs_compat.load_file path) with
           | Ok bytes -> Ok (Some bytes)
           | Error e -> Error e)
        else Ok None
    | `Direct key -> Ok (Some key)
  in
  match key_result with
  | Error e -> Error e
  | Ok None -> Error (KeyNotFound "encryption key not configured")
  | Ok (Some key) when String.length key <> 32 ->
      Error (InvalidKeyLength (String.length key))
  | Ok (Some key) ->
      Ok (GCM.of_secret key)

(** Generate a random 12-byte nonce (GCM recommended size) *)
let generate_nonce () =
  if not !rng_initialized then
    Error RngNotInitialized
  else
    Ok (Mirage_crypto_rng.generate 12)

(** Encrypt JSON data *)
let encrypt_json ~key ~adata json : (envelope, encryption_error) result =
  match generate_nonce () with
  | Error e -> Error e
  | Ok nonce ->
      let plaintext = Yojson.Safe.to_string json in
      let ciphertext = GCM.authenticate_encrypt ~key ~nonce ~adata plaintext in
      Ok {
        encrypted = true;
        version = 1;
        nonce = Base64.encode_string nonce;
        ciphertext = Base64.encode_string ciphertext;
        adata;
      }

(** Decrypt envelope back to JSON *)
let decrypt_envelope ~key envelope : (Yojson.Safe.t, encryption_error) result =
  if not envelope.encrypted then
    Error (InvalidEnvelope "not encrypted")
  else
    match Base64.decode envelope.nonce, Base64.decode envelope.ciphertext with
    | Error _, _ -> Error (InvalidEnvelope "invalid nonce encoding")
    | _, Error _ -> Error (InvalidEnvelope "invalid ciphertext encoding")
    | Ok nonce, Ok ciphertext ->
        match GCM.authenticate_decrypt ~key ~nonce ~adata:envelope.adata ciphertext with
        | None -> Error DecryptionFailed
        | Some plaintext ->
            try Ok (Yojson.Safe.from_string plaintext)
            with Yojson.Json_error _ -> Error (InvalidEnvelope "decrypted data is not valid JSON")

(** Convert envelope to JSON for storage *)
let envelope_to_json envelope =
  `Assoc [
    ("_encrypted", `Bool envelope.encrypted);
    ("v", `Int envelope.version);
    ("nonce", `String envelope.nonce);
    ("ct", `String envelope.ciphertext);
    ("adata", `String envelope.adata);
  ]

(** Parse JSON to envelope *)
let envelope_of_json json : envelope option =
  match Safe_ops.json_bool_opt "_encrypted" json,
        Safe_ops.json_int_opt "v" json,
        Safe_ops.json_string_opt "nonce" json,
        Safe_ops.json_string_opt "ct" json,
        Safe_ops.json_string_opt "adata" json with
  | Some encrypted, Some version, Some nonce, Some ciphertext, Some adata ->
    Some { encrypted; version; nonce; ciphertext; adata }
  | _ -> None

(** Check if JSON is an encrypted envelope *)
let is_encrypted_json json =
  Safe_ops.json_bool ~default:false "_encrypted" json

(** Smart read: transparently decrypt if encrypted, pass through if plain *)
let smart_read_json ~config ~adata path : (Yojson.Safe.t, encryption_error) result =
  let content = Fs_compat.load_file path in
  let json = Yojson.Safe.from_string content in
  if is_encrypted_json json then
    match load_key config with
    | Error e -> Error e
    | Ok key ->
        match envelope_of_json json with
        | None -> Error (InvalidEnvelope "malformed envelope")
        | Some env ->
            if env.adata <> adata then
              Error (InvalidEnvelope "adata mismatch")
            else
              decrypt_envelope ~key env
  else
    Ok json

(** Smart write: encrypt if enabled, write plain if disabled *)
let smart_write_json ~config ~adata path json : (unit, encryption_error) result =
  if not config.enabled then begin
    let content = Yojson.Safe.pretty_to_string json in
    Fs_compat.save_file path content;
    Ok ()
  end else
    match load_key config with
    | Error e -> Error e
    | Ok key ->
        match encrypt_json ~key ~adata json with
        | Error e -> Error e
        | Ok envelope ->
            let content = Yojson.Safe.pretty_to_string (envelope_to_json envelope) in
            Fs_compat.save_file path content;
            Ok ()

(** Generate a new random 32-byte key (hex encoded for storage) *)
let generate_key_hex () =
  if not !rng_initialized then
    Error RngNotInitialized
  else
    let key_bytes = Mirage_crypto_rng.generate 32 in
    let buf = Buffer.create 64 in
    for i = 0 to String.length key_bytes - 1 do
      Buffer.add_string buf (Printf.sprintf "%02x" (Char.code (String.get key_bytes i)))
    done;
    Ok (Buffer.contents buf)

(** Encryption status for diagnostics *)
let get_status config =
  let key_status = match load_key config with
    | Ok _ -> "loaded"
    | Error e -> show_encryption_error e
  in
  `Assoc [
    ("enabled", `Bool config.enabled);
    ("rng_initialized", `Bool !rng_initialized);
    ("key_status", `String key_status);
    ("version", `Int config.version);
  ]
