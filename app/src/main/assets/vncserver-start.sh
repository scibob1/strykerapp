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
pkill -9 -f 'xfce-session.sh' 2>/dev/null
pkill -9 -f 'dbus-run-session' 2>/dev/null
pkill -9 -f 'x11vnc.*-rfbport' 2>/dev/null
pkill -9 xfwm4 xfdesktop xfce4-panel xfconfd xfsettingsd 2>/dev/null
sleep 1

mkdir -p /var/run/dbus
[ ! -s /etc/machine-id ] && dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null
[ -z "$(pidof dbus-daemon)" ] && dbus-daemon --system --fork

rm -rf /root/.cache/sessions /root/.cache/xfce4 2>/dev/null

# xfce4-session asks xfconf for /general/FailsafeSessionName. That default lives in
# /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml, which this guest image does not
# have, so xfce4-session shows "Unable to load a failsafe session" and quits. Provide the stock
# default when it is missing.
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

/usr/bin/Xvfb $DISPLAY -screen 0 $RESOLUTION -ac +extension GLX +render -noreset 2>/tmp/xvfb.log &
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
ls -l /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/ 2>&1 | head -n 12
echo "[session] xfce4-session package files:"
dpkg -L xfce4-session 2>/dev/null | grep -E '/etc/|xfconf|\.xml$' | head -n 8
if [ -n "$XFCONFD" ]; then
    "$XFCONFD" >/tmp/xfconfd.log 2>&1 &
fi
ready=0
for i in $(seq 1 60); do
    if xfconf-query -c xfce4-session -l >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
echo "[session] xfconf answers: $ready (waited ${i}s)"
xfconf-query -c xfce4-session -p /general/FailsafeSessionName 2>&1
exec xfce4-session
EOS
chmod 755 /tmp/xfce-session.sh
dbus-run-session -- /tmp/xfce-session.sh >/tmp/xfce.log 2>&1 &
sleep 5

x11vnc -xkb -noxrecord -noxfixes -noxdamage -display $DISPLAY -forever -bg \
    -rfbauth /root/.vnc/passwd -users root -rfbport $PORT -noshm 2>/tmp/x11vnc.log
echo "[!] VNC server started at: localhost:$PORT"
echo "[!] If you see a dark screen with an X cursor: cat /tmp/xfce.log"
