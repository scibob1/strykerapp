#!/bin/bash

function usage () {
    echo "Stryker VNC setup helper <<"
    echo ""
    echo "Usage: vncserver-start"
    echo "-p|--port Setup port for VNC"
    echo "-r|--resolution Setup resolution for VNC"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            PORT="$2"
            shift
            shift
        ;;
        -r|--resolution)
            RESOLUTION="$2"
            shift
            shift
        ;;
        --pulse)
            PULSE_PORT="$2"
            shift
            shift
        ;;
        *) break
    esac
done

if [ -z "$PORT" ]; then
    usage
fi
if [ -z "$RESOLUTION" ]; then
    usage
fi

if [ -n "$PULSE_PORT" ]; then
    export PULSE_SERVER=tcp:0.0.0.0:$PULSE_PORT
fi

unset DBUS_SESSION_BUS_ADDRESS XAUTHORITY ICEAUTHORITY SESSION_MANAGER
unset ANDROID_ROOT ANDROID_DATA ANDROID_STORAGE EXTERNAL_STORAGE
unset GTK_PATH GIO_LAUNCHED_DESKTOP_FILE_PID GIO_LAUNCHED_DESKTOP_FILE
unset DESKTOP_SESSION GNOME_KEYRING_CONTROL TMPDIR TEMP TMP

export DISPLAY=:1
export HOME=/root
export USER=root
export LOGNAME=root
export XDG_RUNTIME_DIR=/tmp/runtime-root
export XDG_CONFIG_HOME=/root/.config
export XDG_CACHE_HOME=/root/.cache
export XDG_DATA_HOME=/root/.local/share
export XDG_CONFIG_DIRS=/etc/xdg
export XDG_DATA_DIRS=/usr/local/share:/usr/share
export XDG_SESSION_TYPE=x11
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- performance: this VM has no GPU and its CPU is emulated -------------------------------
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
# llvmpipe starts one rasteriser thread per CPU; on an emulated 8-core CPU that costs more than it gains.
export LP_NUM_THREADS=2
# Do not look for the accessibility bus (every GTK app otherwise tries, and logs a warning).
export NO_AT_BRIDGE=1
# Browsers: skip GPU compositing paths, which only run slowly on llvmpipe.
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
# WebKit's own sandbox needs kernel features this VM may lack; the VM itself is the sandbox.
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export MOZ_WEBRENDER=0

mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR
mkdir -p $XDG_CONFIG_HOME $XDG_CACHE_HOME $XDG_DATA_HOME

rm -rf /tmp/.X1-lock /tmp/.X11-unix/X1 /tmp/dbus-* 2>/dev/null
pkill -9 -f 'Xvfb :1' 2>/dev/null
pkill -9 -f 'xfce4-session' 2>/dev/null
pkill -9 -f 'xfce-session.sh' 2>/dev/null
pkill -9 -f 'dbus-run-session' 2>/dev/null
pkill -9 -f 'x11vnc.*-rfbport' 2>/dev/null
pkill -9 xfwm4 xfdesktop xfce4-panel xfconfd xfsettingsd 2>/dev/null
sleep 1

mkdir -p /var/run/dbus
[ ! -s /etc/machine-id ] && dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null
[ -z "$(pidof dbus-daemon)" ] && dbus-daemon --system --fork

rm -rf /root/.cache/sessions /root/.cache/xfce4 2>/dev/null

# ---------------------------------------------------------------------------------------------
# Why the desktop lacked its panel, menus and default settings: the XFCE packages in this guest
# were unpacked but never configured (the install was interrupted, e.g. while the app was in the
# background). dpkg only puts a package's configuration files in place when it configures it.
# stryker-doctor finishes that and installs what is missing. Progress: /tmp/xfce-repair.log
# Healthy guests pay only a few seconds. Keep Stryker visible while this runs.
# ---------------------------------------------------------------------------------------------
echo "[repair] checking the desktop packages" > /tmp/xfce-repair.log
if command -v stryker-doctor >/dev/null 2>&1; then
    stryker-doctor autofix >> /tmp/xfce-repair.log 2>&1
    stryker-doctor tune >> /tmp/xfce-repair.log 2>&1
fi

# Fallbacks for when the packages could not provide these (for example no network).
# xfce4-session asks xfconf for /general/FailsafeSessionName; without this file it shows
# "Unable to load a failsafe session" and quits.
XFSD=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
if [ ! -s "$XFSD/xfce4-session.xml" ]; then
    mkdir -p "$XFSD"
    cat > "$XFSD/xfce4-session.xml" <<'EOX'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-session" version="1.0">
  <property name="splash" type="empty">
    <property name="Engine" type="string" value=""/>
  </property>
  <property name="general" type="empty">
    <property name="FailsafeSessionName" type="string" value="Failsafe"/>
  </property>
  <property name="sessions" type="empty">
    <property name="Failsafe" type="empty">
      <property name="IsFailsafe" type="bool" value="true"/>
      <property name="Count" type="int" value="4"/>
      <property name="Client0_Command" type="array">
        <value type="string" value="xfwm4"/>
      </property>
      <property name="Client0_Priority" type="int" value="15"/>
      <property name="Client0_PerScreen" type="bool" value="false"/>
      <property name="Client1_Command" type="array">
        <value type="string" value="xfsettingsd"/>
      </property>
      <property name="Client1_Priority" type="int" value="20"/>
      <property name="Client1_PerScreen" type="bool" value="false"/>
      <property name="Client2_Command" type="array">
        <value type="string" value="xfce4-panel"/>
      </property>
      <property name="Client2_Priority" type="int" value="25"/>
      <property name="Client2_PerScreen" type="bool" value="false"/>
      <property name="Client3_Command" type="array">
        <value type="string" value="xfdesktop"/>
      </property>
      <property name="Client3_Priority" type="int" value="35"/>
      <property name="Client3_PerScreen" type="bool" value="false"/>
    </property>
  </property>
</channel>
EOX
fi

# Plain applications menu so the panel's menu opens ("Failed to load the applications menu:
# File 'menus/xfce-applications.menu' not found"). Lists every installed application by category.
if [ ! -s /etc/xdg/menus/xfce-applications.menu ]; then
    mkdir -p /etc/xdg/menus
    cat > /etc/xdg/menus/xfce-applications.menu <<'EOM'
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN" "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
<Menu>
  <Name>Xfce</Name>
  <DefaultAppDirs/>
  <DefaultDirectoryDirs/>
  <DefaultMergeDirs/>
  <Menu><Name>Accessories</Name><Include><Category>Utility</Category></Include></Menu>
  <Menu><Name>Development</Name><Include><Category>Development</Category></Include></Menu>
  <Menu><Name>Education</Name><Include><Category>Education</Category></Include></Menu>
  <Menu><Name>Games</Name><Include><Category>Game</Category></Include></Menu>
  <Menu><Name>Graphics</Name><Include><Category>Graphics</Category></Include></Menu>
  <Menu><Name>Internet</Name><Include><Category>Network</Category></Include></Menu>
  <Menu><Name>Multimedia</Name><Include><Category>AudioVideo</Category></Include></Menu>
  <Menu><Name>Office</Name><Include><Category>Office</Category></Include></Menu>
  <Menu><Name>Settings</Name><Include><Category>Settings</Category></Include></Menu>
  <Menu><Name>System</Name><Include><Category>System</Category></Include></Menu>
</Menu>
EOM
fi

/usr/bin/Xvfb $DISPLAY -screen 0 $RESOLUTION -ac +extension GLX +render -noreset -nolisten tcp 2>/tmp/xvfb.log &
sleep 2

xset -display $DISPLAY s off s noblank 2>/dev/null
xset -display $DISPLAY -dpms 2>/dev/null

# Start xfconfd ourselves inside the session bus, wait until it answers, and only then start the
# session. Everything it saw is written to /tmp/xfce.log.
cat > /tmp/xfce-session.sh <<'EOS'
#!/bin/bash
XFCONFD=$(ls /usr/lib/*/xfce4/xfconf/xfconfd /usr/lib/xfce4/xfconf/xfconfd 2>/dev/null | head -n 1)
echo "[session] bus=$DBUS_SESSION_BUS_ADDRESS xfconfd=${XFCONFD:-not found}"
echo "[session] XDG_CONFIG_DIRS=$XDG_CONFIG_DIRS"
if [ -n "$XFCONFD" ]; then
    "$XFCONFD" >/tmp/xfconfd.log 2>&1 &
fi
ready=0
for i in $(seq 1 60); do
    if xfconf-query -c xfce4-session -l >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
echo "[session] xfconf answers: $ready (waited ${i}s)"

# Once: switch off the window manager's compositing, shadows and animations. Each one costs a lot
# of CPU on a VM without a GPU and makes every window move redraw the whole screen. Delete
# /root/.config/stryker-perf-applied to have it applied again; change them in Settings > Window
# Manager Tweaks if you want them back.
if [ "$ready" = 1 ] && [ ! -e /root/.config/stryker-perf-applied ]; then
    xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false
    xfconf-query -c xfwm4 -p /general/show_dock_shadow -n -t bool -s false
    xfconf-query -c xfwm4 -p /general/show_frame_shadow -n -t bool -s false
    xfconf-query -c xfwm4 -p /general/show_popup_shadow -n -t bool -s false
    xfconf-query -c xfwm4 -p /general/zoom_desktop -n -t bool -s false
    xfconf-query -c xsettings -p /Gtk/EnableAnimations -n -t bool -s false
    touch /root/.config/stryker-perf-applied
    echo "[session] performance settings applied"
fi
exec xfce4-session
EOS
chmod 755 /tmp/xfce-session.sh
dbus-run-session -- /tmp/xfce-session.sh >/tmp/xfce.log 2>&1 &
sleep 5

# x11vnc. The previous flags (-noxdamage -noshm) made it re-read the whole screen on a timer and
# copy every frame through a socket, which is what made the picture lag and the VM busy even when
# nothing moved. Now it waits for the X server's change notifications (XDAMAGE) and reads frames
# through shared memory. If it cannot start that way it falls back to the old, slower flags.
# Extra x11vnc options can be put, on one line, in /root/.vnc/x11vnc.extra
EXTRA=""
[ -s /root/.vnc/x11vnc.extra ] && EXTRA=$(head -n 1 /root/.vnc/x11vnc.extra)
x11vnc -display $DISPLAY -forever -shared -bg -rfbauth /root/.vnc/passwd -users root -rfbport $PORT \
    -xkb -noxrecord -noxfixes -xdamage -wait 10 -defer 10 $EXTRA 2>/tmp/x11vnc.log
sleep 3
if ! pidof x11vnc >/dev/null 2>&1; then
    echo "[!] x11vnc did not start with the fast settings - retrying with the safe ones" >> /tmp/x11vnc.log
    x11vnc -xkb -noxrecord -noxfixes -noxdamage -display $DISPLAY -forever -shared -bg \
        -rfbauth /root/.vnc/passwd -users root -rfbport $PORT -noshm 2>>/tmp/x11vnc.log
fi
echo "[!] VNC server started at: localhost:$PORT"
echo "[!] If you see a dark screen with an X cursor: cat /tmp/xfce.log"
