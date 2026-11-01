#!/bin/bash
# Stryker app installer for the Linux guest.
#   stryker-apps            interactive menu
#   stryker-apps list       show bundles
#   stryker-apps install archive fonts browser ...
#   stryker-apps register   add "Stryker Apps" to the desktop menu

export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BUNDLES="archive fonts browser editor viewer pdf media screenshot dev office"
RECOMMENDED="archive fonts browser editor viewer pdf screenshot"

pkgs_for() {
    case "$1" in
        archive)    echo "xarchiver thunar-archive-plugin unzip zip unrar-free 7zip" ;;
        fonts)      echo "fonts-noto-cjk fonts-wqy-microhei fonts-noto-color-emoji" ;;
        browser)    echo "firefox-esr" ;;
        editor)     echo "mousepad" ;;
        viewer)     echo "ristretto" ;;
        pdf)        echo "atril" ;;
        media)      echo "mpv" ;;
        screenshot) echo "xfce4-screenshooter xfce4-taskmanager" ;;
        dev)        echo "git curl wget nano vim python3 python3-pip build-essential htop" ;;
        office)     echo "libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-gtk3" ;;
        *)          return 1 ;;
    esac
}

desc_for() {
    case "$1" in
        archive)    echo "Open and create zip / rar / 7z / tar files (double-click and right-click Extract)" ;;
        fonts)      echo "Chinese, Japanese, Korean and emoji fonts (fixes square boxes instead of text)" ;;
        browser)    echo "Firefox web browser" ;;
        editor)     echo "Mousepad text editor" ;;
        viewer)     echo "Ristretto image viewer" ;;
        pdf)        echo "Atril PDF viewer" ;;
        media)      echo "mpv video and audio player (slow on this emulated CPU)" ;;
        screenshot) echo "Screenshot tool and task manager" ;;
        dev)        echo "git, curl, wget, nano, vim, python3 + pip, compiler, htop" ;;
        office)     echo "LibreOffice Writer / Calc / Impress (large download, slow to start)" ;;
    esac
}

is_installed() {
    local first
    first=$(pkgs_for "$1" | awk '{print $1}')
    dpkg -s "$first" >/dev/null 2>&1
}

INDEX_DONE=""
refresh_index() {
    [ -n "$INDEX_DONE" ] && return 0
    echo "==> Updating the package list (needs internet)"
    apt-get update || echo "!! apt-get update failed - is the phone online?"
    INDEX_DONE=1
}

post_install() {
    case "$1" in
        archive)
            command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null
            if command -v xdg-mime >/dev/null 2>&1; then
                xdg-mime default xarchiver.desktop application/zip application/x-7z-compressed \
                    application/x-rar application/vnd.rar application/x-tar application/gzip \
                    application/x-xz application/x-bzip2 application/x-compressed-tar \
                    application/x-bzip-compressed-tar application/x-xz-compressed-tar 2>/dev/null
            fi
            # Thunar loads its plugins at start: quit it so the next window has "Extract Here".
            thunar -q 2>/dev/null
            echo "    zip files now open with Xarchiver; right-click a file for Extract Here."
            ;;
        fonts)
            fc-cache -f >/dev/null 2>&1
            echo "    Restart running programs to see the new fonts."
            ;;
    esac
}

install_bundle() {
    local name="$1" pk p
    pk=$(pkgs_for "$name") || { echo "Unknown bundle: $name"; return 1; }
    refresh_index
    echo "==> $name: $pk"
    if ! apt-get install -y --no-install-recommends $pk; then
        echo "    Retrying one package at a time..."
        for p in $pk; do
            apt-get install -y --no-install-recommends "$p" || echo "!! could not install $p"
        done
    fi
    post_install "$name"
}

list_bundles() {
    local b mark
    for b in $BUNDLES; do
        if is_installed "$b"; then mark="[x]"; else mark="[ ]"; fi
        printf "%s %-11s %s\n" "$mark" "$b" "$(desc_for "$b")"
    done
}

register() {
    cat > /usr/share/applications/stryker-apps.desktop <<'EOD'
[Desktop Entry]
Type=Application
Name=Stryker Apps (install software)
Comment=Install common applications such as an archive manager, browser and fonts
Exec=stryker-apps menu
Icon=system-software-install
Terminal=true
Categories=Utility;
EOD
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null
}

menu() {
    local i b ans sel
    while true; do
        echo
        echo "Stryker Apps - install software into this Linux VM (needs internet)"
        echo
        i=1
        for b in $BUNDLES; do
            if is_installed "$b"; then mark="[x]"; else mark="[ ]"; fi
            printf "%2d) %s %-11s %s\n" "$i" "$mark" "$b" "$(desc_for "$b")"
            i=$((i + 1))
        done
        echo " a) install the recommended set: $RECOMMENDED"
        echo " q) quit"
        echo
        read -rp "Numbers to install (e.g. 1 2 3): " ans
        [ -z "$ans" ] && continue
        case "$ans" in
            q|Q) return 0 ;;
            a|A) for b in $RECOMMENDED; do install_bundle "$b"; done ;;
            *)
                for sel in $ans; do
                    b=$(echo $BUNDLES | tr ' ' '\n' | sed -n "${sel}p" 2>/dev/null)
                    [ -n "$b" ] && install_bundle "$b" || echo "Not a valid choice: $sel"
                done
                ;;
        esac
        echo
        read -rp "Done. Press Enter to continue..." _
    done
}

case "${1:-menu}" in
    menu)     menu ;;
    list)     list_bundles ;;
    install)  shift; [ $# -eq 0 ] && { echo "usage: stryker-apps install NAME..."; exit 1; }; for b in "$@"; do install_bundle "$b"; done ;;
    register) register ;;
    *)        echo "usage: stryker-apps [menu|list|install NAME...|register]"; exit 1 ;;
esac
