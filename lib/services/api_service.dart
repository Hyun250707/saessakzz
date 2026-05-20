import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/api_models.dart';

class ApiService {
  // 서버 IP 주소 (사용자 환경에 맞게 수정 필요)
  // 서버 IP 주소 (노트북의 Wi-Fi IP로 설정됨)
  // 현재 연결된 Wi-Fi의 IP 주소로 업데이트
  static const String _baseUrl = "http://165.229.125.244:8000"; 

  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // 1. 위치 데이터 전송
  Future<bool> sendLocation(LocationData data) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/location'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(data.toJson()),
      );
      return response.statusCode == 200;
    } catch (e) {
      print("Error sending location: $e");
      return false;
    }
  }

  // 2. 노드(좌표 점) 추가
  Future<int?> createNode(NodeData node) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/nodes'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(node.toJson()),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['node_id'];
      }
    } catch (e) {
      print("Error creating node: $e");
    }
    return null;
  }

  // 3. 엣지(연결 선) 추가
  Future<int?> createEdge(EdgeData edge) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/edges'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(edge.toJson()),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['edge_id'];
      }
    } catch (e) {
      print("Error creating edge: $e");
    }
    return null;
  }

  // 4. 모든 노드 조회
  Future<List<NodeData>> getNodes() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/nodes'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['nodes'] as List)
            .map((e) => NodeData.fromJson(e))
            .toList();
      }
    } catch (e) {
      print("Error getting nodes: $e");
    }
    return [];
  }

  // 5. 길찾기 요청
  Future<RouteResponse?> findRoute(RouteRequest request) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/route'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(request.toJson()),
      );
      if (response.statusCode == 200) {
        return RouteResponse.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      print("Error finding route: $e");
    }
    return null;
  }

  // 6. 카메라 스캔 결과 전송 (명령 발동)
  Future<bool> sendCameraScan(String qrData) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/camera_scan'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(qrData), // 서버에서는 str로 받음
      );
      return response.statusCode == 200;
    } catch (e) {
      print("Error sending camera scan: $e");
      return false;
    }
  }

  // 7. 사용자의 활성 경로 가져오기
  Future<RouteResponse?> getActiveRoute(String userId) async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/route/$userId'));
      if (response.statusCode == 200) {
        return RouteResponse.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      print("Error getting active route: $e");
    }
    return null;
  }

  // 8. 실내 지도 데이터 저장
  Future<bool> saveIndoorMap(String mapId, Map<String, dynamic> mapData) async {
    try {
      final body = {...mapData, "map_id": mapId};
      final response = await http.post(
        Uri.parse('$_baseUrl/api/indoor_map'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      return response.statusCode == 200;
    } catch (e) {
      print("Error saving indoor map: $e");
      return false;
    }
  }

  // 9. 실내 지도 데이터 불러오기
  Future<Map<String, dynamic>?> loadIndoorMap(String mapId) async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/api/indoor_map?map_id=$mapId'));
      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body);
        return payload['data'] ?? payload;
      }
    } catch (e) {
      print("Error loading indoor map: $e");
    }
    return null;
  }
}
