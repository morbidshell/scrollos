# Fedora bootc  +  Niri  +  Noctalia
# CachyOS (LTO) kernel, RPM Fusion codecs, Steam/Lutris/Bottles/Ghostty,
# OpenSnitch, Windscribe, Waterfox.   x86_64 only.
#
#   sudo podman build -t fedora-niri-bootc .
#
# Pin external downloads with e.g.  --build-arg OPENSNITCH_VERSION=1.8.0

ARG FEDORA_VERSION=44
FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

ARG FEDORA_VERSION
ARG OPENSNITCH_VERSION=latest
ARG WINDSCRIBE_VERSION=latest

# Fail early on the wrong arch / base release.
RUN set -eu; \
    [ "$(uname -m)" = x86_64 ] || { echo "x86_64 only (CachyOS kernel, OpenSnitch and Windscribe RPMs)" >&2; exit 1; }; \
    [ "$(rpm -E %fedora)" = "${FEDORA_VERSION}" ] || { echo "FEDORA_VERSION does not match the base image" >&2; exit 1; }


# ── 1. Repositories ───────────────────────────────────────────────────────────
# RPM Fusion (free, nonfree, free-tainted for libdvdcss), the four COPRs, and
# the official Waterfox repo (isv:BrowserWorks, built on the openSUSE OBS).
RUN set -euxo pipefail; \
    dnf -y install dnf5-plugins; \
    dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"; \
    dnf -y install rpmfusion-free-release-tainted; \
    for copr in lionheartp/Hyprland vertigo-red/bottles scottames/ghostty bieszczaders/kernel-cachyos-lto; do \
        dnf -y copr enable "${copr}"; \
    done; \
    curl -fsSL -o "/etc/yum.repos.d/isv:BrowserWorks.repo" \
        "https://download.opensuse.org/repositories/isv:/BrowserWorks/Fedora_${FEDORA_VERSION}/isv:BrowserWorks.repo"


# ── 2. Kernel: swap Fedora's kernel for CachyOS LTO ───────────────────────────
# bootc wants exactly one kernel in /usr/lib/modules/<kver>/ with an initramfs.img
# next to vmlinuz, so: remove the stock kernel, install CachyOS, rebuild the
# initramfs explicitly (dracut invocation as per the Fedora bootc docs).
RUN set -euxo pipefail; \
    old="$(rpm -qa --qf '%{NAME}\n' | grep -E '^kernel(-core|-modules|-modules-core|-modules-extra|-modules-internal)?$' | sort -u | tr '\n' ' ')"; \
    if [ -n "${old}" ]; then dnf -y remove --setopt=clean_requirements_on_remove=False ${old}; fi; \
    rm -rf /usr/lib/modules/*; \
    dnf -y install kernel-cachyos-lto kernel-cachyos-lto-devel-matched; \
    [ "$(ls -1 /usr/lib/modules | wc -l)" -eq 1 ] || { echo "expected exactly one kernel in /usr/lib/modules" >&2; ls -l /usr/lib/modules >&2; exit 1; }; \
    kver="$(ls -1 /usr/lib/modules)"; \
    test -s "/usr/lib/modules/${kver}/vmlinuz"; \
    depmod -a "${kver}"; \
    env DRACUT_NO_XATTR=1 dracut -vf --no-hostonly --reproducible "/usr/lib/modules/${kver}/initramfs.img" "${kver}"; \
    test -s "/usr/lib/modules/${kver}/initramfs.img"


# ── 3. Desktop + apps ─────────────────────────────────────────────────────────
# niri / noctalia           Fedora repos (Noctalia v5)
# noctalia-greeter-git      COPR lionheartp/Hyprland (+ greetd, configured below)
# steam                     RPM Fusion nonfree
# lutris                    Fedora
# bottles                   COPR vertigo-red/bottles
# ghostty                   COPR scottames/ghostty
# waterfox                  isv:BrowserWorks repo
# The rest is the minimum runtime a bare fedora-bootc lacks for a Wayland desktop.
RUN set -euxo pipefail; \
    dnf -y install \
        niri noctalia xwayland-satellite \
        xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
        greetd kate nautilus adw-gtk3-theme nautilus-python greetd-selinux noctalia-greeter-git \
        steam lutris bottles ghostty nautilus-megasync waterfox mesa-libGLU.x86_64 mesa-libGLU.i686 \
        pipewire pipewire-pulseaudio pipewire-alsa wireplumber \
        NetworkManager-wifi bluez power-profiles-daemon upower polkit \
        gnome-keyring gnome-keyring-pam xdg-user-dirs xdg-utils \
        linux-firmware peazip-gtk3 adw-gtk3-theme qt5ct qt6ct dracut mesa-dri-drivers mesa-vulkan-drivers \
        google-noto-sans-fonts sushi file-roller-nautilus seahorse-nautilus google-noto-emoji-fonts


# ── 4. Codecs (RPM Fusion "Multimedia on Fedora") ─────────────────────────────
# Run after the apps so any ffmpeg-free libs they pulled in get replaced.
#  - full ffmpeg instead of ffmpeg-free (same result as `dnf swap ffmpeg-free ffmpeg
#    --allowerasing`, but doesn't fail if ffmpeg-free isn't installed)
#  - @multimedia (gstreamer) and sound-and-video groups, as in the howto
#  - hardware video decode: AMD (mesa freeworld), Intel, NVIDIA
#  - libdvdcss from rpmfusion-free-tainted
RUN set -euxo pipefail; \
    dnf -y install --allowerasing ffmpeg; \
    dnf -y install @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin; \
    dnf -y group install sound-and-video; \
    dnf -y install --allowerasing mesa-va-drivers-freeworld intel-media-driver libva-nvidia-driver libva-utils; \
    dnf -y install libdvdcss; \
    rpm -q ffmpeg ffmpeg-libs mesa-va-drivers-freeworld libdvdcss; \
    if rpm -q ffmpeg-free >/dev/null 2>&1; then echo "ffmpeg-free is still installed" >&2; exit 1; fi


# ── 5. OpenSnitch (GitHub release RPMs: daemon + Qt6 GUI) ─────────────────────
# "latest" is resolved via the /releases/latest redirect (no API rate limits).
# The daemon RPM's %post ends with an unconditional `systemctl start`, which can't
# work during an image build (no running systemd) and makes dnf fail the whole
# transaction. Its scriptlets only enable/start the unit, so install it with
# scriptlets off and enable the unit in step 7. The GUI RPM's scriptlet is fine
# (it adds the XDG autostart entry), so that one installs normally.
RUN set -euxo pipefail; \
    ver="${OPENSNITCH_VERSION}"; \
    if [ "${ver}" = latest ]; then \
        tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/evilsocket/opensnitch/releases/latest)"; \
        ver="${tag##*/v}"; \
    fi; \
    base="https://github.com/evilsocket/opensnitch/releases/download/v${ver}"; \
    curl -fsSL -o /tmp/opensnitch.rpm    "${base}/opensnitch-${ver}-1.x86_64.rpm"; \
    curl -fsSL -o /tmp/opensnitch-ui.rpm "${base}/opensnitch-ui-${ver}-1.noarch.rpm"; \
    dnf -y install --setopt=tsflags=noscripts /tmp/opensnitch.rpm; \
    dnf -y install /tmp/opensnitch-ui.rpm; \
    rm -f /tmp/opensnitch.rpm /tmp/opensnitch-ui.rpm; \
    test -e /usr/lib/systemd/system/opensnitch.service


# ── 6. Windscribe (GitHub release RPM, signature-checked) ─────────────────────
# The RPM installs to /opt/windscribe. On Fedora bootc images /opt is a symlink to
# /var/opt, and /var is not carried across image updates, so the payload is moved
# to /usr/lib/opt and linked back at boot with tmpfiles.d.
RUN set -euxo pipefail; \
    ver="${WINDSCRIBE_VERSION}"; \
    if [ "${ver}" = latest ]; then \
        tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/Windscribe/Desktop-App/releases/latest)"; \
        ver="${tag##*/v}"; \
    fi; \
    pkg="windscribe_${ver}_amd64_fedora.rpm"; \
    curl -fsSL -o "/tmp/${pkg}" "https://github.com/Windscribe/Desktop-App/releases/download/v${ver}/${pkg}"; \
    curl -fsSL -o /tmp/windscribe.pub https://windscribe.com/windscribe_linux_signing_key.pub; \
    rpm --import /tmp/windscribe.pub; \
    rpmkeys --checksig "/tmp/${pkg}" | tee /dev/stderr | grep -q 'signatures OK'; \
    if [ -L /opt ]; then mkdir -p /var/opt; fi; \
    dnf -y install "/tmp/${pkg}"; \
    rm -f "/tmp/${pkg}" /tmp/windscribe.pub; \
    if [ -L /opt ]; then \
        mkdir -p /usr/lib/opt; \
        for d in /var/opt/*; do \
            [ -e "${d}" ] || continue; \
            n="${d##*/}"; \
            mv "${d}" "/usr/lib/opt/${n}"; \
            printf 'L+ /var/opt/%s - - - - /usr/lib/opt/%s\n' "${n}" "${n}" > "/usr/lib/tmpfiles.d/opt-${n}.conf"; \
        done; \
    fi; \
    test -e /opt/windscribe || test -e /usr/lib/opt/windscribe


# ── 7. Image config ───────────────────────────────────────────────────────────
# files/ ships: greetd -> noctalia-greeter, a default /etc/niri/config.kdl that
# starts Noctalia, and the SELinux label for the greeter's state dir.
COPY files/ /

RUN set -euxo pipefail; \
    niri validate -c /etc/niri/config.kdl; \
    systemctl enable greetd.service NetworkManager.service bluetooth.service power-profiles-daemon.service opensnitch.service; \
    units="$(rpm -ql windscribe | grep -E '/systemd/system/[^/]+\.service$' | xargs -r -n1 basename)"; \
    [ -n "${units}" ] || { echo "no systemd unit found in the windscribe package" >&2; exit 1; }; \
    for unit in ${units}; do systemctl enable "${unit}"; done; \
    systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service; \
    systemctl set-default graphical.target


# ── 8. Clean up + lint ────────────────────────────────────────────────────────
RUN set -euxo pipefail; \
    dnf clean all; \
    rm -rf /var/cache/* /var/log/* /tmp/*; \
    find /boot -mindepth 1 -delete

RUN bootc container lint
