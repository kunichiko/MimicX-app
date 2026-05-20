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
  String get homeSearching => 'Searching for devices…';

  @override
  String get homeNoDevicesTitle => 'No devices found';

  @override
  String get homeNoDevicesHint =>
      'Connect a Mimic X device and press the reload button in the top right.';

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
      'No response from device (may not be Mimic X compatible)';

  @override
  String get noChannelsAvailable => 'No usable channels';

  @override
  String unsupportedFunction(String hidType, String target) {
    return 'Unsupported function: $hidType / $target';
  }

  @override
  String protocolTooOld(String deviceVersion, String minVersion) {
    return 'Firmware is too old (proto $deviceVersion, requires $minVersion or newer). Please update the device.';
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
  String get turboToggleSection => 'Turbo on/off';

  @override
  String get turboToggleHelp =>
      'Buttons with turbo enabled will repeat press / release at the rate above while held.';

  @override
  String get turboBadge => 'T';

  @override
  String get x68kKeyboardTitle => 'X68000 Keyboard';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutAppDescription =>
      'USB-MIDI controller app for retro PC HID emulation. Use a smartphone as a joystick or keyboard for X68000 / MSX via the Mimic X device.';

  @override
  String aboutVersion(String version, String build) {
    return 'Version $version ($build)';
  }

  @override
  String get aboutLicensesButton => 'Open source licenses';

  @override
  String get aboutCopyright => '© 2026 Kunihiko Ohnaka';
}
