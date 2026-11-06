# Fedora bootc + Niri + Noctalia, CachyOS LTO kernel, RPM Fusion codecs, gaming
# apps, OpenSnitch, Windscribe, Waterfox.  x86_64 only.
#
#   sudo podman build -t fedora-niri-bootc .
#   (pin external downloads: --build-arg OPENSNITCH_VERSION=1.8.0 --build-arg WINDSCRIBE_VERSION=...)
#
# Steps are ordered by how often they change. Editing one re-runs it and everything
# after it. Every dnf step ends in `dnf clean all` so its cache never lands in a layer.

ARG FEDORA_VERSION=44
FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

ARG FEDORA_VERSION
ARG OPENSNITCH_VERSION=latest
ARG WINDSCRIBE_VERSION=latest
# niri recommends a starter kit that Noctalia and Ghostty replace (mako would also
# compete with Noctalia for notifications). Excluded weak deps are skipped silently.
ARG UNWANTED=alacritty,fuzzel,waybar,swaylock,mako,swaybg


# 1. Repositories: RPM Fusion (+ tainted for libdvdcss), COPRs, Waterfox.
RUN set -euxo pipefail; \
    [ "$(uname -m)" = x86_64 ] || { echo "x86_64 only" >&2; exit 1; }; \
    [ "$(rpm -E %fedora)" = "${FEDORA_VERSION}" ] || { echo "FEDORA_VERSION does not match the base image" >&2; exit 1; }; \
    dnf -y install dnf5-plugins \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"; \
    dnf -y install rpmfusion-free-release-tainted; \
    for copr in yannmasoch/nautilus-my-computer lionheartp/Hyprland vertigo-red/bottles scottames/ghostty bieszczaders/kernel-cachyos-lto; do \
        dnf -y copr enable "${copr}"; \
    done; \
    curl -fsSL -o "/etc/yum.repos.d/isv:BrowserWorks.repo" \
        "https://download.opensuse.org/repositories/isv:/BrowserWorks/Fedora_${FEDORA_VERSION}/isv:BrowserWorks.repo"; \
    dnf clean all


# 2. Kernel: replace Fedora's with CachyOS LTO (bootc wants exactly one kernel).
#    The initramfs is rebuilt in step 7, once everything else is installed.
RUN set -euxo pipefail; \
    old="$(rpm -qa --qf '%{NAME}\n' | grep -E '^kernel(-core|-modules|-modules-core|-modules-extra|-modules-internal)?$' | sort -u | tr '\n' ' ')"; \
    if [ -n "${old}" ]; then dnf -y remove --setopt=clean_requirements_on_remove=False ${old}; fi; \
    rm -rf /usr/lib/modules/*; \
    dnf -y install kernel-cachyos-lto kernel-cachyos-lto-devel-matched; \
    [ "$(ls /usr/lib/modules | wc -l)" -eq 1 ] || { ls -l /usr/lib/modules >&2; echo "expected exactly one kernel" >&2; exit 1; }; \
    test -s "/usr/lib/modules/$(ls /usr/lib/modules)/vmlinuz"; \
    dnf clean all


# 3. Desktop core + apps (big, keep this list stable; it holds most of the download).
RUN set -euxo pipefail; \
    dnf -y install --exclude="${UNWANTED}" \
        niri noctalia xwayland-satellite \
        xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
        greetd greetd-selinux noctalia-greeter-git \
        steam lutris bottles ghostty waterfox mesa-libGLU.x86_64 mesa-libGLU.i686 \
        pipewire pipewire-pulseaudio pipewire-alsa wireplumber \
        NetworkManager-wifi bluez power-profiles-daemon upower polkit \
        gnome-keyring gnome-keyring-pam xdg-user-dirs xdg-utils \
        linux-firmware alsa-firmware alsa-sof-firmware dracut mesa-dri-drivers mesa-vulkan-drivers; \
    dnf clean all


# 4. Extras (the list you tweak often).
RUN set -euxo pipefail; \
    dnf -y install --exclude="${UNWANTED}" \
        @fonts @hardware-support plymouth-system-theme \
        glibc-all-langpacks google-noto-sans-fonts google-noto-emoji-fonts \
        nemo nemo-compare nemo-preview nemo-fileroller nemo-seahorse nemo-search-helpers \
        nemo-dropbox nemo-extensions \
        adw-gtk3-theme qt5ct qt6ct kate peazip-gtk3 pavucontrol alsa-utils \
        distrobox podman flatpak wget; \
    dnf clean all


# 5. Codecs (RPM Fusion "Multimedia on Fedora"). After the apps, so any ffmpeg-free
#    libs they pulled in get replaced by the full ffmpeg.
RUN set -euxo pipefail; \
    dnf -y install --allowerasing ffmpeg; \
    dnf -y install @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin; \
    dnf -y group install sound-and-video; \
    dnf -y install --allowerasing mesa-va-drivers-freeworld.i686 mesa-va-drivers-freeworld intel-media-driver libva-nvidia-driver libva-utils; \
    dnf -y install libdvdcss; \
    if rpm -q ffmpeg-free >/dev/null 2>&1; then echo "ffmpeg-free is still installed" >&2; exit 1; fi; \
    dnf clean all


# 6. OpenSnitch + Windscribe (GitHub release RPMs). "latest" is resolved through the
#    /releases/latest redirect, which has no API rate limit.
#    - The OpenSnitch daemon RPM's %post runs `systemctl start`, which fails during an
#      image build and aborts the whole transaction. It only enables/starts the unit,
#      so it is installed with scriptlets off and enabled in step 8.
#    - Windscribe installs into /opt, which on Fedora bootc is a symlink to /var/opt
#      (not carried across image updates). Anything landing there is moved to
#      /usr/lib/opt and linked back at boot via tmpfiles.d.
#    - The Windscribe RPM's signature is verified against Windscribe's published key.
RUN set -euxo pipefail; \
    latest() { local t; t="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")"; echo "${t##*/v}"; }; \
    os="${OPENSNITCH_VERSION}"; [ "${os}" != latest ] || os="$(latest evilsocket/opensnitch)"; \
    ws="${WINDSCRIBE_VERSION}"; [ "${ws}" != latest ] || ws="$(latest Windscribe/Desktop-App)"; \
    cd /tmp; \
    curl -fsSL --fail-early \
        -O "https://github.com/evilsocket/opensnitch/releases/download/v${os}/opensnitch-${os}-1.x86_64.rpm" \
        -O "https://github.com/evilsocket/opensnitch/releases/download/v${os}/opensnitch-ui-${os}-1.noarch.rpm" \
        -O "https://github.com/Windscribe/Desktop-App/releases/download/v${ws}/windscribe_${ws}_amd64_fedora.rpm" \
        -O "https://windscribe.com/windscribe_linux_signing_key.pub"; \
    rpm --import windscribe_linux_signing_key.pub; \
    rpmkeys --checksig "windscribe_${ws}_amd64_fedora.rpm" | tee /dev/stderr | grep -q 'signatures OK'; \
    [ ! -L /opt ] || mkdir -p /var/opt; \
    dnf -y install --setopt=tsflags=noscripts "/tmp/opensnitch-${os}-1.x86_64.rpm"; \
    dnf -y install "/tmp/opensnitch-ui-${os}-1.noarch.rpm" "/tmp/windscribe_${ws}_amd64_fedora.rpm"; \
    if [ -L /opt ]; then \
        mkdir -p /usr/lib/opt; \
        for d in /var/opt/*; do \
            [ -e "${d}" ] || continue; \
            mv "${d}" /usr/lib/opt/; \
            echo "L+ /var/opt/${d##*/} - - - - /usr/lib/opt/${d##*/}" > "/usr/lib/tmpfiles.d/opt-${d##*/}.conf"; \
        done; \
    fi; \
    test -e /usr/lib/opt/windscribe || test -e /opt/windscribe; \
    rm -f /tmp/*.rpm /tmp/*.pub; \
    dnf clean all


# 7. Initramfs, built after every package is installed so it includes GPU/sound
#    firmware, plymouth and any dracut modules. Before COPY so config edits skip it.
RUN set -euxo pipefail; \
    [ "$(ls /usr/lib/modules | wc -l)" -eq 1 ] || { ls -l /usr/lib/modules >&2; echo "expected exactly one kernel" >&2; exit 1; }; \
    kver="$(ls /usr/lib/modules)"; \
    depmod -a "${kver}"; \
    env DRACUT_NO_XATTR=1 dracut -vf --no-hostonly --reproducible "/usr/lib/modules/${kver}/initramfs.img" "${kver}"; \
    test -s "/usr/lib/modules/${kver}/initramfs.img"


# 8. Image config from files/ (greetd -> noctalia-greeter, /etc/niri/config.kdl, the
#    greeter's SELinux label, the Flathub first-boot unit), services, cleanup, lint.
#    flatpak-add-fedora-repos.service (Fedora's own remote) is masked in favour of Flathub.
COPY files/ /

RUN set -euxo pipefail; \
    niri validate -c /etc/niri/config.kdl; \
    systemctl enable greetd NetworkManager bluetooth power-profiles-daemon opensnitch windscribe-helper flatpak-add-flathub; \
    systemctl mask flatpak-add-fedora-repos.service; \
    systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service; \
    systemctl set-default graphical.target; \
    rm -rf /var/cache/* /var/log/* /tmp/*; \
    find /boot -mindepth 1 -delete; \
    dnf clean all; \
    bootc container lint
