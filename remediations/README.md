# Remediations

Intune Proactive Remediations (device health scripts) for a Cimian fleet. Each
folder is one package: `detection.ps1` decides whether the device needs help,
`script.ps1` gives it.

| Package | Detects | Does |
|---|---|---|
| `RestartStuckCimianWatcher` | A Cimian self-update is staged and unconsumed on a client old enough to read it only at service start. | Restarts CimianWatcher so it hands the update to the installer, and confirms the handoff. |
| `RemoveStaleCimianPrefs` | `ClientIdentifier` or `SoftwareRepoURL` delivered as policy under `HKLM\SOFTWARE\Policies\Cimian`, overriding the per-device values the preflight computes. | Deletes those two values and nothing else. |
| `BootstrapMateLastRun` | BootstrapMate's last run ended `partial_failure` or `failed`. | Nothing. It reports; the next run retries. Its value is the detection output in the Intune report. |

## Exit-code contract

Intune runs `detection.ps1` on its schedule, as SYSTEM.

| Script | Exit 0 | Exit 1 |
|---|---|---|
| `detection.ps1` | Healthy, or not applicable. Nothing runs. | Needs remediation; Intune runs `script.ps1`. |
| `script.ps1` | Remediated, or nothing left to do. | Could not remediate; reported as failed. |

Whatever a script writes to standard output becomes the "detection output" or
"remediation output" column in the Intune report, so each writes one line
that says what it found.

Every script here is idempotent and narrow on purpose. A detection that fires
too broadly turns a fleet-wide schedule into a fleet-wide change, so each one
checks for the exact state it repairs and exits 0 for anything else,
including a machine without Cimian.

## Deploying

By hand: Intune admin center, Devices, Scripts and remediations, Create. Upload
the two files, run as SYSTEM in 64-bit PowerShell, with signature check per
your policy, then assign a device group and a schedule (daily suits all
three).

As code: the reference Intune pipeline in
[`../intune/pipelines/reference/`](../intune/pipelines/reference/) publishes
proactive remediations from one folder per package, so these folders drop
straight into that layout. The `# Catalogs:` line at the top of each
`script.ps1` records which device cohorts the remediation is meant for, in the
same cumulative form a package uses. Start a new remediation at
`[Development, Testing]` and widen it by a reviewed edit, as described under
catalog-staged releases in the top-level README.
