#!/bin/bash
pkill -9 -f x11vnc
pkill -9 -f Xvfb
pkill pulse
for i in $(pidof startxfce4; pidof xfce4-session; pidof xfconfd; pidof xfce4-panel; pidof xfce4-power-manager; pidof xfdesktop; pidof xfwm4); do
    kill $i;
done
rm -rf /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null
