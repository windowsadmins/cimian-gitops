# Cimian preflight package

A [cimipkg](https://github.com/windowsadmins/cimian-pkg) project that installs a
`preflight.ps1` for Cimian to run before every `managedsoftwareupdate` check.

## Where Cimian looks

Cimian runs the first of these that exists:

1. `C:\Program Files\Cimian\preflight.ps1`, where this package installs it.
2. `C:\ProgramData\ManagedInstalls\sbin\preflight.ps1`, the fallback. Drop a
   script there by hand to test a change on one machine without a package.

## Exit codes

A non-zero exit counts as a preflight failure. `PreflightFailureAction` in
`C:\ProgramData\ManagedInstalls\Config.yaml` decides what happens next:

| Value | Effect |
|---|---|
| `continue` | The default. Logs the failure and runs the check anyway. |
| `warn` | Runs the check anyway, with a warning. |
| `abort` | Stops the run. |

## Build

The payload is flat: `payload/preflight.ps1` lands directly in
`install_location`. The version is `${TIMESTAMP}`, and the signing certificate
is read from `SIGNING_CERT_SUBJECT` in the environment or a gitignored `.env`
beside `build-info.yaml`.

```sh
cimipkg preflight/cimian
```

## Ideas for the body

The sample body only writes a run marker. Things a preflight is good for:

- Choosing `ClientIdentifier` from inventory, so a machine follows its manifest
  when it moves between rooms or owners. Refuse to write a blank value: an
  empty `ClientIdentifier` points the client at no manifest at all.
- Choosing `SoftwareRepoURL`, for example an on-site cache when one answers and
  the CDN when it does not.
- One-time fixes that should run once per machine, with a marker file so the
  next cycle skips them.
