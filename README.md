# fedora-niri-bootc

Personal Fedora bootc image: Niri + Noctalia (v5) with the Noctalia greeter, CachyOS LTO kernel,
RPM Fusion + codecs, Steam, Lutris, Bottles, Ghostty, OpenSnitch, Windscribe and Waterfox.
x86_64 only.

## What comes from where

| Piece | Source |
|---|---|
| niri, noctalia, lutris, greetd | Fedora repos |
| steam, ffmpeg, codecs, libdvdcss | RPM Fusion (free, nonfree, free-tainted) |
| noctalia-greeter-git | COPR `lionheartp/Hyprland` |
| bottles | COPR `vertigo-red/bottles` |
| ghostty | COPR `scottames/ghostty` |
| kernel-cachyos-lto, -devel-matched | COPR `bieszczaders/kernel-cachyos-lto` |
| waterfox | `isv:BrowserWorks` repo (download.opensuse.org) |
| opensnitch + opensnitch-ui | GitHub release RPMs (latest, or `--build-arg OPENSNITCH_VERSION=1.8.0`) |
| windscribe | GitHub release RPM, signature-checked (latest, or `--build-arg WINDSCRIBE_VERSION=...`) |

## Build

```
sudo podman build --pull=newer -t fedora-niri-bootc .
```

Or push this repo to GitHub: `.github/workflows/build.yml` builds on every push and daily,
and publishes to `ghcr.io/<you>/<repo>:latest`.

## Install

From an existing Fedora bootc / Atomic system:

```
sudo bootc switch ghcr.io/<you>/<repo>:latest && sudo systemctl reboot
```

For a fresh install, make a disk image or ISO with `bootc-image-builder` and a `config.toml`
that creates your user (bootc images ship without one):

```toml
[[customizations.user]]
name = "you"
password = "change-me"
groups = ["wheel"]
```

## Things to know

- **Secure Boot:** the CachyOS kernel is not signed for Fedora's shim. Disable Secure Boot,
  or sign the kernel and enrol your key.
- **Noctalia versions:** the image installs stable `noctalia` from Fedora but the greeter as
  a git snapshot. If they disagree (greeter sync, new features), replace `noctalia` with
  `noctalia-git` in the Containerfile (same COPR as the greeter).
- **`/etc/niri/config.kdl`** is the system default and starts Noctalia. A user file in
  `~/.config/niri/config.kdl` overrides it, so copy it there before customising.
- **OpenSnitch:** the daemon (`opensnitch.service`) is enabled; start the GUI with `opensnitch-ui`.
- **Windscribe:** the RPM installs into `/opt`, which on Fedora bootc points at `/var/opt`.
  The Containerfile moves it to `/usr/lib/opt` and relinks it at boot.
