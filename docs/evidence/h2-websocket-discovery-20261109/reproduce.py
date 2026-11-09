#!/usr/bin/env python3
"""Run verbatim router/handler control flow with isolated response sinks.

No MASC Dune build, TLS handshake or WebSocket runtime is performed here.
The request/header parser is the installed httpun library; auth, discovery
payload generation and upgrade attachment are stubs.
"""
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
BASE = "66cb2c7317b2"
CORE = "lib/http_server_eio.ml"
FRONTEND = "lib/server/server_routes_http_routes_frontend.ml"

PREAMBLE = r"""
module Http_reqd = struct
  type upgrade = unit
  type t = { mutable status : int; mutable body : string; capability : upgrade option }
  let upgrade t = t.capability
end
module Response = struct
  let text ?(status=`OK) body reqd =
    reqd.Http_reqd.status <- (match status with `OK -> 200 | `Upgrade_required -> 426 | `Bad_request -> 400 | `Service_unavailable -> 503);
    reqd.body <- body
  let not_found reqd = reqd.Http_reqd.status <- 404
  let method_not_allowed reqd = reqd.Http_reqd.status <- 405
end
module Http = struct module Response = Response end
module Mcp_server = struct
  type config = {base_path:string}
  let workspace_config () = {base_path="fixture"}
end
let current_server_state_opt () = None
module Server_mcp_transport_http = struct let default_base_path () = "fixture" end
module Server_request_authority = struct let current_exn () = () end
let websocket_upgrade_unavailable_reason () = None
let websocket_upgrade_authorized ~base_path:_ ~request_authority:_ _ = Ok ()
module Server_mcp_transport_http_types = struct let auth_failure_of_masc_error () = () end
module Server_mcp_transport_http_respond = struct let record_mcp_auth_reject_metric ~endpoint:_ () = () end
let respond_auth_error _ reqd () = Response.text ~status:`Bad_request "auth error" reqd
module Sse = struct let runtime_authority_exn ~base_path:_ = () end
module Server_mcp_transport_ws = struct
  let dispatch_inbound_message = ()
  let upgrade_connection ~runtime_authority:_ ?sw:_ ?clock:_ ~on_message:_ ~upgrade:_ reqd =
    reqd.Http_reqd.status <- 101; Ok ()
end
let websocket_discovery_handler _ reqd = Response.text "discovery" reqd
"""

SCENARIO = r"""
let () =
  let route = { Router.handler = Router.Ws (websocket_handler ?sw:None ?clock:None) } in
  let run label headers capability =
    let reqd = {Http_reqd.status=0;body="";capability} in
    Router.dispatch route (Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET "/ws") reqd;
    Printf.printf "%s status=%d body=%s\n%!" label reqd.status reqd.body
  in
  run "ordinary h2 GET" [] None;
  run "unsupported upgrade" ["connection","Upgrade";"upgrade","websocket"] None;
  run "capable upgrade" ["connection","Upgrade";"upgrade","websocket"] (Some ())
"""


def run(*argv: str, cwd: Path = ROOT) -> str:
    return subprocess.check_output(argv, cwd=cwd, text=True)


def read(path: str, baseline: bool) -> str:
    return run("git", "show", f"{BASE}:{path}") if baseline else (ROOT / path).read_text()


def main() -> None:
    output = ROOT / "artifacts" / "h2-websocket-discovery" / str(time.time_ns())
    output.mkdir(parents=True)
    print(f"compiler={run('ocamlc', '-version').strip()}", flush=True)
    for label, baseline in (("before", True), ("after", False)):
        core, frontend = read(CORE, baseline), read(FRONTEND, baseline)
        helpers = frontend[frontend.index("let header_contains_token"):
                           frontend.index("let websocket_upgrade_unavailable_reason")]
        handler = frontend[frontend.index("let websocket_handler"):
                           frontend.index("let add_routes")]
        start = core.index("  let dispatch router request reqd =", core.index("module Router = struct"))
        dispatch = core[start:core.index("\nend\n", start)]
        capability = "unit" if baseline else "unit option"
        router = ("module Router = struct\n"
                  "  type target = Plain of (Httpun.Request.t -> Http_reqd.t -> unit)\n"
                  f"    | Ws of (upgrade:{capability} -> Httpun.Request.t -> Http_reqd.t -> unit)\n"
                  "  type route = {handler:target}\n"
                  "  let resolve route _ = `Matched route\n")
        (output / f"{label}.ml").write_text(
            PREAMBLE + helpers + handler + router + dispatch + "\nend\n" + SCENARIO)
        run("ocamlfind", "ocamlopt", "-linkpkg", "-package", "httpun",
            "-o", label, f"{label}.ml", cwd=output)
        result = run(str(output / label))
        print(f"{label}:\n{result}", end="", flush=True)
        (output / f"{label}.txt").write_text(result)
    print(f"output={output}")


if __name__ == "__main__":
    main()
