(** Encryption tools - Data encryption management *)

open Tool_args

type context = {
  state: Mcp_server.server_state;
}

type result = bool * string

let handle_encryption_status ctx _args =
  let status = Encryption.get_status (Atomic.get ctx.state.Mcp_server.encryption_config) in
  let msg = Printf.sprintf "🔐 Encryption Status\n%s"
    (Yojson.Safe.pretty_to_string status) in
  (true, msg)

let handle_encryption_enable ctx args =
  Encryption.initialize ();
  let key_source = get_string args "key_source" "env" in
  let parse_hex_to_bytes hex =
    if String.length hex <> 64 then
      Error (Printf.sprintf "Invalid hex key length: %d (expected 64)" (String.length hex))
    else
      try
        let bytes = Bytes.create 32 in
        for i = 0 to 31 do
          let hex_pair = String.sub hex (i * 2) 2 in
          Bytes.set bytes i (Char.chr (int_of_string ("0x" ^ hex_pair)))
        done;
        Ok (Bytes.to_string bytes)
      with Invalid_argument _ | Failure _ -> Error "Failed to decode hex key"
  in
  let (key_source_variant, generated_key_opt) =
    if key_source = "env" then
      (`Env "MASC_ENCRYPTION_KEY", None)
    else if String.length key_source > 5 && String.sub key_source 0 5 = "file:" then
      let path = String.sub key_source 5 (String.length key_source - 5) in
      (`File path, None)
    else if key_source = "generate" then
      match Encryption.generate_key_hex () with
      | Error e -> (`Env "MASC_ENCRYPTION_KEY", Some (Error (Encryption.show_encryption_error e)))
      | Ok hex ->
          (match parse_hex_to_bytes hex with
           | Ok bytes -> (`Direct bytes, Some (Ok hex))
           | Error err -> (`Env "MASC_ENCRYPTION_KEY", Some (Error err)))
    else
      (`Env "MASC_ENCRYPTION_KEY", Some (Error "Invalid key_source"))
  in
  match generated_key_opt with
  | Some (Error e) -> (false, Printf.sprintf "❌ %s" e)
  | _ ->
      let current_config = Atomic.get ctx.state.Mcp_server.encryption_config in
      let new_config = { current_config with
        Encryption.enabled = true;
        key_source = key_source_variant;
      } in
      (match Encryption.load_key new_config with
       | Error e ->
           (false, Printf.sprintf "❌ Failed: %s" (Encryption.show_encryption_error e))
       | Ok _ ->
           Atomic.set ctx.state.Mcp_server.encryption_config new_config;
           let msg =
             match generated_key_opt with
             | Some (Ok hex) ->
                 Printf.sprintf "🔐 Encryption enabled (generated key).\n\n🔑 Key (hex): %s\n\n⚠️ Store this securely!" hex
             | _ -> "🔐 Encryption enabled."
           in
           (true, msg))

let handle_encryption_disable ctx _args =
  let current = Atomic.get ctx.state.Mcp_server.encryption_config in
  Atomic.set ctx.state.Mcp_server.encryption_config { current with Encryption.enabled = false };
  (true, "🔓 Encryption disabled. New data will be stored in plain text.")

let handle_generate_key _ctx args =
  Encryption.initialize ();
  match Encryption.generate_key_hex () with
  | Error e ->
      (false, Printf.sprintf "❌ Failed: %s" (Encryption.show_encryption_error e))
  | Ok hex_key ->
      let output = get_string args "output" "hex" in
      let key_str =
        if output = "base64" then
          let bytes = Bytes.create 32 in
          for i = 0 to 31 do
            let hex = String.sub hex_key (i * 2) 2 in
            Bytes.set bytes i (Char.chr (int_of_string ("0x" ^ hex)))
          done;
          Base64.encode_string (Bytes.to_string bytes)
        else
          hex_key
      in
      let msg = Printf.sprintf "🔑 Generated 256-bit AES key (%s):\n\n%s\n\n⚠️ Store this securely! Losing the key = losing encrypted data." output key_str in
      (true, msg)

let schemas : Types.tool_schema list = [
  {
    name = "masc_encryption_status";
    description = "Get encryption status for this MASC room. Shows if encryption is enabled, key status, and RNG state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_encryption_enable";
    description = "Enable encryption for sensitive data in this MASC room. Requires setting MASC_ENCRYPTION_KEY environment variable (32-byte key) or providing a key file path.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key_source", `Assoc [
          ("type", `String "string");
          ("description", `String "Key source: 'env' (from MASC_ENCRYPTION_KEY), 'file:<path>' (from file), or 'generate' (create new key)");
          ("default", `String "env");
        ]);
      ]);
    ];
  };
  {
    name = "masc_encryption_disable";
    description = "Disable encryption for this MASC room. Existing encrypted data will remain encrypted but new data will be stored in plain text.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_generate_key *)
  {
    name = "masc_generate_key";
    description = "Generate a random 256-bit encryption key in hex or base64 format. \
Use when setting up encryption for the first time or rotating keys. \
Store the key securely. Pair with masc_encryption_enable to apply.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("output", `Assoc [
          ("type", `String "string");
          ("description", `String "Output format: 'hex' (64 chars), 'base64' (44 chars)");
          ("default", `String "hex");
        ]);
      ]);
    ];
  };

]

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_encryption_status" -> Some (handle_encryption_status ctx args)
  | "masc_encryption_enable" -> Some (handle_encryption_enable ctx args)
  | "masc_encryption_disable" -> Some (handle_encryption_disable ctx args)
  | "masc_generate_key" -> Some (handle_generate_key ctx args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_encryption
           ~input_schema:s.input_schema
           ()))
    schemas
