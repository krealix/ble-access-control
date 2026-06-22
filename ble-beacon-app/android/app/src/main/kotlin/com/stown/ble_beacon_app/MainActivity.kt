package com.stown.ble_beacon_app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telecom.TelecomManager
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

    // Ожидающий результат запроса разрешений «телефона» (заполняется в
    // onRequestPermissionsResult). Нужен, чтобы Dart узнал, выдан ли сброс.
    private var pendingPermResult: MethodChannel.Result? = null

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
                            val withHangup =
                                call.argument<Boolean>("withHangup") ?: false
                            val perms = ArrayList<String>()
                            perms.add(Manifest.permission.READ_PHONE_STATE)
                            perms.add(Manifest.permission.READ_CALL_LOG)
                            // ANSWER_PHONE_CALLS появилось в API 26 (O).
                            if (withHangup && Build.VERSION.SDK_INT >=
                                    Build.VERSION_CODES.O) {
                                perms.add(Manifest.permission.ANSWER_PHONE_CALLS)
                            }
                            // Все разрешения «телефона» запрашиваем ОДНИМ вызовом:
                            // система показывает только один диалог за раз, поэтому
                            // два отдельных requestPermissions приводят к тому, что
                            // второй (ANSWER_PHONE_CALLS) молча отбрасывается.
                            pendingPermResult?.let {
                                try {
                                    it.success(null)
                                } catch (_: Throwable) {}
                            }
                            pendingPermResult = result
                            ActivityCompat.requestPermissions(
                                this, perms.toTypedArray(), 7001)
                        } catch (e: Throwable) {
                            pendingPermResult = null
                            result.error("PERM_ERROR", e.message, null)
                        }
                    }
                    "openAppSettings" -> {
                        try {
                            val intent = Intent(
                                android.provider.Settings
                                    .ACTION_APPLICATION_DETAILS_SETTINGS,
                                android.net.Uri.fromParts(
                                    "package", packageName, null),
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    "endCall" -> {
                        try {
                            result.success(endCurrentCall())
                        } catch (e: Throwable) {
                            result.error("END_CALL_ERROR", e.message, null)
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 7001) return
        val map = HashMap<String, Boolean>()
        for (i in permissions.indices) {
            map[permissions[i]] = i < grantResults.size &&
                grantResults[i] == PackageManager.PERMISSION_GRANTED
        }
        // Итоговый факт: реально ли сейчас доступен сброс звонка.
        map["hangupGranted"] =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.ANSWER_PHONE_CALLS,
            ) == PackageManager.PERMISSION_GRANTED
        pendingPermResult?.let {
            try {
                it.success(map)
            } catch (_: Throwable) {}
        }
        pendingPermResult = null
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

    /// Сбрасывает текущий звонок через TelecomManager.endCall() (API 28+,
    /// нужно разрешение ANSWER_PHONE_CALLS). Возвращает строку-статус для
    /// диагностики: ok / no_permission / api_too_old / no_telecom /
    /// endcall_false / error.
    private fun endCurrentCall(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return "api_too_old"
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ANSWER_PHONE_CALLS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return "no_permission"
        }
        val tm = getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            ?: return "no_telecom"
        return try {
            @Suppress("MissingPermission")
            val ok = tm.endCall()
            // Повтор через 600 мс: состояние звонка могло ещё не установиться
            // в момент RINGING.
            if (!ok) {
                android.os.Handler(mainLooper).postDelayed({
                    try {
                        @Suppress("MissingPermission")
                        tm.endCall()
                    } catch (_: Throwable) {}
                }, 600)
            }
            if (ok) "ok" else "endcall_false"
        } catch (e: Throwable) {
            "error: ${e.message}"
        }
    }

    private fun btAdapter(): BluetoothAdapter? {
        val manager =
            applicationContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
    }
}
