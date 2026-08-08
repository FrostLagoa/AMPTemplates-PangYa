# PangYa AMP template

This public AMP template supervises an existing PangYa USA Fresh Up beta
runtime derived from the original `Acrisio-Filho/SuperSS-Dev-USA-Beta-Build`
release. It does not redistribute the proprietary client, server archive,
database dump or game assets.

The default runtime is `D:\PangYa\Server`. The config-version-8 lifecycle is
deliberately minimal: AMP starts Auth, Message, Game and Login in dependency
order, waits once for TCP 7777, 10103, 20202 and 30303, and reports a failed
start when a native service exits. AMP stop uses its ordinary process-tree
shutdown. There is no PowerShell supervisor, console relay, automatic restart
loop, binary patching or SQL-side announcement worker in the production path.
The PangYa binaries and their own logs remain the source of diagnostics.

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

The verified server binary/data source is the original SuperSS USA beta build,
while the deployed compatible client is PangYa USA 852. All four service
configurations use `ServerPacketVersion=2016110200`, and the initialized
database/game-list contract advertises `ClienteVersion=852.00`. Packet, binary
and database versions must move together; changing only one layer is
unsupported and causes a client/server mismatch. The provisioned USA 851
material is retained only as rollback/reference material while issue #154
validates multiplayer.

AMP exposes the supported legacy service and channel settings through managed
configuration fragments. On every start the lifecycle applies those fragments
to the four native `Config.ini` files before launching any binary. Database
credentials remain outside the AMP form and stay protected in the native
configuration files.
The stopped-runtime USA 852 migration also updates AMP's persisted
`GenericModule.kvp` `App.AppSettings` source. This is required because ADS
recreates the managed fragments from that source when its instance controller
starts; changing only an already-generated fragment would be reverted.

The config form does not alter native binaries, run a SQL announcement worker or
modify legacy developer-credit behavior. Any native announcement is therefore
owned by the unmodified server build and should be changed only through a
separately reviewed game-server change.

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
sets the official USA `PANGYA_ARG` and applies the process-local
`RunAsInvoker` compatibility layer before starting `ProjectG.exe`. This is
required because the original packed executable embeds a
`requireAdministrator` manifest, while its WinINet compatibility requests must
run in the interactive player's network profile. The machine-wide installer,
not the launcher, registers `projectg700gb+.pak` as `IntegratedPak` in the
32-bit PangYa registry view. Starting the packed executable directly is
unsupported for this prepared client.

## Public client installer

`installer/pangya-client.iss` is the reproducible Inno Setup definition for the
public Kallidos PangYa US 852 client. Proprietary client files remain in
`D:\PangYa\Client` and are supplied only at build time; they are never copied
into this repository. Build it from the Iris root with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build_pangya_client_installer.ps1
```

The build script verifies pinned hashes for `ProjectG.exe`, both `ijl15` DLLs,
the language data and the final 851 patch, validates the supported launcher and
refuses any Rugburn route that does not use `server.kallidos.com` on 10103,
20202 and 30303. It also rejects any definition that permits a per-user install
or any launcher that elevates the game or modifies machine state. Setup 852.0.1
requires an administrator, installs for all users under `Program Files (x86)`,
and writes the required 32-bit HKLM value during installation. The public
installer never writes a hosts-file entry or embeds the current public IPv4
address. DNS/DDNS therefore remains responsible for mapping
`server.kallidos.com` to whichever public address currently belongs to Genesis
Server.

The special client under `G:\Games\KallidosPangYa` on Genesis-Windows is not a
public installer source and must not have its local-only connection behavior
reconciled with this package. It may be inspected read-only to verify immutable
US 852 runtime assets. The Inno package deliberately excludes that deployment's
shortcut, logs, captures, temporary files and the preservation archive's old
`uninstall.exe`. It creates fresh all-users Start Menu and optional Desktop
shortcuts that call `Start Kallidos PangYa.cmd`; the optional post-install
launch explicitly returns to the original interactive user and silent
installation skips launching the game.

### Client-side `string load failed` diagnosis

Setup 852.0.1 passed the translation stage on Windows 11 but a clean Windows
10 22H2 VM reproduced the failure. Protocol-pinned OpenSSL checks established
the actual boundary: the Cloudflare edge rejected TLS 1.2 with alert 70 while
accepting TLS 1.3. The legacy WinINet path can negotiate the latter on Windows
11 but needs TLS 1.2 on Windows 10. Setting the Cloudflare zone minimum to TLS
1.2 fixed Windows 10 without disabling TLS 1.3 or changing the setup, packed
client, Rugburn DLL, registry contract or HTTPS URLs.

The operator confirmed the incident resolved. For future unrelated failures,
run `scripts/diagnose_pangya_client_wininet.cmd` as the affected interactive
user. Its x86 probe uses the same WinINet API, reload flag, URL, expected
24,324-byte length and SHA-256 as `ProjectG.exe`, repeats the request to expose
intermittent timeouts and writes `pangya-wininet-report.txt`.

The report also audits, without changing anything, the former per-user folder,
the machine-wide folder, VirtualStore overrides, user/common shortcuts, both
32-bit and 64-bit PangYa/uninstall registry views and relevant AppCompat layer
entries. It redacts the user-profile prefix and never records response content,
proxy addresses, credentials, authorization headers or secrets. Do not delete
or rewrite any reported residue until its exact path and hash have been
reviewed. Do not copy Schannel provider values from another Windows release or
modify global TLS registry state as an installer workaround.

The legacy protocol stores a numeric IPv4 address in an 18-byte server-list
field and cannot advertise a hostname directly. Config version 8 resolves the
editable `Public server hostname` (default `server.kallidos.com`) once on every
start and writes that IPv4 address to the Login, Game and Message service
advertisements before any binary launches. The initial Rugburn endpoint can
remain DDNS-based.

By default, the external artifact and checksum are written to
`D:\PangYa\Installer\Output\Kallidos-PangYa-US852-Setup.exe` and the adjacent
`.sha256` file. The package is currently unsigned, so Windows may show an
unknown-publisher or SmartScreen warning until an approved code-signing
certificate is configured. Do not replace that limitation with a self-signed
public distribution certificate.

The lifecycle considers a service ready when its required TCP port is
listening on any local interface. The pinned legacy binaries currently bind
the public services to a Hyper-V Default Switch address rather than the LAN
address. When that occurs, configure three host-owned, TCP-only Windows
port-proxy rules that listen on the specific LAN address for 10103, 20202 and
30303 and forward to the corresponding native listener. They are not an AMP
child and must not change VMware/Hyper-V adapters, routes or interface metrics.
Keep an elevated, host-local rollback script that removes only those three
rules. Do not use a wildcard listen address or publish site-specific network
addresses in this template repository.

The AMP card intentionally has an empty description so its secondary line is
reserved for the connection endpoint. Application auto-start is not enabled by
the template. Configuration pages use the standard `PangYa:gamepad` category,
which renders the game name and joystick icon instead of the literal
`APPLICATION` label. The registered Genesis Server instance uses management/SFTP
ports 20094/20095 and keeps the application services on 7777, 10103, 20202 and
30303. During maintenance, the controller may remain available without
starting any of the four game processes or application listeners.

AMP config version 8 persists 46 supported settings as managed fragments for
the Auth, Login, Game and Message `Config.ini` files. The lifecycle merges them
into the real runtime tree on start while preserving the legacy quoted/unquoted
type and byte-width suffixes. A verified `runtime-config` junction targets
`D:\PangYa\Server`, so Save does not write to a shadow copy. Database
usernames/passwords and integration-managed connection wiring are excluded and
remain under the existing protected configuration/Vault contract.

The slot fields remain operator-editable. The legacy client renders 20/20 as
`Server is full` even with no players connected; the practical baseline is 200
channel slots and 2000 server slots. The AMP field descriptions retain that
warning without hiding or locking lower values. The existing US 852 installer
material is not a substitute for the USA 851 multiplayer validation client and
must be rebuilt/revalidated separately before publishing it again.
