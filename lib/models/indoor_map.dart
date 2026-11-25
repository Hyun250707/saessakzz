/// 실내 도면 위의 한 지점(핀)
/// x, y: 이미지 위 위치. 정규화(0.0~1.0) 또는 픽셀 값 사용 가능.
class IndoorPin {
  final String id;
  final String name;
  final double x;
  final double y;

  const IndoorPin({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
  });

  IndoorPin copyWith({String? id, String? name, double? x, double? y}) {
    return IndoorPin(
      id: id ?? this.id,
      name: name ?? this.name,
      x: x ?? this.x,
      y: y ?? this.y,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'x': x,
        'y': y,
      };

  factory IndoorPin.fromJson(Map<String, dynamic> json) {
    return IndoorPin(
      id: json['id'] as String,
      name: json['name'] as String? ?? '이름 없음',
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
    );
  }
}

/// 두 핀 사이의 연결(통로/복도)
class IndoorEdge {
  final String fromId;
  final String toId;
  final double weight; // 거리 또는 소요 시간

  const IndoorEdge({
    required this.fromId,
    required this.toId,
    this.weight = 0,
  });

  Map<String, dynamic> toJson() => {
        'fromId': fromId,
        'toId': toId,
        'weight': weight,
      };

  factory IndoorEdge.fromJson(Map<String, dynamic> json) {
    return IndoorEdge(
      fromId: json['fromId'] as String,
      toId: json['toId'] as String,
      weight: (json['weight'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// 실내 도면 데이터 (이미지 + 핀 + 연결)
class IndoorMapData {
  final String imagePath;
  final List<IndoorPin> pins;
  final List<IndoorEdge> edges;
  final String name;

  const IndoorMapData({
    required this.imagePath,
    required this.name,
    this.pins = const [],
    this.edges = const [],
  });

  IndoorMapData copyWith({
    String? imagePath,
    String? name,
    List<IndoorPin>? pins,
    List<IndoorEdge>? edges,
  }) {
    return IndoorMapData(
      imagePath: imagePath ?? this.imagePath,
      name: name ?? this.name,
      pins: pins ?? this.pins,
      edges: edges ?? this.edges,
    );
  }

  Map<String, dynamic> toJson() => {
        'imagePath': imagePath,
        'name': name,
        'pins': pins.map((e) => e.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
      };

  factory IndoorMapData.fromJson(Map<String, dynamic> json) {
    return IndoorMapData(
      imagePath: json['imagePath'] as String,
      name: json['name'] as String? ?? '실내 지도',
      pins: (json['pins'] as List<dynamic>?)
              ?.map((e) => IndoorPin.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      edges: (json['edges'] as List<dynamic>?)
              ?.map((e) => IndoorEdge.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
