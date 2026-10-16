import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:vol_spotter/vol_spotter.dart';

/// Watches for a Volume Up double-press and triggers the emergency call flow.
///
/// Behaviour when triggered:
///   1. Vibrate 3 times as tactile confirmation
///   2. Show a full-screen 3-second countdown overlay with a Cancel button
///   3. If not cancelled, dial the number DIRECTLY (no dialer, no user tap)
class EmergencyTrigger {
  EmergencyTrigger._();
  static final EmergencyTrigger instance = EmergencyTrigger._();

  final VolSpotter _volSpotter = const VolSpotter();
  StreamSubscription<ButtonEvent>? _sub;
  DateTime? _lastVolumeUp;
  bool _active = false;
  bool _started = false;

  static const Duration _doublePressWindow = Duration(milliseconds: 700);
  static const int _countdownSeconds = 3;

  bool get isRunning => _started;

  Future<void> start({
    required BuildContext Function() contextProvider,
    required String Function() getNumber,
  }) async {
    if (_started) return;
    _started = true;

    try {
      await _volSpotter.startListening(
        config: const VolSpotterConfig(interceptVolumeEvents: true),
      );
    } catch (_) {
      _started = false;
      return;
    }

    _sub = _volSpotter.buttonEvents.listen((event) {
      if (_active) return;
      if (event.action is! ButtonPressed) return;
      if (event.button is! VolumeUpButton) return;

      final now = DateTime.now();
      final last = _lastVolumeUp;
      _lastVolumeUp = now;

      if (last == null) return;
      if (now.difference(last) > _doublePressWindow) return;

      _lastVolumeUp = null;
      _trigger(contextProvider, getNumber);
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _volSpotter.stopListening();
    } catch (_) {}
    _started = false;
  }

  Future<void> _trigger(
    BuildContext Function() contextProvider,
    String Function() getNumber,
  ) async {
    _active = true;

    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 200, 100, 200, 100, 200]);
      }
    } catch (_) {}

    final ctx = contextProvider();
    if (!ctx.mounted) {
      _active = false;
      return;
    }

    final cancelled = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _EmergencyCountdownDialog(
        seconds: _countdownSeconds,
        number: getNumber(),
      ),
    );

    _active = false;
    if (cancelled == true) return;

    final number = getNumber();
    if (number.isEmpty) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text('Emergency number is not configured.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    // --- DIRECT CALL: no dialer, no user tap (Android only) ---
    if (Platform.isAndroid) {
      try {
        final ok = await FlutterPhoneDirectCaller.callNumber(number);
        if (ok != true) {
          // Fallback to dialer if direct call is refused
          await _fallbackDialer(number);
        }
        return;
      } catch (_) {
        await _fallbackDialer(number);
        return;
      }
    }

    // --- iOS and others: open the dialer ---
    await _fallbackDialer(number);
  }

  Future<void> _fallbackDialer(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    try {
      await launchUrl(uri);
    } catch (_) {}
  }
}

class _EmergencyCountdownDialog extends StatefulWidget {
  const _EmergencyCountdownDialog({
    required this.seconds,
    required this.number,
  });

  final int seconds;
  final String number;

  @override
  State<_EmergencyCountdownDialog> createState() =>
      _EmergencyCountdownDialogState();
}

class _EmergencyCountdownDialogState extends State<_EmergencyCountdownDialog> {
  late int _left;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _left = widget.seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= 1) {
        _timer?.cancel();
        Navigator.of(context).pop(false);
      } else {
        setState(() => _left--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sos, size: 64, color: Color(0xFFE15712)),
            const SizedBox(height: 12),
            const Text(
              'Calling Emergency',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              widget.number.isEmpty ? '(no number configured)' : widget.number,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            TweenAnimationBuilder<double>(
              key: ValueKey(_left),
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(seconds: 1),
              builder: (context, value, child) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 90,
                      height: 90,
                      child: CircularProgressIndicator(
                        value: value,
                        strokeWidth: 6,
                        backgroundColor: const Color(0xFFF1F5F9),
                        valueColor:
                            const AlwaysStoppedAnimation(Color(0xFFE15712)),
                      ),
                    ),
                    Text(
                      '$_left',
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE15712),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () {
                  _timer?.cancel();
                  Navigator.of(context).pop(true);
                },
                child: const Text(
                  'CANCEL',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Release now to cancel the emergency call',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
