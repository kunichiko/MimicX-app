// ===================================================================================
// link_diagnostics_page.dart
// ===================================================================================
// アダプタとの通信遅延を計測する「通信診断」画面。
//
// 「BLE だと入力が遅れる」という報告を、ユーザ自身の環境で数値化するためのもの。
// 結果はテキストでコピーでき、そのまま開発者へ送ってもらえる。
//
// 計測するもの:
//   1) HEART_BEAT の往復時間 (アプリ → ブリッジ → I2C → CH32 → … → アプリ)
//      CH32 は ACK を返す前にそれまで届いたノートを GPIO へ反映し終えているので、
//      これは「送信 → GPIO 反映」の上限になる (片道はおおむねこの半分〜全体)。
//   2) BRIDGE_LINK_INFO (§6.4.7) の往復時間 (アプリ ⇄ ブリッジのみ)
//      1) との差がブリッジ内 (I2C + CH32) の所要時間。
//   3) BRIDGE_LINK_INFO の中身 = BLE で実際に合意された connection interval 等。
//      BLE の遅延は connection interval に支配されるため、ここが最重要の手掛かり。
//
// 入場時: 接続 → 生存確認 → IDENTIFY → HEART_BEAT 開始 (device_rename_page と同じ流れ)
// 計測中: HEART_BEAT タイマーは止め、プローブ自体を生存通知として使う (並行して
//         HB が飛ぶと計測値が乱れるため)。終わったら HB を再開する。
// 離場時: HB 停止 → DISCONNECT → 100ms 待ち → 切断
// ===================================================================================

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'l10n/app_localizations.dart';
import 'midi_service.dart';
import 'protocol.dart';

class LinkDiagnosticsPage extends StatefulWidget {
  final MidiDeviceInfo deviceInfo;
  final String deviceName;
  final MidiService midi;

  const LinkDiagnosticsPage({
    super.key,
    required this.deviceInfo,
    required this.deviceName,
    required this.midi,
  });

  @override
  State<LinkDiagnosticsPage> createState() => _LinkDiagnosticsPageState();
}

/// 往復時間サンプル列の統計。
class _RttStats {
  final List<double> samples = [];
  int lost = 0;

  void clear() {
    samples.clear();
    lost = 0;
  }

  bool get isEmpty => samples.isEmpty;

  List<double> get _sorted => [...samples]..sort();

  double? get min => isEmpty ? null : _sorted.first;
  double? get max => isEmpty ? null : _sorted.last;
  double? get avg =>
      isEmpty ? null : samples.reduce((a, b) => a + b) / samples.length;

  /// nearest-rank 方式のパーセンタイル。
  double? percentile(double p) {
    if (isEmpty) return null;
    final s = _sorted;
    final rank = (p / 100 * s.length).ceil().clamp(1, s.length);
    return s[rank - 1];
  }
}

class _LinkDiagnosticsPageState extends State<LinkDiagnosticsPage> {
  /// 1 回の計測で送る HEART_BEAT プローブ数
  static const int _probeCount = 200;
  /// プローブ間の待ち (ms)。connection interval と位相が揃って同じ値ばかり
  /// 拾わないよう、毎回ランダムにずらす。
  static const int _gapMinMs = 20;
  static const int _gapMaxMs = 40;
  /// 連続でこれだけ応答が無ければ接続が切れたとみなして打ち切る
  static const int _maxConsecutiveLost = 8;
  /// ヒストグラムの階級幅 (ms) と階級数 (最後の階級は「それ以上」)
  static const int _binMs = 10;
  static const int _binCount = 10;

  bool _connecting = true;
  bool _connectFailed = false;
  bool _running = false;
  bool _cancel = false;
  bool _leaving = false;
  int _done = 0;

  BridgeLinkInfoResult? _linkBefore;
  BridgeLinkInfoResult? _linkAfter;
  final _RttStats _device = _RttStats();
  final _RttStats _bridge = _RttStats();
  /// 計測中に観測した connection interval (1.25ms 単位) の集合。途中で変わったら
  /// 複数入る (iOS はアプリの状態や他の BT 通信で張り替えることがある)。
  final Set<int> _intervalsSeen = {};
  DateTime? _measuredAt;

  final Random _rand = Random();

  @override
  void initState() {
    super.initState();
    Future.microtask(_enter);
  }

  Future<void> _enter() async {
    final midi = widget.midi;
    var ok = await midi.connect(widget.deviceInfo);
    // Android の接続直後の送信詰まり対策 (midi_service.probeConnection 参照)
    if (ok) ok = await midi.probeConnection();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _connecting = false;
        _connectFailed = true;
      });
      return;
    }
    await midi.identifyDevice();
    if (!mounted) return;
    midi.startHeartBeat(onFailure: _onHeartBeatFailure);
    final link = await midi.queryBridgeLinkInfo();
    if (!mounted) return;
    setState(() {
      _linkBefore = link;
      _connecting = false;
    });
  }

  void _onHeartBeatFailure() {
    if (!mounted) return;
    // 最前面のときだけ pop する (device_rename_page と同じ理由)
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.of(context).pop('CONN_LOST');
  }

  Future<void> _leave() async {
    _leaving = true;
    _cancel = true;
    widget.midi.stopHeartBeat();
    widget.midi.sendDisconnect();
    await Future.delayed(const Duration(milliseconds: 100));
    widget.midi.disconnect();
  }

  @override
  void dispose() {
    _leave();  // fire-and-forget (dispose は await できない)
    super.dispose();
  }

  Future<void> _run() async {
    final midi = widget.midi;
    final bridgeSupported = _linkBefore?.supported ?? false;
    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
      _device.clear();
      _bridge.clear();
      _intervalsSeen.clear();
      _linkAfter = null;
      final ci = _linkBefore?.info?.connInterval;
      if (ci != null && ci > 0) _intervalsSeen.add(ci);
    });
    // 計測中はプローブ自体が生存通知になる。HB を並行させると往復が重なって乱れる。
    midi.stopHeartBeat();

    var consecutiveLost = 0;
    var connLost = false;
    for (var i = 0; i < _probeCount; i++) {
      if (_cancel || !mounted) break;
      final rtt = await midi.measureHeartBeatRtt();
      if (rtt == null) {
        _device.lost++;
        consecutiveLost++;
      } else {
        _device.samples.add(rtt);
        consecutiveLost = 0;
      }
      // ブリッジ単体の往復は 2 回に 1 回だけ挟む (合意 interval の変化も拾う)
      if (bridgeSupported && i.isOdd && !_cancel) {
        // ACK 受信直後 = 接続イベント直後に送ると毎回ほぼ 1 interval 待つ位相に
        // 当たり、往復が 2 interval に偏る (実測で HB より遅く見えた)。HB と同じく
        // ランダムに間を空けて位相を散らす。
        await Future.delayed(
          Duration(milliseconds: _gapMinMs + _rand.nextInt(_gapMaxMs - _gapMinMs + 1)),
        );
        if (_cancel || !mounted) break;
        final r = await midi.queryBridgeLinkInfo();
        final ms = r.rttMs;
        if (ms == null) {
          _bridge.lost++;
        } else {
          _bridge.samples.add(ms);
          final ci = r.info?.connInterval;
          if (ci != null && ci > 0) _intervalsSeen.add(ci);
        }
      }
      if (!mounted) return;
      setState(() => _done = i + 1);
      if (consecutiveLost >= _maxConsecutiveLost) {
        connLost = true;
        break;
      }
      await Future.delayed(
        Duration(milliseconds: _gapMinMs + _rand.nextInt(_gapMaxMs - _gapMinMs + 1)),
      );
    }
    if (!mounted || _leaving) return;
    if (connLost) {
      _onHeartBeatFailure();
      return;
    }
    final after = bridgeSupported ? await midi.queryBridgeLinkInfo() : null;
    if (!mounted || _leaving) return;
    midi.startHeartBeat(onFailure: _onHeartBeatFailure);
    setState(() {
      _linkAfter = after;
      _running = false;
      _measuredAt = DateTime.now();
    });
  }

  // ---------------------------------------------------------------------------
  // 表示
  // ---------------------------------------------------------------------------

  static String _ms(double? v) => v == null ? '-' : '${v.toStringAsFixed(1)} ms';

  BridgeLinkInfoResult? get _link => _linkAfter ?? _linkBefore;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.linkDiagTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.deviceName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              widget.deviceInfo.isBle ? 'Bluetooth' : 'USB',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(l.linkDiagDescription, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 16),
            if (_connecting)
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(l.linkDiagConnecting),
                ],
              )
            else if (_connectFailed)
              Text(
                l.linkDiagConnectFailed,
                style: const TextStyle(color: Colors.redAccent),
              )
            else ...[
              _buildControls(l),
              const SizedBox(height: 16),
              _buildLinkSection(l),
              const SizedBox(height: 16),
              _buildRttSection(l),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildControls(AppLocalizations l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _running
                  ? OutlinedButton.icon(
                      onPressed: () => setState(() => _cancel = true),
                      icon: const Icon(Icons.stop),
                      label: Text(l.linkDiagStop),
                    )
                  : FilledButton.icon(
                      onPressed: _run,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(l.linkDiagStart),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _running || _device.isEmpty ? null : _copyReport,
                icon: const Icon(Icons.copy),
                label: Text(l.linkDiagCopy),
              ),
            ),
          ],
        ),
        if (_running || _done > 0) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _done / _probeCount),
          const SizedBox(height: 4),
          Text(
            l.linkDiagProgress(_done, _probeCount),
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildLinkSection(AppLocalizations l) {
    final link = _link;
    final rows = <Widget>[];
    if (link == null || link.info == null) {
      rows.add(Text(
        widget.deviceInfo.isBle ? l.linkDiagLinkUnsupported : l.linkDiagLinkUsb,
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ));
    } else if (!link.info!.bleLinked) {
      rows.add(Text(
        l.linkDiagLinkUsb,
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ));
    } else {
      final i = link.info!;
      final ciText = _intervalsSeen.length > 1
          ? (_intervalsSeen.toList()..sort())
              .map((v) => (v * 1.25).toStringAsFixed(2))
              .join(' / ')
          : i.connIntervalMs.toStringAsFixed(2);
      rows.addAll([
        _kv(l.linkDiagInterval, '$ciText ms', emphasize: true),
        _kv(
          l.linkDiagRequested,
          '${i.requestedMinMs.toStringAsFixed(2)}–${i.requestedMaxMs.toStringAsFixed(2)} ms'
          ' (${i.updateAccepted ? l.linkDiagAccepted : l.linkDiagNotAccepted})',
        ),
        _kv(l.linkDiagInitialInterval, '${i.initialIntervalMs.toStringAsFixed(2)} ms'),
        _kv(l.linkDiagLatency, '${i.slaveLatency}'),
        _kv(l.linkDiagTimeout, '${i.supervisionTimeoutMs} ms'),
        _kv('MTU', '${i.attMtu}'),
        _kv('PHY', '${BridgeLinkInfo.phyLabel(i.txPhy)} / ${BridgeLinkInfo.phyLabel(i.rxPhy)}'),
        _kv('RSSI', i.rssi == null ? '-' : '${i.rssi} dBm'),
      ]);
    }
    return _section(l.linkDiagLinkSection, rows);
  }

  Widget _buildRttSection(AppLocalizations l) {
    if (_device.isEmpty && _device.lost == 0) {
      return _section(l.linkDiagRttSection, [
        Text(l.linkDiagNotMeasured,
            style: const TextStyle(color: Colors.grey, fontSize: 13)),
      ]);
    }
    return _section(l.linkDiagRttSection, [
      _statsTable(l),
      const SizedBox(height: 12),
      _histogram(l),
      const SizedBox(height: 8),
      Text(l.linkDiagHint, style: const TextStyle(color: Colors.grey, fontSize: 12)),
    ]);
  }

  Widget _statsTable(AppLocalizations l) {
    final hasBridge = !_bridge.isEmpty || _bridge.lost > 0;
    TableRow row(String label, String a, [String? b]) => TableRow(children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Text(a, textAlign: TextAlign.right),
          if (hasBridge) Text(b ?? '', textAlign: TextAlign.right),
        ]);
    return Table(
      columnWidths: const {0: FlexColumnWidth(1.2)},
      children: [
        row('', l.linkDiagColDevice, l.linkDiagColBridge),
        row(l.linkDiagStatMin, _ms(_device.min), _ms(_bridge.min)),
        row(l.linkDiagStatMedian, _ms(_device.percentile(50)), _ms(_bridge.percentile(50))),
        row(l.linkDiagStatAvg, _ms(_device.avg), _ms(_bridge.avg)),
        row('95%', _ms(_device.percentile(95)), _ms(_bridge.percentile(95))),
        row(l.linkDiagStatMax, _ms(_device.max), _ms(_bridge.max)),
        row(l.linkDiagStatLost, '${_device.lost} / ${_device.samples.length + _device.lost}',
            '${_bridge.lost} / ${_bridge.samples.length + _bridge.lost}'),
      ],
    );
  }

  Widget _histogram(AppLocalizations l) {
    final bins = List<int>.filled(_binCount, 0);
    for (final v in _device.samples) {
      bins[min(v ~/ _binMs, _binCount - 1)]++;
    }
    final peak = bins.reduce(max);
    final color = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.linkDiagHistogram, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        for (var b = 0; b < _binCount; b++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    b == _binCount - 1 ? '${b * _binMs}+' : '${b * _binMs}–${(b + 1) * _binMs}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (_, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 12,
                        width: peak == 0 ? 0 : c.maxWidth * bins[b] / peak,
                        color: color,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text('${bins[b]}',
                      textAlign: TextAlign.right, style: const TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v, {bool emphasize = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(k, style: const TextStyle(color: Colors.grey))),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: emphasize ? const TextStyle(fontWeight: FontWeight.bold) : null,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // レポート (開発者へ送ってもらう用。言語に依らず英語の固定書式にする)
  // ---------------------------------------------------------------------------

  Future<void> _copyReport() async {
    final l = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final text = await _buildReport();
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(l.linkDiagCopied)));
  }

  Future<String> _buildReport() async {
    final pkg = await PackageInfo.fromPlatform();
    final id = widget.deviceInfo.identity;
    final b = StringBuffer()
      ..writeln('MimicX link diagnostics')
      ..writeln('date: ${(_measuredAt ?? DateTime.now()).toIso8601String()}')
      ..writeln('app: ${pkg.version}+${pkg.buildNumber}')
      ..writeln('os: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('transport: ${widget.deviceInfo.isBle ? "BLE" : "USB"}')
      ..writeln('device: ${widget.deviceInfo.name}'
          '${id == null ? "" : " fw ${id.firmwareVersion} proto ${id.protocolVersion}"}');

    void link(String tag, BridgeLinkInfoResult? r) {
      if (r == null) return;
      final i = r.info;
      if (i == null) {
        b.writeln('$tag: unsupported (status ${AckStatus.label(r.status)})');
        return;
      }
      if (!i.bleLinked) {
        b.writeln('$tag: no BLE link');
        return;
      }
      b.writeln('$tag: interval ${i.connIntervalMs.toStringAsFixed(2)}ms'
          ' latency ${i.slaveLatency} timeout ${i.supervisionTimeoutMs}ms'
          ' initial ${i.initialIntervalMs.toStringAsFixed(2)}ms'
          ' requested ${i.requestedMinMs.toStringAsFixed(2)}-${i.requestedMaxMs.toStringAsFixed(2)}ms'
          ' (requested=${i.updateRequested} accepted=${i.updateAccepted}'
          ' updates=${i.updateCount} last=${i.lastUpdateStatus ?? "-"})'
          ' mtu ${i.attMtu} phy ${BridgeLinkInfo.phyLabel(i.txPhy)}/${BridgeLinkInfo.phyLabel(i.rxPhy)}'
          ' rssi ${i.rssi ?? "-"}');
    }

    link('link(before)', _linkBefore);
    link('link(after)', _linkAfter);
    if (_intervalsSeen.length > 1) {
      b.writeln('intervals seen: ${(_intervalsSeen.toList()..sort()).map((v) => (v * 1.25).toStringAsFixed(2)).join(", ")}ms');
    }

    void stats(String tag, _RttStats s) {
      if (s.isEmpty && s.lost == 0) return;
      String f(double? v) => v == null ? '-' : v.toStringAsFixed(1);
      b.writeln('$tag: n=${s.samples.length} lost=${s.lost}'
          ' min=${f(s.min)} p50=${f(s.percentile(50))} avg=${f(s.avg)}'
          ' p90=${f(s.percentile(90))} p95=${f(s.percentile(95))}'
          ' p99=${f(s.percentile(99))} max=${f(s.max)} (ms)');
    }

    stats('rtt device (HEART_BEAT)', _device);
    stats('rtt bridge (LINK_INFO)', _bridge);
    if (_device.samples.isNotEmpty) {
      b.writeln('raw device rtt (ms, in order):');
      b.writeln(_device.samples.map((v) => v.toStringAsFixed(1)).join(','));
    }
    return b.toString();
  }
}
