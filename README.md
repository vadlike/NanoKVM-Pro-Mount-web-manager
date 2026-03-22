# NanoKVM Pro Mount Web Manager

Web manager for NanoKVM Pro with:

- file manager for `/data` and `/sdcard`
- inline ISO mount actions
- safe `Upload from URL`
- torrent download manager with `aria2`
- torrent preview and file tree selection
- dark NanoKVM-themed UI

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

## Main files in this repo

- `install.sh` - bootstrap installer
- `uninstall.sh` - bootstrap uninstaller
- `scripts/install-tinyfilemanager.sh` - main NanoKVM Pro installer
- `scripts/uninstall-tinyfilemanager.sh` - main NanoKVM Pro uninstaller

## Notes

- Torrent service uses `aria2`
- Uploaded torrent source files are stored in `_torrent_files`
- Some active `.aria2` files may stay near download targets while a torrent is running because `aria2` needs them for resume
