import 'dart:async';
import 'dart:io' show Platform;

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

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sunny Logistic App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        textTheme: GoogleFonts.kanitTextTheme(
          Theme.of(context).textTheme,
        ),
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
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  bool _isLoading = true;

  // final String _baseUrl = 'https://logistic.worldchemical.co.th';
  final String _baseUrl = 'http://192.168.1.38:3000';

  // ค่าที่ cache ไว้จาก WebView เพื่อใช้ยิง API ตอนแอปอยู่ background
  StreamSubscription<Position>? _positionStreamSubscription;
  String? _truckId;
  String? _driverId;
  String? _authCookieValue;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ensureLocationPermission()
        .then((_) => _startBackgroundLocationTracking())
        .catchError((e) => debugPrint('Permission error: $e'));

    // 1. สร้าง params สำหรับรองรับการเลือกไฟล์บน WebView
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final WebViewController controller = WebViewController.fromPlatformCreationParams(params);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
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
            await _cacheDriverContext();
          },
          onWebResourceError: (error) {
            debugPrint('WebView error: ${error.description}');
          },
        ),
      )
      ..addJavaScriptChannel(
        'LocationChannel',
        onMessageReceived: (JavaScriptMessage message) {
          if (message.message == 'requestLocation') {
            _requestLocationAndSend();
          }
        },
      );

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
      (controller.platform as AndroidWebViewController)
          .setOnShowFileSelector(_androidFilePicker);
    }

    _controller = controller;
    _controller.loadRequest(Uri.parse(_baseUrl));
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
      final cookies = await _cookieManager.getCookies(domain: Uri.parse(_baseUrl));
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

  // อ่าน truck_id/driver_id ที่หน้าเว็บตั้งไว้เป็น global variable แล้ว cache เก็บไว้ใน Dart
  // เพื่อให้ยิงพิกัดขึ้น API ได้แม้ตอนแอปอยู่ background และ WebView ไม่ได้ทำงาน
  Future<void> _cacheDriverContext() async {
    try {
      final truckIdRaw = await _controller.runJavaScriptReturningResult(
        'window.truck_id ?? ""',
      );
      final driverIdRaw = await _controller.runJavaScriptReturningResult(
        'window.driver_id ?? ""',
      );
      final truckId = _unwrapJsString(truckIdRaw);
      final driverId = _unwrapJsString(driverIdRaw);
      if (truckId.isNotEmpty) _truckId = truckId;
      if (driverId.isNotEmpty) _driverId = driverId;
      debugPrint('[Flutter] cache driver context: truck_id=$_truckId, driver_id=$_driverId');
    } catch (e) {
      debugPrint('Driver context read error: $e');
    }
  }

  String _unwrapJsString(Object result) {
    var value = result.toString();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  Future<void> _requestLocationAndSend() async {
    try {
      debugPrint('[Flutter] กำลังดึงพิกัด GPS...');

      await _ensureLocationPermission();

      Position? position;

      try {
        // 1. พยายามดึงพิกัดปัจจุบัน (ให้เวลา 5 วินาทีพอ)
        position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 5),
          ),
        );
      } catch (e) {
        debugPrint('[Flutter] ดึงพิกัดปัจจุบัน Timeout/ล้มเหลว พยายามดึง Last Known Position แทน...');
        // 2. ถ้าดึงพิกัดปัจจุบันไม่ได้ ให้ดึงพิกัดล่าสุดที่เครื่องเคยบันทึกไว้
        position = await Geolocator.getLastKnownPosition();
      }

      if (position != null) {
        debugPrint('[Flutter] ได้รับพิกัดแล้ว: ${position.latitude}, ${position.longitude}');
        await _setLocation(position);
      } else {
        debugPrint('[Flutter] ไม่สามารถหาพิกัด GPS จากเครื่องได้');
        
        final mockPosition = Position(
          latitude: 13.7563, 
          longitude: 100.5018, 
          timestamp: DateTime.now(), 
          accuracy: 0, altitude: 0, heading: 0, speed: 0, speedAccuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0
        );
        await _setLocation(mockPosition);
        
      }

    } catch (error) {
      debugPrint('[Flutter Location Error]: $error');
    }
  }

  Future<List<String>> _androidFilePicker(FileSelectorParams params) async {
    final ImagePicker picker = ImagePicker();
    XFile? photo;

    try {
      final ImageSource? source = await showDialog<ImageSource>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('เลือกรูปภาพหลักฐาน'),
          content: const Text('กรุณาเลือกช่องทางในการอัปโหลดรูปภาพ'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, ImageSource.camera),
              style: TextButton.styleFrom(
                textStyle: TextStyle(fontSize: 18),
              ),
              child: const Text('📸 ถ่ายรูปเลย !'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, ImageSource.gallery),
              style: TextButton.styleFrom(
                textStyle: TextStyle(fontSize: 18),
              ),
              child: const Text('📁 เลือกจากคลังภาพ'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              style: TextButton.styleFrom(
                textStyle: TextStyle(fontSize: 18),
              ),
              child: const Text('ยกเลิก', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      );

      if (source != null) {
        photo = await picker.pickImage(source: source);
      }
      
      if (photo != null) {
        return <String>[Uri.file(photo.path).toString()];
      }
    } catch (e) {
      debugPrint('ข้อผิดพลาด: $e');
    }
    return <String>[];
  }

  Future<void> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled.');
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw Exception('Location permission denied.');
    }
    // ขอสิทธิ์ location "Always" เพิ่ม เพื่อให้ยังส่งพิกัดต่อได้แม้ปิดหน้าจอ/แอปอยู่ background
    if (permission == LocationPermission.whileInUse) {
      final alwaysPermission = await Geolocator.requestPermission();
      if (alwaysPermission != LocationPermission.always) {
        debugPrint('[Flutter] ผู้ใช้ไม่ได้ให้สิทธิ์ Always location, background tracking อาจไม่เสถียร');
      }
    }
  }

  // สตรีมพิกัดต่อเนื่องผ่าน Foreground Service (Android) / Background Location (iOS)
  // เพื่อให้ยังส่งพิกัดได้แม้ปิดหน้าจอหรือสลับแอปไปทำงานอื่น
  Future<void> _startBackgroundLocationTracking() async {
    // Android 13+ ต้องขอ POST_NOTIFICATIONS ก่อน ไม่งั้น notification ของ foreground service จะไม่ถูกส่งเลย
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      if (!status.isGranted) {
        debugPrint('[BackgroundLocation] ผู้ใช้ไม่ได้ให้สิทธิ์ Notification, foreground service อาจไม่แสดง notification');
      }
    }

    final LocationSettings locationSettings;
    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 0,
        intervalDuration: const Duration(minutes: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Sunny Logistic กำลังติดตามตำแหน่ง',
          notificationText: 'แอปกำลังส่งพิกัดตำแหน่งของคุณให้ระบบขนส่ง',
          enableWakeLock: true,
        ),
      );
    } else if (Platform.isIOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.medium,
        activityType: ActivityType.otherNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 0,
      );
    }

    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _onBackgroundPosition,
      onError: (Object e) => debugPrint('[BackgroundLocation] stream error: $e'),
    );
  }

  Future<void> _onBackgroundPosition(Position position) async {
    debugPrint('[BackgroundLocation] ${position.latitude}, ${position.longitude}');
    if (_appLifecycleState == AppLifecycleState.resumed) {
      await _setLocation(position);
    }
    await _sendLocationToServer(position);
  }

  Future<void> _sendLocationToServer(Position position) async {
    if (_truckId == null || _driverId == null || (_authCookieValue ?? '').isEmpty) {
      debugPrint('[BackgroundLocation] ยังไม่มี truck_id/driver_id/cookie ครบ, ข้ามการส่ง');
      return;
    }
    final uri = Uri.parse(
      '$_baseUrl/api/saveLocation/$_truckId/$_driverId/${position.latitude}/${position.longitude}',
    );
    try {
      final response = await http.get(uri, headers: {'Cookie': 'auth=$_authCookieValue'});
      debugPrint('[BackgroundLocation] sent -> ${response.statusCode}: ${response.body}');
    } catch (e) {
      debugPrint('[BackgroundLocation] send error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      // รีเฟรช cookie/truck_id/driver_id ใหม่ทุกครั้งที่กลับมาหน้าจอ เผื่อมีการ login ใหม่
      _checkCookies();
      _cacheDriverContext();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  Future<void> _setLocation(Position position) async {
    final String jsCode = '''
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
      debugPrint('[Flutter -> EJS Variable] ยิงค่าพิกัดสำเร็จ: ${position.latitude}, ${position.longitude}');
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