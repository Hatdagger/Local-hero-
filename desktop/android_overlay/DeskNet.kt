package __PACKAGE__

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Wi-Fi and Bluetooth for the desktop's own windows. Android lets an app read
 * the state, scan, list devices, pair and add a Wi-Fi network (Android asks to
 * confirm). Switching Wi-Fi on/off is only allowed through Android's own
 * quick panel on Android 10+, so those buttons open it.
 */
@SuppressLint("MissingPermission")
object DeskNet {
    private var channel: MethodChannel? = null
    private var receiver: BroadcastReceiver? = null
    private val found = LinkedHashMap<String, BluetoothDevice>()
    private val main = Handler(Looper.getMainLooper())
    private var pending = false

    @Suppress("DEPRECATION")
    fun register(activity: Activity, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "desk/net")
        channel = ch
        listen(activity)
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "wifiStatus" -> result.success(wifiStatus(activity))
                    "wifiScan" -> {
                        val ok = wifi(activity)?.startScan() ?: false
                        result.success(ok)
                    }
                    "wifiSetEnabled" -> result.success(wifiSetEnabled(activity, call.argument<Boolean>("on") ?: true))
                    "wifiConnect" -> result.success(
                        wifiConnect(
                            activity,
                            call.argument<String>("ssid") ?: "",
                            call.argument<String>("password") ?: "",
                            call.argument<String>("security") ?: "open",
                        ))
                    "wifiPanel" -> {
                        wifiPanel(activity)
                        result.success(null)
                    }
                    "askPermissions" -> {
                        askPermissions(activity)
                        result.success(null)
                    }
                    "locationSettings" -> {
                        open(activity, Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        result.success(null)
                    }
                    "btStatus" -> result.success(btStatus(activity))
                    "btSetEnabled" -> result.success(btSetEnabled(activity, call.argument<Boolean>("on") ?: true))
                    "btDiscover" -> {
                        val a = adapter(activity)
                        val on = call.argument<Boolean>("on") ?: true
                        val ok = if (a == null || !btAllowed(activity)) false else {
                            if (on) {
                                found.clear()
                                if (a.isDiscovering) a.cancelDiscovery()
                                a.startDiscovery()
                            } else {
                                a.cancelDiscovery()
                            }
                        }
                        result.success(ok)
                    }
                    "btPair" -> {
                        val d = device(activity, call.argument<String>("address") ?: "")
                        result.success(d?.createBond() ?: false)
                    }
                    "btUnpair" -> {
                        val d = device(activity, call.argument<String>("address") ?: "")
                        val ok = try {
                            d != null && (d.javaClass.getMethod("removeBond").invoke(d) as Boolean)
                        } catch (e: Exception) {
                            false
                        }
                        if (!ok) open(activity, Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                        result.success(ok)
                    }
                    "btSettings" -> {
                        open(activity, Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("net", e.message, null)
            }
        }
    }

    // ------------------------------------------------------------ change events

    /** Tells the desktop something changed (bunched up, at most every 300 ms). */
    private fun changed() {
        if (pending) return
        pending = true
        main.postDelayed({
            pending = false
            channel?.invokeMethod("changed", null)
        }, 300)
    }

    @Suppress("DEPRECATION")
    private fun listen(activity: Activity) {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.action == BluetoothDevice.ACTION_FOUND) {
                    val d: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) {
                        i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                    } else {
                        i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    if (d != null) found[d.address] = d
                }
                changed()
            }
        }
        val f = IntentFilter().apply {
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
            addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
            addAction(WifiManager.RSSI_CHANGED_ACTION)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(BluetoothDevice.ACTION_NAME_CHANGED)
        }
        val app = activity.applicationContext
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(r, f, Context.RECEIVER_EXPORTED)
        } else {
            app.registerReceiver(r, f)
        }
        receiver = r
    }

    // ------------------------------------------------------------ helpers

    private fun open(activity: Activity, i: Intent) {
        try {
            activity.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            try {
                activity.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: Exception) {}
        }
    }

    private fun granted(activity: Activity, p: String) =
        Build.VERSION.SDK_INT < 23 || activity.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun locationAllowed(activity: Activity) = granted(activity, Manifest.permission.ACCESS_FINE_LOCATION)

    private fun btAllowed(activity: Activity) = if (Build.VERSION.SDK_INT >= 31) {
        granted(activity, Manifest.permission.BLUETOOTH_CONNECT) && granted(activity, Manifest.permission.BLUETOOTH_SCAN)
    } else {
        locationAllowed(activity)
    }

    private fun askPermissions(activity: Activity) {
        if (Build.VERSION.SDK_INT < 23) return
        val list = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (Build.VERSION.SDK_INT >= 31) {
            list.add(Manifest.permission.BLUETOOTH_CONNECT)
            list.add(Manifest.permission.BLUETOOTH_SCAN)
        }
        val missing = list.filter { !granted(activity, it) }
        if (missing.isEmpty()) return
        activity.requestPermissions(missing.toTypedArray(), 61)
    }

    private fun locationOn(activity: Activity): Boolean {
        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else true
    }

    // ------------------------------------------------------------ Wi-Fi

    private fun wifi(activity: Activity) = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private fun bars(rssi: Int): Int = when {
        rssi >= -55 -> 4
        rssi >= -67 -> 3
        rssi >= -78 -> 2
        rssi >= -88 -> 1
        else -> 0
    }

    private fun security(caps: String): String = when {
        caps.contains("EAP") -> "enterprise"
        caps.contains("PSK") -> "wpa2"
        caps.contains("SAE") -> "wpa3"
        caps.contains("WEP") -> "wep"
        caps.contains("OWE") -> "owe"
        else -> "open"
    }

    @Suppress("DEPRECATION")
    private fun wifiStatus(activity: Activity): Map<String, Any?> {
        val wm = wifi(activity) ?: return mapOf("available" to false)
        val info = wm.connectionInfo
        val connected = info != null && info.networkId != -1
        var ssid = info?.ssid ?: ""
        if (ssid.startsWith("\"") && ssid.endsWith("\"") && ssid.length >= 2) ssid = ssid.substring(1, ssid.length - 1)
        if (ssid == "<unknown ssid>") ssid = ""
        val nets = mutableListOf<Map<String, Any?>>()
        if (locationAllowed(activity)) {
            val best = LinkedHashMap<String, android.net.wifi.ScanResult>()
            for (r in wm.scanResults) {
                val name = r.SSID ?: ""
                if (name.isEmpty()) continue
                val old = best[name]
                if (old == null || r.level > old.level) best[name] = r
            }
            for (r in best.values.sortedByDescending { it.level }) {
                val sec = security(r.capabilities ?: "")
                nets.add(mapOf(
                    "ssid" to r.SSID,
                    "bars" to bars(r.level),
                    "security" to sec,
                    "band" to if (r.frequency > 4900) "5 GHz" else "2.4 GHz",
                    "current" to (connected && r.SSID == ssid),
                ))
            }
        }
        return mapOf(
            "available" to true,
            "enabled" to wm.isWifiEnabled,
            "connected" to connected,
            "ssid" to ssid,
            "bars" to if (connected) bars(info.rssi) else 0,
            "mbps" to (info?.linkSpeed ?: 0),
            "permission" to locationAllowed(activity),
            "locationOn" to locationOn(activity),
            "networks" to nets,
        )
    }

    private fun wifiPanel(activity: Activity) {
        if (Build.VERSION.SDK_INT >= 29) {
            open(activity, Intent(Settings.Panel.ACTION_WIFI))
        } else {
            open(activity, Intent(Settings.ACTION_WIFI_SETTINGS))
        }
    }

    /** True if switched here; false when Android's panel was opened instead. */
    @Suppress("DEPRECATION")
    private fun wifiSetEnabled(activity: Activity, on: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < 29) {
            if (wifi(activity)?.setWifiEnabled(on) == true) return true
        }
        wifiPanel(activity)
        return false
    }

    /**
     * Adds a network: Android shows its own "Save this network?" box and then
     * joins it. Returns "added", or "panel" when Android's Wi-Fi panel was
     * opened instead (old Android, or a network type it can't add this way).
     */
    private fun wifiConnect(activity: Activity, ssid: String, password: String, sec: String): String {
        if (Build.VERSION.SDK_INT >= 30 && sec in setOf("open", "wpa2", "wpa3", "owe")) {
            try {
                val b = WifiNetworkSuggestion.Builder().setSsid(ssid)
                when (sec) {
                    "wpa2" -> b.setWpa2Passphrase(password)
                    "wpa3" -> b.setWpa3Passphrase(password)
                    "owe" -> b.setIsEnhancedOpen(true)
                }
                val i = Intent(Settings.ACTION_WIFI_ADD_NETWORKS)
                    .putParcelableArrayListExtra(Settings.EXTRA_WIFI_NETWORK_LIST, arrayListOf(b.build()))
                activity.startActivityForResult(i, 62)
                return "added"
            } catch (_: Exception) {}
        }
        wifiPanel(activity)
        return "panel"
    }

    // ------------------------------------------------------------ Bluetooth

    private fun adapter(activity: Activity): BluetoothAdapter? =
        (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun device(activity: Activity, address: String): BluetoothDevice? {
        val a = adapter(activity) ?: return null
        if (!btAllowed(activity)) return null
        return found[address] ?: try {
            a.getRemoteDevice(address)
        } catch (e: Exception) {
            null
        }
    }

    private fun kind(d: BluetoothDevice): String {
        val c: BluetoothClass = (try { d.bluetoothClass } catch (e: Exception) { null }) ?: return "other"
        return when (c.majorDeviceClass) {
            BluetoothClass.Device.Major.AUDIO_VIDEO -> "audio"
            BluetoothClass.Device.Major.PHONE -> "phone"
            BluetoothClass.Device.Major.COMPUTER -> "computer"
            BluetoothClass.Device.Major.PERIPHERAL -> when {
                c.deviceClass and 0x40 != 0 -> "keyboard"
                c.deviceClass and 0x80 != 0 -> "mouse"
                else -> "gamepad"
            }
            BluetoothClass.Device.Major.WEARABLE -> "watch"
            BluetoothClass.Device.Major.TOY -> "gamepad"
            else -> "other"
        }
    }

    private fun isConnected(d: BluetoothDevice): Boolean = try {
        d.javaClass.getMethod("isConnected").invoke(d) as Boolean
    } catch (e: Exception) {
        false
    }

    private fun btStatus(activity: Activity): Map<String, Any?> {
        val a = adapter(activity) ?: return mapOf("available" to false)
        val allowed = btAllowed(activity)
        val devices = mutableListOf<Map<String, Any?>>()
        if (allowed && a.isEnabled) {
            val bonded = a.bondedDevices ?: emptySet()
            val seen = HashSet<String>()
            for (d in bonded) {
                seen.add(d.address)
                devices.add(mapOf(
                    "name" to (d.name ?: d.address),
                    "address" to d.address,
                    "kind" to kind(d),
                    "paired" to true,
                    "pairing" to false,
                    "connected" to isConnected(d),
                ))
            }
            for (d in found.values) {
                if (!seen.add(d.address)) continue
                devices.add(mapOf(
                    "name" to (d.name ?: d.address),
                    "address" to d.address,
                    "kind" to kind(d),
                    "paired" to false,
                    "pairing" to (d.bondState == BluetoothDevice.BOND_BONDING),
                    "connected" to false,
                ))
            }
        }
        return mapOf(
            "available" to true,
            "enabled" to a.isEnabled,
            "permission" to allowed,
            "name" to (if (allowed) a.name else null),
            "discovering" to (allowed && a.isDiscovering),
            "devices" to devices,
        )
    }

    /** True if switched here; false when Android's own screen was opened. */
    @Suppress("DEPRECATION")
    private fun btSetEnabled(activity: Activity, on: Boolean): Boolean {
        val a = adapter(activity) ?: return false
        if (on) {
            if (!btAllowed(activity)) {
                askPermissions(activity)
                return false
            }
            open(activity, Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
            return false
        }
        if (Build.VERSION.SDK_INT < 33 && btAllowed(activity)) {
            if (a.disable()) return true
        }
        open(activity, Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
        return false
    }
}
