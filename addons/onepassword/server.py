"""Model-safe exports plus a separate, non-exportable operator control port."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import sys
import time
from urllib import parse

from oauth import Configuration, ConnectionError, Connector, Phase, PrivateStore, https_url

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import INPUT_SCHEMA, OUTPUT_SCHEMA, InvalidInput, decode_json, encode_output


EMPTY = {"type": "object", "properties": {}, "additionalProperties": False}
PHASES = ["not_configured", "unavailable", *(phase.value for phase in Phase)]
STATUS_SCHEMA = {"type": "object", "additionalProperties": False,
                 "properties": {"phase": {"type": "string", "enum": PHASES},
                                "connected": {"type": "boolean"},
                                "browser_login_available": {"type": "boolean"}},
                 "required": ["phase", "connected", "browser_login_available"]}
STATUS_TOOL = {"name": "onepassword_status",
               "description": "Read whether this connector's 1Password account is connected. "
                              "Browser login is under development; this tool does not sign in. "
                              "Connection setup and approvals belong to the operator's private controls.",
               "inputSchema": EMPTY, "outputSchema": STATUS_SCHEMA,
               "annotations": {"readOnlyHint": True, "destructiveHint": False,
                               "idempotentHint": True, "openWorldHint": False}}
CONTROL_SCHEMA = {"type": "object", "additionalProperties": False,
                  "properties": {"tool": {"type": "string"}, "arguments": EMPTY,
                                 "caller": {"type": "object"}},
                  "required": ["tool", "arguments", "caller"]}
OPERATOR_SCHEMA = {"type": "object", "additionalProperties": False,
                   "properties": {"action": {"type": "string", "enum": ["view", "connect", "complete", "cancel"]},
                                  "arguments": {"type": "object", "additionalProperties": False,
                                                "properties": {key: {"type": "string"} for key in
                                                               ["state", "connection_id", "callback_url"]}}},
                   "required": ["action", "arguments"]}


def private_text(path: Path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise ConnectionError("unsafe_configuration_file")
        with os.fdopen(fd, "r", encoding="utf-8", closefd=False) as stream:
            return stream.read()
    finally:
        os.close(fd)


def load_connector(path: Path, *, provision=False):
    if not path.is_absolute():
        raise ConnectionError("configuration_path_not_absolute")
    config = decode_json(private_text(path))
    if (not isinstance(config, dict) or set(config) != {
            "client_id", "client_secret_file", "redirect_uri", "store_directory"}):
        raise ConnectionError("invalid_configuration")
    paths = [Path(config[field]) for field in ["client_secret_file", "store_directory"]]
    if not all(item.is_absolute() for item in paths):
        raise ConnectionError("configuration_path_not_absolute")
    configuration = Configuration(config["client_id"], private_text(paths[0]).removesuffix("\n"),
                                  config["redirect_uri"])
    return Connector(configuration, PrivateStore(paths[1], provision=provision))


class Worker:
    def __init__(self, configuration: Path):
        self.configuration = configuration

    def operator(self, envelope):
        if (not isinstance(envelope, dict) or set(envelope) != {"action", "arguments"}
                or not isinstance(envelope["arguments"], dict)):
            raise InvalidInput("invalid private operator request")
        action, arguments = envelope["action"], envelope["arguments"]
        expected = {"view": set(), "connect": set(), "complete": {"state", "connection_id", "callback_url"},
                    "cancel": {"state", "connection_id"}}
        if (not isinstance(action, str) or action not in expected or set(arguments) != expected[action]
                or not all(isinstance(value, str) and value for value in arguments.values())):
            raise InvalidInput("invalid private operator action")
        connector = None
        try:
            connector = load_connector(self.configuration, provision=action in {"view", "connect"})
            if action == "connect":
                pending = connector.begin()
                view = self.operator_view(connector)
                callback = view.get("callback")
                if (callback is None
                        or callback["arguments"]["connection_id"] != pending["connection_id"]):
                    raise ConnectionError("authorization_attempt_mismatch")
                return {**view, "open_url": pending["authorization_url"]}
            if action == "cancel":
                connector.cancel_authorization(expected_state=arguments["state"],
                                               expected_connection_id=arguments["connection_id"])
            elif action == "complete":
                callback = parse.urlsplit(arguments["callback_url"])
                configured = parse.urlsplit(connector.configuration.redirect_uri)
                if (callback.scheme, callback.netloc, callback.path) != (configured.scheme, configured.netloc, configured.path):
                    raise ConnectionError("callback_destination_mismatch")
                query = parse.parse_qs(callback.query, strict_parsing=True, keep_blank_values=True)
                fragment = parse.parse_qs(callback.fragment, strict_parsing=True, keep_blank_values=True)
                declined = "error" in query
                required = {"error", "state"} if declined else {"code", "state"}
                if (not required <= set(query)
                        or not set(query) <= required | {"iss", "base_url"}
                        or set(fragment) != (set() if declined else {"integration_key"})
                        or any(len(values) != 1 or not values[0] for values in [*query.values(), *fragment.values()])
                        or query["state"][0] != arguments["state"]):
                    raise ConnectionError("invalid_callback")
                # Optional provider metadata never changes the configured
                # token endpoint, client binding or redirect authority.
                for key in {"iss", "base_url"} & set(query):
                    value = query[key][0]
                    if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value):
                        raise ConnectionError("invalid_callback")
                    https_url(value)
                    if key == "base_url" and parse.urlsplit(value).path not in {"", "/"}:
                        raise ConnectionError("invalid_callback")
                if declined:
                    if query["error"] != ["access_denied"]:
                        raise ConnectionError("invalid_callback")
                    receipt = connector.decline_authorization(expected_state=query["state"][0],
                                                              expected_connection_id=arguments["connection_id"])
                    return {**self.operator_view(connector), "callback_receipt": receipt}
                else:
                    identity = connector.authorization_identity()
                    if identity != {key: arguments[key] for key in ["state", "connection_id"]}:
                        raise ConnectionError("callback_attempt_mismatch")
                    connector.complete(state=query["state"][0], code=query["code"][0],
                                       integration_key=fragment["integration_key"][0])
            return self.operator_view(connector)
        except (ConnectionError, OSError, InvalidInput, ValueError, TypeError, KeyError, UnicodeError):
            # The operator learns only a fixed outcome. The durable backend
            # phase, not an exception's wording, decides whether reconnect is safe.
            return self.with_callback_receipt(connector, {
                "title": "1Password", "message": "Connection unavailable. Inspect the account connection before another attempt.",
                "actions": [{"id": "view", "label": "Inspect connection", "arguments": {}, "fields": []}]})

    @staticmethod
    def with_callback_receipt(connector, view):
        if connector is not None:
            try:
                receipt = connector.callback_receipt()
            except (ConnectionError, OSError, ValueError, TypeError, KeyError, UnicodeError):
                receipt = None
            if receipt is not None:
                return {**view, "callback_receipt": receipt}
        return view

    def operator_view(self, connector):
        status = connector.status()
        phase = Phase(status["phase"])
        actions = []
        messages = {Phase.DISCONNECTED: "Connect your personal 1Password account.",
                    Phase.AUTHORIZING: "Approve the connection in 1Password, then return here.",
                    Phase.CONNECTED: "Account connected. Browser login docking is still under development.",
                    Phase.RECONNECT_REQUIRED: "A previous connection operation has an unknown outcome. Reconcile it with 1Password before reconnecting."}
        callback = None
        if phase is Phase.DISCONNECTED:
            actions.append({"id": "connect", "label": "Connect 1Password", "arguments": {}, "fields": [], "opens_window": True})
        elif phase is Phase.AUTHORIZING:
            identity = connector.authorization_identity()
            actions.extend([
                {"id": "complete", "label": "Finish connection", "arguments": identity,
                 "fields": [{"name": "callback_url", "label": "Returned connection URL", "secret": True}]},
                {"id": "cancel", "label": "Cancel this connection attempt", "arguments": identity, "fields": []}])
            callback = {"action": "complete", "field": "callback_url", "arguments": identity, "state": identity["state"]}
        result = {"title": "1Password", "message": messages[phase], "actions": actions}
        if callback is not None:
            result["callback"] = callback
        return self.with_callback_receipt(connector, result)

    def status(self):
        # Only this first boundary constructs public data. No provider or OS
        # error prose is echoed into content, metadata or stderr.
        try:
            connector = load_connector(self.configuration)
        except FileNotFoundError:
            # Distinguish absent configuration from its missing referenced
            # secret/store; both are unavailable, but only the former is setup.
            try:
                self.configuration.lstat()
                phase = "unavailable"
            except FileNotFoundError:
                phase = "not_configured"
            except OSError:
                phase = "unavailable"
            value = {"phase": phase, "connected": False}
        except (ConnectionError, OSError, ValueError, TypeError, UnicodeError):
            value = {"phase": "unavailable", "connected": False}
        else:
            try:
                value = connector.status()
            except (ConnectionError, OSError, ValueError, TypeError, KeyError, UnicodeError):
                value = {"phase": "unavailable", "connected": False}
        return {**value, "browser_login_available": False}

    def observe(self, arguments):
        if (not isinstance(arguments, dict) or set(arguments) != {"binding", "sources"}
                or arguments["binding"] != {"sources": []} or arguments["sources"] != []):
            raise InvalidInput("connector observation takes no sources or credentials")
        return {"rows": [{"id": "connection", "lane_id": "connection", "kind": "value",
                          "title": "1Password connection", "observed_at": time.time(),
                          "subject_id": "onepassword", "clock": None, "actor": None,
                          "fields": self.status(), "evidence": [], "related_ids": []}],
                "coverage": []}

    def admitted(self, envelope):
        if not isinstance(envelope, dict) or set(envelope) != {"tool", "arguments", "caller"}:
            raise InvalidInput("invalid host caller envelope")
        caller = envelope["caller"]
        if not isinstance(caller, dict):
            raise InvalidInput("host caller required")
        if caller == {"kind": "operator"}:
            pass
        elif (set(caller) == {"kind", "name"} and caller["kind"] in {"keeper", "agent", "host_actor"}
              and isinstance(caller["name"], str) and caller["name"]
              and caller["name"].strip() == caller["name"]):
            pass
        else:
            raise InvalidInput("verified host caller required")
        if envelope["tool"] != STATUS_TOOL["name"] or envelope["arguments"] != {}:
            raise InvalidInput("only the safe status tool is exported")
        return self.status()


def tool_result(value):
    return {"content": [{"type": "text", "text": encode_output(value)}],
            "structuredContent": value, "isError": False}


def serve(worker):
    for line in sys.stdin.buffer:
        identity = None
        try:
            rpc = decode_json(line.decode("utf-8"))
            if not isinstance(rpc, dict) or rpc.get("jsonrpc") != "2.0":
                raise InvalidInput("invalid JSON-RPC")
            if "id" not in rpc:
                continue
            identity = rpc["id"]
            if type(identity) not in {str, int}:
                raise InvalidInput("invalid JSON-RPC id")
            params = rpc.get("params", {})
            if not isinstance(params, dict):
                raise InvalidInput("invalid JSON-RPC params")
            match rpc.get("method"):
                case "initialize":
                    result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                              "serverInfo": {"name": "masc-onepassword", "version": "0.1.0"}}
                case "ping":
                    result = {}
                case "tools/list":
                    result = {"tools": [{"name": "lane_observe", "description": "Read safe connection state.",
                                         "inputSchema": INPUT_SCHEMA, "outputSchema": OUTPUT_SCHEMA},
                                        STATUS_TOOL,
                                        {"name": "lane_call", "description": "Private host caller port.",
                                         "inputSchema": CONTROL_SCHEMA},
                                        {"name": "lane_operator", "description": "Private authenticated operator controls.",
                                         "inputSchema": OPERATOR_SCHEMA}]}
                case "tools/call":
                    try:
                        match params.get("name"):
                            case "lane_observe":
                                value = worker.observe(params.get("arguments"))
                            case "lane_call":
                                value = worker.admitted(params.get("arguments"))
                            case "lane_operator":
                                value = worker.operator(params.get("arguments"))
                            case _:
                                raise InvalidInput("use the host-admitted exported tool")
                        result = (tool_result(value) if params.get("name") != "lane_operator" else
                                  {"content": [], "structuredContent": value, "isError": False})
                    except InvalidInput:
                        result = {"content": [{"type": "text", "text": "connector input or caller refused"}],
                                  "isError": True}
                case _:
                    print(encode_output({"jsonrpc": "2.0", "id": identity,
                                         "error": {"code": -32601, "message": "Method not found"}}), flush=True)
                    continue
            response = {"jsonrpc": "2.0", "id": identity, "result": result}
        except (InvalidInput, ValueError, TypeError, KeyError, UnicodeError):
            response = {"jsonrpc": "2.0", "id": identity,
                        "error": {"code": -32602, "message": "invalid connector request"}}
        print(encode_output(response), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path(__file__).resolve().with_name("connection-config.json"))
    options = parser.parse_args()
    serve(Worker(options.config))
