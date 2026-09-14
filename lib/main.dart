import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

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

class _WebViewPageState extends State<WebViewPage> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  bool _isLoading = true;

  final String _baseUrl = 'https://logistic.worldchemical.co.th';

  @override
  void initState() {
    super.initState();

    _ensureLocationPermission().catchError((e) => debugPrint('Permission error: $e'));

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
            _checkCookies();
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
      }
    } catch (e) {
      debugPrint('Cookie Check Error: $e');
    }
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