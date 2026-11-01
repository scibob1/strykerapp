package com.zalexdev.stryker.engine;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.provider.Settings;
import android.widget.Toast;

import java.util.HashSet;
import java.util.Set;

/**
 * Keeps the app's process (and with it the QEMU child process, which Android kills together with
 * the app) from being stopped or throttled while the VM or the VNC server is in use.
 *
 * A foreground service alone is not enough on vendor ROMs such as HarmonyOS / EMUI: they freeze or
 * throttle a backgrounded app unless it holds a wake lock and the user has exempted it from battery
 * optimisation. The wake lock and a Wi-Fi lock are taken here; the exemption is a system setting
 * only the user can grant, so {@link #askOnce} asks for it. {@link #tick} lets a periodic task
 * notice when the whole process was suspended.
 */
public final class KeepAlive {

    private static final long LOCK_MS = 6L * 60L * 60L * 1000L;
    private static final String PREF_ASKED = "keepalive_asked_v2";

    private static final Set<String> owners = new HashSet<>();
    private static PowerManager.WakeLock lock;
    private static WifiManager.WifiLock wifiLock;
    private static long lastTick = 0L;

    private KeepAlive() {}

    /** Takes (or refreshes) the wake lock and Wi-Fi lock on behalf of {@code owner}, e.g. "vm" or "vnc". */
    public static synchronized void acquire(Context ctx, String owner) {
        Context app = ctx.getApplicationContext();
        owners.add(owner);
        try {
            if (lock == null) {
                PowerManager pm = (PowerManager) app.getSystemService(Context.POWER_SERVICE);
                if (pm != null) {
                    lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "stryker:guest");
                    lock.setReferenceCounted(false);
                }
            }
            if (lock != null && !lock.isHeld()) lock.acquire(LOCK_MS);
        } catch (Throwable ignored) {
        }
        try {
            if (wifiLock == null) {
                WifiManager wm = (WifiManager) app.getSystemService(Context.WIFI_SERVICE);
                if (wm != null) {
                    int mode = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                            ? WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                            : WifiManager.WIFI_MODE_FULL_HIGH_PERF;
                    wifiLock = wm.createWifiLock(mode, "stryker:guest");
                    wifiLock.setReferenceCounted(false);
                }
            }
            if (wifiLock != null && !wifiLock.isHeld()) wifiLock.acquire();
        } catch (Throwable ignored) {
        }
    }

    /** Drops {@code owner}'s claim; the locks go once nobody needs them. */
    public static synchronized void release(String owner) {
        owners.remove(owner);
        if (!owners.isEmpty()) return;
        try {
            if (lock != null && lock.isHeld()) lock.release();
        } catch (Throwable ignored) {
        }
        try {
            if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
        } catch (Throwable ignored) {
        }
    }

    /**
     * Call from a task that runs on a fixed period. Returns how many milliseconds passed since the
     * previous call (0 on the first), measured on a clock that keeps counting while the device
     * sleeps. A value far above the period means the process was suspended by the system.
     */
    public static synchronized long tick() {
        long now = SystemClock.elapsedRealtime();
        long gap = lastTick == 0L ? 0L : now - lastTick;
        lastTick = now;
        return gap;
    }

    public static synchronized void resetTicks() {
        lastTick = 0L;
    }

    public static boolean batteryExempt(Context ctx) {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            return pm != null && pm.isIgnoringBatteryOptimizations(ctx.getPackageName());
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Once per install, if the app is not exempt: tells the user what to switch on and asks the
     * system to exempt the app from battery optimisation (falling back to the optimisation list
     * and then the app's own settings page).
     */
    public static void askOnce(com.zalexdev.stryker.utils.Core core, Context ctx) {
        try {
            if (batteryExempt(ctx) || core.getBoolean(PREF_ASKED)) return;
            core.putBoolean(PREF_ASKED, true);
            new Handler(Looper.getMainLooper()).post(() -> {
                try {
                    Toast.makeText(ctx.getApplicationContext(),
                            "To keep the VM and VNC running while Stryker is in the background: "
                                    + "allow background activity / unrestricted battery use for "
                                    + "Stryker, and lock it in the recent-apps screen.\n"
                                    + "要让 Stryker 切到后台后虚拟机和 VNC 继续运行：请允许后台活动、"
                                    + "电池不受限制，并在多任务界面锁定本应用。",
                            Toast.LENGTH_LONG).show();
                } catch (Throwable ignored) {
                }
            });
            Intent direct = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:" + ctx.getPackageName()))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                ctx.startActivity(direct);
                return;
            } catch (ActivityNotFoundException | SecurityException ignored) {
            }
            Intent list = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                ctx.startActivity(list);
            } catch (ActivityNotFoundException | SecurityException e) {
                Intent details = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:" + ctx.getPackageName()))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                ctx.startActivity(details);
            }
        } catch (Throwable ignored) {
        }
    }
}
