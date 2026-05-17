(** Server_mcp_streaming_tools — auto-upgrade dispatch registry for
    POST /mcp [tools/call] requests.

    RFC-0100 PR-3: a [POST /mcp] [tools/call] request promotes to SSE
    framing (same chunked connection, [content-type: text/event-stream])
    only when the named tool appears in this registry. Tools outside the
    registry receive the chunked-JSON shape introduced by RFC-0100 PR-2.

    The registry is a hand-curated SSOT. Each entry should correspond to a
    tool whose handler is wired to emit incremental progress through the
    POST-SSE writer ([stream_post_sse_json] in [server_mcp_transport_http]).
    Adding a tool name here without that wiring is harmless — the dispatcher
    still emits a single [event: message] terminal frame — but it pays for
    the SSE keepalive fiber and the [text/event-stream] framing overhead
    without benefit.

    Removing a tool name flips its POST response from SSE framing to
    chunked JSON. JSON-RPC body and headers are identical; only the
    transfer framing differs. A client that already accepts chunked JSON
    (the default per RFC-0100 PR-2) is unaffected. *)

let streaming_capable_tools =
  [ (* Coordination surface — long-poll messaging and status, currently the
       only consumers of inline POST→SSE framing exercised by the e2e suite
       (test/test_mcp_post_sse_e2e.ml). Promoting these to the registry
       holds the public contract while non-listed tools default to chunked
       JSON under RFC-0100 PR-3. *)
    "masc_status"
  ; "masc_join"
  ]

let set =
  let tbl = Hashtbl.create (List.length streaming_capable_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) streaming_capable_tools;
  tbl

let is_streaming_capable name = Hashtbl.mem set name
