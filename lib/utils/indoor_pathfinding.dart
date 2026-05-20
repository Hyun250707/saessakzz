import 'dart:math' as math;
import '../models/indoor_map.dart';

/// 실내 그래프 위에서 A* 경로 탐색
class IndoorPathfinding {
  /// 두 핀 사이 직선 거리 (픽셀)
  static double distance(IndoorPin a, IndoorPin b) {
    return math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
  }

  /// 인접 리스트 생성: [핀id] -> [{연결된 핀id, 비용}]
  static Map<String, List<({String toId, double cost})>> _buildGraph(
    List<IndoorPin> pins,
    List<IndoorEdge> edges,
  ) {
    final pinIds = pins.map((p) => p.id).toSet();
    final mapPin = {for (var p in pins) p.id: p};

    final graph = <String, List<({String toId, double cost})>>{};
    for (final id in pinIds) {
      graph[id] = [];
    }

    // 엣지(통로 연결)만 이동 가능하도록 구성.
    // 벽/통로를 구분하려면 반드시 edges를 채워야 함.
    for (final e in edges) {
      if (!pinIds.contains(e.fromId) || !pinIds.contains(e.toId)) continue;
      final from = mapPin[e.fromId]!;
      final to = mapPin[e.toId]!;
      final cost = e.weight > 0 ? e.weight : distance(from, to);
      graph[e.fromId]!.add((toId: e.toId, cost: cost));
      graph[e.toId]!.add((toId: e.fromId, cost: cost));
    }

    return graph;
  }

  /// A* 경로 탐색. 반환: [시작핀, ..., 도착핀] 또는 빈 리스트
  static List<IndoorPin> findPath({
    required List<IndoorPin> pins,
    required List<IndoorEdge> edges,
    required String startPinId,
    required String endPinId,
  }) {
    if (pins.isEmpty) return [];
    final mapPin = {for (var p in pins) p.id: p};
    if (!mapPin.containsKey(startPinId) || !mapPin.containsKey(endPinId)) {
      return [];
    }
    if (startPinId == endPinId) {
      return [mapPin[startPinId]!];
    }

    final graph = _buildGraph(pins, edges);
    final start = mapPin[startPinId]!;
    final end = mapPin[endPinId]!;

    // A*: (f, g, nodeId, parentId)
    final open = <_Node>[];
    final closed = <String>{};
    final gScore = <String, double>{startPinId: 0};
    final cameFrom = <String, String>{};

    double heuristic(String id) => distance(mapPin[id]!, end);

    open.add(_Node(f: heuristic(startPinId), g: 0, id: startPinId));

    while (open.isNotEmpty) {
      open.sort((a, b) => a.f.compareTo(b.f));
      final current = open.removeAt(0);
      if (current.id == endPinId) {
        final path = <IndoorPin>[];
        String? id = endPinId;
        while (id != null) {
          path.insert(0, mapPin[id]!);
          id = cameFrom[id];
        }
        return path;
      }
      closed.add(current.id);

      for (final edge in graph[current.id] ?? []) {
        if (closed.contains(edge.toId)) continue;
        final tentativeG = gScore[current.id]! + edge.cost;
        if (tentativeG < (gScore[edge.toId] ?? double.infinity)) {
          cameFrom[edge.toId] = current.id;
          gScore[edge.toId] = tentativeG;
          final f = tentativeG + heuristic(edge.toId);
          open.removeWhere((n) => n.id == edge.toId);
          open.add(_Node(f: f, g: tentativeG, id: edge.toId));
        }
      }
    }

    return [];
  }
}

class _Node {
  final double f;
  final double g;
  final String id;
  _Node({required this.f, required this.g, required this.id});
}
