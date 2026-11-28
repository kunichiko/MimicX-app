import Carbon
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // EventChannel の stream handler は channel から弱参照なので保持しておく。
  private let inputSourceObserver = InputSourceObserver()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // "mimicx/input_source": 日本語入力 (IM) のオン/オフを Dart (lib/ime_state.dart)
    // に通知する。標準キーボード画面で IM がオンのときだけ入力バーを出すため。
    let inputSourceChannel = FlutterEventChannel(
      name: "mimicx/input_source",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    inputSourceChannel.setStreamHandler(inputSourceObserver)

    super.awakeFromNib()
  }
}

/// 現在のキーボード入力ソースを監視し、変わるたびに
/// `{japanese: Bool, id: String, mode: String, languages: [String]}` を流す。
/// `japanese` は「日本語の入力ソースで、かつ英字 (Roman) モードでない」とき true。
/// (ことえりのひらがな/カタカナ、Google 日本語入力のひらがな等。英字/英数は false)
class InputSourceObserver: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(inputSourceChanged),
      name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil,
      suspensionBehavior: .deliverImmediately)
    // 入力ソースをアプリ(書類)ごとに切り替える設定だと、アプリの切替で変わる。
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(inputSourceChanged),
      name: NSApplication.didBecomeActiveNotification,
      object: nil)
    emit()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    DistributedNotificationCenter.default().removeObserver(self)
    NotificationCenter.default.removeObserver(self)
    sink = nil
    return nil
  }

  @objc private func inputSourceChanged() {
    DispatchQueue.main.async { [weak self] in self?.emit() }
  }

  private func emit() {
    sink?(InputSourceObserver.currentState())
  }

  static func currentState() -> [String: Any] {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return ["japanese": false]
    }
    func property(_ key: CFString) -> AnyObject? {
      guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
      return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }
    let id = property(kTISPropertyInputSourceID) as? String ?? ""
    let mode = property(kTISPropertyInputModeID) as? String ?? ""
    let languages = property(kTISPropertyInputSourceLanguages) as? [String] ?? []
    let isRoman = id.contains("Roman") || mode.contains("Roman")
    let japanese = languages.first == "ja" && !isRoman
    return ["japanese": japanese, "id": id, "mode": mode, "languages": languages]
  }
}
