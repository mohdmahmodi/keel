# Security

Keel includes a privileged helper that runs as root. It accepts requests only from Keel signed by the same Developer
ID team, and it executes only the operations listed in `PrivOp` (`Sources/KeelShared/PrivOp.swift`), each validated
against an allow-list, without a shell.

## Reporting a vulnerability

Report security problems privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Please include the macOS version, the Keel version, and steps to reproduce.

Do not open public issues for vulnerabilities. You can expect an acknowledgement within a few days.

## Scope

In scope: the helper accepting requests it should not, an allow-listed operation that can be abused to do more than
intended, Keel writing outside the paths it documents, and anything that leaks data off the Mac.
