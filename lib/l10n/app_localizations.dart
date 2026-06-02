import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
  ];

  /// App display name
  ///
  /// In en, this message translates to:
  /// **'Mimic X'**
  String get appTitle;

  /// No description provided for @homeRescanTooltip.
  ///
  /// In en, this message translates to:
  /// **'Rescan'**
  String get homeRescanTooltip;

  /// No description provided for @homeAboutTooltip.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get homeAboutTooltip;

  /// No description provided for @homeSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching for devices…'**
  String get homeSearching;

  /// No description provided for @homeNoDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'No devices found'**
  String get homeNoDevicesTitle;

  /// No description provided for @homeNoDevicesHint.
  ///
  /// In en, this message translates to:
  /// **'Connect a Mimic X device and press the reload button in the top right.'**
  String get homeNoDevicesHint;

  /// No description provided for @homeIncompatibleNote.
  ///
  /// In en, this message translates to:
  /// **'Not Mimic X compatible (no response)'**
  String get homeIncompatibleNote;

  /// No description provided for @homeFirmwareVersion.
  ///
  /// In en, this message translates to:
  /// **'fw {fwVersion} (proto {protoVersion})'**
  String homeFirmwareVersion(String fwVersion, String protoVersion);

  /// No description provided for @homeChannelLabel.
  ///
  /// In en, this message translates to:
  /// **'CH{channel} - {target}'**
  String homeChannelLabel(int channel, String target);

  /// No description provided for @deviceNotResponding.
  ///
  /// In en, this message translates to:
  /// **'No response from device (may not be Mimic X compatible)'**
  String get deviceNotResponding;

  /// No description provided for @noChannelsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No usable channels'**
  String get noChannelsAvailable;

  /// No description provided for @unsupportedFunction.
  ///
  /// In en, this message translates to:
  /// **'Unsupported function: {hidType} / {target}'**
  String unsupportedFunction(String hidType, String target);

  /// No description provided for @protocolTooOld.
  ///
  /// In en, this message translates to:
  /// **'Firmware is too old (proto {deviceVersion}, requires {minVersion} or newer). Please update the device.'**
  String protocolTooOld(String deviceVersion, String minVersion);

  /// No description provided for @protocolNewerWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Possibly incompatible'**
  String get protocolNewerWarningTitle;

  /// No description provided for @protocolNewerWarningBody.
  ///
  /// In en, this message translates to:
  /// **'The firmware protocol version (proto {deviceVersion}) is newer than the latest known to this app (proto {knownVersion}). Please update the app for full compatibility.'**
  String protocolNewerWarningBody(String deviceVersion, String knownVersion);

  /// No description provided for @padModeSwitchFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to switch to {mode} mode ({reason})'**
  String padModeSwitchFailed(String mode, String reason);

  /// No description provided for @selectFunction.
  ///
  /// In en, this message translates to:
  /// **'Select function'**
  String get selectFunction;

  /// No description provided for @joystickTitle.
  ///
  /// In en, this message translates to:
  /// **'Joystick'**
  String get joystickTitle;

  /// No description provided for @controllerSettings.
  ///
  /// In en, this message translates to:
  /// **'Controller Settings'**
  String get controllerSettings;

  /// No description provided for @padModeAtari.
  ///
  /// In en, this message translates to:
  /// **'ATARI'**
  String get padModeAtari;

  /// No description provided for @padModeMd6.
  ///
  /// In en, this message translates to:
  /// **'MD 6B'**
  String get padModeMd6;

  /// No description provided for @padModeLibbleRabble.
  ///
  /// In en, this message translates to:
  /// **'Libble Rabble'**
  String get padModeLibbleRabble;

  /// No description provided for @padModeMsxMouse.
  ///
  /// In en, this message translates to:
  /// **'MSX Mouse'**
  String get padModeMsxMouse;

  /// No description provided for @msxMouseFirmwareUpdateHint.
  ///
  /// In en, this message translates to:
  /// **'Your firmware may not support MSX Mouse yet. Please update the firmware.'**
  String get msxMouseFirmwareUpdateHint;

  /// No description provided for @deadZoneLabel.
  ///
  /// In en, this message translates to:
  /// **'D-pad dead zone radius: {percent}%'**
  String deadZoneLabel(int percent);

  /// No description provided for @deadZoneHelp.
  ///
  /// In en, this message translates to:
  /// **'Smaller values respond to less finger movement. 0% means a direction is always pressed even at the center.'**
  String get deadZoneHelp;

  /// No description provided for @extraHitLabel.
  ///
  /// In en, this message translates to:
  /// **'Button hit area extension: +{px} px'**
  String extraHitLabel(int px);

  /// No description provided for @extraHitHelp.
  ///
  /// In en, this message translates to:
  /// **'Larger values overlap adjacent buttons, so you can press multiple buttons with the side of one finger or slide from A to B.'**
  String get extraHitHelp;

  /// No description provided for @turboRateLabel.
  ///
  /// In en, this message translates to:
  /// **'Turbo rate: {hz} Hz'**
  String turboRateLabel(int hz);

  /// No description provided for @turboRateHelp.
  ///
  /// In en, this message translates to:
  /// **'Number of presses per second for buttons with turbo enabled.'**
  String get turboRateHelp;

  /// No description provided for @turboToggleSection.
  ///
  /// In en, this message translates to:
  /// **'Turbo on/off'**
  String get turboToggleSection;

  /// No description provided for @turboToggleHelp.
  ///
  /// In en, this message translates to:
  /// **'Buttons with turbo enabled will repeat press / release at the rate above while held.'**
  String get turboToggleHelp;

  /// Short badge shown on a button when turbo is enabled
  ///
  /// In en, this message translates to:
  /// **'T'**
  String get turboBadge;

  /// No description provided for @x68kKeyboardTitle.
  ///
  /// In en, this message translates to:
  /// **'X68000 Keyboard'**
  String get x68kKeyboardTitle;

  /// No description provided for @deviceRenameTooltip.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get deviceRenameTooltip;

  /// No description provided for @deviceRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename adapter'**
  String get deviceRenameTitle;

  /// No description provided for @deviceRenameHint.
  ///
  /// In en, this message translates to:
  /// **'Nickname (up to 50 characters)'**
  String get deviceRenameHint;

  /// No description provided for @deviceRenameSerialLabel.
  ///
  /// In en, this message translates to:
  /// **'Serial: {serial}'**
  String deviceRenameSerialLabel(String serial);

  /// No description provided for @deviceRenameSaveButton.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get deviceRenameSaveButton;

  /// No description provided for @deviceRenameClearButton.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get deviceRenameClearButton;

  /// No description provided for @deviceRenameConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get deviceRenameConnecting;

  /// No description provided for @deviceRenameConnectFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not connect to the adapter for renaming.'**
  String get deviceRenameConnectFailed;

  /// No description provided for @connectionLost.
  ///
  /// In en, this message translates to:
  /// **'Lost connection to the device. Rescanning…'**
  String get connectionLost;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutTitle;

  /// No description provided for @aboutAppDescription.
  ///
  /// In en, this message translates to:
  /// **'USB-MIDI controller app for retro PC HID emulation. Use a smartphone as a joystick or keyboard for X68000 / MSX via the Mimic X device.'**
  String get aboutAppDescription;

  /// No description provided for @aboutVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version} ({build})'**
  String aboutVersion(String version, String build);

  /// No description provided for @aboutLicensesButton.
  ///
  /// In en, this message translates to:
  /// **'Open source licenses'**
  String get aboutLicensesButton;

  /// No description provided for @aboutCopyright.
  ///
  /// In en, this message translates to:
  /// **'© 2026 Kunihiko Ohnaka'**
  String get aboutCopyright;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
