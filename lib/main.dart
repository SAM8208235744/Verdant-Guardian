import 'package:flutter/material.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'dart:io';
import 'dart:math';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  PaintingBinding.instance.imageCache
    ..maximumSize = 80
    ..maximumSizeBytes = 20 << 20;

  runApp(const WaterApp());
}

class MQTTService {
  late MqttServerClient client;
  bool _hasClient = false;
  Function(String topic, String message)? onMessageGlobal;

  Future<void> connect(String clientId) async {
    const broker = String.fromEnvironment('VERDANT_MQTT_BROKER');
    const mqttPort = int.fromEnvironment(
      'VERDANT_MQTT_PORT',
      defaultValue: 8883,
    );
    const mqttUsername = String.fromEnvironment('VERDANT_MQTT_USERNAME');
    const mqttPassword = String.fromEnvironment('VERDANT_MQTT_PASSWORD');

    if (broker.isEmpty) {
      return;
    }

    final mqttClient = MqttServerClient(broker, clientId);
    client = mqttClient;
    _hasClient = true;

    final certData = await rootBundle.load('assets/certs/emqxsl-ca.pem');

    SecurityContext context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificatesBytes(certData.buffer.asUint8List());

    mqttClient.securityContext = context;
    mqttClient.secure = true;

    mqttClient.port = mqttPort;
    mqttClient.keepAlivePeriod = 30;
    mqttClient.autoReconnect = true;
    client.logging(on: false); // Logging is disabled to reduce noise

    var connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();
    if (mqttUsername.isNotEmpty) {
      connectionMessage = connectionMessage.authenticateAs(
        mqttUsername,
        mqttPassword,
      );
    }
    mqttClient.connectionMessage = connectionMessage;

    client.onConnected = () => debugPrint("MQTT CONNECTED");
    client.onDisconnected = () => debugPrint("MQTT DISCONNECTED");

    try {
      await mqttClient.connect().timeout(const Duration(seconds: 6));

      if (mqttClient.connectionStatus?.state == MqttConnectionState.connected) {
        debugPrint("MQTT Connected");
      } else {
        debugPrint("MQTT Failed: ${client.connectionStatus?.returnCode}");
        mqttClient.disconnect();
      }
    } catch (e) {
      debugPrint("MQTT ERROR: $e");
      mqttClient.disconnect();
    }

    mqttClient.updates?.listen((events) {
      final rec = events.first.payload as MqttPublishMessage;
      final msg = MqttPublishPayload.bytesToStringAsString(rec.payload.message);
      final topic = events.first.topic;
      onMessageGlobal?.call(topic, msg);
    });
  }

  bool get isConnected =>
      _hasClient &&
      client.connectionStatus?.state == MqttConnectionState.connected;

  void subscribe(String topic) {
    if (isConnected) {
      client.subscribe(topic, MqttQos.atMostOnce);
    }
  }

  bool publish(String topic, String message) {
    if (!isConnected) {
      return false;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(message);
    client.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
    return true;
  }
}

// Data model
class GardenDevice {
  final String id;
  final String name;
  String ip;
  bool isOnline;
  bool isWatering;
  int remainingSeconds;
  int totalSeconds;
  bool isRaining;
  bool rainDelayActive;
  int rainDelayRemaining;
  int rainLastWetSec;
  bool rainDetected;
  List<Map<String, dynamic>> schedules;

  GardenDevice({
    required this.id,
    required this.name,
    required this.ip,
    this.isOnline = false,
    this.isWatering = false,
    this.remainingSeconds = 0,
    this.totalSeconds = 0,
    this.isRaining = false,
    this.rainDelayActive = false,
    this.rainDelayRemaining = 0,
    this.rainLastWetSec = 0,
    this.rainDetected = false,
    required this.schedules,
  });

  Map<String, dynamic> toMap() {
    return {'id': id, 'name': name, 'ip': ip, 'schedules': schedules};
  }

  factory GardenDevice.fromMap(Map<String, dynamic> map) {
    return GardenDevice(
      id: map['id'],
      name: map['name'],
      ip: map['ip'] ?? '',
      schedules: List<Map<String, dynamic>>.from(map['schedules']),
      isOnline: false,
      isWatering: false,
      remainingSeconds: 0,
      totalSeconds: 0,
      isRaining: false,
      rainDelayActive: false,
      rainDelayRemaining: 0,
      rainLastWetSec: 0,
      rainDetected: false,
    );
  }
}

// Shaders and requirements
class WaterShader extends StatefulWidget {
  final double progress;
  const WaterShader({super.key, required this.progress});

  @override
  State<WaterShader> createState() => _WaterShaderState();
}

class _WaterShaderState extends State<WaterShader>
    with SingleTickerProviderStateMixin {
  double _time = 0.0;
  late AnimationController _controller;

  static const int maxRipples = 5;

  List<Offset> tapPositions = List.generate(
    maxRipples,
    (_) => const Offset(-1, -1),
  );

  List<double> tapTimes = List.generate(maxRipples, (_) => -10.0);

  int currentRippleIndex = 0;
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShaderBuilder(assetKey: 'shaders/water.frag', (
      context,
      shader,
      child,
    ) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              _time = _controller.value * 1000;

              final size = Size(constraints.maxWidth, constraints.maxHeight);

              shader.setFloat(0, _time);
              shader.setFloat(1, size.width);
              shader.setFloat(2, size.height);
              shader.setFloat(3, widget.progress);

              return CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _ShaderPainter(shader),
              );
            },
          );
        },
      );
    });
  }
}

class _ShaderPainter extends CustomPainter {
  final FragmentShader shader;
  _ShaderPainter(this.shader);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class RainPainter extends CustomPainter {
  final Random random = Random();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 1;
    for (int i = 0; i < 120; i++) {
      double x = random.nextDouble() * size.width;
      double y = random.nextDouble() * size.height;
      canvas.drawLine(Offset(x, y), Offset(x + 2, y + 10), paint);
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}

// Main app and page
class WaterApp extends StatelessWidget {
  const WaterApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  // Master state
  List<GardenDevice> devices = [];
  List<GardenDevice> get visibleDevicesFiltered {
    return devices
        .where((d) => d.isOnline || d.id == _selectedDevice?.id)
        .toList();
  }

  Set<String> localDeviceIds = {};
  Set<String> mqttDeviceIds = {};
  final Set<String> knownCloudDeviceIds = {
    const String.fromEnvironment('VERDANT_DEVICE_ID', defaultValue: 'ESP32_1'),
  };
  bool _isLocalSearching = false;
  Timer? _localSearchTimer;
  GardenDevice? _selectedDevice;
  Map<String, DateTime> lastSeen = {};
  bool isLoadingAction = false;
  DateTime lastActionTime = DateTime.now();
  late Timer _httpStatusTimer;
  Timer? _offlineTimer;

  bool _httpRequestInFlight = false;
  static const Duration _httpStatusTimeout = Duration(seconds: 3);
  static const Duration _httpCommandAckTimeout = Duration(milliseconds: 1500);
  int _commandSerial = 0;

  // User interface and navigation state
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _pageSwipeLocked = false;
  Timer? _pageSwipeUnlockTimer;
  bool buttonPressed = false;
  RawDatagramSocket? udpSocket;
  int failCount = 0;
  static const int maxFails = 3;

  final MQTTService mqtt = MQTTService();

  late Timer countdownTimer;
  late AnimationController glowController;
  late Animation<double> glowAnimation;

  final List<String> dayNames = ["S", "M", "T", "W", "T", "F", "S"];
  Set<String> subscribedTopics = {};

  double get pageOffset {
    if (!_pageController.hasClients) return 0;
    return _pageController.page ?? 0;
  }

  double get pageDelta {
    if (!_pageController.hasClients) return 0;
    final page = _pageController.page ?? 0;
    return page - page.floor();
  }

  int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  bool _hasFreshEspStatus(GardenDevice device) {
    final last = lastSeen[device.id];
    if (last == null) return false;

    return DateTime.now().difference(last) <= const Duration(seconds: 12);
  }

  bool _canControlDevice(GardenDevice device) {
    return device.isOnline && _hasFreshEspStatus(device);
  }

  void _applyEspTimer(GardenDevice device, Map<String, dynamic> data) {
    final hasState = data.containsKey("state");
    final espWatering = hasState ? data["state"] == "ON" : device.isWatering;

    final espRemaining = data.containsKey("remaining")
        ? _asInt(data["remaining"], device.remainingSeconds)
        : device.remainingSeconds;

    final espDuration = data.containsKey("duration")
        ? _asInt(
            data["duration"],
            device.totalSeconds == 0 ? 600 : device.totalSeconds,
          )
        : device.totalSeconds;

    if (espDuration > 0) {
      device.totalSeconds = espDuration;
    }

    // Trust the ESP immediately when state changes
    if (hasState && espWatering != device.isWatering) {
      device.isWatering = espWatering;
      device.remainingSeconds = espWatering
          ? espRemaining.clamp(0, 999999).toInt()
          : 0;
      return;
    }

    device.isWatering = espWatering;

    if (!espWatering) {
      device.remainingSeconds = 0;
      return;
    }

    // Correct the Flutter timer when the ESP differs by more than 3 seconds
    final diff = (espRemaining - device.remainingSeconds).abs();

    if (diff > 3) {
      device.remainingSeconds = espRemaining.clamp(0, 999999).toInt();
    }
  }

  bool _isAllowedDeviceId(String id) {
    return knownCloudDeviceIds.contains(id);
  }

  List<GardenDevice> get visibleLocalDevices {
    return devices
        .where(
          (d) =>
              _isAllowedDeviceId(d.id) &&
              d.isOnline &&
              localDeviceIds.contains(d.id),
        )
        .toList();
  }

  List<GardenDevice> get visibleNetworkDevices {
    return devices
        .where(
          (d) =>
              _isAllowedDeviceId(d.id) &&
              d.isOnline &&
              mqttDeviceIds.contains(d.id),
        )
        .toList();
  }

  void _subscribeToDevice(GardenDevice device) {
    if (!mqtt.isConnected) return;
    final topic = "water/${device.id}/status";
    if (subscribedTopics.contains(topic)) return;
    mqtt.subscribe(topic);
    subscribedTopics.add(topic);
  }

  Future<void> connectMqtt() async {
    try {
      await mqtt.connect("flutter_${DateTime.now().millisecondsSinceEpoch}");

      if (!mqtt.isConnected) {
        debugPrint("MQTT unavailable; running local-only mode");
        return;
      }

      mqtt.onMessageGlobal = (topic, msg) {
        final parts = topic.split('/');
        if (parts.length != 3 || parts[0] != "water" || parts[2] != "status") {
          return;
        }

        Map<String, dynamic> data;
        try {
          data = jsonDecode(msg) as Map<String, dynamic>;
        } catch (_) {
          return;
        }

        final deviceId = parts[1];
        GardenDevice? device;
        var createdDevice = false;
        try {
          device = devices.firstWhere((d) => d.id == deviceId);
        } catch (_) {
          if (!knownCloudDeviceIds.contains(deviceId)) {
            debugPrint("Ignoring unknown MQTT device: $deviceId");
            return;
          }

          device = GardenDevice(
            id: deviceId,
            name: "Garden Node ${devices.length + 1}",
            ip: "",
            schedules: List.generate(
              4,
              (i) => {
                "hour": 6,
                "minute": 0,
                "duration": 10,
                "enabled": false,
                "days": [false, false, false, false, false, false, false],
              },
            ),
          );

          devices.add(device);
          _selectedDevice ??= device;
          createdDevice = true;
          unawaited(_saveDevicesToPrefs());
        }

        if (!mounted) return;
        final statusChanged = _applyStatusPayload(device, data);
        final sourceChanged = mqttDeviceIds.add(device.id);

        if (createdDevice || statusChanged || sourceChanged) {
          setState(() {});
        }
      };

      mqtt.subscribe("water/+/status");
      for (final d in devices) {
        _subscribeToDevice(d);
      }
    } catch (e) {
      debugPrint("MQTT exception: $e; running local-only");
    }
  }

  @override
  void initState() {
    super.initState();

    glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    glowAnimation = Tween<double>(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: glowController, curve: Curves.easeInOut));

    _httpStatusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_selectedDevice != null && _selectedDevice!.ip.isNotEmpty) {
        fetchHttpStatus();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrapAfterFirstFrame());
    });

    countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tickSelectedCountdown();
    });

    _offlineTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _expireStaleDevices();
    });
  }

  @override
  void dispose() {
    _httpStatusTimer.cancel();
    _offlineTimer?.cancel();
    _localSearchTimer?.cancel();
    _pageSwipeUnlockTimer?.cancel();

    udpSocket?.close();

    countdownTimer.cancel();
    glowController.dispose();
    _pageController.dispose();

    super.dispose();
  }

  Future<void> _bootstrapAfterFirstFrame() async {
    await _loadDevicesFromPrefs();
    if (!mounted) return;

    startUDPListener();

    final dev = _selectedDevice;
    if (dev != null && dev.ip.isNotEmpty) {
      unawaited(fetchHttpStatus());
    }

    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    unawaited(connectMqtt());
  }

  void _syncGlowAnimation() {
    final shouldAnimate = _selectedDevice?.isWatering == true;

    if (shouldAnimate) {
      if (!glowController.isAnimating) {
        glowController.repeat(reverse: true);
      }
      return;
    }

    if (glowController.isAnimating) {
      glowController.stop();
    }
    glowController.value = 0;
  }

  bool _applyStatusPayload(
    GardenDevice device,
    Map<String, dynamic> data, {
    String? ip,
  }) {
    final wasOnline = device.isOnline;
    final wasWatering = device.isWatering;
    final wasRemaining = device.remainingSeconds;
    final wasTotal = device.totalSeconds;
    final wasRaining = device.isRaining;
    final wasRainDelayActive = device.rainDelayActive;
    final wasRainDelayRemaining = device.rainDelayRemaining;
    final wasRainDetected = device.rainDetected;
    final wasIp = device.ip;

    _applyEspTimer(device, data);

    if (ip != null && ip.isNotEmpty) {
      device.ip = ip;
    }

    device.isRaining = data["rain"] == true;
    device.rainDelayActive = data["rainDelayActive"] == true;
    device.rainDelayRemaining = _asInt(data["rainDelayRemaining"], 0);
    device.rainDetected = data["rainDetected"] == true || data["rain"] == true;
    device.isOnline = true;
    lastSeen[device.id] = DateTime.now();

    if (identical(device, _selectedDevice)) {
      _syncGlowAnimation();
    }

    return wasOnline != device.isOnline ||
        wasWatering != device.isWatering ||
        wasRemaining != device.remainingSeconds ||
        wasTotal != device.totalSeconds ||
        wasRaining != device.isRaining ||
        wasRainDelayActive != device.rainDelayActive ||
        wasRainDelayRemaining != device.rainDelayRemaining ||
        wasRainDetected != device.rainDetected ||
        wasIp != device.ip;
  }

  void _tickSelectedCountdown() {
    final dev = _selectedDevice;
    if (dev == null || !mounted) return;

    if (dev.isWatering && !_hasFreshEspStatus(dev)) {
      setState(() {
        dev.isOnline = false;
        dev.isWatering = false;
        dev.remainingSeconds = 0;
      });
      _syncGlowAnimation();
      return;
    }

    if (!dev.isOnline || !dev.isWatering || dev.remainingSeconds <= 0) {
      return;
    }

    setState(() {
      dev.remainingSeconds = (dev.remainingSeconds - 1).clamp(0, 999999);
      if (dev.remainingSeconds == 0) {
        dev.isWatering = false;
      }
    });
    _syncGlowAnimation();
  }

  void _expireStaleDevices() {
    if (!mounted) return;

    final now = DateTime.now();
    var changed = false;

    for (final d in devices) {
      final last = lastSeen[d.id];
      final stale =
          last == null || now.difference(last) > const Duration(seconds: 15);

      if (stale && (d.isOnline || d.isWatering || d.remainingSeconds != 0)) {
        d.isOnline = false;
        d.isWatering = false;
        d.remainingSeconds = 0;
        changed = true;
      }
    }

    if (!changed) return;

    setState(() {});
    _syncGlowAnimation();
  }

  void _handlePageChanged(int index) {
    setState(() {
      _currentPage = index;
      _pageSwipeLocked = true;
    });

    _pageSwipeUnlockTimer?.cancel();
    _pageSwipeUnlockTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted || !_pageSwipeLocked) return;
      setState(() => _pageSwipeLocked = false);
    });
  }

  String formatSeconds(int sec) {
    final d = Duration(seconds: sec);
    String two(int n) => n.toString().padLeft(2, '0');
    return "${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}";
  }

  String getRainStatusText() {
    if (_selectedDevice == null) return "Weather clear";
    if (_selectedDevice!.isRaining) return "Raining now";
    if (_selectedDevice!.rainDelayActive) return "Rain delay active";
    return "Weather clear";
  }

  IconData getRainIcon() {
    if (_selectedDevice == null) return Icons.wb_sunny_rounded;
    if (_selectedDevice!.isRaining) return Icons.grain_rounded;
    if (_selectedDevice!.rainDelayActive) return Icons.schedule_rounded;
    return Icons.wb_sunny_rounded;
  }

  Color getRainAccent() {
    if (_selectedDevice == null) return Colors.greenAccent;
    if (_selectedDevice!.isRaining) return Colors.blueAccent;
    if (_selectedDevice!.rainDelayActive) return Colors.orangeAccent;
    return Colors.greenAccent;
  }

  Color getDynamicBackground() {
    final t = pageDelta;
    return Color.lerp(const Color(0xFF07131A), const Color(0xFF0E2F44), t)!;
  }

  Future<void> fetchHttpStatus() async {
    if (_httpRequestInFlight) return;

    final dev = _selectedDevice;
    if (dev == null || dev.ip.isEmpty) return;

    HttpClient? httpClient;
    _httpRequestInFlight = true;

    try {
      httpClient = HttpClient()..connectionTimeout = _httpStatusTimeout;

      final request = await httpClient.getUrl(
        Uri.parse('http://${dev.ip}/status'),
      );

      request.headers.set('Connection', 'close');

      final response = await request.close().timeout(_httpStatusTimeout);

      if (response.statusCode == 200) {
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(_httpStatusTimeout);

        final data = jsonDecode(body) as Map<String, dynamic>;

        if (!mounted) return;

        final statusChanged = _applyStatusPayload(dev, data);
        failCount = 0;

        if (statusChanged) {
          setState(() {});
        }
      }
    } on SocketException catch (_) {
      failCount++;

      final commandGraceActive =
          isLoadingAction ||
          DateTime.now().difference(lastActionTime) <
              const Duration(seconds: 8);

      if (failCount >= maxFails && !commandGraceActive && mounted) {
        setState(() => dev.isOnline = false);
      }
    } on TimeoutException catch (_) {
      failCount++;

      final commandGraceActive =
          isLoadingAction ||
          DateTime.now().difference(lastActionTime) <
              const Duration(seconds: 8);

      if (failCount >= maxFails && !commandGraceActive && mounted) {
        setState(() => dev.isOnline = false);
      }
    } catch (e) {
      debugPrint("HTTP status error: $e");
    } finally {
      httpClient?.close(force: true);
      _httpRequestInFlight = false;
    }
  }

  Future<bool> sendHttpCommand(
    String cmd,
    int durationSec, {
    String? commandId,
  }) async {
    final dev = _selectedDevice;
    if (dev == null || dev.ip.isEmpty) {
      debugPrint("No device IP for HTTP command");
      return false;
    }

    HttpClient? httpClient;
    _httpRequestInFlight = true;

    try {
      final path = cmd == 'ON' ? '/on' : '/off';
      final queryParameters = {
        'duration': durationSec.toString(),
        'source': 'verdant_guardian_app',
      };
      if (commandId != null) {
        queryParameters['commandId'] = commandId;
      }

      final uri = Uri.parse(
        'http://${dev.ip}$path',
      ).replace(queryParameters: queryParameters);

      httpClient = HttpClient()..connectionTimeout = _httpCommandAckTimeout;
      final request = await httpClient.getUrl(uri);
      request.headers.set('Connection', 'close');

      final response = await request.close().timeout(_httpCommandAckTimeout);
      await response.drain<void>().timeout(_httpCommandAckTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint("HTTP $cmd acknowledged by ${dev.ip}");
        if (mounted) {
          setState(() {
            dev.isOnline = true;
            lastSeen[dev.id] = DateTime.now();
            failCount = 0;
          });
        }
        return true;
      }

      debugPrint("HTTP $cmd returned ${response.statusCode}");
      return false;
    } on TimeoutException catch (_) {
      debugPrint("HTTP $cmd acknowledgement timed out");
      return false;
    } on SocketException catch (e) {
      debugPrint("HTTP command socket error: $e");
      return false;
    } catch (e) {
      debugPrint("HTTP command failed: $e");
      return false;
    } finally {
      httpClient?.close(force: true);
      _httpRequestInFlight = false;
    }
  }

  Future<bool> sendMQTTCommand(
    String cmd,
    int duration, {
    String? commandId,
  }) async {
    final dev = _selectedDevice;
    if (dev == null) return false;
    final payload = {
      "cmd": cmd,
      "duration": duration,
      "source": "verdant_guardian_app",
    };
    if (commandId != null) {
      payload["commandId"] = commandId;
    }

    return mqtt.publish("water/${dev.id}/control", jsonEncode(payload));
  }

  String _nextCommandId(String cmd) {
    _commandSerial = (_commandSerial + 1) & 0x7fffffff;
    return '${DateTime.now().millisecondsSinceEpoch}_${_commandSerial}_$cmd';
  }

  Future<bool> sendSmartCommand(String cmd, int duration) async {
    final dev = _selectedDevice;
    if (dev == null) return false;

    final commandId = _nextCommandId(cmd);

    // Prefer local HTTP when the IP is known
    if (dev.ip.isNotEmpty) {
      final localSent = await sendHttpCommand(
        cmd,
        duration,
        commandId: commandId,
      );

      if (localSent) {
        debugPrint("Command $commandId sent over local HTTP");
        return true;
      }

      debugPrint("Local HTTP failed, falling back to MQTT");
    }

    // Fall back to cloud MQTT
    final mqttSent = await sendMQTTCommand(cmd, duration, commandId: commandId);

    if (mqttSent) {
      debugPrint("Command $commandId sent over MQTT");
    } else {
      debugPrint("Command $commandId could not be delivered");
    }

    return mqttSent;
  }

  Future<bool> sendScheduleHttp(int slot, Map<String, dynamic> schedule) async {
    final dev = _selectedDevice;
    if (dev == null) return false;

    final rawDays = schedule["days"] as List? ?? [];
    final days = List<bool>.generate(
      7,
      (i) => i < rawDays.length ? rawDays[i] == true : false,
    );

    final bodyMap = {
      "slot": slot,
      "hour": _asInt(schedule["hour"], 6),
      "minute": _asInt(schedule["minute"], 0),
      "duration": _asInt(schedule["duration"], 10), // Minutes
      "enabled": schedule["enabled"] == true,
      "days": days,
      "source": "verdant_guardian_app",
    };

    final body = jsonEncode(bodyMap);

    // Try local HTTP first
    if (dev.ip.isNotEmpty) {
      HttpClient? httpClient;

      try {
        final uri = Uri.parse('http://${dev.ip}/schedule');
        httpClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 3);

        final request = await httpClient.postUrl(uri);
        request.headers
          ..set('Content-Type', 'application/json')
          ..set('Connection', 'close');

        request.write(body);

        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        await response.drain<void>().timeout(const Duration(seconds: 3));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          debugPrint("Schedule $slot saved locally on ESP");

          if (mounted) {
            setState(() {
              dev.schedules[slot] = {
                "hour": bodyMap["hour"],
                "minute": bodyMap["minute"],
                "duration": bodyMap["duration"],
                "enabled": bodyMap["enabled"],
                "days": days,
              };
              dev.isOnline = true;
              lastSeen[dev.id] = DateTime.now();
            });
          }

          await _saveDevicesToPrefs();
          return true;
        }

        debugPrint("Schedule HTTP returned ${response.statusCode}");
      } catch (e) {
        debugPrint("Schedule local HTTP failed: $e");
      } finally {
        httpClient?.close(force: true);
      }
    }

    // Fall back to MQTT
    final mqttSent = mqtt.publish("water/${dev.id}/schedule", body);

    if (mqttSent) {
      debugPrint("Schedule $slot sent over MQTT");

      if (mounted) {
        setState(() {
          dev.schedules[slot] = {
            "hour": bodyMap["hour"],
            "minute": bodyMap["minute"],
            "duration": bodyMap["duration"],
            "enabled": bodyMap["enabled"],
            "days": days,
          };
        });
      }

      await _saveDevicesToPrefs();
      return true;
    }

    debugPrint("Schedule $slot could not be saved");
    return false;
  }

  Future<void> _loadDevicesFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final deviceList = prefs.getStringList("garden_devices") ?? [];

    final loaded = deviceList
        .map(
          (item) =>
              GardenDevice.fromMap(jsonDecode(item) as Map<String, dynamic>),
        )
        .where((d) => _isAllowedDeviceId(d.id))
        .toList();

    if (!mounted) return;

    setState(() {
      devices = loaded;

      localDeviceIds.clear();
      mqttDeviceIds.clear();

      for (final d in devices) {
        if (d.ip.isNotEmpty) {
          localDeviceIds.add(d.id);
        }
      }

      if (_selectedDevice == null ||
          !devices.any((d) => d.id == _selectedDevice!.id)) {
        _selectedDevice = devices.isNotEmpty ? devices.first : null;
      }
    });
    _syncGlowAnimation();
  }

  Future<void> _saveDevicesToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = devices.map((d) => jsonEncode(d.toMap())).toList();
    await prefs.setStringList("garden_devices", list);
  }

  Future<bool> isOnLocalWifi() async {
    final result = await Connectivity().checkConnectivity();
    if (!result.contains(ConnectivityResult.wifi)) return false;

    try {
      final interfaces = await NetworkInterface.list();
      for (final i in interfaces) {
        for (final addr in i.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              (addr.address.startsWith('192.') ||
                  addr.address.startsWith('10.') ||
                  addr.address.startsWith('172.'))) {
            return true;
          }
        }
      }
    } catch (_) {}
    return true;
  }

  Stream<Map<String, dynamic>> discoverESPStream({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    final result = await Connectivity().checkConnectivity();
    if (result.contains(ConnectivityResult.mobile) &&
        !result.contains(ConnectivityResult.wifi)) {
      debugPrint("Mobile data only; skipping UDP discovery");
      return;
    }

    const espPort = 4210;
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
    } catch (e) {
      debugPrint("UDP bind failed: $e");
      return;
    }

    final broadcastAddr = InternetAddress("255.255.255.255");
    var stopped = false;

    void sendDiscoveryPing() {
      final activeSocket = socket;
      if (stopped || activeSocket == null) return;
      try {
        activeSocket.send(
          "WATER_DISCOVERY_REQUEST".codeUnits,
          broadcastAddr,
          espPort,
        );
      } catch (_) {}
    }

    sendDiscoveryPing();
    final timer = Timer.periodic(const Duration(seconds: 2), (_) {
      sendDiscoveryPing();
    });

    final stopTimer = Timer(timeout, () {
      stopped = true;
      socket?.close();
    });

    try {
      await for (final event in socket) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg == null) continue;
          try {
            final msg = utf8.decode(dg.data);
            if (!msg.startsWith("{")) continue;
            final data = jsonDecode(msg) as Map<String, dynamic>;
            if (data["device"] == "water") yield data;
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint("UDP stream error: $e");
    } finally {
      stopped = true;
      timer.cancel();
      stopTimer.cancel();
      try {
        socket.close();
      } catch (_) {}
    }
  }

  Future<void> _runLocalSearch() async {
    if (_isLocalSearching) return;
    if (mounted) setState(() => _isLocalSearching = true);

    _localSearchTimer?.cancel();
    _localSearchTimer = Timer(const Duration(seconds: 12), () {
      if (mounted) setState(() => _isLocalSearching = false);
    });

    try {
      await for (final found in discoverESPStream(
        timeout: const Duration(seconds: 12),
      )) {
        final ip = found['ip'] as String? ?? '';
        final id = found['id'] as String? ?? '';
        if (id.isEmpty || ip.isEmpty || !mounted) continue;
        if (!_isAllowedDeviceId(id)) {
          debugPrint("Ignoring unknown local search device: $id");
          continue;
        }

        setState(() {
          localDeviceIds.add(id);
          final index = devices.indexWhere((d) => d.id == id);
          if (index != -1) {
            _applyStatusPayload(devices[index], found, ip: ip);
          } else {
            final newDevice = GardenDevice(
              id: id,
              name: "Garden Node ${devices.length + 1}",
              ip: ip,
              isOnline: true,
              schedules: List.generate(
                4,
                (i) => {
                  "hour": 6,
                  "minute": 0,
                  "duration": 10,
                  "enabled": false,
                  "days": [false, false, false, false, false, false, false],
                },
              ),
            );
            _applyStatusPayload(newDevice, found, ip: ip);
            devices.add(newDevice);
            _selectedDevice ??= newDevice;
          }
          lastSeen[id] = DateTime.now();
        });
        unawaited(_saveDevicesToPrefs());
      }
    } finally {
      _localSearchTimer?.cancel();
      if (mounted) setState(() => _isLocalSearching = false);
    }
  }

  void startUDPListener() async {
    if (udpSocket != null) return;

    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 4210);
    } catch (e) {
      debugPrint("UDP listener bind failed: $e");
      return;
    }
    udpSocket = socket;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;

      final msg = String.fromCharCodes(datagram.data);
      if (!msg.startsWith("{")) return;

      Map<String, dynamic> data;
      try {
        data = jsonDecode(msg) as Map<String, dynamic>;
      } catch (_) {
        return;
      }

      final deviceId = data["id"] as String?;
      if (deviceId == null || deviceId.isEmpty) return;

      if (!_isAllowedDeviceId(deviceId)) {
        debugPrint("Ignoring unknown UDP broadcast device: $deviceId");
        return;
      }

      GardenDevice? device;
      try {
        device = devices.firstWhere((d) => d.id == deviceId);
      } catch (_) {
        final newDevice = GardenDevice(
          id: deviceId,
          name: "Garden Node ${devices.length + 1}",
          ip: data["ip"] as String? ?? datagram.address.address,
          isOnline: true,
          schedules: List.generate(
            4,
            (i) => {
              "hour": 6,
              "minute": 0,
              "duration": 10,
              "enabled": false,
              "days": [false, false, false, false, false, false, false],
            },
          ),
        );
        if (mounted) {
          setState(() {
            _applyStatusPayload(
              newDevice,
              data,
              ip: data["ip"] as String? ?? datagram.address.address,
            );
            devices.add(newDevice);
            localDeviceIds.add(deviceId);
            _selectedDevice ??= newDevice;
          });
          unawaited(_saveDevicesToPrefs());
        }
        return;
      }

      if (!mounted) return;
      final ip = data["ip"] is String
          ? data["ip"] as String
          : datagram.address.address;
      final statusChanged = _applyStatusPayload(device, data, ip: ip);
      final localChanged = localDeviceIds.add(device.id);

      if (statusChanged || localChanged) {
        setState(() {});
      }
    });
  }

  Future<void> toggleWater() async {
    if (_selectedDevice == null) return;
    if (isLoadingAction) return;

    final dev = _selectedDevice!;
    final targetState = !dev.isWatering;
    const durationSec = 600;

    final previousState = dev.isWatering;
    final previousRemaining = dev.remainingSeconds;
    final previousTotal = dev.totalSeconds;

    // Block start and stop commands when ESP status is stale
    if (!_canControlDevice(dev)) {
      setState(() {
        dev.isOnline = false;
        dev.isWatering = false;
        dev.remainingSeconds = 0;
      });
      _syncGlowAnimation();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Controller is offline. Command not sent."),
        ),
      );

      return;
    }

    final commandStartedAt = DateTime.now();

    setState(() {
      isLoadingAction = true;
      lastActionTime = commandStartedAt;
    });

    final delivered = await sendSmartCommand(
      targetState ? "ON" : "OFF",
      durationSec,
    );

    if (!mounted) return;

    if (!delivered) {
      setState(() {
        isLoadingAction = false;
        dev.isOnline = false;
        dev.isWatering = previousState;
        dev.remainingSeconds = previousRemaining;
        dev.totalSeconds = previousTotal;
      });
      _syncGlowAnimation();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Could not reach the watering controller"),
        ),
      );

      return;
    }

    // Update the interface only after the command is delivered
    // Keep lastSeen based only on ESP status
    setState(() {
      dev.isWatering = targetState;
      dev.remainingSeconds = targetState ? durationSec : 0;
      dev.totalSeconds = targetState ? durationSec : previousTotal;
      isLoadingAction = false;
    });
    _syncGlowAnimation();

    // Verify that the ESP reports back after the command
    unawaited(
      Future.delayed(const Duration(seconds: 4), () async {
        if (!mounted) return;

        if (dev.ip.isNotEmpty) {
          await fetchHttpStatus();
        }

        if (!mounted) return;

        final last = lastSeen[dev.id];
        final confirmed = last != null && last.isAfter(commandStartedAt);

        if (!confirmed) {
          setState(() {
            dev.isOnline = false;
            dev.isWatering = previousState;
            dev.remainingSeconds = previousRemaining;
            dev.totalSeconds = previousTotal;
          });
          _syncGlowAnimation();

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("No confirmation from ESP. Marked offline."),
            ),
          );
        }
      }),
    );
  }

  void _showWiFiDialog() {
    if (_selectedDevice == null) return;
    final ssidController = TextEditingController();
    final passController = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Update WiFi"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ssidController,
              decoration: const InputDecoration(labelText: "SSID"),
            ),
            TextField(
              controller: passController,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Password"),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
            },
            child: const Text("Update"),
          ),
        ],
      ),
    );
  }

  // User interface building

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (details) {
          final pos = details.localPosition;
          final screenWidth = MediaQuery.of(context).size.width;
          final topPadding = MediaQuery.of(context).padding.top;

          // Ignore the top right menu area
          final tappedMenuArea =
              pos.dx > screenWidth - 90 && pos.dy < topPadding + 100;

          if (tappedMenuArea) return;

          RippleController.instance.trigger(pos);
        },
        child: Stack(
          children: [
            const RippleBackground(),
            _buildParallaxOrb(),
            Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      PageView(
                        controller: _pageController,
                        physics: _pageSwipeLocked
                            ? const NeverScrollableScrollPhysics()
                            : const PageScrollPhysics(),
                        onPageChanged: _handlePageChanged,
                        children: [
                          RepaintBoundary(child: _buildMainWaterUI()),
                          RepaintBoundary(child: _buildSchedulePage()),
                        ],
                      ),
                      _buildPopupMenu(),
                      IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _pageController,
                          builder: (context, child) {
                            double page = _pageController.hasClients
                                ? _pageController.page ?? 0
                                : 0;
                            double t = (1.0 - (page % 1.0 - 0.5).abs() * 2)
                                .clamp(0.0, 1.0);
                            return BackdropFilter(
                              filter: ImageFilter.blur(
                                sigmaX: t * 8,
                                sigmaY: t * 8,
                              ),
                              child: Container(
                                color: Colors.black.withValues(alpha: t * 0.12),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                _buildPageIndicator(),
                const SizedBox(height: 16),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPopupMenu() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      right: 10,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PopupMenuButton<String?>(
            icon: const Icon(Icons.more_vert, color: Colors.white, size: 30),
            color: const Color(0xFF1A2A35),
            onSelected: (value) {
              if (value == null || value.isEmpty) return;
              if (value == 'search_local') {
                _runLocalSearch();
                return;
              }
              if (value.startsWith('device:')) {
                final id = value.substring(7);

                if (!knownCloudDeviceIds.contains(id)) return;

                try {
                  final device = devices.firstWhere(
                    (d) => d.id == id && d.isOnline,
                  );

                  setState(() => _selectedDevice = device);
                  _subscribeToDevice(device);
                } catch (_) {}
              }
            },
            itemBuilder: (context) {
              return [
                const PopupMenuItem<String?>(
                  value: null,
                  enabled: false,
                  height: 28,
                  child: Text(
                    "LOCAL",
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                PopupMenuItem<String?>(
                  value: 'search_local',
                  child: Row(
                    children: [
                      _isLocalSearching
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.cyanAccent,
                              ),
                            )
                          : const Icon(
                              Icons.wifi_find,
                              color: Colors.cyanAccent,
                              size: 18,
                            ),
                      const SizedBox(width: 12),
                      Text(
                        _isLocalSearching
                            ? "Searching..."
                            : "Search Local Network",
                        style: const TextStyle(color: Colors.cyanAccent),
                      ),
                    ],
                  ),
                ),
                ...visibleLocalDevices.map(
                  (d) => PopupMenuItem<String?>(
                    value: 'device:${d.id}',
                    child: Row(
                      children: [
                        Icon(
                          Icons.router,
                          color: d.isOnline
                              ? Colors.greenAccent
                              : Colors.orange,
                          size: 18,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                d.name,
                                style: const TextStyle(color: Colors.white),
                              ),
                              Text(
                                d.ip.isEmpty ? "IP unknown" : d.ip,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_selectedDevice?.id == d.id)
                          const Icon(
                            Icons.check,
                            color: Colors.cyanAccent,
                            size: 14,
                          ),
                      ],
                    ),
                  ),
                ),
                if (visibleLocalDevices.isEmpty)
                  const PopupMenuItem<String?>(
                    value: null,
                    enabled: false,
                    height: 30,
                    child: Text(
                      "  No local devices found",
                      style: TextStyle(color: Colors.white24, fontSize: 12),
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem<String?>(
                  value: null,
                  enabled: false,
                  height: 28,
                  child: Text(
                    "NETWORK",
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                ...visibleNetworkDevices.map(
                  (d) => PopupMenuItem<String?>(
                    value: 'device:${d.id}',
                    child: Row(
                      children: [
                        Icon(
                          Icons.cloud_queue,
                          color: d.isOnline ? Colors.blueAccent : Colors.grey,
                          size: 18,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          d.name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const Spacer(),
                        if (_selectedDevice?.id == d.id)
                          const Icon(
                            Icons.check,
                            color: Colors.cyanAccent,
                            size: 14,
                          ),
                      ],
                    ),
                  ),
                ),
                if (visibleNetworkDevices.isEmpty)
                  const PopupMenuItem<String?>(
                    value: null,
                    enabled: false,
                    height: 30,
                    child: Text(
                      "  No cloud devices",
                      style: TextStyle(color: Colors.white24, fontSize: 12),
                    ),
                  ),
              ];
            },
          ),
          if (_isLocalSearching)
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: Colors.cyanAccent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildParallaxOrb() {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _pageController,
          builder: (context, child) {
            final page = _pageController.hasClients
                ? _pageController.page ?? _currentPage.toDouble()
                : _currentPage.toDouble();
            final eased = page.clamp(0.0, 1.0);
            final topPadding = MediaQuery.of(context).padding.top;

            return Transform.translate(
              offset: Offset(
                -30 - (eased * 54),
                topPadding + 62 + (eased * 12),
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: Transform.scale(
                  scale: 1.0 + (eased * 0.08),
                  alignment: Alignment.center,
                  child: Opacity(opacity: 0.95 - (eased * 0.10), child: child),
                ),
              ),
            );
          },
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.25),
                      Colors.blue.withValues(alpha: 0.15),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.6, 1.0],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withValues(alpha: 0.25),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.08),
                      blurRadius: 10,
                      spreadRadius: -2,
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: 20,
                      left: 25,
                      child: Container(
                        width: 40,
                        height: 20,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainWaterUI() {
    final dev = _selectedDevice ?? (devices.isNotEmpty ? devices.first : null);

    if (dev == null) {
      return const Center(
        child: Text(
          "No Device Selected",
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return Stack(
      children: [
        buildRainParticles(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 40),
                const Text(
                  "Smart Water System",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                buildRainCard(),
                const SizedBox(height: 20),
                _buildGlassCard(),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _showWiFiDialog,
                  icon: const Icon(Icons.wifi),
                  label: const Text("Change WiFi"),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Swipe left for Schedule",
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGlassCard() {
    if (_selectedDevice == null) return const SizedBox();
    final dev = _selectedDevice!;

    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0.04),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: dev.isOnline ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      dev.isOnline ? "Online" : "Offline",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AnimatedBuilder(
                animation: glowAnimation,
                builder: (context, child) {
                  double waterLevel = dev.totalSeconds > 0
                      ? (dev.remainingSeconds / dev.totalSeconds).clamp(
                          0.0,
                          1.0,
                        )
                      : 0.0;

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(
                          alpha: dev.isWatering ? 0.22 : 0.30,
                        ),
                        width: 1.2,
                      ),
                      boxShadow: [
                        if (dev.isWatering)
                          BoxShadow(
                            color: Colors.blue.withValues(
                              alpha: glowAnimation.value * 0.65,
                            ),
                            blurRadius: 42,
                            spreadRadius: 8,
                          )
                        else
                          BoxShadow(
                            color: const Color(
                              0xFF075C9B,
                            ).withValues(alpha: 0.30),
                            blurRadius: 38,
                            spreadRadius: 3,
                          ),
                      ],
                    ),
                    child: ClipOval(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Idle blue and cyan gradient
                          if (!dev.isWatering)
                            Positioned.fill(
                              child: Stack(
                                children: [
                                  // Base deep blue gradient
                                  Positioned.fill(
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            Color(0xFF0B4F86), // Soft top blue
                                            Color(0xFF063A70), // Middle blue
                                            Color(0xFF021F45), // Deep blue
                                            Color(0xFF000B1D), // Dark edge
                                          ],
                                          stops: [0.0, 0.38, 0.72, 1.0],
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Soft center depth glow
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: RadialGradient(
                                          center: const Alignment(-0.28, -0.35),
                                          radius: 0.85,
                                          colors: [
                                            const Color(
                                              0xFF1687C9,
                                            ).withValues(alpha: 0.42),
                                            const Color(
                                              0xFF064C86,
                                            ).withValues(alpha: 0.20),
                                            Colors.transparent,
                                          ],
                                          stops: const [0.0, 0.45, 1.0],
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Dark outer vignette adds depth
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: RadialGradient(
                                          center: Alignment.center,
                                          radius: 0.72,
                                          colors: [
                                            Colors.transparent,
                                            Colors.black.withValues(
                                              alpha: 0.35,
                                            ),
                                          ],
                                          stops: const [0.55, 1.0],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // Use the watering shader only while watering
                          if (dev.isWatering)
                            Positioned.fill(
                              child: WaterShader(progress: waterLevel),
                            ),

                          // Simple water drop icon
                          Icon(
                            Icons.water_drop,
                            size: 60,
                            color: dev.isWatering
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.72),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 25),
              Text(
                dev.isWatering
                    ? "Remaining: ${dev.remainingSeconds ~/ 60}m ${dev.remainingSeconds % 60}s"
                    : "System Idle",
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 30),
              _buildWaterButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWaterButton() {
    if (_selectedDevice == null) return const SizedBox();

    final dev = _selectedDevice!;
    final canControl = _canControlDevice(dev) && !isLoadingAction;

    return GestureDetector(
      onTapDown: (_) {
        if (!canControl) return;
        setState(() => buttonPressed = true);
      },
      onTapUp: (_) {
        setState(() => buttonPressed = false);

        if (!canControl) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Controller is offline. Command not sent."),
            ),
          );
          return;
        }

        toggleWater();
      },
      onTapCancel: () => setState(() => buttonPressed = false),
      child: AnimatedScale(
        scale: buttonPressed ? 0.94 : 1,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 40),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: !canControl
                  ? [Colors.grey.shade700, Colors.grey.shade600]
                  : dev.isWatering
                  ? [Colors.red, Colors.deepOrange]
                  : [Colors.blue, Colors.cyan],
            ),
            borderRadius: BorderRadius.circular(50),
            boxShadow: [
              BoxShadow(
                color:
                    (!canControl
                            ? Colors.grey
                            : dev.isWatering
                            ? Colors.red
                            : Colors.blue)
                        .withValues(alpha: 0.45),
                blurRadius: 20,
              ),
            ],
          ),
          child: isLoadingAction
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  !canControl
                      ? "CONTROLLER OFFLINE"
                      : dev.isWatering
                      ? "STOP WATERING"
                      : "START WATERING",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ),
    );
  }

  Widget buildRainCard() {
    final accent = getRainAccent();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.04),
            Colors.white.withValues(alpha: 0.02),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.28),
            blurRadius: 28,
            spreadRadius: -10,
            offset: const Offset(0, 14),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 40,
            spreadRadius: -20,
            offset: const Offset(0, 25),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 1.2,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.35),
                    Colors.white.withValues(alpha: 0.05),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        accent.withValues(alpha: 0.35),
                        accent.withValues(alpha: 0.12),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: -4,
                      ),
                    ],
                  ),
                  child: Icon(getRainIcon(), color: accent, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Rain Intelligence",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        getRainStatusText(),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 13.5,
                        ),
                      ),
                      if (_selectedDevice?.rainDelayActive == true) ...[
                        const SizedBox(height: 8),
                        Text(
                          "Next watering in ${formatSeconds(_selectedDevice!.rainDelayRemaining)}",
                          style: TextStyle(
                            color: accent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.6, end: 1.2),
                  duration: const Duration(seconds: 1),
                  curve: Curves.easeInOut,
                  builder: (context, value, child) {
                    return Container(
                      width: 12 * value,
                      height: 12 * value,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.75),
                            blurRadius: 14,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildRainParticles() {
    if (_selectedDevice?.rainDetected != true) return const SizedBox();
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: 0.25,
          child: CustomPaint(painter: RainPainter()),
        ),
      ),
    );
  }

  Widget _buildSchedulePage() {
    if (_selectedDevice == null) {
      return const Center(
        child: Text(
          "Select a device to see schedules",
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 10),
        const Text(
          "Water Schedule",
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          "Automate watering times",
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 25),
        _buildScheduleTile(0),
        _buildScheduleTile(1),
        _buildScheduleTile(2),
        _buildScheduleTile(3),
        const SizedBox(height: 50),
      ],
    );
  }

  Widget _buildScheduleTile(int index) {
    if (_selectedDevice == null) return const SizedBox();
    final schedule = _selectedDevice!.schedules[index];

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 25,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Schedule ${index + 1}",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Switch(
                value: schedule["enabled"] ?? false,
                activeThumbColor: Colors.cyan,
                onChanged: (value) =>
                    setState(() => schedule["enabled"] = value),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: schedule["hour"],
                        minute: schedule["minute"],
                      ),
                    );
                    if (picked != null) {
                      setState(() {
                        schedule["hour"] = picked.hour;
                        schedule["minute"] = picked.minute;
                      });
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.access_time, color: Colors.white70),
                        const SizedBox(width: 10),
                        Text(
                          "${schedule["hour"].toString().padLeft(2, '0')}:${schedule["minute"].toString().padLeft(2, '0')}",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () async {
                    int? picked = await showDialog<int>(
                      context: context,
                      builder: (context) {
                        int tempDuration = schedule["duration"];
                        return AlertDialog(
                          title: const Text("Duration"),
                          content: StatefulBuilder(
                            builder: (context, setStateDialog) {
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Slider(
                                    value: tempDuration.toDouble(),
                                    min: 1,
                                    max: 60,
                                    divisions: 59,
                                    onChanged: (value) => setStateDialog(
                                      () => tempDuration = value.toInt(),
                                    ),
                                  ),
                                  Text("$tempDuration minutes"),
                                ],
                              );
                            },
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text("Cancel"),
                            ),
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(context, tempDuration),
                              child: const Text("OK"),
                            ),
                          ],
                        );
                      },
                    );
                    if (picked != null) {
                      setState(() => schedule["duration"] = picked);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.timer, color: Colors.white70),
                        const SizedBox(width: 10),
                        Text(
                          "${schedule["duration"]} min",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            children: List.generate(7, (dayIndex) {
              bool selected = schedule["days"][dayIndex];
              return ChoiceChip(
                label: Text(dayNames[dayIndex]),
                selected: selected,
                backgroundColor: Colors.white.withValues(alpha: 0.06),
                selectedColor: Colors.cyan,
                labelStyle: TextStyle(
                  color: selected ? Colors.black : Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
                onSelected: (value) =>
                    setState(() => schedule["days"][dayIndex] = value),
              );
            }),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              onPressed: () async {
                final ok = await sendScheduleHttp(index, schedule);

                if (!mounted) return;

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? "Schedule saved to device"
                          : "Could not save schedule",
                    ),
                  ),
                );
              },
              child: const Text("Save"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(2, (index) {
        bool active = _currentPage == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          height: 8,
          width: active ? 26 : 8,
          decoration: BoxDecoration(
            color: active ? Colors.blue : Colors.white24,
            borderRadius: BorderRadius.circular(20),
          ),
        );
      }),
    );
  }
}

// Ripple background

class RippleBackground extends StatefulWidget {
  const RippleBackground({super.key});

  @override
  State<RippleBackground> createState() => _RippleBackgroundState();
}

class _RippleBackgroundState extends State<RippleBackground>
    with SingleTickerProviderStateMixin {
  List<TapData> taps = [];
  double globalTime = 0.0;
  late double _lastFrameTime;
  late AnimationController _controller;
  Timer? _rippleIdleTimer;

  @override
  void initState() {
    super.initState();
    _lastFrameTime = DateTime.now().microsecondsSinceEpoch.toDouble();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );

    RippleController.instance.onTap = (pos) {
      if (!mounted) return;

      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox) return;

      final size = renderObject.size;
      if (size.width <= 0 || size.height <= 0) return;

      final normalized = Offset(pos.dx / size.width, pos.dy / size.height);

      setState(() {
        taps.insert(0, TapData(normalized, globalTime));
        if (taps.length > 5) taps.removeLast();
      });

      _startRippleAnimation();
    };
  }

  void _startRippleAnimation() {
    _lastFrameTime = DateTime.now().microsecondsSinceEpoch.toDouble();

    if (!_controller.isAnimating) {
      _controller.repeat();
    }

    _rippleIdleTimer?.cancel();
    _rippleIdleTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;

      _controller.stop();
      setState(() {
        taps.removeWhere((tap) => globalTime - tap.time > 3);
      });
    });
  }

  @override
  void dispose() {
    _rippleIdleTimer?.cancel();
    _controller.dispose();

    if (RippleController.instance.onTap != null) {
      RippleController.instance.onTap = null;
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ShaderBuilder(assetKey: "shaders/ripple.frag", (
          context,
          shader,
          child,
        ) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final now = DateTime.now().microsecondsSinceEpoch.toDouble();
              if (_controller.isAnimating) {
                final delta = (now - _lastFrameTime) / 1000000.0;
                globalTime += delta;
              }
              _lastFrameTime = now;

              // Use monotonic time and never reset to zero
              shader.setFloat(0, constraints.maxWidth);
              shader.setFloat(1, constraints.maxHeight);
              shader.setFloat(2, globalTime);

              TapData t(int i) => i < taps.length
                  ? taps[i]
                  : TapData(const Offset(-1, -1), -1000);

              shader.setFloat(3, t(0).pos.dx);
              shader.setFloat(4, t(0).pos.dy);
              shader.setFloat(5, t(1).pos.dx);
              shader.setFloat(6, t(1).pos.dy);
              shader.setFloat(7, t(2).pos.dx);
              shader.setFloat(8, t(2).pos.dy);
              shader.setFloat(9, t(3).pos.dx);
              shader.setFloat(10, t(3).pos.dy);
              shader.setFloat(11, t(4).pos.dx);
              shader.setFloat(12, t(4).pos.dy);

              shader.setFloat(13, t(0).time);
              shader.setFloat(14, t(1).time);
              shader.setFloat(15, t(2).time);
              shader.setFloat(16, t(3).time);
              shader.setFloat(17, t(4).time);

              return CustomPaint(
                size: Size.infinite,
                painter: RippleShaderPainter(shader),
              );
            },
          );
        });
      },
    );
  }
}

class RippleController {
  RippleController._();
  static final RippleController instance = RippleController._();
  void Function(Offset pos)? onTap;
  void trigger(Offset pos) {
    onTap?.call(pos);
  }
}

class TapData {
  final Offset pos;
  final double time;
  TapData(this.pos, this.time);
}

class RippleShaderPainter extends CustomPainter {
  final FragmentShader shader;
  RippleShaderPainter(this.shader);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
