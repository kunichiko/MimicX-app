// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Mimic X';

  @override
  String get homeRescanTooltip => 'Rescan';

  @override
  String get homeAboutTooltip => 'About';

  @override
  String get homeSearching => 'Searching for adapters…';

  @override
  String get homeConnecting => 'Connecting to adapter…';

  @override
  String get homeNoDevicesTitle => 'No adapters found';

  @override
  String get homeNoDevicesHint =>
      'Connect a Mimic X Adapter and press the reload button in the top right.';

  @override
  String get homeIncompatibleNote => 'Not Mimic X compatible (no response)';

  @override
  String homeFirmwareVersion(String fwVersion, String protoVersion) {
    return 'fw $fwVersion (proto $protoVersion)';
  }

  @override
  String homeChannelLabel(int channel, String target) {
    return 'CH$channel - $target';
  }

  @override
  String get deviceNotResponding =>
      'No response from adapter (may not be Mimic X compatible)';

  @override
  String get noChannelsAvailable => 'No usable channels';

  @override
  String unsupportedFunction(String hidType, String target) {
    return 'Unsupported function: $hidType / $target';
  }

  @override
  String protocolTooOld(String deviceVersion, String minVersion) {
    return 'Firmware is too old (proto $deviceVersion, requires $minVersion or newer). Please update the adapter.';
  }

  @override
  String get protocolNewerWarningTitle => 'Possibly incompatible';

  @override
  String protocolNewerWarningBody(String deviceVersion, String knownVersion) {
    return 'The firmware protocol version (proto $deviceVersion) is newer than the latest known to this app (proto $knownVersion). Please update the app for full compatibility.';
  }

  @override
  String padModeSwitchFailed(String mode, String reason) {
    return 'Failed to switch to $mode mode ($reason)';
  }

  @override
  String get selectFunction => 'Select function';

  @override
  String get joystickTitle => 'Joystick';

  @override
  String get controllerSettings => 'Controller Settings';

  @override
  String get padModeAtari => 'ATARI';

  @override
  String get padModeMd6 => 'MD 6B';

  @override
  String get padModeLibbleRabble => 'Libble Rabble';

  @override
  String get padModeMsxMouse => 'MSX Mouse';

  @override
  String get msxMouseFirmwareUpdateHint =>
      'Your firmware may not support MSX Mouse yet. Please update the firmware.';

  @override
  String deadZoneLabel(int percent) {
    return 'D-pad dead zone radius: $percent%';
  }

  @override
  String get deadZoneHelp =>
      'Smaller values respond to less finger movement. 0% means a direction is always pressed even at the center.';

  @override
  String extraHitLabel(int px) {
    return 'Button hit area extension: +$px px';
  }

  @override
  String get extraHitHelp =>
      'Larger values overlap adjacent buttons, so you can press multiple buttons with the side of one finger or slide from A to B.';

  @override
  String turboRateLabel(int hz) {
    return 'Turbo rate: $hz Hz';
  }

  @override
  String get turboRateHelp =>
      'Number of presses per second for buttons with turbo enabled.';

  @override
  String get turboToggleSection => 'Turbo on/off (on-screen buttons)';

  @override
  String get turboToggleHelp =>
      'Buttons with turbo enabled will repeat press / release at the rate above while held.';

  @override
  String get turboBadge => 'T';

  @override
  String get padAssignSection => 'Gamepad button assignment';

  @override
  String get padAssignNone => 'None';

  @override
  String get padAssignHelp =>
      'Press a button on your controller to highlight its row. Use the turbo chip to enable per-button turbo (rate is shared with the turbo rate above).';

  @override
  String get bleWinPairingHintTitle => 'Cannot connect';

  @override
  String get bleWinPairingHintBody =>
      'The BLE connection to the adapter keeps failing. The adapter may have lost its pairing keys (e.g. after a firmware update with \"erase device\").\n\nRemove this adapter (MimicX) in Windows Settings > Bluetooth & devices, then try connecting again.';

  @override
  String get townsPadLabel => 'TOWNS pad feature (RUN/SELECT)';

  @override
  String get townsPadHelp =>
      'Shows RUN / SELECT buttons on screen and maps the gamepad Start / Back buttons to them. RUN asserts left+right and SELECT asserts up+down on the target machine (firmware v1.1.0+).';

  @override
  String get x68kKeyboardTitle => 'X68000 Keyboard';

  @override
  String get deviceRenameTooltip => 'Rename';

  @override
  String get deviceRenameTitle => 'Rename adapter';

  @override
  String get deviceRenameHint => 'Nickname (up to 50 characters)';

  @override
  String deviceRenameSerialLabel(String serial) {
    return 'Serial: $serial';
  }

  @override
  String get deviceRenameSaveButton => 'Save';

  @override
  String get deviceRenameClearButton => 'Reset to default';

  @override
  String get deviceRenameConnecting => 'Connecting…';

  @override
  String get deviceRenameConnectFailed =>
      'Could not connect to the adapter for renaming.';

  @override
  String get connectionLost => 'Lost connection to the adapter. Rescanning…';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutAppDescription =>
      'USB-MIDI controller app for retro PC HID emulation. Use a smartphone as a joystick or keyboard for X68000 / MSX via the Mimic X Adapter.';

  @override
  String aboutVersion(String version, String build) {
    return 'Version $version ($build)';
  }

  @override
  String get aboutLicensesButton => 'Open source licenses';

  @override
  String get aboutCopyright => '© 2026 Kunihiko Ohnaka';

  @override
  String get switchToKeyboard => 'Switch to keyboard';

  @override
  String get switchToJoystick => 'Switch to joystick';
}
