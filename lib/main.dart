import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:convert';

import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sunny Logistic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1976D2)),
        textTheme: GoogleFonts.kanitTextTheme(Theme.of(context).textTheme),
      ),
      home: const WebViewPage(),
    );
  }
}

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  static const int _maxLocationsPerFlush = 20;
  static const Duration _locationFlushInterval = Duration(milliseconds: 200);

  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  final List<Map<String, dynamic>> _pendingLocationBuffer = [];
  File? _locationBufferFile;
  Timer? _locationBufferRetryTimer;
  Future<void> _locationBufferReady = Future<void>.value();
  Future<void> _locationWork = Future<void>.value();
  bool _isLoading = true;

  // final String _baseUrl = 'https://logistic.worldchemical.co.th';
  final String _baseUrl = 'http://192.168.1.29:3000';

  // ค่าที่ cache ไว้จาก WebView เพื่อใช้ยิง API ตอนแอปอยู่ background
  StreamSubscription<Position>? _positionStreamSubscription;
  String? _truckId;
  String? _driverId;
  String? _authCookieValue;
  bool _isLocationTracking = false;
  bool _trackingStoppedByWeb = true;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _locationBufferReady = _loadLocationBuffer();

    // 1. สร้าง params สำหรับรองรับการเลือกไฟล์บน WebView
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'LocationControlChannel',
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint('[JS -> Flutter] ${message.message}');

          if (message.message == 'stopLocationTracking') {
            unawaited(_stopLocationTracking());
          }

          if (message.message == 'startLocationTracking') {
            _trackingStoppedByWeb = false;
            unawaited(_startTrackingWhenReady());
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) async {
            final uri = Uri.parse(request.url);
            if (_shouldOpenExternal(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) async {
            setState(() {
              _isLoading = false;
            });

            await _checkCookies();
            // driver_id มาจาก WebView
            await _cacheDriverContext();
            // truck_id ดึงจาก API โดย Flutter
            await _loadTruckId();
            debugPrint(
              '[Flutter] context: '
              'driver_id=$_driverId '
              'truck_id=$_truckId',
            );

            if (_driverId == null || _truckId == null) {
              debugPrint(
                '[Flutter] Context ยังไม่พร้อม ไม่เริ่ม Background Tracking',
              );
              await _stopLocationTracking();
              return;
            }

            await _syncTrackingWithWeb();
          },
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
          },
        ),
      );

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
      (controller.platform as AndroidWebViewController).setOnShowFileSelector(
        _androidFilePicker,
      );
    }

    _controller = controller;
    _controller.loadRequest(Uri.parse(_baseUrl));
  }

  Future<void> _stopLocationTracking() async {
    debugPrint('[BackgroundLocation] STOP requested from WebView');

    _trackingStoppedByWeb = true;
    _isLocationTracking = false;
    _locationBufferRetryTimer?.cancel();
    _locationBufferRetryTimer = null;

    final subscription = _positionStreamSubscription;

    _positionStreamSubscription = null;

    await subscription?.cancel();

    debugPrint('[BackgroundLocation] TRACKING STOPPED');
  }

  Future<void> _startTrackingWhenReady() async {
    await _checkCookies();
    await _cacheDriverContext();
    await _loadTruckId();
    if (_trackingStoppedByWeb || _truckId == null || _driverId == null) return;
    await _ensureLocationPermission();
    if (_trackingStoppedByWeb) return;
    await _startBackgroundLocationTracking();
  }

  Future<void> _syncTrackingWithWeb() async {
    try {
      final result = await _controller.runJavaScriptReturningResult(
        'typeof shouldReportDriverLocation === "function" && shouldReportDriverLocation()',
      );
      if (_unwrapJsString(result) == 'true') {
        _trackingStoppedByWeb = false;
        await _startTrackingWhenReady();
      } else {
        await _stopLocationTracking();
      }
    } catch (error) {
      await _stopLocationTracking();
      debugPrint('[Location] Cannot read work status: $error');
    }
  }

  bool _shouldOpenExternal(Uri uri) {
    final baseUri = Uri.parse(_baseUrl);

    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return uri.host != baseUri.host;
    }

    return true;
  }

  Future<void> _checkCookies() async {
    try {
      final cookies = await _cookieManager.getCookies(
        domain: Uri.parse(_baseUrl),
      );
      for (var c in cookies) {
        debugPrint('Auth Cookie: ${c.name} = ${c.value}');
        if (c.name == 'auth' && c.value.isNotEmpty) {
          _authCookieValue = c.value;
        }
      }
    } catch (e) {
      debugPrint('Cookie Check Error: $e');
    }
  }

  Future<void> _requestCurrentLocationNow() async {
    if (!_isLocationTracking || _trackingStoppedByWeb) {
      debugPrint('[Location] Skip immediate request - tracking is stopped');
      return;
    }

    try {
      debugPrint('[Location] Requesting current location now...');

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      debugPrint(
        '[Location] Current position: '
        '${position.latitude}, ${position.longitude}',
      );

      // อัปเดต OpenLayers
      if (_appLifecycleState == AppLifecycleState.resumed) {
        await _setLocation(position);
      }

      // ส่ง API ทันที
      if (_isLocationTracking && !_trackingStoppedByWeb) {
        await _sendLocationToServer(position);
      }
    } catch (e) {
      debugPrint('[Location] Immediate location error: $e');
    }
  }

  Future<bool> _loadTruckId() async {
    _truckId = null;
    if ((_authCookieValue ?? '').isEmpty) {
      debugPrint('[Flutter] ไม่มี auth cookie');
      return false;
    }

    try {
      final uri = Uri.parse('$_baseUrl/api/driver/getMyRoute');

      debugPrint('[Flutter] กำลังดึง truck_id จาก API...');

      final response = await http.get(
        uri,
        headers: {'Cookie': 'auth=$_authCookieValue'},
      );

      debugPrint('[Flutter] getMyRoute status=${response.statusCode}');

      if (response.statusCode != 200) {
        debugPrint('[Flutter] getMyRoute error: ${response.body}');
        return false;
      }

      final routes = jsonDecode(response.body);

      if (routes is List && routes.isNotEmpty) {
        final truckId = routes[0]['truck_id'];

        if (truckId != null) {
          _truckId = truckId.toString();

          debugPrint('[Flutter] truck_id=$_truckId');

          return true;
        }
      }

      debugPrint('[Flutter] ไม่พบ truck_id ใน routes');
      return false;
    } catch (e) {
      debugPrint('[Flutter] load truck_id error: $e');
      return false;
    }
  }

  // อ่าน truck_id/driver_id ที่หน้าเว็บตั้งไว้เป็น global variable แล้ว cache เก็บไว้ใน Dart
  Future<bool> _cacheDriverContext() async {
    try {
      final truckIdRaw = await _controller.runJavaScriptReturningResult(
        'typeof truck_id !== "undefined" && truck_id != null ? truck_id : ""',
      );

      final driverIdRaw = await _controller.runJavaScriptReturningResult(
        'typeof driver_id !== "undefined" && driver_id != null ? driver_id : ""',
      );

      final truckId = _unwrapJsString(truckIdRaw);
      final driverId = _unwrapJsString(driverIdRaw);

      _truckId = truckId.isNotEmpty ? truckId : null;
      _driverId = driverId.isNotEmpty ? driverId : null;

      debugPrint(
        '[Flutter] cache driver context: '
        'truck_id=$_truckId, '
        'driver_id=$_driverId',
      );

      return _truckId != null &&
          _driverId != null &&
          _truckId!.isNotEmpty &&
          _driverId!.isNotEmpty;
    } catch (e) {
      debugPrint('Driver context read error: $e');

      return false;
    }
  }

  String _unwrapJsString(Object result) {
    var value = result.toString();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<List<String>> _androidFilePicker(
    FileSelectorParams params,
  ) async {
    final ImagePicker picker = ImagePicker();
    try {
      final ImageSource? source = await showDialog<ImageSource>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('เลือกรูปภาพหลักฐาน'),
          content: const Text('กรุณาเลือกช่องทางในการอัปโหลดรูปภาพ'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                ImageSource.camera,
              ),
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 18),
              ),
              child: const Text('📸 ถ่ายรูปเลย !'),
            ),

            TextButton(
              onPressed: () => Navigator.pop(
                context,
                ImageSource.gallery,
              ),
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 18),
              ),
              child: const Text('📁 เลือกจากคลังภาพ'),
            ),

            TextButton(
              onPressed: () => Navigator.pop(context, null),
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 18),
              ),
              child: const Text(
                'ยกเลิก',
                style: TextStyle(color: Colors.black),
              ),
            ),
          ],
        ),
      );

      if (source == null) {
        return [];
      }

      if (source == ImageSource.camera) {
        final XFile? photo = await picker.pickImage(
          source: ImageSource.camera,
        );

        if (photo == null) {
          return [];
        }

        return [
          Uri.file(photo.path).toString(),
        ];
      }

      if (source == ImageSource.gallery) {
        final List<XFile> photos = await picker.pickMultiImage(
          imageQuality: 90,
        );

        return photos.map((photo) {
          return Uri.file(photo.path).toString();
        }).toList();
      }

      return [];
    } catch (e) {
      debugPrint('ข้อผิดพลาด: $e');
      return [];
    }
  }

  Future<void> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }

    // Foreground
    PermissionStatus foreground = await Permission.locationWhenInUse.status;

    if (!foreground.isGranted) {
      foreground = await Permission.locationWhenInUse.request();
    }

    if (!foreground.isGranted) {
      throw Exception('Foreground location permission denied: $foreground');
    }

    // Background / Always
    if (Platform.isAndroid) {
      PermissionStatus background = await Permission.locationAlways.status;

      if (!background.isGranted) {
        background = await Permission.locationAlways.request();
      }

      debugPrint(
        '[LocationPermission] '
        'foreground=$foreground '
        'background=$background',
      );

      if (!background.isGranted) {
        debugPrint(
          '[LocationPermission] '
          'Background location is NOT granted',
        );
      }
    }

    final geoPermission = await Geolocator.checkPermission();

    debugPrint('[LocationPermission] Geolocator=$geoPermission');
  }

  Future<void> _startBackgroundLocationTracking() async {
    if (_isLocationTracking) {
      debugPrint('[BackgroundLocation] Already running.');
      return;
    }

    if (_trackingStoppedByWeb) return;

    debugPrint('[BackgroundLocation] STARTING...');

    if (Platform.isAndroid) {
      final notificationStatus = await Permission.notification.request();

      debugPrint('[BackgroundLocation] notification=$notificationStatus');
    }

    late final LocationSettings locationSettings;

    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 60),

        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Sunny Logistic กำลังติดตามตำแหน่ง',
          notificationText: 'แอปกำลังส่งพิกัดตำแหน่งของคุณให้ระบบขนส่ง',
          enableWakeLock: true,
          enableWifiLock: true,
          setOngoing: true,
        ),
      );
    } else if (Platform.isIOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.otherNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      );
    }

    await _positionStreamSubscription?.cancel();

    if (_trackingStoppedByWeb || _isLocationTracking) return;

    debugPrint('[BackgroundLocation] Creating stream...');

    _positionStreamSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            debugPrint(
              '[BackgroundLocation] GPS EVENT '
              '${DateTime.now().toIso8601String()} '
              '${position.latitude},${position.longitude}',
            );

            _onBackgroundPosition(position);
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('[BackgroundLocation] STREAM ERROR: $error');
            debugPrintStack(stackTrace: stackTrace);
          },
          onDone: () {
            _isLocationTracking = false;
            _positionStreamSubscription = null;
            debugPrint('[BackgroundLocation] STREAM DONE !!!');
          },
          cancelOnError: false,
        );

    _isLocationTracking = true;

    debugPrint(
      '[BackgroundLocation] STREAM CREATED '
      'isPaused=${_positionStreamSubscription?.isPaused}',
    );
  }

  Future<void> _onBackgroundPosition(Position position) async {
    if (!_isLocationTracking || _trackingStoppedByWeb) {
      debugPrint('[GPS] IGNORE - tracking stopped');
      return;
    }

    debugPrint(
      '[GPS] ${DateTime.now().toIso8601String()} '
      '${position.latitude}, ${position.longitude}',
    );

    debugPrint('[GPS] lifecycle=$_appLifecycleState');

    if (_appLifecycleState == AppLifecycleState.resumed) {
      await _setLocation(position);
    }

    if (!_isLocationTracking || _trackingStoppedByWeb) {
      debugPrint('[GPS] STOPPED while updating WebView - skip API');
      return;
    }

    await _sendLocationToServer(position);
  }

  Future<void> _sendLocationToServer(Position position) {
    return _queueLocationWork(() async {
      await _locationBufferReady;

      if (!_isLocationTracking || _trackingStoppedByWeb) {
        debugPrint('[BackgroundLocation] API SKIP - tracking stopped');
        return;
      }

      // Save each fix before sending so it survives an app restart while
      // offline.
      _pendingLocationBuffer.add({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'recordedAt': position.timestamp.toIso8601String(),
        'truckId': _truckId,
        'driverId': _driverId,
      });
      await _persistLocationBuffer();
      await _flushLocationBuffer();
    });
  }

  Future<void> _queueLocationWork(Future<void> Function() work) {
    final operation = _locationWork.then((_) => work());
    _locationWork = operation.catchError(
      (Object error, StackTrace stackTrace) {
        debugPrint('[LocationBuffer] queued work failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );
    return _locationWork;
  }

  Future<void> _loadLocationBuffer() async {
    try {
      final directory = await getApplicationSupportDirectory();
      _locationBufferFile = File(
        '${directory.path}${Platform.pathSeparator}pending_locations.json',
      );

      final file = _locationBufferFile!;
      if (!await file.exists()) return;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;

      for (final item in decoded) {
        if (item is! Map) continue;
        final record = Map<String, dynamic>.from(item);
        final latitude = record['latitude'];
        final longitude = record['longitude'];
        if (latitude is! num || longitude is! num) continue;
        record['latitude'] = latitude.toDouble();
        record['longitude'] = longitude.toDouble();
        _pendingLocationBuffer.add(record);
      }

      debugPrint(
        '[LocationBuffer] loaded ${_pendingLocationBuffer.length} pending locations',
      );
    } catch (error) {
      debugPrint('[LocationBuffer] load failed: $error');
    }
  }

  Future<void> _persistLocationBuffer() async {
    final file = _locationBufferFile;
    if (file == null) return;

    try {
      await file.parent.create(recursive: true);
      final temporaryFile = File('${file.path}.tmp');
      await temporaryFile.writeAsString(
        jsonEncode(_pendingLocationBuffer),
        flush: true,
      );
      await temporaryFile.rename(file.path);
    } catch (error) {
      debugPrint('[LocationBuffer] save failed: $error');
    }
  }

  Future<void> _flushLocationBuffer() async {
    _locationBufferRetryTimer?.cancel();
    _locationBufferRetryTimer = null;

    if (!_isLocationTracking || _trackingStoppedByWeb) return;
    if (_pendingLocationBuffer.isEmpty) return;

    var sentCount = 0;
    while (sentCount < _maxLocationsPerFlush &&
        _pendingLocationBuffer.isNotEmpty &&
        _isLocationTracking &&
        !_trackingStoppedByWeb) {
      final location = _pendingLocationBuffer.first;
      final wasSent = await _postBufferedLocation(location);
      if (wasSent == null) return;
      if (!wasSent) {
        _scheduleLocationBufferRetry(const Duration(seconds: 30));
        return;
      }

      _pendingLocationBuffer.removeAt(0);
      await _persistLocationBuffer();
      sentCount++;

      if (sentCount < _maxLocationsPerFlush &&
          _pendingLocationBuffer.isNotEmpty) {
        await Future<void>.delayed(_locationFlushInterval);
      }
    }

    debugPrint(
      '[LocationBuffer] sent $sentCount; '
      '${_pendingLocationBuffer.length} still pending',
    );
    if (_pendingLocationBuffer.isNotEmpty) {
      _scheduleLocationBufferRetry(const Duration(seconds: 1));
    }
  }

  void _scheduleLocationBufferRetry(Duration delay) {
    if (!_isLocationTracking || _trackingStoppedByWeb) return;

    _locationBufferRetryTimer?.cancel();
    _locationBufferRetryTimer = Timer(delay, () {
      _locationBufferRetryTimer = null;
      unawaited(_flushLocationBufferWhenReady());
    });
  }

  Future<bool?> _postBufferedLocation(Map<String, dynamic> location) async {
    final savedTruckId = (location['truckId'] ?? '').toString();
    final savedDriverId = (location['driverId'] ?? '').toString();
    final truckId = savedTruckId.isEmpty ? (_truckId ?? '') : savedTruckId;
    final driverId = savedDriverId.isEmpty ? (_driverId ?? '') : savedDriverId;
    final cookie = _authCookieValue ?? '';

    if (truckId.isEmpty || driverId.isEmpty || cookie.isEmpty) {
      debugPrint('[LocationBuffer] waiting for truck, driver, and auth cookie');
      return null;
    }

    // Don't replay a previous driver's points under a different account.
    if (truckId != _truckId || driverId != _driverId) {
      debugPrint('[LocationBuffer] waiting for the original driver context');
      return null;
    }

    if (savedTruckId.isEmpty || savedDriverId.isEmpty) {
      location['truckId'] = truckId;
      location['driverId'] = driverId;
      await _persistLocationBuffer();
    }

    final uri = Uri.parse(
      '$_baseUrl/api/saveLocation/'
      '$truckId/'
      '$driverId/'
      '${location['latitude']}/'
      '${location['longitude']}',
    );

    try {
      final response = await http
          .get(uri, headers: {'Cookie': 'auth=$cookie'})
          .timeout(const Duration(seconds: 10));

      debugPrint(
        '[BackgroundLocation] sent -> ${response.statusCode}: ${response.body}',
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (error) {
      debugPrint('[LocationBuffer] send failed; will retry later: $error');
      return false;
    }
  }

  Future<void> _flushLocationBufferWhenReady() {
    return _queueLocationWork(() async {
      await _locationBufferReady;
      await _flushLocationBuffer();
    });
  }

  Future<void> _refreshContextAndFlushLocationBuffer() async {
    await _checkCookies();
    await _cacheDriverContext();
    await _loadTruckId();
    await _syncTrackingWithWeb();
    await _flushLocationBufferWhenReady();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      // รีเฟรช cookie/truck_id/driver_id ใหม่ทุกครั้งที่กลับมาหน้าจอ เผื่อมีการ login ใหม่
      unawaited(_refreshContextAndFlushLocationBuffer());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationBufferRetryTimer?.cancel();
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  Future<void> _setLocation(Position position) async {
    final String jsCode =
        '''
      position_latitude = ${position.latitude};
      position_longitude = ${position.longitude};
      if (typeof updateDriverMap === 'function') {
        updateDriverMap();
      } else {
        console.log("ไม่เจอฟังก์ชัน updateDriverMap() บนหน้าเว็บนี้");
      }
    ''';

    try {
      await _controller.runJavaScript(jsCode);
      debugPrint(
        'Flutter -> JS Variable to Draw Map and Route ${position.latitude}, ${position.longitude}',
      );
    } catch (error) {
      debugPrint('Failed to inject location to EJS variables: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isLoading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
