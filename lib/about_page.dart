import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'demo_adapter.dart';
import 'l10n/app_localizations.dart';

/// デモ用の仮想アダプタ (demo_adapter.dart) の表示スイッチ。
/// 設定は [DemoModeStore] に保存し、ホーム画面は戻ったときに読み直して再スキャンする。
class _DemoAdaptersSwitch extends StatefulWidget {
  const _DemoAdaptersSwitch();

  @override
  State<_DemoAdaptersSwitch> createState() => _DemoAdaptersSwitchState();
}

class _DemoAdaptersSwitchState extends State<_DemoAdaptersSwitch> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    DemoModeStore.load().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: SwitchListTile(
        secondary: const Icon(Icons.science_outlined),
        title: Text(l.aboutDemoAdapters),
        subtitle: Text(l.aboutDemoAdaptersHint),
        value: _enabled ?? false,
        onChanged: _enabled == null
            ? null
            : (v) {
                setState(() => _enabled = v);
                DemoModeStore.save(v);
              },
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.aboutTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/icon.png',
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l.appTitle,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (ctx, snap) {
                  // 取得前は空文字でレイアウトを保つ
                  final info = snap.data;
                  final text = info == null
                      ? ''
                      : l.aboutVersion(info.version, info.buildNumber);
                  return Text(
                    text,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  );
                },
              ),
              const SizedBox(height: 24),
              Text(
                l.aboutAppDescription,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                icon: const Icon(Icons.description_outlined),
                label: Text(l.aboutLicensesButton),
                onPressed: () => _showLicenses(context, l),
              ),
              const SizedBox(height: 24),
              const _DemoAdaptersSwitch(),
              const SizedBox(height: 32),
              Text(
                l.aboutCopyright,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showLicenses(BuildContext context, AppLocalizations l) async {
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showLicensePage(
      context: context,
      applicationName: l.appTitle,
      applicationVersion: l.aboutVersion(info.version, info.buildNumber),
      applicationLegalese: l.aboutCopyright,
      applicationIcon: Padding(
        padding: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset('assets/icon.png', width: 64, height: 64),
        ),
      ),
    );
  }
}
