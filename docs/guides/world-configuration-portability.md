# Export authored world configuration

[한국어](world-configuration-portability.ko.md)

An administrator can download the serving workspace's complete Runtime TOML,
Keeper TOML declarations and durable prompt overrides in one JSON response.
This preserves fields that an instructions-only preset cannot carry, including
explicit empty tool/skill lists, false values and omitted fields.

This endpoint exports configuration documents. Import, dependency assets,
CLI commands and Dashboard controls are tracked in
[issue #52824](https://github.com/jeong-sik/masc/issues/52824). The export does
not create another world or establish that its Keepers can run elsewhere.

## Request and permissions

Use `GET /api/v1/world/configuration/export` on the intended MASC server with
an `Authorization: Bearer <admin-token>` header. Workspace authentication must
be enabled with `require_token=true`, and the token must grant `CanAdmin`.
Turning off strict HTTP authentication does not make this export public.

The existing workspace read precondition is supported: send both
`expected_base_path` and `expected_masc_root` query parameters to refuse a
different serving workspace. These parameters check the server being read;
they do not select a different export source. Use the actual server's resolved
paths rather than the shell's current directory.

Successful exports return HTTP 200:

```json
{
  "ok": true,
  "scope": "authored_configuration_documents",
  "bundle": {
    "schema_version": 1,
    "origin": {
      "base_path": "/workspace/a",
      "config_root": "/workspace/a/.masc/config"
    },
    "runtime": null,
    "overrides": null,
    "keepers": []
  },
  "lock_warnings": []
}
```

This example describes an existing readable config root with no configuration
documents. A present document is `{"content":"...","sha256":"..."}`.
Each Keeper row is `{"name":"alpha","declaration":{"content":"...","sha256":"..."}}`.
The digest identifies the original document bytes. `null` means absent, and an
empty Keeper list means there were no declarations to capture. Neither means
that a failed read was ignored. Source paths are provenance, not permission to
write those paths on a receiving machine.

Authored Runtime and Keeper documents can themselves contain confidential
values. Export retains them exactly; it does not redact or remove secrets.
The route sends `Cache-Control: no-store` on captures and capture errors, and
does not log the bundle body. Keep a downloaded response private. Exporting
does not publish or share it.

## What the capture means

The config root comes from the normal resolver, including `MASC_CONFIG_DIR`.
Two different BasePaths can therefore share a config root. Prompt overrides
still come from the explicit serving workspace's `.masc/prompt_overrides.json`,
not from that shared config root. `origin` records both locations.

The reader holds the Runtime configuration lock and this process's prompt
mutation lock while copying documents. It then releases those scopes before
hashing and validating the captured bytes. Runtime TOML is checked for syntax;
Keeper declarations use the existing strict validator, including filename/name
agreement and required instructions. Overrides use the existing versioned
persistence decoder and retain their authorship provenance.

These scopes exclude cooperating writers while the reader holds them. They
do not serialize manual editors or another process's prompt writes, and they
do not make a writer's separate transactions into one world transaction.
This is not a full BasePath backup or an atomic snapshot of runtime state.

An unavailable config root, unreadable declaration, symlink or invalid document
fails the export rather than producing a smaller fleet. Missing Runtime and
override files remain absent. A missing Keeper directory is an empty authored
roster only when the existing owned config root can be read successfully.
The reader does not bootstrap a config root. Lock admission can create its
ordinary lock file.

Capture failures return `{"ok":false,"error":"..."}`. Invalid BasePath is
HTTP 400; unavailable/unreadable/invalid source documents are 422; configuration
lock admission failure is 409. Authentication, workspace preconditions and
server readiness retain their existing responses. `lock_warnings` records
Runtime lock release observations after an otherwise successful capture; it
is not an activation or durability receipt.

Referenced Skills, packages, tools, exact-worker assets, images and host paths
are not copied or checked for availability. Login/credential stores, Memory,
original requests and in-flight effects are not included. No configuration is
installed or activated. See the [Keeper file model](../KEEPER-FILE-MODEL.md)
for the boundary between declarations and runtime data.
