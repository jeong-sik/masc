(* Unit tests for Keeper_claude_mcp_autoconfig.

   See lib/keeper/keeper_claude_mcp_autoconfig.mli.  Issue #10049. *)

module KCA = Masc_mcp.Keeper_claude_mcp_autoconfig

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_base () =
  let dir = Filename.temp_file "kca_autoconfig_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  Unix.mkdir (Filename.concat (Filename.concat dir ".masc") "auth") 0o755;
  dir

let write_token base_path agent_name content =
  let auth_dir = Filename.concat (Filename.concat base_path ".masc") "auth" in
  let path = Filename.concat auth_dir (agent_name ^ ".token") in
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let rm_rf path =
  let rec rm p =
    match Unix.lstat p with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun n -> rm (Filename.concat p n)) (Sys.readdir p);
        Unix.rmdir p
    | _ -> Unix.unlink p
    | exception Unix.Unix_error _ -> ()
  in
  try rm path with _ -> ()

let test_happy_path () =
  let base = temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf base) @@ fun () ->
  write_token base "keeper-demo-agent" "hex_token_abc123";
  with_env "MASC_MCP_URL" "http://127.0.0.1:8935/mcp" @@ fun () ->
  match KCA.auto_construct ~base_path:base ~agent_name:"keeper-demo-agent" with
  | None -> Alcotest.fail "expected Some JSON, got None"
  | Some json ->
      (* Parse and assert structure rather than exact string — schema is
         what the downstream CLI reads. *)
      let doc = Yojson.Safe.from_string json in
      let open Yojson.Safe.Util in
      let servers = doc |> member "mcpServers" |> member "masc" in
      Alcotest.(check string) "type http"
        "http" (servers |> member "type" |> to_string);
      Alcotest.(check string) "url"
        "http://127.0.0.1:8935/mcp"
        (servers |> member "url" |> to_string);
      Alcotest.(check string) "authorization header"
        "Bearer hex_token_abc123"
        (servers |> member "headers" |> member "Authorization" |> to_string)

let test_missing_token_file () =
  let base = temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf base) @@ fun () ->
  (* No token written. *)
  with_env "MASC_MCP_URL" "http://127.0.0.1:8935/mcp" @@ fun () ->
  Alcotest.(check bool) "None when token file missing" true
    (KCA.auto_construct ~base_path:base ~agent_name:"keeper-ghost-agent" = None)

let test_empty_token_file () =
  let base = temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf base) @@ fun () ->
  write_token base "keeper-empty-agent" "   \n";
  with_env "MASC_MCP_URL" "http://127.0.0.1:8935/mcp" @@ fun () ->
  Alcotest.(check bool) "None when token file is whitespace" true
    (KCA.auto_construct ~base_path:base ~agent_name:"keeper-empty-agent" = None)

let test_missing_mcp_url_env () =
  let base = temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf base) @@ fun () ->
  write_token base "keeper-demo-agent" "hex_token";
  with_env "MASC_MCP_URL" "" @@ fun () ->
  Alcotest.(check bool) "None when MASC_MCP_URL is empty" true
    (KCA.auto_construct ~base_path:base ~agent_name:"keeper-demo-agent" = None)

let test_token_trimming () =
  let base = temp_base () in
  Fun.protect ~finally:(fun () -> rm_rf base) @@ fun () ->
  write_token base "keeper-ws-agent" "  padded_token_xyz  \n\n";
  with_env "MASC_MCP_URL" "http://localhost:8935/mcp" @@ fun () ->
  match KCA.auto_construct ~base_path:base ~agent_name:"keeper-ws-agent" with
  | None -> Alcotest.fail "expected Some"
  | Some json ->
      let doc = Yojson.Safe.from_string json in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "trimmed bearer"
        "Bearer padded_token_xyz"
        (doc |> member "mcpServers" |> member "masc"
           |> member "headers" |> member "Authorization" |> to_string)

let () =
  Alcotest.run "keeper_claude_mcp_autoconfig"
    [
      ( "auto_construct",
        [
          Alcotest.test_case "happy path" `Quick test_happy_path;
          Alcotest.test_case "missing token file → None" `Quick
            test_missing_token_file;
          Alcotest.test_case "empty token file → None" `Quick
            test_empty_token_file;
          Alcotest.test_case "missing MASC_MCP_URL → None" `Quick
            test_missing_mcp_url_env;
          Alcotest.test_case "token whitespace is trimmed" `Quick
            test_token_trimming;
        ] );
    ]
