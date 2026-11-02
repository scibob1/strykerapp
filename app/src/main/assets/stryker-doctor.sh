#!/bin/bash
# stryker-doctor: look for and repair problems with the XFCE desktop in this VM.
#   stryker-doctor           menu (report / repair / reset settings)
#   stryker-doctor report    short health report (also what Stryker writes to its Logs)
#   stryker-doctor test-gui  start the Settings window for a few seconds and show why it fails
#   stryker-doctor prepare   write fallback desktop settings that are missing (runs on every start)
#   stryker-doctor autofix   finish half-installed packages and install missing desktop parts
#   stryker-doctor fix       same as autofix, with a closing message
#   stryker-doctor tune      switch off periodic background jobs (once)
#   stryker-doctor reset     back up and clear XFCE's per-user settings (then restart VNC)

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

UXML=/root/.config/xfce4/xfconf/xfce-perchannel-xml

# What the desktop needs to look and behave normally. The VNC installer used
# --no-install-recommends, so several of these may never have been installed.
CHECK_PKGS="xfce4-session xfce4-panel xfce4-settings xfdesktop4 xfdesktop4-data xfwm4 xfconf thunar thunar-data xfce4-appfinder libgarcon-common shared-mime-info hicolor-icon-theme adwaita-icon-theme librsvg2-common gvfs desktop-file-utils"

# Packages dpkg unpacked but never configured. A package's configuration files (the panel layout,
# the session defaults, the applications menu...) only appear when it is configured, so an install
# that was interrupted - for example while the app was in the background - leaves them missing.
broken_pkgs() {
    dpkg -l 2>/dev/null | awk 'NR>5 && $1 ~ /^.[HUFWt]/ {print $2}'
}

missing_pkgs() {
    local p
    for p in $CHECK_PKGS; do
        dpkg -s "$p" >/dev/null 2>&1 || printf '%s ' "$p"
    done
}

session_env() {
    local pid line
    pid=$(pidof xfce4-session | awk '{print $1}')
    [ -z "$pid" ] && return 1
    export DISPLAY=:1
    while IFS= read -r line; do
        export "$line"
    done < <(tr '\0' '\n' < "/proc/$pid/environ" | grep -E '^(DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|XDG_CONFIG_DIRS|XDG_DATA_DIRS|HOME)=')
    return 0
}

report() {
    local p f up
    up=""
    for p in xfwm4 xfce4-panel xfdesktop xfsettingsd Thunar xfconfd; do
        if pidof "$p" >/dev/null 2>&1; then up="$up $p=up"; else up="$up $p=DOWN"; fi
    done
    echo "processes:$up"
    echo "packages not installed: $(missing_pkgs)"
    echo "packages half-installed (unpacked, not configured): $(broken_pkgs | tr '\n' ' ')"
    for f in /etc/xdg/menus/xfce-applications.menu /etc/xdg/xfce4/panel/default.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml; do
        if [ -e "$f" ]; then echo "file ok: $f"; else echo "file MISSING: $f"; fi
    done
    echo "panel config: $(grep -c 'plugin-ids' "$UXML/xfce4-panel.xml" 2>/dev/null) plugin-ids entries, $(wc -c < "$UXML/xfce4-panel.xml" 2>/dev/null) bytes"
    echo "x11vnc: $(pgrep -a x11vnc 2>/dev/null | cut -c1-230)"
    echo "load: $(cut -d' ' -f1-3 /proc/loadavg), cpus: $(nproc 2>/dev/null)"
    echo "busiest: $(ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | sed -n '2,7p' | awk '{printf "%s%% %s; ", $1, $2}')"
    echo "compositing off: $([ -e /root/.config/stryker-perf-applied ] && echo yes || echo no)"
    echo "repair log: $(tail -n 6 /tmp/xfce-repair.log 2>/dev/null | tr '\n' ' ')"
}

test_gui() {
    session_env || { echo "The desktop session is not running."; return 1; }
    echo "Starting the desktop Settings window for 6 seconds..."
    timeout 6 xfdesktop-settings >/tmp/doctor-xfdesktop-settings.log 2>&1
    echo "xfdesktop-settings exit code $? (124 = it stayed open, so it works)"
    tail -n 8 /tmp/doctor-xfdesktop-settings.log
    echo "thunar --version: $(thunar --version 2>&1 | head -n 1)"
}

prepare() {
    mkdir -p "$UXML"
    # Without any panel layout xfce4-panel shows no bar at all. Use a plain top bar (applications
    # menu, window list, clock, log-out button) when the system has no default and the user's own
    # file is missing or empty. autofix drops this stand-in again once the real default exists.
    if [ ! -e /etc/xdg/xfce4/panel/default.xml ] && [ ! -e /usr/share/xfce4/panel/default.xml ]; then
        if [ ! -s "$UXML/xfce4-panel.xml" ] || ! grep -q 'plugin-ids' "$UXML/xfce4-panel.xml"; then
            [ -s "$UXML/xfce4-panel.xml" ] && mv "$UXML/xfce4-panel.xml" "$UXML/xfce4-panel.xml.bak"
            cat > "$UXML/xfce4-panel.xml" <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="icon-size" type="uint" value="24"/>
      <property name="size" type="uint" value="44"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="grouping" type="uint" value="1"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="clock"/>
    <property name="plugin-5" type="string" value="actions"/>
  </property>
</channel>
EOP
        fi
    fi
    cat > /usr/share/applications/stryker-doctor.desktop <<'EOD'
[Desktop Entry]
Type=Application
Name=Stryker Doctor (repair desktop)
Comment=Check the desktop for problems, install missing parts, reset settings
Exec=stryker-doctor menu
Icon=utilities-system-monitor
Terminal=true
Categories=Utility;
EOD
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null
    return 0
}

autofix() {
    local broken missing p

    broken=$(broken_pkgs | tr '\n' ' ')
    if [ -n "$broken" ]; then
        echo "[fix] finishing half-installed packages: $broken"
        # --force-confnew: the package's own default files win over the stand-ins written by Stryker.
        dpkg --force-confnew --configure -a || echo "[fix] dpkg --configure -a reported errors"
        apt-get install -f -y --no-install-recommends -o Dpkg::Options::=--force-confnew 2>&1 | tail -n 5
        echo "[fix] still half-installed afterwards: $(broken_pkgs | tr '\n' ' ')"
    fi

    missing=$(missing_pkgs)
    if [ -n "$missing" ]; then
        echo "[fix] installing missing packages: $missing"
        if timeout 90 apt-get update >/dev/null 2>&1; then
            if ! timeout 900 apt-get install -y --no-install-recommends \
                -o Dpkg::Options::=--force-confmiss -o Dpkg::Options::=--force-confnew $missing; then
                for p in $missing; do
                    timeout 600 apt-get install -y --no-install-recommends \
                        -o Dpkg::Options::=--force-confmiss -o Dpkg::Options::=--force-confnew "$p" \
                        || echo "[fix] could not install $p"
                done
            fi
        else
            echo "[fix] the package index could not be fetched (no network?)"
        fi
        echo "[fix] still not installed afterwards: $(missing_pkgs)"
    fi

    # Once the real panel layout exists, drop the small stand-in written by prepare so it is used.
    if [ -e /etc/xdg/xfce4/panel/default.xml ] && [ -s "$UXML/xfce4-panel.xml" ] \
        && [ "$(wc -c < "$UXML/xfce4-panel.xml")" -lt 2500 ]; then
        mv "$UXML/xfce4-panel.xml" "$UXML/xfce4-panel.xml.stryker-bak"
        echo "[fix] using the system's panel layout instead of the stand-in"
    fi

    glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1
    gdk-pixbuf-query-loaders --update-cache >/dev/null 2>&1
    update-mime-database /usr/share/mime >/dev/null 2>&1
    echo "[fix] done"
}

fix() {
    autofix
    echo "Finished. Stop and start VNC in Stryker to load everything."
}

# The guest runs systemd timers (daily package-list refresh, man-page index, disk trim...). On an
# emulated CPU they cause bursts of load, and the package refresh also takes the dpkg lock that
# stryker-apps and the repair need. Switch them off once; re-enable with systemctl enable --now.
tune() {
    [ -e /root/.config/stryker-tuned ] && return 0
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        for t in apt-daily.timer apt-daily-upgrade.timer man-db.timer e2scrub_all.timer fstrim.timer dpkg-db-backup.timer; do
            systemctl disable --now "$t" >/dev/null 2>&1
        done
        echo "[tune] periodic background jobs switched off"
    fi
    mkdir -p /root/.config && touch /root/.config/stryker-tuned
    return 0
}

reset_settings() {
    local ts d
    ts=$(date +%s)
    mkdir -p /root/stryker-backup
    for d in /root/.config/xfce4 /root/.config/Thunar /root/.cache/sessions /root/.cache/xfce4 /root/.local/share/xfce4 /root/.config/stryker-perf-applied; do
        [ -e "$d" ] && mv "$d" "/root/stryker-backup/$(basename "$d").$ts" && echo "moved $d"
    done
    echo "Settings reset (old ones are in /root/stryker-backup). Stop and start VNC in Stryker."
}

menu() {
    local ans
    while true; do
        echo
        echo "Stryker Doctor"
        echo " 1) Show a health report"
        echo " 2) Repair the desktop (finish half-installed packages, install missing parts; needs internet)"
        echo " 3) Reset desktop settings (keeps a backup)"
        echo " 4) Try the Settings window and show why it fails"
        echo " q) Quit"
        read -rp "Choice: " ans
        case "$ans" in
            1) report ;;
            2) fix ;;
            3) reset_settings ;;
            4) test_gui ;;
            q|Q) return 0 ;;
        esac
        read -rp "Press Enter to continue..." _
    done
}

case "${1:-menu}" in
    menu)     menu ;;
    report)   report ;;
    test-gui) test_gui ;;
    prepare)  prepare ;;
    autofix)  autofix ;;
    fix)      fix ;;
    tune)     tune ;;
    reset)    reset_settings ;;
    *)        echo "usage: stryker-doctor [menu|report|test-gui|prepare|autofix|fix|tune|reset]"; exit 1 ;;
esac
