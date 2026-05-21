import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../services/api_service.dart';
import '../models/api_models.dart' as api;

const distanceCalc = Distance();

// 경로 타입 정의
enum RouteType { car, transit, pedestrian }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController mapController = MapController();
  final TextEditingController searchController = TextEditingController();

  // 🔑 TMAP API Key (본인 키 확인!)
  final String tmapApiKey = "oPmHu2DTfF9nZDMxf8oR51PKiQIdpAVZ7rKq6Tj5";

  // 📡 [필수] 내 컴퓨터(서버) IP 주소
  final String serverIp = "165.229.125.244"; 
  final String serverPort = "8000";
  
  final ApiService apiService = ApiService();

  // 📍 위치 데이터f
  LatLng myPosition = const LatLng(35.83063, 128.75437); // 영남대
  LatLng? destination;
  String destinationName = "";

  // 🛣️ 경로 데이터
  RouteType selectedRouteType = RouteType.pedestrian;
  List<LatLng> routePoints = [];
  Map<RouteType, List<LatLng>> routeCache = {}; 
  Map<RouteType, Map<String, dynamic>> routeInfo = {}; 
  
  // 📱 UI 상태
  bool isNavigating = false;
  bool showPreciseLocationInfo = false;
  bool showSearchScreen = false;
  bool largeTextMode = true; 
  double markerRotation = 0.0;
  bool showRouteGuidePanel = false; // 다음 경로 안내 패널 표시 여부 

  // 데이터 리스트
  List<Map<String, dynamic>> searchResults = [];
  List<Map<String, String>> friendlyCues = []; // [{title, subtitle, icon}]

  // 안내 멘트 / 단계 정보
  String mainInstruction = "도착지를 선택해주세요";
  String subInstruction = "지도를 눌러 목적지를 선택하거나, 위 검색창에서 장소를 검색하세요.";
  IconData currentTurnIcon = Icons.explore;
  int _currentCueIndex = 0; // friendlyCues 내 현재 단계 인덱스

  // 타이머 & GPS 스트림
  Timer? _navigationTimer;
  int _currentPointIndex = 0;
  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<CompassEvent>? _compassStreamSubscription;
  
  // 🧭 라즈베리파이 방향 지시용 변수
  double myCurrentHeading = 0.0;
  String _lastSentCommand = "";

  @override
  void initState() {
    super.initState();
    _startGpsTracking();
    _startCompassTracking();
  }

  @override
  void dispose() {
    _navigationTimer?.cancel();
    _positionStreamSubscription?.cancel();
    _compassStreamSubscription?.cancel();
    searchController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // 🛰️ [GPS] 실시간 위치 추적
  // ===========================================================================
  Future<void> _startGpsTracking() async {
    bool serviceEnabled;
    LocationPermission permission;

    // 위치 서비스 활성화 여부 확인
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showErrorDialog("GPS 오류", "스마트폰의 위치 서비스(GPS)를 켜주세요.");
      return;
    }

    // 권한 확인 및 요청
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showErrorDialog("권한 오류", "위치 권한이 거부되었습니다.");
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      _showErrorDialog("권한 오류", "위치 권한이 영구적으로 거부되었습니다. 설정에서 허용해주세요.");
      return;
    }

    // 실시간 위치 스트림 구독 (걸을 때마다 업데이트됨)
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high, // 높은 정확도
      distanceFilter: 0,               // 즉각 반응을 위해 필터 0으로 설정 (실내/제자리 테스트 용이)
    );

    _positionStreamSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        setState(() {
          myPosition = LatLng(position.latitude, position.longitude);
        });
        
        // 내비게이션 중이면 지도 카메라를 내 위치로 자동 이동
        if (isNavigating) {
          mapController.move(myPosition, mapController.camera.zoom);
        }
        
        // (선택) 위치가 바뀔 때마다 서버에 전송
        sendLocationToServer();
      },
      onError: (e) {
        print("GPS Stream Error: $e");
      }
    );
  }

  // 🚨 에러 알림창
  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("🚨 $title"),
        content: Text(content),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("확인"))],
      ),
    );
  }

  // ===========================================================================
  // 🧭 [나침반] 실시간 방향 추적
  // ===========================================================================
  void _startCompassTracking() {
    _compassStreamSubscription = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading != null) {
        setState(() {
          // 스마트폰의 진짜 물리적 나침반 각도 저장
          myCurrentHeading = event.heading!; 
        });
      }
    });
  }

  // ===========================================================================
  // 📡 [서버 통신] 서버 연결 테스트
  // ===========================================================================
  Future<bool> testServerConnection() async {
    final url = Uri.parse("http://$serverIp:$serverPort/api/location");
    
    try {
      var response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "user_id": "test",
          "latitude": 0.0,
          "longitude": 0.0,
          "timestamp": DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 3));
      
      return response.statusCode == 200;
    } catch (e) {
      print("서버 연결 테스트 실패: $e");
      return false;
    }
  }

  // ===========================================================================
  // 📡 [서버 통신] 내 위치를 파이썬 서버로 전송! (복구됨)
  // ===========================================================================
  Future<void> sendLocationToServer() async {
    final success = await apiService.sendLocation(api.LocationData(
      userId: "student_229",
      latitude: myPosition.latitude,
      longitude: myPosition.longitude,
      timestamp: DateTime.now().toIso8601String(),
    ));

    if (success) {
      print("✅ 서버 전송 성공");
    } else {
      print("❌ 서버 전송 실패");
    }
  }

  // ===========================================================================
  // 📡 [서버 통신] 라즈베리파이로 실시간 방향(화살표) 전송
  // ===========================================================================
  Future<void> sendDirectionToServer(String directionCommand) async {
    // 중복 전송 방지
    if (_lastSentCommand == directionCommand) return;
    
    try {
      final url = Uri.parse("http://$serverIp:$serverPort/api/navi/direction"); 
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'command': directionCommand}), 
      );
      _lastSentCommand = directionCommand;
      print('✅ 라즈베리파이 방향 갱신: $directionCommand');
    } catch (e) {
      print('❌ 방향 서버 전송 에러: $e');
    }
  }

  // ===========================================================================
  // 📡 [API 1] 장소 검색
  // ===========================================================================
  Future<void> searchPlace(String query) async {
    if (query.isEmpty) return;

    final url = Uri.https(
      "apis.openapi.sk.com",
      "/tmap/pois",
      {
        "version": "1",
        "searchKeyword": query,
        "resCoordType": "WGS84GEO",
        "reqCoordType": "WGS84GEO",
        "count": "10",
      },
    );
    
    try {
      var response = await http.get(url, headers: {
        "appKey": tmapApiKey,
        "Content-Type": "application/json",
      });
      
      if (response.statusCode == 200) {
        var json = jsonDecode(response.body);
        var poiInfo = json['searchPoiInfo'];
        
        if (poiInfo == null || poiInfo['pois'] == null) {
           _showErrorDialog("검색 실패", "검색 결과가 없습니다.");
           return;
        }

        var poiList = poiInfo['pois']['poi'] as List;

        setState(() {
          searchResults = poiList.map((item) {
            return {
              "name": item['name'],
              "addr": item['upperAddrName'] + " " + item['middleAddrName'] + " " + item['lowerAddrName'],
              "lat": double.parse(item['noorLat']),
              "lng": double.parse(item['noorLon']),
            };
          }).toList();
        });
      }
    } catch (e) {
      _showErrorDialog("네트워크 오류", "인터넷 연결을 확인해주세요.\n$e");
    }
  }

  // ===========================================================================
  // 📡 [API 2] 주소 변환
  // ===========================================================================
  Future<void> getAddressFromLatLng(LatLng point) async {
    final url = Uri.https(
      "apis.openapi.sk.com",
      "/tmap/geo/reversegeocoding",
      {
        "version": "1",
        "lat": point.latitude.toString(),
        "lon": point.longitude.toString(),
        "coordType": "WGS84GEO",
        "addressType": "A04",
      },
    );
    
    try {
      var response = await http.get(url, headers: {"appKey": tmapApiKey});
      
      if (response.statusCode == 200) {
        var json = jsonDecode(response.body);
        var addressInfo = json['addressInfo'];
        
        setState(() {
          String building = addressInfo['buildingName'] ?? "";
          if (building.isEmpty) {
            destinationName = addressInfo['fullAddress'];
          } else {
            destinationName = building;
          }
          
          if (destination != point) {
            routeCache.clear();
            routeInfo.clear();
            routePoints.clear();
          }
          
          destination = point;
          showPreciseLocationInfo = true;
          showSearchScreen = false;
        });
      } else {
        setState(() {
          destinationName = "선택한 위치";
          destination = point;
          showPreciseLocationInfo = true;
          showSearchScreen = false;
        });
      }
    } catch (e) {
      print("주소 변환 에러: $e");
    }
  }

  // ===========================================================================
  // 📡 [API 3] 경로 탐색
  // ===========================================================================
  Future<void> getRoute() async {
    if (destination == null) return;
    
    if (routeCache.containsKey(selectedRouteType) && routeCache[selectedRouteType]!.isNotEmpty) {
      setState(() {
        routePoints = routeCache[selectedRouteType]!;
        showPreciseLocationInfo = false;
        if (routePoints.isNotEmpty) {
          mapController.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(routePoints),
              padding: const EdgeInsets.all(80),
            ),
          );
        }
      });
      return;
    }

    String endpoint;
    Map<String, dynamic> requestBody = {};

    if (selectedRouteType == RouteType.transit) {
      endpoint = "/transit/routes";
      DateTime now = DateTime.now();
      String formattedTime = "${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}${_twoDigits(now.hour)}${_twoDigits(now.minute)}";

      requestBody = {
        "startX": myPosition.longitude.toString(),
        "startY": myPosition.latitude.toString(),
        "endX": destination!.longitude.toString(),
        "endY": destination!.latitude.toString(),
        "format": "json",
        "count": 1,
        "searchDttm": formattedTime, 
      };
    } else {
      endpoint = selectedRouteType == RouteType.car ? "/tmap/routes" : "/tmap/routes/pedestrian";
      requestBody = {
        "startX": myPosition.longitude,
        "startY": myPosition.latitude,
        "endX": destination!.longitude,
        "endY": destination!.latitude,
        "reqCoordType": "WGS84GEO",
        "resCoordType": "WGS84GEO",
        "startName": "출발지",
        "endName": "도착지",
      };
    }

    final url = Uri.https("apis.openapi.sk.com", endpoint, {"version": "1", "format": "json", "appKey": tmapApiKey});
    
    try {
      var response = await http.post(
        url,
        headers: {
          "appKey": tmapApiKey,
          "Content-Type": "application/json",
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        List<LatLng> tempPoints = [];
        Map<String, dynamic> info = {};
        
        // 🚌 대중교통 파싱
        if (selectedRouteType == RouteType.transit) {
          if (data['metaData'] != null && data['metaData']['plan'] != null && data['metaData']['plan']['itineraries'].isNotEmpty) {
            var itinerary = data['metaData']['plan']['itineraries'][0];
            info = {
              'totalTime': itinerary['totalTime'],
              'totalDistance': itinerary['totalDistance'],
            };
            var legs = itinerary['legs'] as List;
            for (var leg in legs) {
              dynamic passShape = leg['passShape'];
              if (passShape != null && passShape is String) {
                var points = passShape.split(' ');
                for (var p in points) {
                  var coords = p.split(',');
                  if (coords.length == 2) {
                    tempPoints.add(LatLng(double.parse(coords[1]), double.parse(coords[0])));
                  }
                }
              }
            }
          } else {
             _showErrorDialog("경로 없음", "대중교통 경로를 찾을 수 없습니다.\n(시간표가 없거나 거리가 너무 가까울 수 있습니다.)");
             return;
          }
        } else {
          // 🚶‍♂️🚗 보행자/자동차 파싱
          var features = data['features'] as List?;
          if (features != null) {
            for (var feature in features) {
              if (feature['geometry']['type'] == 'LineString') {
                var coords = feature['geometry']['coordinates'];
                for (var coord in coords) {
                  tempPoints.add(LatLng(coord[1].toDouble(), coord[0].toDouble()));
                }
              }
            }
            if (features.isNotEmpty) {
               var props = features[0]['properties'];
               info = {
                 'totalTime': props['totalTime'] ?? 0,
                 'totalDistance': props['totalDistance'] ?? 0,
               };
            }
          }
        }
        
        setState(() {
          routePoints = tempPoints;
          routeCache[selectedRouteType] = tempPoints;
          routeInfo[selectedRouteType] = info;
          friendlyCues = _buildFriendlyCues(tempPoints);
          _currentCueIndex = 0;

          if (friendlyCues.isNotEmpty) {
            mainInstruction = friendlyCues[0]['title'] ?? "안내를 시작합니다";
            subInstruction = friendlyCues[0]['subtitle'] ?? "";
            currentTurnIcon = _getIconFromCue(friendlyCues[0]['icon']);
          }
          
          if (routePoints.isNotEmpty) {
            showPreciseLocationInfo = false;
            mapController.fitCamera(
              CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(routePoints),
                padding: const EdgeInsets.all(80),
              ),
            );
          }
        });
      } else {
        _showErrorDialog("경로 탐색 실패", "서버 응답 오류 (${response.statusCode})\n${response.body}");
      }
    } catch (e) {
      _showErrorDialog("오류", "네트워크 오류: $e");
    }
  }

  // ===========================================================================
  // 📡 [서버 기반 길찾기] FastAPI /api/route 사용
  // ===========================================================================
  Future<void> getRouteFromServer() async {
    if (destination == null) return;

    final response = await apiService.findRoute(api.RouteRequest(
      userId: "student_229",
      startLatitude: myPosition.latitude,
      startLongitude: myPosition.longitude,
      endLatitude: destination!.latitude,
      endLongitude: destination!.longitude,
    ));

    if (response != null && response.status == "success") {
      final List<LatLng> tempPoints = response.path
          .map<LatLng>((p) => LatLng(p.latitude, p.longitude))
          .toList();

      setState(() {
        routePoints = tempPoints;
        routeCache.clear();
        routeInfo.clear();
        friendlyCues = _buildFriendlyCues(tempPoints);
        _currentCueIndex = 0;

        if (friendlyCues.isNotEmpty) {
          mainInstruction = friendlyCues[0]['title'] ?? "안내를 시작합니다";
          subInstruction = friendlyCues[0]['subtitle'] ?? "";
          currentTurnIcon = Icons.navigation;
        }

        if (routePoints.isNotEmpty) {
          showPreciseLocationInfo = false;
          mapController.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(routePoints),
              padding: const EdgeInsets.all(80),
            ),
          );
        }
      });
    } else {
      _showErrorDialog("경로 탐색 실패", response?.message ?? "서버 응답 오류");
    }
  }

  // ---------------------------------------------------------
  // 🧩 유틸리티
  // ---------------------------------------------------------
  String _twoDigits(int n) {
    if (n >= 10) return "$n";
    return "0$n";
  }
  
  void _changeRouteType(RouteType type) {
    setState(() {
      selectedRouteType = type;
      if (destination != null) getRoute();
    });
  }

  Color _getRouteColor(RouteType type) {
    switch (type) {
      case RouteType.car: return Colors.blue;
      case RouteType.transit: return Colors.green;
      case RouteType.pedestrian: return Colors.redAccent;
    }
  }

  String _getRouteInfoText() {
    if (!routeInfo.containsKey(selectedRouteType)) return "";
    var info = routeInfo[selectedRouteType]!;
    int seconds = info['totalTime'] is int ? info['totalTime'] : (info['totalTime'] as num).toInt();
    int distance = info['totalDistance'] is int ? info['totalDistance'] : (info['totalDistance'] as num).toInt();
    
    int minutes = (seconds / 60).round();
    String timeStr = minutes < 60 ? "$minutes분" : "${minutes ~/ 60}시간 ${minutes % 60}분";
    String distStr = distance < 1000 ? "${distance}m" : "${(distance / 1000).toStringAsFixed(1)}km";
    
    return "$timeStr · $distStr";
  }

  List<Map<String, String>> _buildFriendlyCues(List<LatLng> points) {
    if (points.length < 2) return [];

    const distanceCalc = Distance();
    final cues = <Map<String, String>>[];
    double accumulated = 0;

    for (int i = 0; i < points.length - 1; i++) {
      final segment = distanceCalc(points[i], points[i + 1]);
      accumulated += segment;

      if (i < points.length - 2) {
        final angle = _calculateTurnAngle(points[i], points[i + 1], points[i + 2]);
        final direction = _getTurnDirection(points[i], points[i + 1], points[i + 2]);
        final isPivot = angle > 25 || accumulated > 120;

        if (isPivot) {
          cues.add({
            "title": direction == "직진" ? "경로 유지" : "$direction 준비",
            "subtitle": "${_formatDistance(accumulated)} 후",
          });
          accumulated = 0;
        }
      }
    }

    if (cues.isEmpty) {
      cues.add({
        "title": "천천히 이동",
        "subtitle": "파란 선을 따라가면 돼요",
      });
    }

    cues.add({
      "title": "목적지",
      "subtitle": destinationName.isNotEmpty ? destinationName : "목적지 근처",
    });

    return cues.take(6).toList();
  }

  // 두 점 간 거리 포맷팅
  String _formatDistance(double meters) {
    if (meters < 1000) {
      return "${meters.round()}m";
    }
    return "${(meters / 1000).toStringAsFixed(1)}km";
  }

  // 방향 전환 각도 계산
  double _calculateTurnAngle(LatLng prev, LatLng current, LatLng next) {
    double bearing1 = _calculateBearing(prev, current);
    double bearing2 = _calculateBearing(current, next);
    double angle = (bearing2 - bearing1 + 360) % 360;
    if (angle > 180) angle = 360 - angle;
    return angle;
  }

  // 방향 전환 타입 판단
  String _getTurnDirection(LatLng prev, LatLng current, LatLng next) {
    double bearing1 = _calculateBearing(prev, current);
    double bearing2 = _calculateBearing(current, next);
    double angle = (bearing2 - bearing1 + 360) % 360;

    if (angle < 30 || angle > 330) return "직진";
    if (angle >= 30 && angle < 150) return "우회전";
    if (angle >= 150 && angle < 210) return "유턴";
    return "좌회전";
  }

  IconData _getIconFromCue(String? type) {
    switch (type) {
      case "start":
        return Icons.my_location;
      case "straight":
        return Icons.arrow_upward;
      case "left":
        return Icons.turn_left;
      case "right":
        return Icons.turn_right;
      case "finish":
        return Icons.flag;
      case "error":
        return Icons.error_outline;
      default:
        return Icons.navigation;
    }
  }

  // Cue 제목에서 아이콘 추출
  IconData _getCueIcon(String title) {
    if (title.contains("좌")) return Icons.turn_left;
    if (title.contains("우")) return Icons.turn_right;
    if (title.contains("유턴")) return Icons.u_turn_left;
    if (title.contains("목적지")) return Icons.flag;
    if (title.contains("경로 유지") || title.contains("직진")) return Icons.arrow_upward;
    return Icons.directions_walk;
  }

  // 길치 전용 다음 경로 안내 패널
  Widget _buildFriendlyGuidePanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 12)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.assistant_navigation,
                color: _getRouteColor(selectedRouteType),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                "다음 경로 안내",
                style: TextStyle(
                  fontSize: largeTextMode ? 16 : 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const Spacer(),
              Text(
                "길치 모드",
                style: TextStyle(
                  fontSize: largeTextMode ? 12 : 11,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (friendlyCues.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                "경로를 따라 천천히 이동하세요.",
                style: TextStyle(
                  fontSize: largeTextMode ? 14 : 13,
                  color: Colors.grey[600],
                ),
              ),
            )
          else
            SizedBox(
              height: 110,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (context, index) {
                  final cue = friendlyCues[index];
                  final isFirst = index == 0;
                  return Container(
                    width: 170,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isFirst
                          ? _getRouteColor(selectedRouteType).withValues(alpha: 0.1)
                          : Colors.grey.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(14),
                      border: isFirst
                          ? Border.all(
                              color: _getRouteColor(selectedRouteType),
                              width: 2,
                            )
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _getCueIcon(cue["title"] ?? ""),
                          color: isFirst
                              ? _getRouteColor(selectedRouteType)
                              : Colors.grey[700],
                          size: 28,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          cue["title"] ?? "",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: largeTextMode ? 15 : 14,
                            color: isFirst ? _getRouteColor(selectedRouteType) : Colors.black87,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          cue["subtitle"] ?? "",
                          style: TextStyle(
                            color: Colors.black54,
                            fontSize: largeTextMode ? 13 : 12,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemCount: friendlyCues.length,
              ),
            ),
        ],
      ),
    );
  }

  double _calculateBearing(LatLng start, LatLng end) {
    double lat1 = start.latitude * math.pi / 180;
    double lat2 = end.latitude * math.pi / 180;
    double dLon = (end.longitude - start.longitude) * math.pi / 180;
    double y = math.sin(dLon) * math.cos(lat2);
    double x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    double bearing = math.atan2(y, x) * 180 / math.pi;
    return (bearing + 360) % 360;
  }

  // 두 지점 간 거리 계산 (미터 단위)
  double _calculateDistance(LatLng start, LatLng end) {
    const double earthRadius = 6371000; // 지구 반지름 (미터)
    double lat1 = start.latitude * math.pi / 180;
    double lat2 = end.latitude * math.pi / 180;
    double dLat = (end.latitude - start.latitude) * math.pi / 180;
    double dLon = (end.longitude - start.longitude) * math.pi / 180;
    
    double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  // 경로에서 다음 방향 전환 지점 찾기
  Map<String, dynamic>? _findNextTurnPoint(int currentIndex) {
    if (routePoints.length < 3 || currentIndex >= routePoints.length - 2) {
      return null;
    }

    // 현재 위치에서 앞으로 10개 포인트씩 확인하면서 방향 변화 감지
    for (int i = currentIndex + 1; i < math.min(currentIndex + 50, routePoints.length - 1); i++) {
      if (i < 2) continue;
      
      LatLng prev = routePoints[i - 2];
      LatLng curr = routePoints[i - 1];
      LatLng next = routePoints[i];
      
      double bearing1 = _calculateBearing(prev, curr);
      double bearing2 = _calculateBearing(curr, next);
      
      // 방향 차이 계산
      double angleDiff = (bearing2 - bearing1 + 540) % 360 - 180;
      
      // 30도 이상 회전이 있으면 방향 전환 지점으로 판단
      if (angleDiff.abs() > 30) {
        double distance = _calculateDistance(routePoints[currentIndex], routePoints[i]);
        String direction;
        IconData icon;
        
        // angleDiff > 0: 시계방향 회전 → 우회전
        // angleDiff < 0: 반시계방향 회전 → 좌회전
        if (angleDiff > 0) {
          direction = angleDiff > 90 ? "오른쪽으로" : "오른쪽으로 약간";
          icon = Icons.turn_right;
        } else {
          direction = angleDiff < -90 ? "왼쪽으로" : "왼쪽으로 약간";
          icon = Icons.turn_left;
        }
        
        return {
          "index": i,
          "distance": distance,
          "direction": direction,
          "icon": icon,
        };
      }
    }
    
    return null;
  }

  // 남은 거리 계산
  double _calculateRemainingDistance(int currentIndex) {
    if (currentIndex >= routePoints.length - 1) return 0;
    
    double total = 0;
    for (int i = currentIndex; i < routePoints.length - 1; i++) {
      total += _calculateDistance(routePoints[i], routePoints[i + 1]);
    }
    return total;
  }

  // 안내 시작 전/주행 중: 현재 단계와 다음 단계 정보 가져오기
  Map<String, dynamic> _getCurrentStepInfo({int? pointIndex}) {
    int index = pointIndex ?? (isNavigating ? _currentPointIndex : 0);
    
    if (routePoints.isEmpty) {
      return {
        "title": "경로를 찾을 수 없어요",
        "subtitle": "도착지를 다시 선택해 주세요",
        "icon": Icons.error_outline,
        "color": Colors.grey,
      };
    }

    // 다음 방향 전환 지점 찾기
    Map<String, dynamic>? nextTurn = _findNextTurnPoint(index);
    double remainingDist = _calculateRemainingDistance(index);
    String remainingText = remainingDist < 1000 
        ? "${remainingDist.toInt()}m" 
        : "${(remainingDist / 1000).toStringAsFixed(1)}km";

    // 목적지에 매우 가까운 경우
    if (remainingDist < 50) {
      return {
        "title": "곧 도착합니다",
        "subtitle": "$destinationName 근처입니다. 주변을 천천히 살펴보세요.",
        "icon": Icons.flag,
        "color": Colors.green,
        "distance": remainingDist,
      };
    }
    // 다음 회전 지점이 가까운 경우 (100m 이내)
    else if (nextTurn != null && nextTurn['distance'] < 100) {
      double dist = nextTurn['distance'];
      String distText = dist < 10 ? "곧" : "${dist.toInt()}m 앞에서";
      return {
        "title": "$distText ${nextTurn['direction']}",
        "subtitle": "방향을 바꿔야 해요. $remainingText 남았어요.",
        "icon": nextTurn['icon'] as IconData,
        "color": _getRouteColor(selectedRouteType),
        "distance": dist,
      };
    }
    // 다음 회전 지점이 먼 경우
    else if (nextTurn != null && nextTurn['distance'] < 200) {
      double dist = nextTurn['distance'];
      return {
        "title": "${dist.toInt()}m 앞에서 ${nextTurn['direction']}",
        "subtitle": "지금은 직진하세요. $remainingText 남았어요.",
        "icon": Icons.arrow_upward,
        "color": _getRouteColor(selectedRouteType),
        "distance": dist,
      };
    }
    // 출발 직후 또는 중간 구간
    else if (index < routePoints.length * 0.1) {
      return {
        "title": "출발 준비",
        "subtitle": "파란 화살표 방향으로 천천히 출발하세요. 총 $remainingText 이동합니다.",
        "icon": Icons.my_location,
        "color": _getRouteColor(selectedRouteType),
        "distance": remainingDist,
      };
    }
    // 중간 구간
    else {
      return {
        "title": "경로를 따라 이동 중",
        "subtitle": "안전하게 이동하세요. $remainingText 남았어요.",
        "icon": Icons.navigation,
        "color": _getRouteColor(selectedRouteType),
        "distance": remainingDist,
      };
    }
  }

  Map<String, dynamic> _getNextStepInfo({int? pointIndex}) {
    int index = pointIndex ?? (isNavigating ? _currentPointIndex : 0);
    
    if (routePoints.isEmpty) return {"title": "", "subtitle": "", "icon": Icons.navigation, "color": Colors.grey};

    // 다음 방향 전환 지점 찾기
    Map<String, dynamic>? nextTurn = _findNextTurnPoint(index);
    double remainingDist = _calculateRemainingDistance(index);

    if (nextTurn != null && nextTurn['distance'] > 100) {
      double dist = nextTurn['distance'];
      String distText = dist < 1000 ? "${dist.toInt()}m" : "${(dist / 1000).toStringAsFixed(1)}km";
      return {
        "title": "$distText 후 ${nextTurn['direction']}",
        "subtitle": "그 다음에 방향을 바꾸면 돼요",
        "icon": nextTurn['icon'] as IconData,
        "color": Colors.orange,
      };
    } else if (remainingDist > 100) {
      return {
        "title": "경로를 따라 이동",
        "subtitle": "파란 선을 따라 천천히 가세요",
        "icon": Icons.arrow_upward,
        "color": Colors.blue,
      };
    } else {
      return {
        "title": "목적지 도착",
        "subtitle": "$destinationName에 곧 도착해요",
        "icon": Icons.flag,
        "color": Colors.green,
      };
    }
  }

  // ---------------------------------------------------------
  // 🚗 시뮬레이션
  // ---------------------------------------------------------
  void startNavigation() {
    if (routePoints.isEmpty) return;
    setState(() { 
      isNavigating = true; 
      _currentPointIndex = 0;
      _currentCueIndex = 0;
      mainInstruction = "출발하세요";
      subInstruction = "파란 화살표 방향으로 천천히 이동하세요.";
      currentTurnIcon = Icons.my_location;
    });

    // 프레임 보정: 1000ms(1초)에서 200ms(0.2초 = 5FPS)로 변경하여 라즈베리파이 화살표가 훨씬 부드럽게 갱신되도록 합니다.
    _navigationTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      if (routePoints.isEmpty) return;
      
      setState(() {
        // 실제 GPS 위치(myPosition)와 가장 가까운 경로상의 점을 찾아서 진행 상황(_currentPointIndex)을 업데이트합니다.
        // 시뮬레이션용 강제 이동 코드(myPosition = routePoints[_currentPointIndex])는 삭제했습니다.
        double minDistance = double.infinity;
        int closestIndex = _currentPointIndex;
        
        // 현재 위치에서 앞으로 가야할 지점 중 가장 가까운 곳 탐색
        for (int i = _currentPointIndex; i < math.min(_currentPointIndex + 20, routePoints.length); i++) {
          double d = _calculateDistance(myPosition, routePoints[i]);
          if (d < minDistance) {
            minDistance = d;
            closestIndex = i;
          }
        }
        
        // 역주행이 아니라면 인덱스 업데이트
        if (closestIndex >= _currentPointIndex) {
          _currentPointIndex = closestIndex;
        }

        // 마커 회전 방향 (이전 점과 현재 위치 기반)
        if (_currentPointIndex > 0) {
          markerRotation = _calculateBearing(routePoints[_currentPointIndex - 1], myPosition);
        }
        
        mapController.move(myPosition, 18.0);

        // 남은 거리 계산 (현재 내 위치에서 다음 점까지의 거리 + 남은 점들의 거리)
        double remainingDist = minDistance + _calculateRemainingDistance(_currentPointIndex);
        String remainingText = remainingDist < 1000 
            ? "${remainingDist.toInt()}m 남음" 
            : "${(remainingDist / 1000).toStringAsFixed(1)}km 남음";

        // 다음 방향 전환 지점 찾기
        Map<String, dynamic>? nextTurn = _findNextTurnPoint(_currentPointIndex);
          
          // 진행 비율 계산
          double progress = _currentPointIndex / routePoints.length;
          
          // 목적지에 매우 가까운 경우
          if (remainingDist < 50 || progress > 0.95) {
            mainInstruction = "곧 도착합니다";
            subInstruction = "$destinationName 근처입니다. 주변을 천천히 살펴보세요.";
            currentTurnIcon = Icons.flag;
          }
          // 다음 회전 지점이 가까운 경우 (100m 이내)
          else if (nextTurn != null && nextTurn['distance'] < 100) {
            double dist = nextTurn['distance'];
            String distText = dist < 10 ? "곧" : "${dist.toInt()}m 앞에서";
            mainInstruction = "$distText ${nextTurn['direction']}";
            subInstruction = "방향을 바꾸세요. $remainingText";
            currentTurnIcon = nextTurn['icon'] as IconData;
          }
          // 다음 회전 지점이 먼 경우
          else if (nextTurn != null && nextTurn['distance'] < 200) {
            double dist = nextTurn['distance'];
            mainInstruction = "${dist.toInt()}m 앞에서 ${nextTurn['direction']}";
            subInstruction = "지금은 직진하세요. $remainingText";
            currentTurnIcon = Icons.arrow_upward;
          }
          // 출발 직후
          else if (progress < 0.1) {
            mainInstruction = "경로를 따라 이동 중";
            subInstruction = "파란 선을 따라 천천히 가세요. $remainingText";
            currentTurnIcon = Icons.arrow_upward;
          }
          // 중간 구간
          else if (progress < 0.8) {
            mainInstruction = "경로를 따라 이동 중";
            subInstruction = "안전하게 이동하세요. $remainingText";
            currentTurnIcon = Icons.navigation;
          }
          // 목적지 근처
          else {
            mainInstruction = "목적지 근처입니다";
            subInstruction = "$destinationName에 곧 도착합니다. $remainingText";
            currentTurnIcon = Icons.flag;
          }
          
          // 현재 위치 기준으로 남은 경로의 friendlyCues 업데이트 (5초마다)
          if (_currentPointIndex % 5 == 0) {
            List<LatLng> remainingPoints = routePoints.sublist(_currentPointIndex);
            if (remainingPoints.length > 1) {
              friendlyCues = _buildFriendlyCues(remainingPoints);
            }
          }
          
          // 📡 [라즈베리파이 연동] 실시간 상대 방향 계산 및 전송
          if (routePoints.length > _currentPointIndex + 1) {
             // 1. 스마트폰의 안정적인 하드웨어 나침반 센서값(myCurrentHeading) 직접 사용! (GPS 튐 완벽 해결)
             double myHeading = myCurrentHeading;
             
             // 2. 가야 할 목표 방향 (현재 위치 -> 다음 경로 노드)
             LatLng targetPoint = routePoints[math.min(_currentPointIndex + 1, routePoints.length - 1)];
             double targetBearing = _calculateBearing(myPosition, targetPoint);
             
             // 3. 각도 차이 계산 (상대 각도: -180 ~ +180)
             double angleDiff = (targetBearing - myHeading + 540) % 360 - 180;
             
             // 🔥 [가장 중요한 핵심] 파이썬 PIL 라이브러리는 각도가 반대입니다!
             // 라즈베리파이에서는 -90도가 오른쪽, +90도가 왼쪽을 의미합니다.
             // 따라서 계산된 각도(angleDiff)의 부호를 뒤집어주어야 나침반처럼 정확히 목적지를 가리킵니다.
             int roundedAngle = -(angleDiff.round());
             
             // 방향이 최소 3도 이상 변했을 때만 서버로 전송 (네트워크 과부하 방지)
             String newCommand = "TARGET:$roundedAngle";
             if (_lastSentCommand.isEmpty || !_lastSentCommand.startsWith("TARGET:")) {
               sendDirectionToServer(newCommand);
             } else {
               int lastAngle = int.tryParse(_lastSentCommand.split(":")[1]) ?? 0;
               if ((roundedAngle - lastAngle).abs() >= 3) {
                 sendDirectionToServer(newCommand);
               }
             }
          }
          
          // 목적지 도착 판정 (10미터 이내)
          if (remainingDist < 10 && _currentPointIndex >= routePoints.length - 5) {
            stopNavigation();
            sendDirectionToServer("도착");
            _showErrorDialog("도착", "목적지에 도착했습니다! 🎉");
          }
        });
    });
  }

  void stopNavigation() {
    _navigationTimer?.cancel();
    setState(() { 
      isNavigating = false; 
      markerRotation = 0.0;
      mainInstruction = "안내가 일시 중지되었습니다";
      subInstruction = "경로를 다시 확인한 뒤, 필요하면 안내를 다시 시작해 주세요.";
      currentTurnIcon = Icons.pause_circle_filled;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 1. 지도
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: myPosition,
              initialZoom: 16.0,
              onTap: (tapPosition, point) {
                if (!isNavigating && !showSearchScreen) {
                  getAddressFromLatLng(point);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.navi_app',
              ),
              if (routePoints.isNotEmpty)
                PolylineLayer(polylines: [
                  Polyline(
                    points: routePoints,
                    strokeWidth: 8.0,
                    color: _getRouteColor(selectedRouteType),
                  ),
                ]),
              MarkerLayer(markers: [
                Marker(
                  point: myPosition, 
                  width: 24, height: 24, 
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blueAccent,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 2)),
                      ],
                    ),
                  ),
                ),
                if (destination != null)
                  Marker(point: destination!, width: 50, height: 50, child: const Icon(Icons.location_on, color: Colors.red, size: 50)),
              ]),
            ],
          ),

          // 2. 상단 버튼
          if (!showSearchScreen && !isNavigating)
            Positioned(
              top: 50, right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [const BoxShadow(color: Colors.black12, blurRadius: 5)]),
                child: Row(
                  children: [
                    const Text("큰 글씨", style: TextStyle(fontWeight: FontWeight.bold)),
                    Switch(value: largeTextMode, onChanged: (v) => setState(() => largeTextMode = v), activeThumbColor: Colors.blue),
                  ],
                ),
              ),
            ),

          // 3. 검색 화면
          if (showSearchScreen)
            Positioned.fill(
              child: Container(
                color: Colors.white,
                child: Column(
                  children: [
                    const SizedBox(height: 50),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Column(
                        children: [
                          TextField(
                            decoration: InputDecoration(prefixIcon: const Icon(Icons.my_location, color: Colors.blue), hintText: "내 위치", filled: true, fillColor: Colors.grey[200], border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)),
                            readOnly: true,
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: searchController,
                            autofocus: true,
                            style: TextStyle(fontSize: largeTextMode ? 20 : 16),
                            decoration: InputDecoration(hintText: "도착지 검색", prefixIcon: const Icon(Icons.search), filled: true, fillColor: Colors.grey[100], border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), suffixIcon: IconButton(icon: const Icon(Icons.clear), onPressed: () => searchController.clear())),
                            onSubmitted: (value) => searchPlace(value),
                          ),
                        ],
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: searchResults.length,
                        itemBuilder: (context, index) {
                          var item = searchResults[index];
                          return ListTile(
                            leading: const Icon(Icons.place, color: Colors.grey),
                            title: Text(item['name'], style: TextStyle(fontWeight: FontWeight.bold, fontSize: largeTextMode ? 18 : 16)),
                            subtitle: Text(item['addr'], style: TextStyle(fontSize: largeTextMode ? 14 : 12)),
                            onTap: () {
                              setState(() {
                                destination = LatLng(item['lat'], item['lng']);
                                destinationName = item['name'];
                                showSearchScreen = false;
                                showPreciseLocationInfo = true;
                                routeCache.clear();
                                routeInfo.clear();
                                routePoints.clear();
                              });
                              mapController.move(destination!, 16.0);
                            },
                          );
                        },
                      ),
                    ),
                    TextButton(onPressed: () => setState(() => showSearchScreen = false), child: const Text("닫기", style: TextStyle(color: Colors.grey, fontSize: 16))),
                  ],
                ),
              ),
            ),

          // 4. 메인 검색바
          if (!showSearchScreen && !isNavigating && !showPreciseLocationInfo && routePoints.isEmpty)
            Positioned(
              top: 50, left: 20, right: 120,
              child: GestureDetector(
                onTap: () => setState(() { showSearchScreen = true; searchResults.clear(); searchController.clear(); }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Colors.blue, size: 26),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "도착지를 검색하거나 지도를 눌러주세요",
                              style: TextStyle(
                                color: Colors.black87,
                                fontSize: largeTextMode ? 18 : 16,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "길치 모드 ON · 한 단계씩 천천히 안내해 드려요",
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: largeTextMode ? 14 : 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 5. 경로 타입 탭
          if (routePoints.isNotEmpty && !isNavigating && !showPreciseLocationInfo)
            Positioned(
              top: 50, left: 20, right: 20,
              child: Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [const BoxShadow(color: Colors.black12, blurRadius: 10)]),
                child: Row(
                  children: [
                    _buildRouteTab(RouteType.car, "자차", Icons.directions_car),
                    _buildRouteTab(RouteType.transit, "대중교통", Icons.directions_transit),
                    _buildRouteTab(RouteType.pedestrian, "도보", Icons.directions_walk),
                  ],
                ),
              ),
            ),

          // 6. 하단 정보창
          if (showPreciseLocationInfo && !showSearchScreen)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.all(25),
                decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20)]),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.flag, color: Colors.red, size: 30),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "도착지 확인",
                                style: TextStyle(
                                  fontSize: largeTextMode ? 20 : 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                destinationName,
                                style: TextStyle(
                                  fontSize: largeTextMode ? 18 : 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      "지도를 움직여 위치가 맞는지 한 번 더 확인해 주세요.\n필요하다면 목적지를 다시 선택할 수 있어요.",
                      style: TextStyle(
                        fontSize: largeTextMode ? 14 : 13,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => setState(() { 
                              showPreciseLocationInfo = false; 
                              destination = null; 
                              routePoints.clear(); 
                              friendlyCues.clear();
                              mainInstruction = "도착지를 선택해주세요";
                              subInstruction = "지도를 눌러 목적지를 선택하거나, 위 검색창에서 장소를 검색하세요.";
                              currentTurnIcon = Icons.explore;
                            }),
                            child: const Text("다시 선택할래요"),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () => getRoute(),
                            child: const Text(
                              "이 위치로 길 안내 시작",
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),

          // 다음 경로 안내 패널 (하단에서 올라오는 애니메이션)
          if (routePoints.isNotEmpty && !isNavigating && !showPreciseLocationInfo && friendlyCues.isNotEmpty)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              bottom: showRouteGuidePanel ? 180 : -500,
              left: 20,
              right: 20,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 350),
                  child: _buildFriendlyGuidePanel(),
                ),
              ),
            ),

          // 7. 안내 시작 버튼 (단계별 안내 강조)
          if (routePoints.isNotEmpty && !isNavigating && !showPreciseLocationInfo)
            Positioned(
              bottom: 30, left: 20, right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 현재 단계 - 큰 카드로 강조
                  Builder(
                    builder: (context) {
                      Map<String, dynamic> currentStep = _getCurrentStepInfo();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: (currentStep['color'] as Color).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: currentStep['color'] as Color,
                            width: 3,
                          ),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4)),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: currentStep['color'] as Color,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    currentStep['icon'] as IconData,
                                    color: Colors.white,
                                    size: largeTextMode ? 32 : 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "지금 해야 할 것",
                                        style: TextStyle(
                                          fontSize: largeTextMode ? 14 : 12,
                                          color: Colors.grey[700],
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        currentStep['title'] as String,
                                        style: TextStyle(
                                          fontSize: largeTextMode ? 24 : 20,
                                          fontWeight: FontWeight.bold,
                                          color: currentStep['color'] as Color,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.info_outline, color: Colors.grey[700], size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      currentStep['subtitle'] as String,
                                      style: TextStyle(
                                        fontSize: largeTextMode ? 16 : 14,
                                        color: Colors.black87,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_getRouteInfoText().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.access_time, size: 18, color: Colors.grey[700]),
                                    const SizedBox(width: 6),
                                    Text(
                                      _getRouteInfoText(),
                                      style: TextStyle(
                                        fontSize: largeTextMode ? 16 : 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.grey[800],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),

                  // 다음 경로 안내 패널 토글 버튼
                  if (friendlyCues.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            showRouteGuidePanel = !showRouteGuidePanel;
                          });
                        },
                        icon: Icon(
                          showRouteGuidePanel ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                          color: Colors.white,
                        ),
                        label: Text(
                          showRouteGuidePanel ? "경로 안내 닫기" : "다음 경로 보기",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: largeTextMode ? 16 : 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _getRouteColor(selectedRouteType).withValues(alpha: 0.8),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),

                  // 안내 시작 버튼
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: startNavigation,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _getRouteColor(selectedRouteType),
                        padding: EdgeInsets.symmetric(vertical: largeTextMode ? 18 : 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 4,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_arrow, color: Colors.white, size: 28),
                          const SizedBox(width: 8),
                          Text(
                            "안내 시작하기",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: largeTextMode ? 24 : 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 8. 주행 중 화면
          if (isNavigating) ...[
            // 상단: 현재 단계 안내
            Positioned(
              top: 50, left: 20, right: 20,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF2D343D),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            currentTurnIcon,
                            color: Colors.white,
                            size: largeTextMode ? 40 : 36,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "지금 해야 할 것",
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: largeTextMode ? 13 : 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                mainInstruction,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: largeTextMode ? 26 : 22,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.white70, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              subInstruction.isNotEmpty ? subInstruction : "안전하게 주변을 살피며 이동해 주세요.",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: largeTextMode ? 15 : 14,
                                height: 1.4,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 다음 경로 안내 패널 (주행 중 - 하단에서 올라오는 애니메이션)
            if (friendlyCues.isNotEmpty)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                bottom: showRouteGuidePanel ? 100 : -500,
                left: 20,
                right: 20,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 350),
                    child: _buildFriendlyGuidePanel(),
                  ),
                ),
              ),
            // 하단: 토글 버튼 + 종료 버튼
            Positioned(
              bottom: 30, left: 20, right: 20,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 다음 경로 안내 패널 토글 버튼
                  if (friendlyCues.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            showRouteGuidePanel = !showRouteGuidePanel;
                          });
                        },
                        icon: Icon(
                          showRouteGuidePanel ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                          color: Colors.white,
                        ),
                        label: Text(
                          showRouteGuidePanel ? "경로 안내 닫기" : "다음 경로 보기",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: largeTextMode ? 16 : 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.withValues(alpha: 0.8),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  // 안내 종료 버튼
                  FloatingActionButton.extended(
                    onPressed: stopNavigation,
                    label: Text(
                      "안내 종료",
                      style: TextStyle(
                        fontSize: largeTextMode ? 18 : 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    icon: const Icon(Icons.stop),
                    backgroundColor: Colors.red,
                  ),
                ],
              ),
            ),
          ]
        ],
      ),
    );
  }

  Widget _buildRouteTab(RouteType type, String label, IconData icon) {
    bool isSelected = selectedRouteType == type;
    Color color = _getRouteColor(type);
    
    return Expanded(
      child: GestureDetector(
        onTap: () => _changeRouteType(type),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: isSelected ? Border.all(color: color, width: 2) : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isSelected ? color : Colors.grey),
              Text(label, style: TextStyle(color: isSelected ? color : Colors.grey, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}