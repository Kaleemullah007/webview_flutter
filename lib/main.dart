import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ThermalWebViewApp(),
  ));
}

class ThermalWebViewApp extends StatefulWidget {
  const ThermalWebViewApp({super.key});

  @override
  State<ThermalWebViewApp> createState() => _ThermalWebViewAppState();
}

class _ThermalWebViewAppState extends State<ThermalWebViewApp> {
  // اپنی ویب سائٹ کا اصل URL یہاں لکھیں
  final String websiteUrl = 'https://happybitepizza.com/login';

  late final WebViewController _webController;
  List<BluetoothInfo> _devices = [];
  String? _connectedMac;
  bool _isConnected = false;
  String _statusText = 'Printer disconnected';

  @override
  void initState() {
    super.initState();
    _initPermissionsAndBluetooth();
    _initWebView();
  }

  Future<void> _initPermissionsAndBluetooth() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.bluetooth,
      ].request();
    }

    await _loadPairedDevices();
  }

  Future<void> _loadPairedDevices() async {
    final List<BluetoothInfo> list =
        await PrintBluetoothThermal.pairedBluetooths;
    setState(() {
      _devices = list;
    });

    // اگر Speed-X پرنٹر پہلے سے موجود ہو تو خودکار کنیکٹ کرنے کی کوشش
    for (final d in list) {
      if (d.name.toUpperCase().contains('SX-BT450M') ||
          d.name.toUpperCase().contains('BT450')) {
        await _connectToPrinter(d);
        break;
      }
    }
  }

  Future<void> _connectToPrinter(BluetoothInfo device) async {
    setState(() {
      _statusText = 'Connecting to ${device.name}...';
    });

    final bool result =
        await PrintBluetoothThermal.connect(macPrinterAddress: device.macAdress);

    setState(() {
      _isConnected = result;
      _connectedMac = result ? device.macAdress : null;
      _statusText = result
          ? 'Connected: ${device.name}'
          : 'Failed to connect: ${device.name}';
    });
  }

  // Desktop-style Chrome UA: some backends silently withhold list/API data
  // (orders, users, etc.) when they detect the Android WebView "; wv)"
  // marker in the default user agent, even though the page itself renders
  // fine. Using a normal Chrome UA avoids that WebView-specific blocking.
  static const String _desktopLikeUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopLikeUserAgent)
      ..addJavaScriptChannel(
        'PrinterBridge',
        onMessageReceived: (JavaScriptMessage message) async {
          await _handlePrintPayload(message.message);
        },
      )
      ..loadRequest(Uri.parse(websiteUrl));
  }

  Future<void> _handlePrintPayload(String rawMessage) async {
    bool connected = await PrintBluetoothThermal.connectionStatus;
    if (!connected && _connectedMac != null) {
      connected = await PrintBluetoothThermal.connect(
          macPrinterAddress: _connectedMac!);
      setState(() => _isConnected = connected);
    }

    if (!connected) {
      _showSnack('پرنٹر کنیکٹ نہیں ہے۔ اوپر بلوٹوتھ آئیکن سے کنیکٹ کریں۔');
      return;
    }

    String title = 'PRINT RECEIPT';
    String body = rawMessage;
    String qr = '';

    try {
      final decoded = jsonDecode(rawMessage);
      if (decoded is Map<String, dynamic>) {
        title = (decoded['title'] ?? 'RECEIPT').toString();
        body = (decoded['body'] ?? '').toString();
        qr = (decoded['qr'] ?? '').toString();
      }
    } catch (_) {
      // سادہ ٹیکسٹ کی صورت میں
    }

    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, profile);
    List<int> bytes = [];

    bytes += generator.reset();
    bytes += generator.text(
      title,
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size1,
      ),
    );
    bytes += generator.hr();

    for (final line in body.split('\n')) {
      bytes += generator.text(
        line,
        styles: const PosStyles(align: PosAlign.left),
      );
    }

    // QR code (invoice verification link), when provided by the web page
    if (qr.isNotEmpty) {
      bytes += generator.feed(1);
      bytes += generator.text(
        'Scan to Verify',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
      bytes += generator.qrcode(qr, size: QRSize.size6);
    }

    bytes += generator.feed(2);
    bytes += generator.cut();

    final bool sent = await PrintBluetoothThermal.writeBytes(bytes);
    _showSnack(
        sent ? 'پرنٹ کامیابی سے بھیج دیا گیا!' : 'پرنٹ بھیجنے میں ناکامی ہوئی۔');
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _openPrinterDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Bluetooth Printer'),
        content: SizedBox(
          width: double.maxFinite,
          child: _devices.isEmpty
              ? const Text(
                  'کوئی پرنٹر نہیں ملا۔ پہلے فون کی بلوٹوتھ سیٹنگز میں Speed-X SX-BT450M کو Pair کریں۔')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    final d = _devices[index];
                    return ListTile(
                      leading: const Icon(Icons.print),
                      title: Text(d.name),
                      subtitle: Text(d.macAdress),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _connectToPrinter(d);
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await _loadPairedDevices();
              if (mounted) Navigator.pop(ctx);
              _openPrinterDialog();
            },
            child: const Text('Refresh'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Go back in WebView history; if there is no history, exit the app.
  Future<void> _goBackOrExit() async {
    if (await _webController.canGoBack()) {
      await _webController.goBack();
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Intercept the Android back button/gesture: navigate the WebView
      // back instead of closing the app (error pages included).
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _goBackOrExit();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: _goBackOrExit,
          ),
          titleSpacing: 0,
          title: Text(
            _statusText,
            style: TextStyle(
              fontSize: 12,
              color: _isConnected ? Colors.greenAccent : Colors.amber,
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload page',
              onPressed: () => _webController.reload(),
            ),
            IconButton(
              icon: const Icon(Icons.home_outlined),
              tooltip: 'Home',
              onPressed: () =>
                  _webController.loadRequest(Uri.parse(websiteUrl)),
            ),
            IconButton(
              icon: Icon(
                _isConnected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
              ),
              onPressed: _openPrinterDialog,
              tooltip: 'Bluetooth Printer',
            ),
          ],
        ),
        body: WebViewWidget(controller: _webController),
      ),
    );
  }
}
