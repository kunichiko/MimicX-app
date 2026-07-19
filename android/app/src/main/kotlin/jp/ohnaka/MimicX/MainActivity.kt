package jp.ohnaka.MimicX

import android.content.pm.ActivityInfo
import android.hardware.input.InputManager
import android.os.Handler
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.flame_engine.gamepads_android.GamepadsCompatibleActivity

class MainActivity : FlutterActivity(), GamepadsCompatibleActivity {
    // --- gamepads プラグイン連携 (物理ゲームコントローラー入力) ------------------
    // gamepads_android は Activity を GamepadsCompatibleActivity へ強制キャスト
    // するため、この実装は必須 (欠けると起動時に ClassCastException で落ちる)。
    //
    // 注意: プラグイン README のボイラープレートは
    //   return keyListener?.invoke(e) ?: super.dispatchKeyEvent(e)
    // だが、これだとリスナーが false (= ゲームパッド以外のデバイスのイベント) を
    // 返したとき super へ渡らず物理キーボード入力がすべて死ぬ。
    // 「true を返したときだけ消費、それ以外は super へ」に修正してある。
    private var gamepadKeyListener: ((KeyEvent) -> Boolean)? = null
    private var gamepadMotionListener: ((MotionEvent) -> Boolean)? = null

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (gamepadKeyListener?.invoke(event) == true) return true
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (gamepadMotionListener?.invoke(event) == true) return true
        return super.dispatchGenericMotionEvent(event)
    }

    override fun registerInputDeviceListener(
        listener: InputManager.InputDeviceListener,
        handler: Handler?
    ) {
        val inputManager = getSystemService(INPUT_SERVICE) as InputManager
        inputManager.registerInputDeviceListener(listener, handler)
    }

    override fun registerKeyEventHandler(handler: (KeyEvent) -> Boolean) {
        gamepadKeyListener = handler
    }

    override fun registerMotionEventHandler(handler: (MotionEvent) -> Boolean) {
        gamepadMotionListener = handler
    }
    // ---------------------------------------------------------------------------

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
