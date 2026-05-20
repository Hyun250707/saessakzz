import 'package:flutter/material.dart';
import 'screens/map_screen.dart';        // 지도 화면 불러오기
import 'screens/indoor_map_screen.dart'; // 실내 길찾기
import 'screens/connection_screen.dart'; // 연결 화면 불러오기

void main() {
  runApp(const NaviApp());
}

class NaviApp extends StatelessWidget {
  const NaviApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '길치 내비게이션',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MainFrame(),
    );
  }
}

class MainFrame extends StatefulWidget {
  const MainFrame({super.key});

  @override
  State<MainFrame> createState() => _MainFrameState();
}

class _MainFrameState extends State<MainFrame> {
  int _selectedIndex = 0; // 현재 선택된 탭 번호

  // 탭별 화면 목록
  final List<Widget> _screens = [
    const MapScreen(),        // 0번: 지도
    const IndoorMapScreen(),  // 1번: 실내 길찾기
    const ConnectionScreen(), // 2번: 연결
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 현재 선택된 인덱스에 맞는 화면을 보여줌
      body: _screens[_selectedIndex], 
      
      // 하단 내비게이션 바
      bottomNavigationBar: BottomNavigationBar(
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.map), label: '지도'),
          BottomNavigationBarItem(icon: Icon(Icons.map_outlined), label: '실내'),
          BottomNavigationBarItem(icon: Icon(Icons.bluetooth), label: '워치 연결'),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.blue,
        onTap: _onItemTapped,
      ),
    );
  }
}