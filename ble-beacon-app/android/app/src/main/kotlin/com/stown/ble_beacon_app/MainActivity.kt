package com.stown.ble_beacon_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "com.stown.ble_beacon_app/bt_info"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBluetoothMac" -> {
                        try {
                            // На Android 10+ это вернёт "02:00:00:00:00:00" из-за приватности.
                            @Suppress("HardwareIds", "MissingPermission")
                            val mac = btAdapter()?.address
                            result.success(mac)
                        } catch (e: Throwable) {
                            result.error("BT_MAC_ERROR", e.message, null)
                        }
                    }
                    "getBluetoothName" -> {
                        try {
                            @Suppress("MissingPermission")
                            result.success(btAdapter()?.name)
                        } catch (e: Throwable) {
                            result.error("BT_NAME_ERROR", e.message, null)
                        }
                    }
                    "setBluetoothName" -> {
                        try {
                            val name = call.argument<String>("name")
                            @Suppress("MissingPermission")
                            val ok = if (name != null) btAdapter()?.setName(name) else false
                            result.success(ok ?: false)
                        } catch (e: Throwable) {
                            result.error("BT_NAME_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun btAdapter(): BluetoothAdapter? {
        val manager =
            applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
    }
}
