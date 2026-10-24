package com.zalexdev.stryker.vnc;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import com.zalexdev.stryker.MainActivity;
import com.zalexdev.stryker.R;
import com.zalexdev.stryker.engine.GuestEngine;
import com.zalexdev.stryker.engine.GuestSsh;
import com.zalexdev.stryker.engine.QmpClient;
import com.zalexdev.stryker.engine.RootlessEngine;
import com.zalexdev.stryker.utils.Core;
import com.zalexdev.stryker.utils.Utils;

import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Timer;
import java.util.TimerTask;

public class VNCService extends Service {
    private final String CHANNEL_ID = "VNCChannel";
    public static final String ACTION_START = "com.zalexdev.stryker.vnc.action.START";
    public static final String ACTION_STOP = "com.zalexdev.stryker.vnc.action.STOP";
    public static final String EXTRA_RESOLUTION = "com.zalexdev.stryker.vnc.extra.resolution";
    public static final String EXTRA_PORT = "com.zalexdev.stryker.vnc.extra.port";

    private static final String LOOPBACK = "127.0.0.1";
    private static final String NETDEV_ID = "net0";

    private Timer timer = new Timer();
    private String port = "";
    private Process vnc = null;
    private Core core = null;
    private NotificationCompat.Builder notification;
    private volatile boolean stopped = false;

    @Override
    public void onCreate() {
        core = new Core(this);
        super.onCreate();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent.getAction();

        createNotificationChannel();
        Intent notificationPendingIntent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(this, 0, notificationPendingIntent, Utils.setPendingIntentFlag());

        notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("VNC Server")
                .setContentText("Running command. Waiting for connection...")
                .setSmallIcon(R.drawable.vnc)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setContentIntent(pendingIntent);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(33, notification.build(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(33, notification.build());
        }
        if (action != null) {
            if (action.equals(ACTION_START)) {
                stopped = false;
                port = intent.getStringExtra(EXTRA_PORT);
                final String param1 = intent.getStringExtra(EXTRA_RESOLUTION);
                final String param2 = intent.getStringExtra(EXTRA_PORT);
                new Thread(() -> {
                    if (!isVNCStarted()) startVNC(param1, param2);
                    else ensureForward(parsePort(param2), true);
                    watchUntilReachable(parsePort(param2));
                }, "stryker-vnc-start").start();
                try {
                    Thread.sleep(5);
                } catch (InterruptedException e) {
                    e.printStackTrace();
                }
                timer.cancel();
                timer = new Timer();
                timer.scheduleAtFixedRate(new TimerTask() {
                    @Override
                    public void run() {
                        checkVNC();
                    }
                }, 0, 10000);
            } else if (action.equals(ACTION_STOP)) {
                new Thread(() -> {
                    try {
                        stopVNC();
                    } catch (IOException e) {
                        e.printStackTrace();
                    }
                }).start();
            }
        }
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel serviceChannel = new NotificationChannel(
                    CHANNEL_ID,
                    "VNCServiceChannel",
                    NotificationManager.IMPORTANCE_DEFAULT
            );

            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.createNotificationChannel(serviceChannel);
        }
    }

    public void startVNC(String resolution, String port) {
        Intent intent = new Intent();
        intent.setAction(ACTION_START);
        intent.addCategory(Intent.CATEGORY_DEFAULT);
        intent.setPackage(getPackageName());
        sendBroadcast(intent);

        core.customChrootCommand("mkdir -p /tmp; setsid nohup vncserver-start -p " + port
                + " -r " + resolution + " > /tmp/vncserver-start.log 2>&1 < /dev/null &");
        openPortForward(port);
    }

    private void openPortForward(String value) {
        ensureForward(parsePort(value), true);
    }

    /**
     * Makes 127.0.0.1:p on the phone lead to port p of the guest, so another VNC app on the
     * phone can connect to "localhost:p".
     *
     * The old code asked QEMU for the forward and believed the answer. QEMU's monitor reports a
     * refused hostfwd_add as plain text inside a successful QMP reply, so a failed forward was
     * logged as "forwarded" and nothing ever listened on the phone. Here the monitor's text is
     * read, the result is checked by looking at the loopback port itself, and if QEMU cannot do it
     * the forward is made through the app's own ssh session to the guest instead.
     *
     * @param force true to (re)create the forward even if something already holds the port
     */
    private boolean ensureForward(int p, boolean force) {
        if (!core.isRootless() || p <= 0) return false;
        if (!force && loopbackPortHeld(p)) return true;

        GuestEngine guest = core.guest();
        String why = "";

        if (guest instanceof RootlessEngine) {
            QmpClient qmp = ((RootlessEngine) guest).qmp();
            if (qmp == null || !qmp.isConnected()) {
                why = "the VM's QMP control channel is not connected";
            } else {
                String host = "tcp:" + LOOPBACK + ":" + p;
                qmp.hostfwdRemove(NETDEV_ID + " " + host);
                String reply = qmp.hostfwdAddReply(NETDEV_ID + " " + host + "-:" + p);
                if (reply == null) {
                    why = "QEMU gave no answer to hostfwd_add";
                } else if (reply.isEmpty()) {
                    core.logger.writeLine("VNC port " + p + " forwarded out of "
                            + guest.displayName() + " (QEMU hostfwd)", 2);
                    return true;
                } else {
                    why = "QEMU refused hostfwd_add: " + reply;
                }
            }
        } else {
            guest.forwardPort(p, p);
            if (loopbackPortHeld(p)) {
                core.logger.writeLine("VNC port " + p + " forwarded out of "
                        + guest.displayName(), 2);
                return true;
            }
            why = guest.displayName() + " did not open the forward";
        }

        core.logger.writeLine("VNC port " + p + ": " + why + " - trying an ssh tunnel into the guest", 1);
        boolean ssh = GuestSsh.forwardLocalPort(p, p);
        if (ssh) {
            core.logger.writeLine("VNC port " + p + " forwarded out of " + guest.displayName()
                    + " (ssh tunnel)", 2);
            return true;
        }
        core.logger.writeLine("VNC port " + p + " could not be forwarded: " + why
                + "; the ssh tunnel failed as well. If another app already listens on "
                + LOOPBACK + ":" + p + " pick a different port in the VNC tab.", 3);
        return false;
    }

    private void closePortForward(String value) {
        if (!core.isRootless()) return;
        int p = parsePort(value);
        if (p <= 0) return;
        core.guest().unforwardPort(p);
        GuestSsh.unforwardLocalPort(p);
    }

    /** After a start: wait until a VNC client could really connect, and say why if it never can. */
    private void watchUntilReachable(int p) {
        if (!core.isRootless() || p <= 0) return;
        for (int i = 0; i < 45 && !stopped; i++) {
            if (rfbAnswers(p)) {
                core.logger.writeLine("VNC server answers on " + LOOPBACK + ":" + p
                        + " - connect your VNC app to localhost:" + p, 2);
                return;
            }
            if (i % 4 == 3) ensureForward(p, false);
            try {
                Thread.sleep(3000);
            } catch (InterruptedException e) {
                return;
            }
        }
        if (stopped) return;
        StringBuilder sb = new StringBuilder();
        sb.append(loopbackPortHeld(p)
                ? "Port " + p + " is open on the phone but x11vnc in the guest does not answer."
                : "Nothing listens on " + LOOPBACK + ":" + p + " on the phone.");
        try {
            ArrayList<String> out = core.customChrootCommand(
                    "ss -ltn 2>/dev/null | grep ':" + p + " ' ; "
                            + "echo '--- x11vnc.log'; tail -n 8 /tmp/x11vnc.log 2>&1; "
                            + "echo '--- vncserver-start.log'; tail -n 8 /tmp/vncserver-start.log 2>&1", true);
            for (String l : out) {
                if (l != null && !l.trim().isEmpty()) sb.append(" | ").append(l.trim());
            }
        } catch (Throwable ignored) {
        }
        core.logger.writeLine(sb.toString(), 3);
    }

    private static int parsePort(String value) {
        try {
            int p = Integer.parseInt(value == null ? "" : value.trim());
            return p > 0 && p < 65536 ? p : -1;
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** True when something already listens on 127.0.0.1:p (we cannot bind it ourselves). */
    private static boolean loopbackPortHeld(int p) {
        try (ServerSocket ss = new ServerSocket()) {
            ss.setReuseAddress(false);
            ss.bind(new InetSocketAddress(InetAddress.getByName(LOOPBACK), p), 1);
            return false;
        } catch (IOException e) {
            return true;
        }
    }

    /** True when 127.0.0.1:p answers with an RFB banner, i.e. a VNC client can talk to it. */
    private static boolean rfbAnswers(int p) {
        try (Socket s = new Socket()) {
            s.connect(new InetSocketAddress(LOOPBACK, p), 2000);
            s.setSoTimeout(3000);
            InputStream in = s.getInputStream();
            byte[] b = new byte[12];
            int n = 0;
            while (n < b.length) {
                int r = in.read(b, n, b.length - n);
                if (r < 0) break;
                n += r;
            }
            return n >= 4 && "RFB ".equals(new String(b, 0, 4, StandardCharsets.US_ASCII));
        } catch (IOException e) {
            return false;
        }
    }

    public void stopVNC() throws IOException {
        stopped = true;
        if (vnc != null) {
            vnc.destroy();
        }

        Intent intent = new Intent();
        intent.setAction(ACTION_STOP);
        intent.addCategory(Intent.CATEGORY_DEFAULT);
        intent.setPackage(getPackageName());
        sendBroadcast(intent);

        vnc = null;
        core.customChrootCommand("vncserver-stop");
        closePortForward(port);

        timer.cancel();
        stopForeground(false);
        stopSelf();
    }

    private boolean isVNCStarted() {
        java.util.ArrayList<String> out = core.customChrootCommand("pidof Xvfb", true);
        for (String l : out) {
            if (l == null) continue;
            String t = l.trim();
            if (!t.isEmpty() && t.matches("[0-9 ]+")) return true;
        }
        return false;
    }

    public void checkVNC() {
        if (isVNCStarted()) {
            int p = parsePort(port);
            if (p > 0 && core.isRootless() && !loopbackPortHeld(p)) ensureForward(p, false);
            notification.setContentText("Running VNC Server on localhost:" + port);
            notification.build();
            NotificationManager mNotificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            mNotificationManager.notify(33, notification.build());
        }
    }
}
