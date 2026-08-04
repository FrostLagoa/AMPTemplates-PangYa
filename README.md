# PangYa (English) AMP template

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

The compatible English client is PangYa US 851/852 from the preservation link
published by `K4T/Py_Source_US`. The host-local preparation keeps the original
client DLL as `ijl15.original.dll` and installs the open-source Rugburn v2.0
shim. `rugburn.json` redirects client TCP ports 10103, 20202 and 30303 to
`server.kallidos.com` without patching the packed `ProjectG.exe`. No client or
unverified binary is included in this repository.

The AMP card intentionally has an empty description so its secondary line is
reserved for the connection endpoint. Application auto-start is not enabled by
the template. The registered Genesis Server instance uses management/SFTP
ports 20094/20095 and keeps the application services on 7777, 10103, 20202 and
30303. Both the controller and game application are currently stopped. During
future maintenance, the controller may be made available without starting any
of the four game processes or application listeners.
