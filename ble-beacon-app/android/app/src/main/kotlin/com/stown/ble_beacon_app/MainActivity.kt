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
                            val manager =
                                applicationContext.getSystemService(Context.BLUETOOTH_SERVICE)
                                    as? BluetoothManager
                            val adapter = manager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
                            // На Android 10+ это вернёт "02:00:00:00:00:00" из-за приватности.
                            @Suppress("HardwareIds", "MissingPermission")
                            val mac = adapter?.address
                            result.success(mac)
                        } catch (e: Throwable) {
                            result.error("BT_MAC_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
