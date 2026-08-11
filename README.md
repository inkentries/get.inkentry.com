# get.inkentry.com

The install scripts for [inkentry](https://inkentry.com), served from
`https://get.inkentry.com` via GitHub Pages.

## Installing inkentry

macOS (Apple silicon) and Linux:

```sh
curl -fsSL https://get.inkentry.com/install.sh | sh
```

Windows (PowerShell):

```powershell
iex ((New-Object Net.WebClient).DownloadString('https://get.inkentry.com/install.ps1'))
```

Visiting `https://get.inkentry.com` in a browser redirects to the
[getting-started docs](https://inkentry.com/docs/getting-started).

## Why this repository looks the way it does

- **`install.sh` / `install.ps1`** download the latest release for the current
  platform and install the `inkentry` and `inkentry-server` binaries. No
  telemetry, no account, and `install.sh` never invokes sudo on its own. Both
  accept a version and an install-directory override — see the header of each
  script.
- **`index.html`** is the root redirect. GitHub Pages cannot issue server-side
  redirects, so the root carries a meta refresh to the docs. Only browsers
  ever see it; scripts are fetched by their full path.
- **`CNAME`** binds the Pages site to `get.inkentry.com`.
- **`.nojekyll`** switches off Jekyll processing so files are served exactly
  as committed.

### Serving scripts from GitHub Pages — what was verified

- `.sh` files are served as `application/x-sh` with a direct `200`, which is
  exactly what `curl | sh` needs (the pipe ignores content type anyway).
- `.ps1` files are served as `application/octet-stream`. That is why the
  Windows one-liner uses `WebClient.DownloadString`, which ignores content
  type — the shorter `irm | iex` pattern can produce a byte array rather than
  a string for octet-stream responses and then fail.
- Pages serves everything with `cache-control: max-age=600`, so a new release
  of a script is visible within ten minutes.

## Go-live checklist

This repository is local-only until the window. To publish:

1. Create the public repository and push `main`.
2. Repository settings → Pages → deploy from branch, `main` / `/ (root)`.
3. DNS: `CNAME get.inkentry.com → <owner>.github.io`.
4. Once the certificate is issued, tick **Enforce HTTPS**.
5. Confirm a release exists whose assets are named
   `inkentry-<version>-<target>.tar.gz` / `.zip` — the scripts are written
   against that naming and must not go live before it exists.
6. Smoke-test both one-liners from a clean machine.

## Licence

[MIT](LICENSE)
