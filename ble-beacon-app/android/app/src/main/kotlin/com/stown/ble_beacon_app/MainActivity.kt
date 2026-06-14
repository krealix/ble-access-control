package com.stown.ble_beacon_app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.telephony.TelephonyManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channel = "com.stown.ble_beacon_app/bt_info"
    private val callChannel = "com.stown.ble_beacon_app/incoming_call"

    private var callReceiver: BroadcastReceiver? = null

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
                    "getAdvertiseSupport" -> {
                        try {
                            val a = btAdapter()
                            val map = HashMap<String, Any?>()
                            map["enabled"] = a?.isEnabled ?: false
                            map["multipleAdvertisement"] =
                                a?.isMultipleAdvertisementSupported ?: false
                            map["advertiserNotNull"] =
                                (a?.bluetoothLeAdvertiser != null)
                            if (android.os.Build.VERSION.SDK_INT >=
                                    android.os.Build.VERSION_CODES.O) {
                                map["leExtendedAdvertising"] =
                                    a?.isLeExtendedAdvertisingSupported ?: false
                            }
                            result.success(map)
                        } catch (e: Throwable) {
                            result.error("BT_SUPPORT_ERROR", e.message, null)
                        }
                    }
                    "startGatewayService" -> {
                        try {
                            val i = Intent(this, GatewayForegroundService::class.java)
                            if (android.os.Build.VERSION.SDK_INT >=
                                    android.os.Build.VERSION_CODES.O) {
                                startForegroundService(i)
                            } else {
                                startService(i)
                            }
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("FGS_ERROR", e.message, null)
                        }
                    }
                    "stopGatewayService" -> {
                        try {
                            stopService(Intent(this, GatewayForegroundService::class.java))
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("FGS_ERROR", e.message, null)
                        }
                    }
                    "requestCallPermissions" -> {
                        try {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    Manifest.permission.READ_PHONE_STATE,
                                    Manifest.permission.READ_CALL_LOG,
                                ),
                                7001,
                            )
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("PERM_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Поток входящих звонков: на состоянии RINGING отдаём номер звонящего.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, callChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(ctx: Context, intent: Intent) {
                            if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) {
                                return
                            }
                            val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
                            if (state == TelephonyManager.EXTRA_STATE_RINGING) {
                                @Suppress("DEPRECATION")
                                val number =
                                    intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                                if (!number.isNullOrBlank()) sink.success(number)
                            }
                        }
                    }
                    callReceiver = receiver
                    ContextCompat.registerReceiver(
                        this@MainActivity,
                        receiver,
                        IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED),
                        ContextCompat.RECEIVER_NOT_EXPORTED,
                    )
                }

                override fun onCancel(args: Any?) {
                    callReceiver?.let {
                        try {
                            unregisterReceiver(it)
                        } catch (_: Exception) {}
                    }
                    callReceiver = null
                }
            })
    }

    override fun onDestroy() {
        callReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        callReceiver = null
        super.onDestroy()
    }

    private fun btAdapter(): BluetoothAdapter? {
        val manager =
            applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
    }
}
