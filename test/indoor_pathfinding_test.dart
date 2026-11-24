import 'package:flutter_test/flutter_test.dart';
import 'package:navi_app/models/indoor_map.dart';
import 'package:navi_app/utils/indoor_pathfinding.dart';

void main() {
  // A에서 G로 가는 길이 두 개: V는 세로로 길게, H는 가로로 길게 돌아감
  const pins = [
    IndoorPin(id: 'A', name: 'A', x: 0.0, y: 0.1),
    IndoorPin(id: 'G', name: 'G', x: 0.1, y: 0.1),
    IndoorPin(id: 'V', name: 'V', x: 0.05, y: 0.6),
    IndoorPin(id: 'H', name: 'H', x: 0.5, y: 0.05),
  ];
  const edges = [
    IndoorEdge(fromId: 'A', toId: 'V'),
    IndoorEdge(fromId: 'V', toId: 'G'),
    IndoorEdge(fromId: 'A', toId: 'H'),
    IndoorEdge(fromId: 'H', toId: 'G'),
  ];

  List<String> route(double yScale) => IndoorPathfinding.findPath(
        pins: pins,
        edges: edges,
        startPinId: 'A',
        endPinId: 'G',
        yScale: yScale,
      ).map((p) => p.id).toList();

  test('정사각형 도면이면 가로로 도는 길이 더 짧다', () {
    expect(route(1.0), ['A', 'H', 'G']);
  });

  test('가로로 긴 도면(1049x550)이면 세로 거리가 줄어서 세로 길이 더 짧다', () {
    expect(route(550 / 1049), ['A', 'V', 'G']);
  });

  test('세로 거리에 비율을 곱해서 계산한다', () {
    const a = IndoorPin(id: 'a', name: 'a', x: 0, y: 0);
    const b = IndoorPin(id: 'b', name: 'b', x: 0, y: 1);
    expect(IndoorPathfinding.distance(a, b, yScale: 0.5), 0.5);
  });
}
