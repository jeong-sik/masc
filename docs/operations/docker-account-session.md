# Linux Docker account access during setup

`Docker_account_access.inspect` distinguishes current process group access from
membership saved in the account database. Only an explicit selected action may
call `grant`; it targets the real nonroot Unix account, never `$USER` or a sudo
variable. The menu must show `grant_detail` before execution because membership
allows root-level control through Docker.

On Debian/Ubuntu, the action runs the supported `usermod -a -G docker` operation
and rereads membership. It does not modify Docker context or the environment and
does not run Docker as root. A group installed in the account database normally
returns `Session_refresh_required`; the old setup process has not gained access.

The selectable `handoff` action uses `sg docker -c` to execute the same canonical
MASC binary and the saved workspace/port, with every shell argument quoted.
The consumer must wire `docker-session-resume` and call `validate_session`
before resuming its saved sandbox setup step. That checks the same nonroot real
and effective UID, active Docker group, and an ordinary-user Docker service
response. It never establishes guest execution. The parent should return after
`Child_finished`, rather than re-enter the old wizard. Failed authentication or
child startup returns `Reauthentication_pending` while committed model/workspace
settings remain available for retry.

Sources: [Docker's non-root post-install procedure](https://docs.docker.com/engine/install/linux-postinstall/)
and [sg command semantics](https://man7.org/linux/man-pages/man1/sg.1.html).
This unit provides the native actions and session boundary; the onboarding
consumer owns the menu, terminal child, and continuation command.

The interactive sandbox prerequisite menu offers account access only when the
native observation says membership is missing, and a group-session continuation
when membership exists but this process has not acquired it. It shows the
root-level Docker privilege before the operator selects the grant. Unsupported
distributions do not receive a guessed account-management command.

`docker-account-access` exposes the applicable actions as JSON. An explicit
`--execute grant` invokes the existing native account boundary;
`--execute handoff --base-path PATH --port PORT` starts the same installed MASC
through `sg`. Child interaction uses the terminal; the parent receives a separate
session outcome. A successful child exit ends the old-group setup process and
is not an imp-readiness receipt.

The internal `docker-session-resume` entry point verifies the expected ordinary
UID, active group, and ordinary-user Docker service before starting the embedded
helper's `--sandbox-step`. That step keeps the saved runtime configuration and
selected port; native `setup --no-tui` still validates the runtime, prepares the
sandbox, authenticates the operator, and boots imp. A failed session keeps the
saved model configuration available for retry.

An owner started before the group grant still has its previous Unix groups. The
resumed sandbox step therefore offers an authenticated graceful restart of an
existing same-workspace owner (or finishing later), without a reuse option. The
new native setup starts its owner from the refreshed account session. This uses
the existing identity-bound owner shutdown path, including same-version owners.
