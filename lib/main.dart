import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final Future minimumDelay = Future.delayed(const Duration(milliseconds: 1000));

  // Prime global audio layer
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
    'odoro_timer_channel',
    'Odoro Timer Service',
    description: 'Keeps the Pomodoro timer and audio alive in the background.',
    importance: Importance.max, // Maxed out importance to tell OS not to kill it
    playSound: true,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartService,
      autoStart: false, // Changed to false: we start it precisely when user presses START
      isForegroundMode: true,
      notificationChannelId: 'odoro_timer_channel',
      initialNotificationTitle: 'Odoro Focus Session',
      initialNotificationContent: 'Your timer is tracking in the background...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

// =======================================================================
// BULLETPROOF BACKGROUND ENGINE (Runs on separate isolate)
// =======================================================================
@pragma('vm:entry-point')
void onStartService(ServiceInstance service) async {
  Timer? backgroundTimer;
  int currentCount = 1500; // Default 25 min fallback
  int workMinutes = 25;
  int breakMinutes = 5;
  bool isBreakMode = false;
  String currentTitle = "Work";

  final AudioPlayer backgroundPlayer = AudioPlayer();

  // Set up background isolate audio rules
  final AudioContext backgroundAudioContext = AudioContext(
    android: AudioContextAndroid(
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );
  AudioPlayer.global.setAudioContext(backgroundAudioContext);

  // Listen for setup configuration parameters from UI layer
  service.on('startTimerWithConfig').listen((event) {
    backgroundTimer?.cancel();
    
    if (event != null) {
      workMinutes = event['workMinutes'] ?? 25;
      breakMinutes = event['breakMinutes'] ?? 5;
    }
    
    isBreakMode = false;
    currentTitle = "Work";
    currentCount = workMinutes * 60;

    backgroundTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (currentCount > 0) {
        currentCount--;
      } else {
        // Fire Zen Bell flawlessly inside background thread context
        backgroundPlayer.stop().then((_) {
          backgroundPlayer.play(AssetSource('zen_bell.wav'));
        });

        if (!isBreakMode) {
          isBreakMode = true;
          currentTitle = "Break";
          currentCount = breakMinutes * 60;
        } else {
          isBreakMode = false;
          currentTitle = "Work";
          currentCount = workMinutes * 60;
        }
      }

      // Stream the ticker up to UI and persistent notification banner info
      service.invoke('timerUpdate', {
        'count': currentCount,
        'title': currentTitle,
        'isBreak': isBreakMode,
      });
    });
  });

  service.on('stopService').listen((event) {
    backgroundTimer?.cancel();
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
  StreamSubscription? _serviceSubscription;

  @override
  void initState() {
    super.initState();
    _count = _workMinutes * 60;
    _listenToBackgroundService();
  }

  // Hook into background engine transmissions
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
    
    // Ensure background service thread awakens
    bool isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }

    // Hand off configurations to service isolate thread
    service.invoke('startTimerWithConfig', {
      'workMinutes': _workMinutes,
      'breakMinutes': _breakMinutes,
    });

    setState(() {
      _titleText = "Work";
      _count = _workMinutes * 60;
      _isBackgroundRunning = true;
    });
  }

  void _resetTimer() {
    final service = FlutterBackgroundService();
    service.invoke('stopService');

    setState(() {
      _isBackgroundRunning = false;
      _count = _workMinutes * 60;
      _titleText = "Odoro";
    });
  }

  void _changeTimerDuration(int work, int breakTime) {
    final service = FlutterBackgroundService();
    if (_isBackgroundRunning) {
      service.invoke('stopService');
    }

    setState(() {
      _isBackgroundRunning = false;
      _workMinutes = work;
      _breakMinutes = breakTime;
      _count = _workMinutes * 60;
      _titleText = "Odoro";
    });
  }

  String _formatTime(int totalSeconds) {
    int mins = totalSeconds ~/ 60;
    int secs = totalSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _serviceSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        width: screenSize.width,
        height: screenSize.height,
        color: Colors.black,
        child: Stack(
          children: [
            // 1. Title
            Align(
              alignment: const Alignment(0, -0.8),
              child: Text(
                _titleText.toUpperCase(),
                style: const TextStyle(
                  fontFamily: 'Orbitron',
                  fontSize: 45,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF333333),
                ),
              ),
            ),

            // 2. Image (The .webp apple logo)
            Positioned(
              top: 60,
              left: -50,
              right: -50,
              bottom: 100,
              child: Image.asset(
                'assets/applelogo.webp',
                fit: BoxFit.contain,
              ),
            ),

            // 3. Timer
            Align(
              alignment: const Alignment(-0.02, -0.05),
              child: Text(
                _formatTime(_count),
                style: const TextStyle(
                  fontFamily: 'Orbitron',
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E1E1E),
                ),
              ),
            ),

            // 4. Controls
            Align(
              alignment: const Alignment(0, 0.74),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildButton("START", _startTimer),
                  const SizedBox(width: 90),
                  _buildButton("RESET", _resetTimer),
                ],
              ),
            ),

            // 5. Minimalist Three-Dot Menu
            Positioned(
              top: 25,
              right: 10,
              child: PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert, 
                  color: Color(0xFF333333), 
                  size: 25,
                ),
                color: Colors.grey[900],
                elevation: 0,
                onSelected: (String value) {
                  if (value == '4-1') {
                    _changeTimerDuration(4, 1);
                  } else if (value == '25-5') {
                    _changeTimerDuration(25, 5);
                  } else if (value == '50-10') {
                    _changeTimerDuration(50, 10);
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: '4-1',
                    child: Text(
                      '4 - 1 mins',
                      style: TextStyle(
                        color: Colors.grey,
                        fontFamily: 'Arial',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: '25-5',
                    child: Text(
                      '25 - 5 mins',
                      style: TextStyle(
                        color: Colors.grey,
                        fontFamily: 'Arial',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: '50-10',
                    child: Text(
                      '50 - 10 mins',
                      style: TextStyle(
                        color: Colors.grey,
                        fontFamily: 'Arial',
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
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
      style: TextButton.styleFrom(backgroundColor: Colors.black),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF333333),
          fontSize: 15,
          fontWeight: FontWeight.w900,
          fontFamily: 'Orbitron',
        ),
      ),
    );
  }
}