<h1 align="center">NanoKVM Pro Mount Web Manager</h1>

<p align="center">
  <img src="https://visitor-badge.laobi.icu/badge?page_id=vadlike.NanoKVM-Pro-Mount-web-manager" alt="visitors">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license MIT">
  <img src="https://img.shields.io/github/last-commit/vadlike/NanoKVM-Pro-Mount-web-manager" alt="last commit">
  <a href="https://wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/introduction.html">
    <img src="https://img.shields.io/badge/NanoKVM%20Pro-Official%20Device%20Page-red" alt="NanoKVM Pro device">
  </a>
</p>

Web manager for NanoKVM Pro with:

- file manager for `/data` and `/sdcard`
- inline ISO mount actions
- direct image mounting from the file manager
- safe `Upload from URL`
- torrent download manager with `aria2`
- torrent preview and file tree selection
- dark NanoKVM-themed UI

## Demo

![NanoKVM Pro demo](demo.gif)

## Security

This repository ships a hardened build, not a stock upstream Tiny File Manager.

| Area | Status | Details |
|---|---|---|
| Hardened build | Included | This project ships a custom hardened build, not a stock upstream Tiny File Manager package. |
| Unsafe paths review | Patched | Known unsafe paths in the original integration were reviewed and patched in this NanoKVM build. |
| `Upload from URL` | Hardened | The feature was rewritten with server-side validation instead of using the original unsafe flow. |
| Redirect handling | Mitigated | Redirects are validated step by step instead of trusting blind redirect chains. |
| SSRF surface | Reduced | Private, reserved, localhost, link-local and metadata-style addresses are blocked for URL fetches. |
| Upstream install dependency | Removed | Installer uses a pinned vendored base file from this repository instead of depending on a live upstream file at install time. |
| `CVE-2025-46651` | Mitigated | Mitigation is included for the `Upload from URL` / redirect-based SSRF abuse path. |

## Image mount support

NanoKVM Pro can mount image files directly from the file manager with inline actions:

- `CD` - mount as virtual `CD-ROM`
- `USB` - mount as virtual `Mass Storage`
- `Unmount` - detach the currently mounted image

Supported image and disk formats in the UI:

| Format | Status | Notes |
|---|---|---|
| `.iso` | Recommended | Best choice for virtual `CD-ROM` mounting. |
| `.img` | Recommended | Reliable raw disk image format. |
| `.raw` | Recommended | Reliable passthrough disk image format. |
| `.dd` | Recommended | Reliable raw disk dump format. |
| `.ima` | Recommended | Good compatibility for floppy/disk style images. |
| `.dsk` | Recommended | Good compatibility for disk image passthrough. |
| `.vfd` | Recommended | Suitable for small virtual disk / floppy style images. |
| `.bin` | Supported | Works in some cases, but plain `.iso` is usually safer. |
| `.efi` | Supported | Available in UI, compatibility depends on the remote host workflow. |
| `.cue` | Experimental | Advanced passthrough option, compatibility depends on image structure. |
| `.mdf` | Experimental | Advanced passthrough option, host compatibility may vary. |
| `.mds` | Experimental | Advanced passthrough option, host compatibility may vary. |
| `.vhd` | Experimental | Exposed in UI as passthrough; not as reliable as raw images. |
| `.vhdx` | Experimental | Exposed in UI as passthrough; not as reliable as raw images. |
| `.vmdk` | Experimental | Exposed in UI as passthrough; not as reliable as raw images. |
| `.qcow2` | Experimental | Exposed in UI as passthrough; compatibility depends on host expectations. |
| `.dmg` | Experimental | Available in UI, but compatibility is host-dependent. |

## Install

Run on NanoKVM as `root`:

```bash
wget https://raw.githubusercontent.com/vadlike/NanoKVM-Pro-Mount-web-manager/main/install.sh -O install.sh && bash install.sh
```

Or with `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/vadlike/NanoKVM-Pro-Mount-web-manager/main/install.sh -o install.sh && bash install.sh
```

Default web login after install:

- username: `admin`
- password: `admin`

Default URL:

```text
http://<nanokvm-ip>:8081/
```

## Custom install

You can pass custom login, password, and port:

```bash
bash install.sh mylogin mypassword 8081
```

Format:

```bash
bash install.sh <username> <password> <port>
```

## Uninstall

```bash
wget https://raw.githubusercontent.com/vadlike/NanoKVM-Pro-Mount-web-manager/main/uninstall.sh -O uninstall.sh && bash uninstall.sh
```

Or:

```bash
curl -fsSL https://raw.githubusercontent.com/vadlike/NanoKVM-Pro-Mount-web-manager/main/uninstall.sh -o uninstall.sh && bash uninstall.sh
```

## What `install.sh` does

`install.sh` is a bootstrap script. It downloads the real installer from this repository:

```text
scripts/install-tinyfilemanager.sh
```

Then it runs that installer on the NanoKVM host. So when you update files in the repository and a user runs the install command again, the latest installer from the repo is used.

The installer does not depend on upstream Tiny File Manager availability during install. It downloads the fixed vendor copy from this repository:

```text
vendor/tinyfilemanager-2.6.php
```

## Main files in this repo

- `install.sh` - bootstrap installer
- `uninstall.sh` - bootstrap uninstaller
- `scripts/install-tinyfilemanager.sh` - main NanoKVM Pro installer
- `scripts/uninstall-tinyfilemanager.sh` - main NanoKVM Pro uninstaller
- `vendor/tinyfilemanager-2.6.php` - pinned upstream base file used by the installer

## Notes

- Torrent service uses `aria2`
- Uploaded torrent source files are stored in `_torrent_files`
- Some active `.aria2` files may stay near download targets while a torrent is running because `aria2` needs them for resume
