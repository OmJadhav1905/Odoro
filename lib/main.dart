import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double _odoroTimeFontSize = 25;
const double _timerTimeFontSize = 25;
const double _timerWheelFontSize = _timerTimeFontSize;
const double _timerTextWidth = 210;
const double _timerWheelWidth = 210;
const double _timerDigitWidth = 28;
const double _timerDotWidth = 14;
const double _timerWheelItemExtent = 28;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final Future minimumDelay = Future.delayed(
    const Duration(milliseconds: 1000),
  );

  final AudioContext audioContext = AudioContext(
    android: AudioContextAndroid(
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );
  AudioPlayer.global.setAudioContext(audioContext);

  await initializeNotificationService();
  await minimumDelay;

  runApp(const OdoroApp());
}

Future<void> initializeNotificationService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'odoro_visual_timer_channel',
    'Odoro Timer Service',
    description: 'Keeps the Pomodoro timer and audio alive in the background.',
    importance: Importance.low,
    playSound: false,
    enableVibration: false,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartService,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'odoro_visual_timer_channel',
      initialNotificationTitle: 'Odoro',
      initialNotificationContent: '',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

// =======================================================================
// BACKGROUND ENGINE
// =======================================================================
@pragma('vm:entry-point')
void onStartService(ServiceInstance service) async {
  Timer? backgroundTimer;
  Timer? mindfulnessTimer;
  int currentCount = 1500;
  int workMinutes = 25;
  int breakMinutes = 5;
  int timerDurationSeconds = 1500;
  bool isBreakMode = false;
  bool isTimerMode = false;
  String currentTitle = "Focus";

  bool mindfulnessEnabled = false;
  int mindfulnessInterval = 0;
  int lastMindfulnessMinute = -1;

  final AudioPlayer backgroundPlayer = AudioPlayer();

  final AudioContext backgroundAudioContext = AudioContext(
    android: AudioContextAndroid(
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );
  AudioPlayer.global.setAudioContext(backgroundAudioContext);

  String _formatOdoroNotificationTime(int totalSeconds) {
    final mins = totalSeconds ~/ 60;
    final secs = totalSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _formatTimerNotificationTime(int totalSeconds) {
    final totalMinutes = totalSeconds ~/ 60;
    final hours = totalSeconds ~/ 3600;
    final minutes = totalMinutes % 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}.${minutes.toString().padLeft(2, '0')}.${seconds.toString().padLeft(2, '0')}';
  }

  void _updateServiceNotification({
    required String title,
    required String content,
  }) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(title: title, content: content);
    }
  }

  void _updateTimerNotification() {
    _updateServiceNotification(
      title: isTimerMode ? currentTitle : 'Odoro',
      content: isTimerMode
          ? _formatTimerNotificationTime(currentCount)
          : '${currentTitle == "Break" ? "Break" : "Focus"} ${_formatOdoroNotificationTime(currentCount)}',
    );
  }

  void _updateMindfulnessNotification() {
    if (!mindfulnessEnabled || mindfulnessInterval == 0) return;
    _updateServiceNotification(
      title: 'Mindfulness',
      content: 'Bell every $mindfulnessInterval min',
    );
  }

  void _startMindfulnessChecker() {
    mindfulnessTimer?.cancel();
    mindfulnessTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mindfulnessEnabled || mindfulnessInterval == 0) return;

      final now = DateTime.now();
      final currentMinute = now.minute;
      bool shouldRing = false;

      if (mindfulnessInterval == 5) {
        shouldRing = currentMinute % 5 == 0;
      } else if (mindfulnessInterval == 15) {
        shouldRing = currentMinute % 15 == 0;
      } else if (mindfulnessInterval == 30) {
        shouldRing = currentMinute % 30 == 0;
      } else if (mindfulnessInterval == 60) {
        shouldRing = currentMinute == 0;
      }

      if (shouldRing && lastMindfulnessMinute != currentMinute) {
        lastMindfulnessMinute = currentMinute;
        backgroundPlayer.stop().then((_) async {
          final bellPlayer = AudioPlayer();
          await bellPlayer.play(AssetSource('zen_bell.wav'));
          bellPlayer.onPlayerComplete.listen((_) => bellPlayer.dispose());
        });
      } else if (!shouldRing) {
        lastMindfulnessMinute = -1;
      }
    });
  }

  service.on('configureMindfulnessBell').listen((event) {
    if (event != null) {
      mindfulnessEnabled = event['enabled'] ?? false;
      mindfulnessInterval = event['intervalMinutes'] ?? 0;
      lastMindfulnessMinute = -1;

      if (mindfulnessEnabled && mindfulnessInterval > 0) {
        _updateMindfulnessNotification();
        _startMindfulnessChecker();
      } else {
        mindfulnessTimer?.cancel();
      }
    }
  });

  service.on('startTimerWithConfig').listen((event) {
    backgroundTimer?.cancel();

    if (event != null) {
      workMinutes = event['workMinutes'] ?? 25;
      breakMinutes = event['breakMinutes'] ?? 5;
      isTimerMode = event['isTimerMode'] ?? false;
      timerDurationSeconds = event['timerDurationSeconds'] ?? workMinutes * 60;
    }

    isBreakMode = false;
    currentTitle = isTimerMode ? "TIMER" : "Focus";
    currentCount = isTimerMode ? timerDurationSeconds : workMinutes * 60;
    _updateTimerNotification();

    backgroundTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (currentCount > 0) {
        currentCount--;

        service.invoke('timerUpdate', {
          'count': currentCount,
          'title': currentTitle,
          'isBreak': isBreakMode,
        });
        _updateTimerNotification();

        if (currentCount != 0) return;

        backgroundPlayer.stop().then((_) async {
          final bellPlayer = AudioPlayer();
          await bellPlayer.play(AssetSource('zen_bell.wav'));
          bellPlayer.onPlayerComplete.listen((_) => bellPlayer.dispose());
        });

        if (isTimerMode) {
          timer.cancel();
          backgroundTimer = null;
        } else {
          if (!isBreakMode) {
            isBreakMode = true;
            currentTitle = "Break";
            currentCount = breakMinutes * 60;
            _updateTimerNotification();
          } else {
            isBreakMode = false;
            currentTitle = "Focus";
            currentCount = workMinutes * 60;
            _updateTimerNotification();
          }
        }
      }
    });
  });

  service.on('pauseTimer').listen((event) {
    backgroundTimer?.cancel();
    backgroundTimer = null;
  });

  service.on('resumeTimer').listen((event) {
    backgroundTimer?.cancel();
    _updateTimerNotification();

    backgroundTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (currentCount > 0) {
        currentCount--;
        service.invoke('timerUpdate', {
          'count': currentCount,
          'title': currentTitle,
          'isBreak': isBreakMode,
        });
        _updateTimerNotification();
        if (currentCount == 0) {
          backgroundPlayer.stop().then((_) async {
            final bellPlayer = AudioPlayer();
            await bellPlayer.play(AssetSource('zen_bell.wav'));
            bellPlayer.onPlayerComplete.listen((_) => bellPlayer.dispose());
          });
          timer.cancel();
          backgroundTimer = null;
        }
      }
    });
  });

  service.on('stopService').listen((event) {
    backgroundTimer?.cancel();
    mindfulnessTimer?.cancel();
    backgroundPlayer.dispose();
    service.stopSelf();
  });
}

class OdoroApp extends StatelessWidget {
  const OdoroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PomodoroRoot(),
    );
  }
}

class PomodoroRoot extends StatefulWidget {
  const PomodoroRoot({super.key});

  @override
  State<PomodoroRoot> createState() => _PomodoroRootState();
}

class _PomodoroRootState extends State<PomodoroRoot> {
  String _titleText = "Odoro";
  int _workMinutes = 25;
  int _breakMinutes = 5;
  int _count = 1500;
  bool _isBackgroundRunning = false;
  bool _isPaused = false;
  bool _isTimerMode = false;
  bool _isSettingTimer = false;
  bool _isLightMode = false;
  int _timerDuration = 1500;
  bool _isMindfulnessEnabled = false;
  int _mindfulnessInterval = 0;

  late FixedExtentScrollController _hourTensController;
  late FixedExtentScrollController _hourOnesController;
  late FixedExtentScrollController _minuteTensController;
  late FixedExtentScrollController _minuteOnesController;
  late FixedExtentScrollController _secondTensController;
  late FixedExtentScrollController _secondOnesController;
  StreamSubscription? _serviceSubscription;

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isLightMode = prefs.getBool('isLightMode') ?? false;
    });
  }

  Future<void> _saveTheme(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLightMode', value);
  }

  @override
  void initState() {
    super.initState();
    _count = _workMinutes * 60;
    _loadTheme();
    _setTimerWheelControllers(_timerDuration);
    _listenToBackgroundService();
  }

  void _setTimerWheelControllers(int totalSeconds) {
    final safeSeconds = totalSeconds.clamp(1, 359999);
    final hours = safeSeconds ~/ 3600;
    final minutes = (safeSeconds % 3600) ~/ 60;
    final seconds = safeSeconds % 60;
    _hourTensController = FixedExtentScrollController(initialItem: hours ~/ 10);
    _hourOnesController = FixedExtentScrollController(initialItem: hours % 10);
    _minuteTensController = FixedExtentScrollController(
      initialItem: minutes ~/ 10,
    );
    _minuteOnesController = FixedExtentScrollController(
      initialItem: minutes % 10,
    );
    _secondTensController = FixedExtentScrollController(
      initialItem: seconds ~/ 10,
    );
    _secondOnesController = FixedExtentScrollController(
      initialItem: seconds % 10,
    );
  }

  void _listenToBackgroundService() async {
    final service = FlutterBackgroundService();
    _serviceSubscription = service.on('timerUpdate').listen((event) {
      if (event != null && mounted) {
        setState(() {
          _count = event['count'];
          _titleText = event['title'];
          _isBackgroundRunning = true;
        });
      }
    });
  }

  void _startTimer() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();
    if (!isRunning) await service.startService();

    if (_isTimerMode) {
      if (_isSettingTimer) _confirmTimerValue();
      service.invoke('startTimerWithConfig', {
        'workMinutes': _timerDuration ~/ 60,
        'breakMinutes': 0,
        'isTimerMode': true,
        'timerDurationSeconds': _timerDuration,
      });
      service.invoke('configureMindfulnessBell', {
        'enabled': _isMindfulnessEnabled,
        'intervalMinutes': _mindfulnessInterval,
      });
      setState(() {
        _titleText = "TIMER";
        _count = _timerDuration;
        _isBackgroundRunning = true;
        _isSettingTimer = false;
      });
    } else {
      service.invoke('startTimerWithConfig', {
        'workMinutes': _workMinutes,
        'breakMinutes': _breakMinutes,
        'isTimerMode': false,
      });
      service.invoke('configureMindfulnessBell', {
        'enabled': _isMindfulnessEnabled,
        'intervalMinutes': _mindfulnessInterval,
      });
      setState(() {
        _titleText = "Focus";
        _count = _workMinutes * 60;
        _isBackgroundRunning = true;
      });
    }
  }

  void _pauseTimer() {
    final service = FlutterBackgroundService();
    service.invoke('pauseTimer');
    setState(() {
      _isBackgroundRunning = false;
      _isPaused = true;
    });
  }

  void _resumeTimer() {
    final service = FlutterBackgroundService();
    service.invoke('resumeTimer');
    setState(() {
      _isBackgroundRunning = true;
      _isPaused = false;
    });
  }

  void _resetTimer() {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
    setState(() {
      _isBackgroundRunning = false;
      _isPaused = false;
      if (_isTimerMode) {
        _titleText = "TIMER";
        _count = _timerDuration;
        _isSettingTimer = true;
        final s = _timerDuration;
        final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
        _hourTensController.jumpToItem(h ~/ 10);
        _hourOnesController.jumpToItem(h % 10);
        _minuteTensController.jumpToItem(m ~/ 10);
        _minuteOnesController.jumpToItem(m % 10);
        _secondTensController.jumpToItem(sec ~/ 10);
        _secondOnesController.jumpToItem(sec % 10);
      } else {
        _titleText = "Odoro";
        _count = _workMinutes * 60;
        _isSettingTimer = false;
      }
    });
  }

  void _changeOdoroDuration(int work, int breakTime) {
    final service = FlutterBackgroundService();
    if (_isBackgroundRunning) service.invoke('stopService');
    setState(() {
      _isBackgroundRunning = false;
      _isTimerMode = false;
      _isSettingTimer = false;
      _workMinutes = work;
      _breakMinutes = breakTime;
      _titleText = "Odoro";
      _count = _workMinutes * 60;
    });
  }

  void _enterTimerMode() {
    final service = FlutterBackgroundService();
    if (_isBackgroundRunning) service.invoke('stopService');
    setState(() {
      _isBackgroundRunning = false;
      _isTimerMode = true;
      _isSettingTimer = true;
      _titleText = "TIMER";
      _count = _timerDuration;
    });
  }

  void _confirmTimerValue() {
    final totalSeconds = _selectedTimerSeconds();
    setState(() {
      _timerDuration = totalSeconds > 0 ? totalSeconds : 1;
      _count = _timerDuration;
      _isSettingTimer = false;
      _titleText = "TIMER";
    });
  }

  int _selectedTimerSeconds() {
    final hours =
        _hourTensController.selectedItem * 10 +
        _hourOnesController.selectedItem;
    final minutes =
        _minuteTensController.selectedItem * 10 +
        _minuteOnesController.selectedItem;
    final seconds =
        _secondTensController.selectedItem * 10 +
        _secondOnesController.selectedItem;
    return hours * 3600 + minutes * 60 + seconds;
  }

  void _updateTimerFromWheels() {
    final totalSeconds = _selectedTimerSeconds();
    setState(() {
      _timerDuration = totalSeconds > 0 ? totalSeconds : 1;
      _count = _timerDuration;
    });
  }

  void _enableMindfulnessBell(int intervalMinutes) async {
    final service = FlutterBackgroundService();

    setState(() {
      if (_isMindfulnessEnabled && _mindfulnessInterval == intervalMinutes) {
        _isMindfulnessEnabled = false;
        _mindfulnessInterval = 0;
      } else {
        _isMindfulnessEnabled = true;
        _mindfulnessInterval = intervalMinutes;
      }
    });

    if (_isMindfulnessEnabled && !await service.isRunning()) {
      await service.startService();
    }

    service.invoke('configureMindfulnessBell', {
      'enabled': _isMindfulnessEnabled,
      'intervalMinutes': _mindfulnessInterval,
    });

    if (!_isMindfulnessEnabled && !_isBackgroundRunning) {
      service.invoke('stopService');
    }
  }

  // Returns a minimal label if mindfulness is on — no emoji, just clean text
  String _formatTime(int totalSeconds) {
    if (_isTimerMode) {
      final totalMinutes = totalSeconds ~/ 60;
      final hours = totalSeconds ~/ 3600;
      final minutes = totalMinutes % 60;
      final seconds = totalSeconds % 60;
      return '${hours.toString().padLeft(2, '0')}.${minutes.toString().padLeft(2, '0')}.${seconds.toString().padLeft(2, '0')}';
    } else {
      int mins = totalSeconds ~/ 60;
      int secs = totalSeconds % 60;
      return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
  }

  @override
  void dispose() {
    _serviceSubscription?.cancel();
    _hourTensController.dispose();
    _hourOnesController.dispose();
    _minuteTensController.dispose();
    _minuteOnesController.dispose();
    _secondTensController.dispose();
    _secondOnesController.dispose();
    super.dispose();
  }

  // =======================================================================
  // LAYERED MENU — anchored to the 3-dot icon
  // =======================================================================

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final result = await showMenu<String>(
      context: context,
      color: const Color(0xFF111111),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy - 80,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        _popupItem('odoro', 'Odoro', hasArrow: true),
        _popupDivider(),
        _popupItem('timer', 'Timer'),
        _popupDivider(),
        _popupItem('mindfulness', 'Mindfulness Bell', hasArrow: true),
        _popupItem('theme', _isLightMode ? 'Dark Mode' : 'Light Mode'),
      ],
    );

    if (!mounted) return;
    if (result == 'odoro') _showOdoroSubmenu(context, position);
    if (result == 'timer') _enterTimerMode();
    if (result == 'mindfulness') _showMindfulnessSubmenu(context, position);
    if (result == 'theme') {
      final newValue = !_isLightMode;
      setState(() => _isLightMode = newValue);
      _saveTheme(newValue);
    }
  }

  Future<void> _showOdoroSubmenu(BuildContext context, Offset position) async {
    final result = await showMenu<String>(
      context: context,
      color: const Color(0xFF111111),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        _popupItem('4-1', '4 — 1  min'),
        _popupDivider(),
        _popupItem('25-5', '25 — 5  min'),
        _popupDivider(),
        _popupItem('50-10', '50 — 10  min'),
      ],
    );
    if (!mounted) return;
    if (result == '4-1') _changeOdoroDuration(4, 1);
    if (result == '25-5') _changeOdoroDuration(25, 5);
    if (result == '50-10') _changeOdoroDuration(50, 10);
  }

  Future<void> _showMindfulnessSubmenu(
    BuildContext context,
    Offset position,
  ) async {
    // Mindfulness needs live toggle state — use a StatefulBuilder workaround
    // by re-calling showMenu each time a toggle fires
    _showMindfulnessMenu(context, position);
  }

  void _showMindfulnessMenu(BuildContext context, Offset position) async {
    final intervals = [5, 15, 30, 60];
    final labels = ['5 min', '15 min', '30 min', '1 hour'];

    final result = await showMenu<int>(
      context: context,
      color: const Color(0xFF111111),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        for (int i = 0; i < intervals.length; i++) ...[
          if (i > 0) _popupDivider(),
          PopupMenuItem<int>(
            value: intervals[i],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  labels[i],
                  style: const TextStyle(
                    color: Color(0xFF777777),
                    fontFamily: 'Arial',
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Switch(
                  value:
                      _isMindfulnessEnabled &&
                      _mindfulnessInterval == intervals[i],
                  onChanged: null, // tap the row to toggle
                  activeColor: Colors.white,
                  activeTrackColor: Colors.white,
                  inactiveThumbColor: Colors.grey[800],
                  inactiveTrackColor: Colors.grey[900],
                ),
              ],
            ),
          ),
        ],
      ],
    );

    if (!mounted || !context.mounted) return;
    if (result != null) {
      _enableMindfulnessBell(result);
      // Re-open so user can see the updated toggle state and toggle others
      if (!mounted || !context.mounted) return;
      _showMindfulnessMenu(context, position);
    }
  }

  PopupMenuItem<String> _popupItem(
    String value,
    String label, {
    bool hasArrow = false,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF777777),
              fontFamily: 'Arial',
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (hasArrow)
            const Icon(Icons.chevron_right, color: Color(0xFF444444), size: 16),
        ],
      ),
    );
  }

  PopupMenuItem<T> _popupDivider<T>() {
    return PopupMenuItem<T>(
      enabled: false,
      height: 1,
      padding: EdgeInsets.zero,
      child: const Divider(
        height: 1,
        thickness: 1,
        color: Color(0xFF111111),
        indent: 14,
        endIndent: 14,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: _isLightMode ? Colors.white : Colors.black,
      body: Container(
        width: screenSize.width,
        height: screenSize.height,
        color: _isLightMode ? Colors.white : Colors.black,
        child: Stack(
          children: [
            // 1. Title / mindfulness label
            Align(
              alignment: const Alignment(0, -0.8),
              child: Text(
                _titleText.toUpperCase(),
                style: TextStyle(
                  fontFamily: 'Orbitron',
                  fontSize: 45,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w900,
                  color: _isLightMode
                      ? const Color.fromARGB(255, 197, 197, 197)
                      : const Color(0xFF1E1E1E),
                ),
              ),
            ),

            // 2. Apple logo image
            Positioned(
              top: 60,
              left: -50,
              right: -50,
              bottom: 100,
              child: Image.asset(
                _isLightMode
                    ? 'assets/applelogo_light.webp'
                    : 'assets/applelogo.webp',
                fit: BoxFit.contain,
              ),
            ),

            // 3. Timer display / edit field
            Align(
              alignment: const Alignment(-0.02, -0.05),
              child: _isSettingTimer && !_isBackgroundRunning
                  ? _TimerWheelSetter(
                      hourTensController: _hourTensController,
                      hourOnesController: _hourOnesController,
                      minuteTensController: _minuteTensController,
                      minuteOnesController: _minuteOnesController,
                      secondTensController: _secondTensController,
                      secondOnesController: _secondOnesController,
                      onChanged: _updateTimerFromWheels,
                      isLightMode: _isLightMode,
                    )
                  : GestureDetector(
                      onTap: _isTimerMode && !_isBackgroundRunning
                          ? _enterTimerMode
                          : null,
                      child: _isTimerMode
                          ? SizedBox(
                              width: _timerTextWidth,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _formatTime(_count),
                                  style: TextStyle(
                                    fontFamily: 'Orbitron',
                                    fontSize: _timerTimeFontSize,
                                    fontWeight: FontWeight.bold,
                                    color: _isLightMode
                                        ? const Color.fromARGB(255, 32, 32, 32)
                                        : const Color(0xFFFFFFFF),
                                  ),
                                ),
                              ),
                            )
                          : Text(
                              _formatTime(_count),
                              style: TextStyle(
                                fontFamily: 'Orbitron',
                                fontSize: _odoroTimeFontSize,
                                fontWeight: FontWeight.bold,
                                color: _isLightMode
                                    ? Colors.black
                                    : const Color(0xFFFFFFFF),
                              ),
                            ),
                    ),
            ),

            // 4. Start / Reset buttons
            Align(
              alignment: const Alignment(0, 0.74),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!_isBackgroundRunning && !_isPaused)
                    _buildButton("Start", _startTimer),
                  if (_isBackgroundRunning) _buildButton("Pause", _pauseTimer),
                  if (_isPaused) _buildButton("Resume", _resumeTimer),
                  const SizedBox(width: 90),
                  _buildButton("Reset", _resetTimer),
                ],
              ),
            ),

            // 5. Minimal three-dot menu — now opens layered bottom sheet
            // 5. Three-dot menu — anchored to tap position
            Positioned(
              top: 25,
              right: 10,
              child: GestureDetector(
                onTapUp: (details) =>
                    _showMenu(context, details.globalPosition),
                child: SizedBox(
                  width: 68,
                  height: 68,
                  child: Center(
                    child: Icon(
                      Icons.more_vert,
                      color: _isLightMode
                          ? const Color.fromARGB(255, 180, 180, 180)
                          : const Color.fromARGB(255, 41, 41, 41),
                      size: 28,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback action) {
    return TextButton(
      onPressed: action,
      style: TextButton.styleFrom(
        backgroundColor: _isLightMode ? Colors.white : Colors.black,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: _isLightMode
              ? const Color.fromARGB(255, 204, 204, 204)
              : const Color(0xFF1E1E1E),
          fontSize: 17,
          fontWeight: FontWeight.w900,
          fontFamily: 'Orbitron',
        ),
      ),
    );
  }
}

class _TimerWheelSetter extends StatelessWidget {
  final FixedExtentScrollController hourTensController;
  final FixedExtentScrollController hourOnesController;
  final FixedExtentScrollController minuteTensController;
  final FixedExtentScrollController minuteOnesController;
  final FixedExtentScrollController secondTensController;
  final FixedExtentScrollController secondOnesController;
  final VoidCallback onChanged;
  final bool isLightMode;

  const _TimerWheelSetter({
    required this.hourTensController,
    required this.hourOnesController,
    required this.minuteTensController,
    required this.minuteOnesController,
    required this.secondTensController,
    required this.secondOnesController,
    required this.onChanged,
    required this.isLightMode,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _timerWheelWidth,
      height: 92,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _TimerDigitWheel(
            controller: hourTensController,
            onChanged: onChanged,
            isLightMode: isLightMode,
          ),
          _TimerDigitWheel(
            controller: hourOnesController,
            onChanged: onChanged,
            isLightMode: isLightMode,
          ),
          const _TimerDot(),
          _TimerDigitWheel(
            controller: minuteTensController,
            maxDigit: 5,
            onChanged: onChanged,
            isLightMode: isLightMode,
          ),
          _TimerDigitWheel(
            controller: minuteOnesController,
            onChanged: onChanged,
            isLightMode: isLightMode,
          ),
          const _TimerDot(),
          _TimerDigitWheel(
            controller: secondTensController,
            maxDigit: 5,
            onChanged: onChanged,
            isLightMode: isLightMode,
          ),
          _TimerDigitWheel(
            controller: secondOnesController,
            onChanged: onChanged,
            isLightMode: isLightMode,
          ),
        ],
      ),
    );
  }
}

class _TimerDigitWheel extends StatefulWidget {
  final FixedExtentScrollController controller;
  final int maxDigit;
  final VoidCallback onChanged;
  final bool isLightMode;

  const _TimerDigitWheel({
    required this.controller,
    required this.onChanged,
    required this.isLightMode,
    this.maxDigit = 9,
  });

  @override
  State<_TimerDigitWheel> createState() => _TimerDigitWheelState();
}

class _TimerDigitWheelState extends State<_TimerDigitWheel> {
  late int _selectedDigit;

  @override
  void initState() {
    super.initState();
    _selectedDigit = widget.controller.initialItem;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _timerDigitWidth,
      child: CupertinoPicker.builder(
        scrollController: widget.controller,
        itemExtent: _timerWheelItemExtent,
        diameterRatio: 1.35,
        magnification: 1,
        squeeze: 0.9,
        useMagnifier: false,
        selectionOverlay: const SizedBox.shrink(),
        onSelectedItemChanged: (index) {
          setState(() => _selectedDigit = index);
          widget.onChanged();
        },
        childCount: widget.maxDigit + 1,
        itemBuilder: (context, index) {
          return Center(
            child: Text(
              '$index',
              style: TextStyle(
                fontFamily: 'Orbitron',
                fontSize: _timerWheelFontSize,
                fontWeight: FontWeight.bold,
                color: index == _selectedDigit
                    ? (widget.isLightMode
                          ? const Color.fromARGB(255, 121, 121, 121)
                          : const Color(0xFFC8C8C8))
                    : (widget.isLightMode
                          ? const Color(0xFFCCCCCC)
                          : const Color(0xFF303030)),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ? const Color(0xFFC8C8C8)
// : const Color(0xFF303030),

class _TimerDot extends StatelessWidget {
  const _TimerDot();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: _timerDotWidth,
      child: Center(
        child: Text(
          '.',
          style: TextStyle(
            fontFamily: 'Orbitron',
            fontSize: _timerWheelFontSize,
            fontWeight: FontWeight.bold,
            color: Color(0xFFC8C8C8),
          ),
        ),
      ),
    );
  }
}
