# Provisioning

`public/management.json` is the manifest BootstrapMate reads at the Enrollment
Status Page. The bootstrap pipeline uploads it to `<container>/bootstrap/` and
purges the CDN path, and BootstrapMate fetches it from the URL set in its
preferences.

Keep it small. It lists only what must be on the machine before the desktop
appears, which is the Cimian client and the preferences that point it at your
repo. Cimian then installs everything else from the catalogs.

The sample installs the Cimian client for the machine's architecture and a
preferences package you build with cimipkg. The URLs are placeholders, and the
`file` names carry a version so a new build is a new path and never a stale
CDN copy. See the
[BootstrapMate README](https://github.com/bootstrapmate/bootstrapmate-windows#readme)
for the full schema, including the optional `preflight` stage and `userland`
items that run after first sign-in.
