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
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

mkdir -p $XDG_RUNTIME_DIR && chmod 700 $XDG_RUNTIME_DIR
mkdir -p $XDG_CONFIG_HOME $XDG_CACHE_HOME $XDG_DATA_HOME

rm -rf /tmp/.X1-lock /tmp/.X11-unix/X1 /tmp/dbus-* 2>/dev/null
pkill -9 -f 'Xvfb :1' 2>/dev/null
pkill -9 -f 'xfce4-session' 2>/dev/null
pkill -9 -f 'x11vnc.*-rfbport' 2>/dev/null
pkill -9 xfwm4 xfdesktop xfce4-panel xfconfd xfsettingsd 2>/dev/null
sleep 1

mkdir -p /var/run/dbus
[ ! -s /etc/machine-id ] && dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null
[ -z "$(pidof dbus-daemon)" ] && dbus-daemon --system --fork

rm -rf /root/.cache/sessions /root/.cache/xfce4 2>/dev/null

/usr/bin/Xvfb $DISPLAY -screen 0 $RESOLUTION -ac +extension GLX +render -noreset 2>/tmp/xvfb.log &
sleep 2

xset -display $DISPLAY s off s noblank 2>/dev/null
xset -display $DISPLAY -dpms 2>/dev/null

dbus-run-session -- xfce4-session >/tmp/xfce.log 2>&1 &
sleep 5

x11vnc -xkb -noxrecord -noxfixes -noxdamage -display $DISPLAY -forever -bg \
    -rfbauth /root/.vnc/passwd -users root -rfbport $PORT -noshm 2>/tmp/x11vnc.log
echo "[!] VNC server started at: localhost:$PORT"
echo "[!] If you see a dark screen with an X cursor: cat /tmp/xfce.log"
