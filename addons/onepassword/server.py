"""Model-safe exports plus a separate, non-exportable operator control port."""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time
from urllib import parse

from oauth import Configuration, ConnectionError, Connector, Phase, PrivateStore, https_url
from login import Extension, Journal, LoginError, Logins, Phase as LoginPhase, TERMINAL, _caller, _uuid
from service import Service

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import INPUT_SCHEMA, OUTPUT_SCHEMA, InvalidInput, decode_json, encode_output


EMPTY = {"type": "object", "properties": {}, "additionalProperties": False}
COMPANION_SCHEMA = {"type": "object", "properties": {"version": {"type": "integer", "enum": [3]}},
                    "required": ["version"], "additionalProperties": False}
PHASES = ["not_configured", "unavailable", *(phase.value for phase in Phase)]
STATUS_SCHEMA = {"type": "object", "additionalProperties": False,
                 "properties": {"phase": {"type": "string", "enum": PHASES},
                                "connected": {"type": "boolean"},
                                "browser_login_available": {"type": "boolean"}},
                 "required": ["phase", "connected", "browser_login_available"]}
STATUS_TOOL = {"name": "onepassword_status",
               "description": "Read whether this connector's 1Password account is connected. "
                              "Browser availability describes configured admission, not a completed login. "
                              "Connection setup and approvals belong to the operator's private controls.",
               "inputSchema": EMPTY, "outputSchema": STATUS_SCHEMA,
               "annotations": {"readOnlyHint": True, "destructiveHint": False,
                               "idempotentHint": True, "openWorldHint": False}}
def closed(properties, required=None):
    return {"type": "object", "properties": properties, "required": list(properties) if required is None else required,
            "additionalProperties": False}


TEXT = {"type": "string", "minLength": 1}
UUID = {"type": "string"}
OPERATION_INPUT = closed({"operation_id": UUID})
LOGIN_OUTPUT = closed({"operation_id": UUID, "phase": {"type": "string", "enum": [p.value for p in LoginPhase]},
                       "fill_submitted": {"type": "boolean"},
                       "website_login_verified": {"type": "boolean", "enum": [False]}})
CANCEL_OUTPUT = closed({"operation_id": UUID, "cancel_requested": {"type": "boolean", "enum": [True]}})
LOGIN_INPUT = closed({"browser_instance_id": UUID, "tab_id": {"type": "integer", "minimum": 0},
                      "website": TEXT, "goal": TEXT, "reason": TEXT})


def login_tool(name, description, input_schema, output_schema, *, read_only=False):
    return {"name": name, "description": description, "inputSchema": input_schema, "outputSchema": output_schema,
            "annotations": {"readOnlyHint": read_only, "destructiveHint": False,
                            "idempotentHint": read_only, "openWorldHint": True}}


LOGIN_TOOLS = [
    login_tool("onepassword_login", "Request sign-in in your existing Browser instance and tab. Returns preparing; "
               "ask the operator to use private Add-on controls. Never request approval links in chat.", LOGIN_INPUT, LOGIN_OUTPUT),
    login_tool("onepassword_login_status", "Read the original login operation. fill_submitted does not prove website authentication.",
               OPERATION_INPUT, LOGIN_OUTPUT, read_only=True),
    login_tool("onepassword_logins", "Recover your own login operation identities and committed states.", EMPTY,
               closed({"operations": {"type": "array", "items": LOGIN_OUTPUT}}), read_only=True),
    login_tool("onepassword_fill_next", "Fill the next sign-in page using the same approved grant. Never replay an unknown fill.",
               OPERATION_INPUT, LOGIN_OUTPUT),
    login_tool("onepassword_finish", "Release the original grant after checking the website. Does not certify authentication.",
               OPERATION_INPUT, LOGIN_OUTPUT),
    login_tool("onepassword_cancel", "Request cancellation of the original operation. Inspect status for settlement.",
               OPERATION_INPUT, CANCEL_OUTPUT),
]
TOOLS = [STATUS_TOOL, *LOGIN_TOOLS]
CONTROL_SCHEMA = closed({"tool": TEXT, "arguments": {"type": "object"}, "caller": {"type": "object"},
                         "companion": closed({"socket_path": TEXT, "invocation_id": TEXT,
                                              "publication_id": {"type": ["string", "null"]},
                                              "max_message_bytes": {"type": "integer"}})},
                        ["tool", "arguments", "caller"])
OPERATOR_ACTIONS = ["view", "connect", "complete", "cancel", "login_approval", "login_opened", "login_confirmed", "login_cancel"]
OPERATOR_SCHEMA = closed({"action": {"type": "string", "enum": OPERATOR_ACTIONS},
                          "arguments": closed({key: {"type": "string"} for key in
                                               ["state", "connection_id", "callback_url", "operation_id"]}, [])})


@dataclass(frozen=True)
class Settings:
    connector: Connector = field(repr=False)
    fingerprint: str = field(repr=False)
    extension: Extension | None


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


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise InvalidInput("duplicate configuration field")
        value[key] = item
    return value


def load_settings(path: Path, *, provision=False):
    if not path.is_absolute():
        raise ConnectionError("configuration_path_not_absolute")
    source = private_text(path)
    config = json.loads(source, object_pairs_hook=_unique_object)
    required = {"client_id", "client_secret_file", "redirect_uri", "store_directory"}
    if (not isinstance(config, dict) or set(config) not in [required, required | {"browser_extension"}]
            or not all(isinstance(config[key], str) for key in required)):
        raise ConnectionError("invalid_configuration")
    paths = [Path(config[field]) for field in ["client_secret_file", "store_directory"]]
    if not all(item.is_absolute() for item in paths):
        raise ConnectionError("configuration_path_not_absolute")
    secret = private_text(paths[0]).removesuffix("\n")
    configuration = Configuration(config["client_id"], secret, config["redirect_uri"])
    extension = config.get("browser_extension")
    if extension is not None:
        if (not isinstance(extension, dict) or set(extension) != {"directory", "extension_id"}
                or not isinstance(extension["directory"], str)):
            raise ConnectionError("invalid_configuration")
        extension = Extension(Path(extension["directory"]), extension["extension_id"])
    elif "browser_extension" in config:
        raise ConnectionError("invalid_configuration")
    fingerprint = hashlib.sha256((source + "\0" + secret).encode()).hexdigest()
    return Settings(Connector(configuration, PrivateStore(paths[1], provision=provision)), fingerprint, extension)


class Worker:
    def __init__(self, configuration: Path):
        self.configuration = configuration
        self._settings_value = None
        self._service_value = None
        self._negotiated = False
        self._retired = False

    def settings(self, *, provision=False):
        if self._retired:
            raise LoginError("unavailable")
        try:
            settings = load_settings(self.configuration, provision=provision)
        except (LoginError, ConnectionError, OSError, InvalidInput, ValueError, TypeError, KeyError, UnicodeError):
            if self._settings_value is not None:
                # A failed reread revokes the original owner's admission just
                # as a changed fingerprint does. Retirement interrupts original
                # IO without making status wait for disposal acknowledgement.
                self.retire()
                raise LoginError("unavailable") from None
            raise
        if self._settings_value is None:
            self._settings_value = settings
        elif settings.fingerprint != self._settings_value.fingerprint:
            self.retire()
            raise LoginError("unavailable")
        return self._settings_value

    def service(self):
        settings = self.settings()
        if not self._negotiated or settings.extension is None:
            raise LoginError("unavailable")
        if self._service_value is None:
            if not settings.connector.status(blocking=False)["connected"]:
                raise LoginError("unavailable")
            self._service_value = Service(Logins(settings.connector,
                Journal(settings.connector.store.directory / "logins", provision=True), settings.extension))
        self._service_value.operations({"kind": "operator"})
        return self._service_value

    def handshake(self, arguments):
        if arguments != {"version": 3} or type(arguments["version"]) is not int:
            raise InvalidInput("invalid private companion handshake")
        self._negotiated = True
        return {"version": 3, "tools": ["onepassword_login"]}

    def retire(self):
        self._retired = True
        if self._service_value is not None:
            self._service_value.retire()

    def close(self):
        self.retire()
        if self._service_value is not None:
            self._service_value.close()

    def operator(self, envelope):
        if (not isinstance(envelope, dict) or set(envelope) != {"action", "arguments"}
                or not isinstance(envelope["arguments"], dict)):
            raise InvalidInput("invalid private operator request")
        action, arguments = envelope["action"], envelope["arguments"]
        expected = {"view": set(), "connect": set(), "complete": {"state", "connection_id", "callback_url"},
                    "cancel": {"state", "connection_id"},
                    **{key: {"operation_id"} for key in
                       ["login_approval", "login_opened", "login_confirmed", "login_cancel"]}}
        if (not isinstance(action, str) or action not in expected or set(arguments) != expected[action]
                or not all(isinstance(value, str) and value for value in arguments.values())):
            raise InvalidInput("invalid private operator action")
        connector = None
        try:
            connector = self.settings(provision=action in {"view", "connect"}).connector
            if action in {"login_approval", "login_opened", "login_confirmed", "login_cancel"}:
                operation = arguments["operation_id"]
                if not _uuid(operation):
                    raise InvalidInput("invalid operation identity")
                service = self.service()
                link = None
                if action == "login_approval":
                    link = service.approval(operation)["open_url"]
                elif action == "login_opened":
                    service.opened(operation)
                elif action == "login_confirmed":
                    service.confirmed(operation)
                else:
                    service.cancel(operation, {"kind": "operator"})
                view = self.operator_view(connector)
                return view if link is None else {**view, "open_url": link}
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
        except (LoginError, ConnectionError, OSError, InvalidInput, ValueError, TypeError, KeyError, UnicodeError):
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
        try:
            status = connector.status(blocking=False)
            phase = Phase(status["phase"])
        except (ConnectionError, OSError):
            phase = None
        actions = []
        messages = {Phase.DISCONNECTED: "Connect your personal 1Password account.",
                    Phase.AUTHORIZING: "Approve the connection in 1Password, then return here.",
                    Phase.CONNECTED: "Account connected. Use the controls below for pending Browser sign-in approvals.",
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
        message = messages[phase] if phase is not None else "Account state is busy or unavailable. Pending login controls remain available."
        if self._service_value is not None:
            operations = self.service().operations({"kind": "operator"})
            for operation in operations:
                operation_id = operation["operation_id"]
                login_phase = LoginPhase(operation["phase"])
                message += f" Login {operation_id}: {login_phase.value}."
                def add(action, label, *, opens_window=False):
                    actions.append({"id": action, "label": f"{label} ({operation_id})",
                                    "arguments": {"operation_id": operation_id}, "fields": [],
                                    "opens_window": opens_window})
                if login_phase in {LoginPhase.APPROVAL_READY, LoginPhase.AWAITING_APPROVAL, LoginPhase.WAITING_USER}:
                    add("login_approval", "Open 1Password approval", opens_window=True)
                if login_phase is LoginPhase.APPROVAL_READY:
                    add("login_opened", "I opened 1Password")
                elif login_phase in {LoginPhase.AWAITING_APPROVAL, LoginPhase.WAITING_USER}:
                    add("login_confirmed", "I approved in 1Password")
                if login_phase not in TERMINAL:
                    add("login_cancel", "Cancel this login")
        result = {"title": "1Password", "message": message, "actions": actions}
        if callback is not None:
            result["callback"] = callback
        return self.with_callback_receipt(connector, result)

    def status(self):
        # Only this first boundary constructs public data. No provider or OS
        # error prose is echoed into content, metadata or stderr.
        try:
            connector = self.settings().connector
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
        except (LoginError, ConnectionError, OSError, ValueError, TypeError, UnicodeError):
            value = {"phase": "unavailable", "connected": False}
        else:
            try:
                value = connector.status(blocking=False)
            except (ConnectionError, OSError, ValueError, TypeError, KeyError, UnicodeError):
                value = {"phase": "unavailable", "connected": False}
        available = False
        if value["connected"] and self._negotiated:
            try:
                self.service()
                available = True
            except (LoginError, ConnectionError, OSError, ValueError, TypeError, UnicodeError):
                pass
        return {**value, "browser_login_available": available}

    def observe(self, arguments):
        if (not isinstance(arguments, dict) or set(arguments) != {"binding", "sources"}
                or arguments["binding"] != {"sources": []} or arguments["sources"] != []):
            raise InvalidInput("connector observation takes no sources or credentials")
        status = self.status()
        if self._service_value is not None:
            self._service_value.notify()
        return {"rows": [{"id": "connection", "lane_id": "connection", "kind": "value",
                          "title": "1Password connection", "observed_at": time.time(),
                          "subject_id": "onepassword", "clock": None, "actor": None,
                          "fields": status, "evidence": [], "related_ids": []}],
                "coverage": []}

    def admitted(self, envelope):
        if not isinstance(envelope, dict):
            raise InvalidInput("invalid host caller envelope")
        tool = envelope.get("tool")
        expected = {"tool", "arguments", "caller"} | ({"companion"} if tool == "onepassword_login" else set())
        if set(envelope) != expected or not _caller(envelope["caller"]):
            raise InvalidInput("verified host caller required")
        caller, arguments = envelope["caller"], envelope["arguments"]
        if not isinstance(arguments, dict):
            raise InvalidInput("invalid tool arguments")
        if tool == "onepassword_status" and arguments == {}:
            return self.status()
        if tool not in {item["name"] for item in LOGIN_TOOLS}:
            raise InvalidInput("unknown exported tool")
        if tool == "onepassword_login":
            if set(arguments) != set(LOGIN_INPUT["properties"]):
                raise InvalidInput("invalid login arguments")
        elif tool == "onepassword_logins":
            if arguments != {}:
                raise InvalidInput("invalid login arguments")
        elif set(arguments) != {"operation_id"} or not _uuid(arguments["operation_id"]):
            raise InvalidInput("invalid operation identity")
        try:
            service = self.service()
            if tool == "onepassword_login":
                return service.submit(descriptor=envelope["companion"], caller=caller, **arguments)
            if tool == "onepassword_logins":
                return {"operations": service.operations(caller)}
            method = {"onepassword_login_status": service.status, "onepassword_fill_next": service.fill_next,
                      "onepassword_finish": service.finish, "onepassword_cancel": service.cancel}[tool]
            return method(arguments["operation_id"], caller)
        except (LoginError, ConnectionError, OSError, ValueError, TypeError, KeyError, UnicodeError):
            raise InvalidInput("login operation unavailable") from None


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
                                        *TOOLS,
                                        {"name": "lane_call", "description": "Private host caller port.",
                                         "inputSchema": CONTROL_SCHEMA},
                                        {"name": "lane_operator", "description": "Private authenticated operator controls.",
                                         "inputSchema": OPERATOR_SCHEMA},
                                        {"name": "lane_companion", "description": "Private host companion protocol negotiation.",
                                         "inputSchema": COMPANION_SCHEMA}]}
                case "tools/call":
                    try:
                        match params.get("name"):
                            case "lane_observe":
                                value = worker.observe(params.get("arguments"))
                            case "lane_call":
                                value = worker.admitted(params.get("arguments"))
                            case "lane_operator":
                                value = worker.operator(params.get("arguments"))
                            case "lane_companion":
                                value = worker.handshake(params.get("arguments"))
                            case _:
                                raise InvalidInput("use the host-admitted exported tool")
                        result = (tool_result(value) if params.get("name") not in {"lane_operator", "lane_companion"} else
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
    worker = Worker(options.config)
    try:
        serve(worker)
    finally:
        try:
            worker.close()
        except BaseException:
            # Resource uncertainty is a failed process exit, never private prose.
            raise SystemExit(1) from None
