# PangYa AMP template

This public AMP template supervises an existing PangYa USA Fresh Up beta
runtime derived from the original `Acrisio-Filho/SuperSS-Dev-USA-Beta-Build`
release. It does not redistribute the proprietary client, server archive,
database dump or game assets.

The default runtime is `D:\PangYa\Server`. One foreground PowerShell
supervisor starts Auth, Message, Game and Login in dependency order, redirects
their output to the AMP Console and avoids separate terminal windows. It checks
Laragon MySQL before launch, verifies pinned SHA-256 hashes for the four server
executables and their bundled MySQL/ZIP libraries, monitors TCP 7777, 10103,
20202 and 30303, and restarts the complete service set at most three times after
an unexpected failure. An AMP stop requests `exit` from every service before a
bounded fallback stop.

The host-local runtime uses the single Laragon schema `pangya` and the existing
shared Iris SQL identity. Credentials remain outside this repository and are
projected only into ACL-restricted runtime configuration files because this
historical binary has no external secret-provider support. The intended runtime
identity is `NT AUTHORITY\NETWORK SERVICE`.
The pinned Login Server computes MD5 from the password received from the client
before comparing it with `account.PASSWORD`. Host provisioning must therefore
ensure that `ProcNewUser` stores `UPPER(MD5(password))`; storing the raw input
makes every newly provisioned account fail authentication even though the
network path is healthy.

The deployed runtime is aligned as a single US 852 compatibility contract:
all four services use `ServerVersion=None` and
`ServerPacketVersion=2016110200`, while `pangya_config.ClienteVersion` is
`852.00`. These values must be migrated together; changing only one packet or
database value creates a client/server-version mismatch. The bounded
`upgrade-us852 --confirm UPGRADE_PANGYA_US852` maintenance action refuses a
running application, verifies the pinned binaries, creates an ACL-restricted
rollback artifact and commits the four configurations plus database value as
one validated operation.

The production Game Server exposes one unrestricted channel named `Kallidos
Channel` with `CanaisCount=1`, ID 0, capacity 200 and `CanalFlag_1=1`.
AMP config version 5 exposes the safe operational subset of the legacy Game
Server configuration: server/channel identity and capacity, Pang, experience,
rare-item, Cookie-item, Scratchy, mastery, treasure and rain rates, Angel
event state, server icon and the advanced property/event/feature masks. The
supervisor validates every value and projects it into `Game Server\Config.ini`
before any child process starts. Only that one protected file grants
`NETWORK SERVICE` modify access; the three other credential-bearing service
configurations remain read-only to the runtime identity.

The historical Game Server executable also contains its own developer-credit
announcement (`Esse Server foi Desenvolvido por Acrisio xD.`). In the pinned
build, its timer immediate is the four-byte value `600000` at file offset
`0x95AB8`. AMP exposes a separate reversible toggle for that legacy credit,
disabled by default. The supervisor accepts only the pinned original and
managed-disabled hashes, validates the surrounding machine-code signature and
changes only that timer value (`600000` / `INFINITE`); an unknown binary or
unexpected byte sequence is rejected before launch.

The same page controls one optional administrator-defined periodic announcement through PangYa's
native `pangya_notice_list` / `pangya_command` queue. Text, repetition count
and interval are editable. The managed row is marked with reserved command
arguments so disabling or replacing it never removes notices created by an
administrator or another tool. The default is disabled. Database credentials
are read from the protected Game Server configuration and passed to the local
Laragon client only in its child-process environment; they are never stored in
AMP settings, command-line arguments or logs. This managed notice is independent
from the executable's legacy developer-credit announcement and its console
startup banner.

Provisioning also normalizes the four legacy card-reader procedures that
compared `DATETIME` columns with empty strings. They use explicit NULL
semantics so strict MySQL 8 remains enabled; relaxing the global SQL mode is
not a supported compatibility workaround. The confirmation-gated
`repair-mysql8-channel --confirm REPAIR_PANGYA_MYSQL8_CHANNEL` action applies
the procedure and channel contracts only while the application is stopped and
keeps an ACL-restricted rollback artifact.

The compatible English client is PangYa US 852 from the preservation link
published by `K4T/Py_Source_US`. The host-local preparation keeps the original
client DLL as `ijl15.original.dll` and installs the open-source Rugburn v2.0
shim. `rugburn.json` redirects client TCP ports 10103, 20202 and 30303 to
`server.kallidos.com` and rewrites the retired translation and patch-list URLs
to validated Iris compatibility routes without patching the packed
`ProjectG.exe`. The external encrypted patch manifest is generated from the
123 immutable client-root files and excludes local launchers, logs, provenance,
backups and mutable Rugburn configuration. No client or unverified binary is
included in this repository.
Because the packed USA 852
executable can validate its updater environment before the Rugburn shim is
loaded, the prepared client includes the preferred `Kallidos PangYa.lnk`
shortcut plus its internal `Start Kallidos PangYa.cmd` launcher. The launcher
elevates first, registers `projectg700gb+.pak` as `IntegratedPak` in the 32-bit
PangYa registry view and then sets the official USA `PANGYA_ARG` before
starting `ProjectG.exe`; starting the packed executable directly is unsupported
for this prepared client.

The supervisor considers a service ready when its TCP port is listening on any
local interface, rather than assuming loopback, and mirrors startup/failure
diagnostics to `pangya-amp/server.log`. Provisioning requests the host's
default-route IPv4 address for public services while Auth stays on loopback.
Because the pinned legacy binaries can instead choose a Hyper-V adapter, the
supervisor starts a user-mode TCP relay only for mismatched public listeners.
That relay is an AMP-managed child: it appears only while the application is
running, stops before the four services and never creates persistent Windows
port-proxy state. Consequently, a stopped application cannot leave false
Login, Game or Message listeners on the AMP status page.

The AMP card intentionally has an empty description so its secondary line is
reserved for the connection endpoint. Application auto-start is not enabled by
the template. Configuration pages use the standard `PangYa:gamepad` category,
which renders the game name and joystick icon instead of the literal
`APPLICATION` label. The registered Genesis Server instance uses management/SFTP
ports 20094/20095 and keeps the application services on 7777, 10103, 20202 and
30303. During maintenance, the controller may remain available without
starting any of the four game processes or application listeners.
