#!/bin/bash
# stryker-doctor: look for and repair problems with the XFCE desktop in this VM.
#   stryker-doctor           menu (report / install missing parts / reset settings)
#   stryker-doctor report    short health report (also what Stryker writes to its Logs)
#   stryker-doctor test-gui  start the Settings window for a few seconds and show why it fails
#   stryker-doctor prepare   write fallback desktop settings that are missing (runs on every start)
#   stryker-doctor fix       install missing desktop packages (needs internet)
#   stryker-doctor reset     back up and clear XFCE's per-user settings (then restart VNC)

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

UXML=/root/.config/xfce4/xfconf/xfce-perchannel-xml

# What the desktop needs to look and behave normally. The VNC installer used
# --no-install-recommends, so several of these may never have been installed.
CHECK_PKGS="xfce4-session xfce4-panel xfce4-settings xfdesktop4 xfdesktop4-data xfwm4 xfconf thunar thunar-data xfce4-appfinder libgarcon-common shared-mime-info hicolor-icon-theme adwaita-icon-theme librsvg2-common gvfs desktop-file-utils"

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
    echo "packages not installed: $(for p in $CHECK_PKGS; do dpkg -s "$p" >/dev/null 2>&1 || printf '%s ' "$p"; done)"
    for f in /etc/xdg/menus/xfce-applications.menu /etc/xdg/xfce4/panel/default.xml /usr/share/xfce4/panel/default.xml /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml; do
        if [ -e "$f" ]; then echo "file ok: $f"; else echo "file MISSING: $f"; fi
    done
    echo "user settings: $(ls "$UXML" 2>/dev/null | tr '\n' ' ')"
    echo "dpkg path-exclude rules: $(grep -rhs '^path-exclude' /etc/dpkg/dpkg.cfg /etc/dpkg/dpkg.cfg.d 2>/dev/null | head -n 6 | tr '\n' ';')"
    echo "dpkg audit: $(dpkg --audit 2>&1 | head -n 4 | tr '\n' ' ')"
    echo "repair log: $(tail -n 4 /tmp/xfce-repair.log 2>/dev/null | tr '\n' ' ')"
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
    # file is missing or empty.
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

fix() {
    local missing p
    missing=""
    for p in $CHECK_PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
    if [ -z "$missing" ]; then
        echo "All desktop packages are installed."
        return 0
    fi
    echo "Installing:$missing"
    apt-get update || echo "!! apt-get update failed - is the phone online?"
    if ! apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confmiss $missing; then
        echo "Retrying one package at a time..."
        for p in $missing; do
            apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confmiss "$p" || echo "!! could not install $p"
        done
    fi
    gdk-pixbuf-query-loaders --update-cache >/dev/null 2>&1
    update-mime-database /usr/share/mime >/dev/null 2>&1
    echo "Finished. Stop and start VNC in Stryker to load everything."
}

reset_settings() {
    local ts d
    ts=$(date +%s)
    mkdir -p /root/stryker-backup
    for d in /root/.config/xfce4 /root/.config/Thunar /root/.cache/sessions /root/.cache/xfce4 /root/.local/share/xfce4; do
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
        echo " 2) Install missing desktop parts (needs internet)"
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
    fix)      fix ;;
    reset)    reset_settings ;;
    *)        echo "usage: stryker-doctor [menu|report|test-gui|prepare|fix|reset]"; exit 1 ;;
esac
