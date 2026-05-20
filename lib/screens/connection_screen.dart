import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  bool _isScanning = false;
  List<ScanResult> _scanResults = [];

  @override
  void initState() {
    super.initState();
    _requestPermissions(); // 화면 켜지면 권한 요청
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
  }

  void _startScan() async {
    setState(() {
      _isScanning = true;
      _scanResults.clear();
    });

    // 4초간 스캔
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    // 스캔 결과 리스너
    FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          _scanResults = results;
        });
      }
    });

    // 스캔 종료 처리
    await Future.delayed(const Duration(seconds: 4));
    if (mounted) {
      setState(() {
        _isScanning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('워치 연결 설정')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[200],
            width: double.infinity,
            child: Text(
              _isScanning ? '주변 기기를 찾는 중...' : '버튼을 눌러 워치를 찾아보세요.',
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _scanResults.length,
              itemBuilder: (context, index) {
                final data = _scanResults[index];
                return ListTile(
                  leading: const Icon(Icons.watch),
                  title: Text(data.device.platformName.isNotEmpty
                      ? data.device.platformName
                      : '이름 없는 기기'),
                  subtitle: Text(data.device.remoteId.toString()),
                  trailing: ElevatedButton(
                    onPressed: () {
                      print('연결 시도: ${data.device.platformName}');
                    },
                    child: const Text('연결'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isScanning ? null : _startScan,
        child: Icon(_isScanning ? Icons.hourglass_top : Icons.search),
      ),
    );
  }
}