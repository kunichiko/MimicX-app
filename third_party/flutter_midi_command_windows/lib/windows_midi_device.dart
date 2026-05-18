import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:win32/win32.dart';

import 'flutter_midi_command_windows.dart';


const _numberOfBuffers = 4;

class WindowsMidiDevice extends MidiDevice {
  Map<int, MIDIINCAPS> _ins = {};
  Map<int, MIDIOUTCAPS> _outs = {};

  StreamController<MidiPacket> _rxStreamCtrl;
  StreamController<String> _setupStreamController;

  final hMidiInDevicePtr = malloc<HMIDIIN>();
  final hMidiOutDevicePtr = malloc<IntPtr>();

  int callbackAddress;

  final _bufferSize = 8192;

  List<Pointer<MIDIHDR>> _midiInHeaders = List.generate(_numberOfBuffers, (index) => nullptr);
  List<Pointer<BYTE>> _midiInBuffers = List.generate(_numberOfBuffers, (index) => nullptr);

  Pointer<MIDIHDR> _midiOutHeader = nullptr;
  Pointer<BYTE> _midiOutBuffer = nullptr;

  WindowsMidiDevice(String id, String name, this._rxStreamCtrl,
      this._setupStreamController, this.callbackAddress)
      : super(id, name, 'native', false);

  /// Connect to the device, ie. open input and output ports
  /// NOTE: Currently only the first input/output port is considered
  bool connect() {
    // Open input

    var mIn = _ins.entries.firstOrNull;
    if (mIn != null) {
      var id = mIn.key;
      int result = midiInOpen(
          hMidiInDevicePtr, id, callbackAddress, 0, CALLBACK_FUNCTION);
      if (result != 0) {
        print("OPEN ERROR($result): ${midiErrorMessage(result)}");
        return false;
      } else {
        // Setup buffer
        for (int i = 0; i < _numberOfBuffers; i++) {
          _midiInBuffers[i] = malloc<BYTE>(_bufferSize);
          _midiInHeaders[i] = malloc<MIDIHDR>();
          _midiInHeaders[i].ref.lpData = _midiInBuffers[i] as LPSTR;
          _midiInHeaders[i].ref.dwBufferLength = _bufferSize;
          _midiInHeaders[i].ref.dwFlags = 0;
          _midiInHeaders[i].ref.dwBytesRecorded = 0;

          result = midiInPrepareHeader(
              hMidiInDevicePtr.value, _midiInHeaders[i], sizeOf<MIDIHDR>());
          if (result != 0) {
            print("HDR PREP ERROR: ${midiErrorMessage(result)}");
            return false;
          }

          result = midiInAddBuffer(
              hMidiInDevicePtr.value, _midiInHeaders[i], sizeOf<MIDIHDR>());
          if (result != 0) {
            print("HDR ADD ERROR: ${midiErrorMessage(result)}");
            return false;
          }
        }

        result = midiInStart(hMidiInDevicePtr.value);
        if (result != 0) {
          print("START ERROR: ${midiErrorMessage(result)}");
          return false;
        }
      }
    }

    // Open output
    var mOut = _outs.entries.firstOrNull;
    if (mOut != null) {
      var id = mOut.key;

      int result = midiOutOpen(hMidiOutDevicePtr, id, 0, 0, CALLBACK_NULL);
      if (result != 0) {
        print("OUT OPEN ERROR: result");
        return false;
      }

      _midiOutBuffer = malloc<BYTE>(_bufferSize);
      _midiOutHeader = malloc<MIDIHDR>();
    }
    connected = true;
    _setupStreamController.add("deviceConnected");
    return true;
  }

  bool _disconnected = false;

  bool disconnect() {
    // 二重 disconnect を禁止 (ハンドルや MIDIHDR は close 後に同じ HMIDIIN
    // 値が別ドライバ用に再利用されることがあり、midiInStop 等を再投入すると
    // 別デバイスのバッファに触ってヒープを壊す)。
    if (_disconnected) return true;
    _disconnected = true;

    int result;
    if (_ins.length > 0) {
      // winmm の正しい片付け順序:
      //   1. midiInReset    -- ドライバキューに残る MHDR_DONE を吐き切らせる
      //   2. midiInStop     -- 入力停止
      //   3. midiInUnprepareHeader -- ヘッダ解除 (まだ free しない)
      //   4. midiInClose    -- ハンドル close (ここまでドライバが触る可能性)
      //   5. ヘッダ / バッファを free
      // 元実装は Stop / Close より先に free していて、winmm ワーカ
      // スレッドが解放済みバッファに書き込むとヒープが壊れ
      // STATUS_HEAP_CORRUPTION (0xC0000374) で落ちていた。
      result = midiInReset(hMidiInDevicePtr.value);
      if (result != 0) {
        print("RESET ERROR($result): ${midiErrorMessage(result)}");
      }

      result = midiInStop(hMidiInDevicePtr.value);
      if (result != 0) {
        print("STOP ERROR($result): ${midiErrorMessage(result)}");
      }

      for (int i = 0; i < _numberOfBuffers; i++) {
        if (_midiInHeaders[i] != nullptr) {
          midiInUnprepareHeader(
              hMidiInDevicePtr.value, _midiInHeaders[i], sizeOf<MIDIHDR>());
        }
      }

      result = midiInClose(hMidiInDevicePtr.value);
      if (result != 0) {
        print("CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }

      for (int i = 0; i < _numberOfBuffers; i++) {
        if (_midiInHeaders[i] != nullptr) {
          free(_midiInHeaders[i]);
          _midiInHeaders[i] = nullptr;
        }
        if (_midiInBuffers[i] != nullptr) {
          free(_midiInBuffers[i]);
          _midiInBuffers[i] = nullptr;
        }
      }

      free(hMidiInDevicePtr);
    }

    if (_outs.length > 0) {
      // 出力側も Reset (pending msg を fail させて完了) → Close → free の順。
      midiOutReset(hMidiOutDevicePtr.value);
      result = midiOutClose(hMidiOutDevicePtr.value);
      if (result != 0) {
        print("OUT CLOSE ERROR($result): ${midiErrorMessage(result)}");
      }
      free(hMidiOutDevicePtr);

      // _midiOutBuffer / _midiOutHeader は _outs.length > 0 のときだけ
      // connect() で malloc されるので、ここでだけ free する。
      if (_midiOutBuffer != nullptr) {
        free(_midiOutBuffer);
        _midiOutBuffer = nullptr;
      }
      if (_midiOutHeader != nullptr) {
        free(_midiOutHeader);
        _midiOutHeader = nullptr;
      }
    }

    connected = false;
    return true;
  }

  addInput(int id, MIDIINCAPS input) {
    _ins[id] = input;
    inputPorts.add(MidiPort(input.wPid, MidiPortType.IN));
  }

  addOutput(int id, MIDIOUTCAPS output) {
    _outs[id] = output;
    outputPorts.add(MidiPort(output.wPid, MidiPortType.OUT));
  }

  containsMidiIn(int input) => hMidiInDevicePtr.value == input;

  _resetHeader(Pointer<MIDIHDR> midiHdrPointer) {
    midiInAddBuffer(hMidiInDevicePtr.value, midiHdrPointer, sizeOf<MIDIHDR>());
  }

  handleData(Uint8List data, int timestamp) {
    // print('handle data $data');
    _rxStreamCtrl.add(MidiPacket(data, timestamp, this));
  }

  handleSysexData(Uint8List data, Pointer<MIDIHDR> midiHdrPointer) {
    // print('handle SysEX: $data');
    _rxStreamCtrl.add(MidiPacket(data, 0, this));
    _resetHeader(midiHdrPointer);
  }

  send(Uint8List data) async {
    if (data.isEmpty) return;
    // チャネルメッセージ (3 バイト以下、status MSB が 0xF0 ではない) は同期
    // API の midiOutShortMsg で送る。midiOutLongMsg は非同期で、ドライバが
    // 読み終わる前に Unprepare → 次の send で同じバッファを書き換える race
    // が起きて winmmbase 内部でアクセス違反するため、短メッセージはこちら
    // に寄せる (MimicX で SHIFT+A 等のキー入力直後にクラッシュしていた問題
    // の根治)。
    // System common / real-time (0xF1-0xFF) も 1-3 バイトなので同経路で送る。
    final status = data.first;
    if (status != 0xF0 && data.length <= 3) {
      int dwMsg = 0;
      for (int i = 0; i < data.length; i++) {
        dwMsg |= (data[i] & 0xFF) << (i * 8);
      }
      final r = midiOutShortMsg(hMidiOutDevicePtr.value, dwMsg);
      if (r != 0) {
        print("SHORT SEND ERROR($r): ${midiErrorMessage(r)}");
      }
      return;
    }

    // SysEx 等の long message: バッファ経由で非同期送信する。
    // 注: midiOutLongMsg は非同期なので、本来は MHDR_DONE まで待ってから
    // Unprepare すべき。連続送信頻度が低い (IDENTIFY/SET_CONFIG 等のみ)
    // なので現状はオリジナル実装の挙動を踏襲する。
    _midiOutBuffer.asTypedList(data.length).setAll(0, data);
    _midiOutHeader.ref.lpData = _midiOutBuffer as LPSTR;
    _midiOutHeader.ref.dwBytesRecorded =
        _midiOutHeader.ref.dwBufferLength = data.length;
    _midiOutHeader.ref.dwFlags = 0;

    int result = midiOutPrepareHeader(
        hMidiOutDevicePtr.value, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("HDR OUT PREP ERROR: ${midiErrorMessage(result)}");
    }

    result = midiOutLongMsg(
        hMidiOutDevicePtr.value, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("SEND ERROR($result): ${midiErrorMessage(result)}");
    }

    result = midiOutUnprepareHeader(
        hMidiOutDevicePtr.value, _midiOutHeader, sizeOf<MIDIHDR>());
    if (result != 0) {
      print("OUT UNPREPARE ERROR($result): ${midiErrorMessage(result)}");
    }
  }
}
