# Fedora bootc + Niri + Noctalia, CachyOS LTO kernel, RPM Fusion codecs, gaming
# apps, OpenSnitch, Windscribe, Waterfox.  x86_64 only.
#
#   GH_TOKEN=... bash scripts/fetch-rpms.sh     # OpenSnitch + Windscribe RPMs -> ./rpms
#   sudo podman build -t fedora-niri-bootc .
#   (pin them: OPENSNITCH_VERSION=1.8.0 WINDSCRIBE_VERSION=2.24.13 bash scripts/fetch-rpms.sh)
#
# Steps are ordered by how often they change. Editing one re-runs it and everything
# after it. Every dnf step mounts a build cache at /var/cache/libdnf5: the repos' package
# lists are downloaded once per build instead of once per step, and never stored in a
# layer. So there is no `dnf clean all` anywhere: cleaning would empty that cache.

ARG FEDORA_VERSION=44

# The RPMs that scripts/fetch-rpms.sh downloaded. Step 6 bind-mounts this stage, so the
# files are used during the build but never stored in an image layer.
FROM scratch AS rpms
COPY rpms/ /

FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

ARG FEDORA_VERSION
# niri recommends a starter kit that Noctalia and Ghostty replace (mako would also
# compete with Noctalia for notifications). Excluded weak deps are skipped silently.
ARG UNWANTED=alacritty,fuzzel,waybar,swaylock,mako,swaybg


# 1. Repositories: RPM Fusion (+ tainted for libdvdcss) and the COPRs.
RUN --mount=type=cache,target=/var/cache/libdnf5,sharing=locked \
    set -euxo pipefail; \
    [ "$(uname -m)" = x86_64 ] || { echo "x86_64 only" >&2; exit 1; }; \
    [ "$(rpm -E %fedora)" = "${FEDORA_VERSION}" ] || { echo "FEDORA_VERSION does not match the base image" >&2; exit 1; }; \
    dnf -y install dnf5-plugins \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"; \
    dnf -y install rpmfusion-free-release-tainted; \
    for copr in lionheartp/Hyprland vertigo-red/bottles scottames/ghostty bieszczaders/kernel-cachyos-lto; do \
        dnf -y copr enable "${copr}"; \
    done


# 2. Kernel: replace Fedora's with CachyOS LTO (bootc wants exactly one kernel).
#    The initramfs is rebuilt in step 7, once everything else is installed.
RUN --mount=type=cache,target=/var/cache/libdnf5,sharing=locked \
    set -euxo pipefail; \
    old="$(rpm -qa --qf '%{NAME}\n' | grep -E '^kernel(-core|-modules|-modules-core|-modules-extra|-modules-internal)?$' | sort -u | tr '\n' ' ')"; \
    if [ -n "${old}" ]; then dnf -y remove --setopt=clean_requirements_on_remove=False ${old}; fi; \
    rm -rf /usr/lib/modules/*; \
    dnf -y install kernel-cachyos-lto kernel-cachyos-lto-devel-matched; \
    [ "$(ls /usr/lib/modules | wc -l)" -eq 1 ] || { ls -l /usr/lib/modules >&2; echo "expected exactly one kernel" >&2; exit 1; }; \
    test -s "/usr/lib/modules/$(ls /usr/lib/modules)/vmlinuz"


# 3. Desktop core + apps (big, keep this list stable; it holds most of the download).
RUN --mount=type=cache,target=/var/cache/libdnf5,sharing=locked \
    set -euxo pipefail; \
    dnf -y install --exclude="${UNWANTED}" \
        niri noctalia xwayland-satellite \
        xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
        greetd greetd-selinux noctalia-greeter-git \
        steam lutris bottles ghostty mesa-libGLU.x86_64 mesa-libGLU.i686 \
        pipewire pipewire-pulseaudio pipewire-alsa wireplumber \
        NetworkManager-wifi bluez power-profiles-daemon upower polkit \
        gnome-keyring gnome-keyring-pam xdg-user-dirs xdg-utils \
        linux-firmware alsa-firmware alsa-sof-firmware dracut mesa-dri-drivers mesa-vulkan-drivers


# 4. Extras (the list you tweak often).
RUN --mount=type=cache,target=/var/cache/libdnf5,sharing=locked \
    set -euxo pipefail; \
    dnf -y install --exclude="${UNWANTED}" \
        @fonts @hardware-support plymouth-system-theme \
        glibc-all-langpacks google-noto-sans-fonts google-noto-emoji-fonts \
        nemo nemo-compare nemo-preview nemo-fileroller nemo-seahorse nemo-search-helpers \
        nemo-dropbox nemo-extensions \
        adw-gtk3-theme qt5ct qt6ct kate peazip-gtk3 pavucontrol alsa-utils \
        distrobox podman flatpak wget


# 4b. Waterfox, from its official repo (isv:BrowserWorks on download.opensuse.org). The repo
#     is added only here, not in step 1: dnf downloads the package list of every enabled
#     repo in every step, so an outage of this one repo would otherwise break (and slow
#     down) all the steps before it. Here a failure only repeats this small step.
RUN --mount=type=cache,target=/var/cache/libdnf5,sharing=locked \
    set -euxo pipefail; \
    curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -o "/etc/yum.repos.d/isv:BrowserWorks.repo" \
        "https://download.opensuse.org/repositories/isv:/BrowserWorks/Fedora_${FEDORA_VERSION}/isv:BrowserWorks.repo"; \
    dnf -y install waterfox


# 5. Codecs (RPM Fusion "Multimedia on Fedora"). After the apps, so any ffmpeg-free
#    libs they pulled in get replaced by the full ffmpeg.
#    libheif-freeworld is deliberately left out. It pins the exact libheif version, RPM
#    Fusion lags behind Fedora's updates, and the mismatch fails the whole transaction.
#    HEIC photos still decode: Fedora's libheif-ffmpeg plugin (already in the image) runs
#    on the full ffmpeg installed here. What is lost is only the HEIC *encoder*.
RUN --mount=type=cache,target=/var/cache/libdnf5,sharing=locked \
    set -euxo pipefail; \
    dnf -y install --allowerasing ffmpeg; \
    dnf -y install @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin,libheif-freeworld; \
    dnf -y group install sound-and-video --exclude=libheif-freeworld; \
    dnf -y install --allowerasing mesa-va-drivers-freeworld.i686 mesa-va-drivers-freeworld intel-media-driver libva-nvidia-driver libva-utils; \
    dnf -y install libdvdcss; \
    if rpm -q ffmpeg-free >/dev/null 2>&1; then echo "ffmpeg-free is still installed" >&2; exit 1; fi


# 6. OpenSnitch + Windscribe + umu-launcher, installed from the RPMs scripts/fetch-rpms.sh put in ./rpms.
#    They are downloaded outside the build, through the authenticated GitHub API, because
#    github.com's web endpoints kept answering 504 to unauthenticated requests from the runners.
#    - The OpenSnitch daemon RPM's %post runs `systemctl start`, which fails during an
#      image build and aborts the whole transaction. It only enables/starts the unit,
#      so it is installed with scriptlets off and enabled in step 8.
#    - Windscribe installs into /opt, which on Fedora bootc is a symlink to /var/opt
#      (not carried across image updates). Anything landing there is moved to
#      /usr/lib/opt and linked back at boot via tmpfiles.d.
#    - The Windscribe RPM's signature is verified against Windscribe's published key.
#    - umu-launcher's RPM has no scriptlets, installs only under /usr and is unsigned, so
#      (like OpenSnitch's, which is not verified either) it is trusted only as far as the
#      HTTPS download from the project's release page. If Lutris already pulled in Fedora's
#      own umu-launcher, this newer RPM upgrades it.
RUN --mount=type=bind,from=rpms,source=/,target=/tmp/rpms \
    --mount=type=cache,target=/var/cache/libdnf5,sharing=locked \
    set -euxo pipefail; \
    cd /tmp/rpms; \
    rpm --import windscribe_linux_signing_key.pub; \
    rpmkeys --checksig windscribe_*_amd64_fedora.rpm | tee /dev/stderr | grep -q 'signatures OK'; \
    [ ! -L /opt ] || mkdir -p /var/opt; \
    dnf -y install --setopt=tsflags=noscripts ./opensnitch-[0-9]*.x86_64.rpm; \
    dnf -y install ./opensnitch-ui-*.noarch.rpm ./windscribe_*_amd64_fedora.rpm ./umu-launcher-*.x86_64.rpm; \
    if [ -L /opt ]; then \
        mkdir -p /usr/lib/opt; \
        for d in /var/opt/*; do \
            [ -e "${d}" ] || continue; \
            mv "${d}" /usr/lib/opt/; \
            echo "L+ /var/opt/${d##*/} - - - - /usr/lib/opt/${d##*/}" > "/usr/lib/tmpfiles.d/opt-${d##*/}.conf"; \
        done; \
    fi; \
    test -e /usr/lib/opt/windscribe || test -e /opt/windscribe


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
    bootc container lint
