package jp.ohnaka.MimicX

import android.content.pm.ActivityInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /**
     * Flutter の SystemChrome.setPreferredOrientations は Android 側で
     * SCREEN_ORIENTATION_USER_LANDSCAPE にマップされ、OS の自動回転ロック設定を
     * 尊重するため、ロック ON だと片側 landscape で固定されてしまう。
     * このチャンネルは SENSOR_LANDSCAPE を直接指定し、自動回転ロックに関係なく
     * 端末を 180° ひっくり返せるようにする (USB ケーブルの向きを左右どちらにも
     * できる) ためのもの。
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mimicx/orientation")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSensorLandscape" -> {
                        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                        result.success(null)
                    }
                    "setPortrait" -> {
                        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                        result.success(null)
                    }
                    "setUnspecified" -> {
                        // 全方向許可、OS の自動回転ロックを無視して傾きセンサに追従。
                        // UNSPECIFIED だとマニフェストの portrait に戻ってしまう端末が
                        // あるため、FULL_SENSOR で 4 方向すべてセンサ追従とする。
                        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
