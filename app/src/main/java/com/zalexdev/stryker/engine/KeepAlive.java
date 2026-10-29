package com.zalexdev.stryker.engine;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.widget.Toast;

import java.util.HashSet;
import java.util.Set;

/**
 * Keeps the app's process (and with it the QEMU child process, which Android kills together with
 * the app) from being stopped while the VM or the VNC server is in use.
 *
 * A foreground service alone is not enough on vendor ROMs such as HarmonyOS / EMUI: they freeze or
 * kill a backgrounded app unless it holds a wake lock and the user has exempted it from battery
 * optimisation. The wake lock is taken here; the exemption is a system setting only the user can
 * grant, so {@link #askOnce} sends them to it.
 */
public final class KeepAlive {

    private static final long LOCK_MS = 6L * 60L * 60L * 1000L;
    private static final String PREF_ASKED = "keepalive_asked";

    private static final Set<String> owners = new HashSet<>();
    private static PowerManager.WakeLock lock;

    private KeepAlive() {}

    /** Takes (or refreshes) the wake lock on behalf of {@code owner}, e.g. "vm" or "vnc". */
    public static synchronized void acquire(Context ctx, String owner) {
        try {
            owners.add(owner);
            if (lock == null) {
                PowerManager pm = (PowerManager) ctx.getApplicationContext()
                        .getSystemService(Context.POWER_SERVICE);
                if (pm == null) return;
                lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "stryker:guest");
                lock.setReferenceCounted(false);
            }
            if (!lock.isHeld()) lock.acquire(LOCK_MS);
        } catch (Throwable ignored) {
        }
    }

    /** Drops {@code owner}'s claim; the wake lock goes once nobody needs it. */
    public static synchronized void release(String owner) {
        try {
            owners.remove(owner);
            if (owners.isEmpty() && lock != null && lock.isHeld()) lock.release();
        } catch (Throwable ignored) {
        }
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
     * Once per install, if the app is not exempt: tells the user what to switch on and opens the
     * battery-optimisation list (falling back to the app's own settings page).
     */
    public static void askOnce(com.zalexdev.stryker.utils.Core core, Context ctx) {
        try {
            if (batteryExempt(ctx) || core.getBoolean(PREF_ASKED)) return;
            core.putBoolean(PREF_ASKED, true);
            new Handler(Looper.getMainLooper()).post(() -> {
                try {
                    Toast.makeText(ctx.getApplicationContext(),
                            "To keep the VM and VNC alive in the background: allow Stryker to run "
                                    + "in the background / not be optimised, and lock it in the "
                                    + "recent-apps screen.\n"
                                    + "要在后台保持虚拟机和 VNC 运行：请允许 Stryker 后台活动、不受电池优化限制，"
                                    + "并在多任务界面锁定本应用。",
                            Toast.LENGTH_LONG).show();
                } catch (Throwable ignored) {
                }
            });
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
