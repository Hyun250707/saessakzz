
class LocationData {
  final String userId;
  final double latitude;
  final double longitude;
  final String timestamp;

  LocationData({
    required this.userId,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
      };
}

class NodeData {
  final int? id;
  final double latitude;
  final double longitude;
  final String? name;

  NodeData({
    this.id,
    required this.latitude,
    required this.longitude,
    this.name,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'name': name,
      };

  factory NodeData.fromJson(Map<String, dynamic> json) {
    return NodeData(
      id: json['id'],
      latitude: json['latitude'],
      longitude: json['longitude'],
      name: json['name'],
    );
  }
}

class EdgeData {
  final int? id;
  final int fromNodeId;
  final int toNodeId;
  final double? distance;
  final double? weight;

  EdgeData({
    this.id,
    required this.fromNodeId,
    required this.toNodeId,
    this.distance,
    this.weight,
  });

  Map<String, dynamic> toJson() => {
        'from_node_id': fromNodeId,
        'to_node_id': toNodeId,
        'distance': distance,
        'weight': weight,
      };

  factory EdgeData.fromJson(Map<String, dynamic> json) {
    return EdgeData(
      id: json['id'],
      fromNodeId: json['from_node_id'],
      toNodeId: json['to_node_id'],
      distance: (json['distance'] as num?)?.toDouble(),
      weight: (json['weight'] as num?)?.toDouble(),
    );
  }
}

class RouteRequest {
  final String userId;
  final double startLatitude;
  final double startLongitude;
  final double endLatitude;
  final double endLongitude;

  RouteRequest({
    required this.userId,
    required this.startLatitude,
    required this.startLongitude,
    required this.endLatitude,
    required this.endLongitude,
  });

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'start_latitude': startLatitude,
        'start_longitude': startLongitude,
        'end_latitude': endLatitude,
        'end_longitude': endLongitude,
      };
}

class RouteResponse {
  final String status;
  final int? routeId;
  final List<NodeData> path;
  final double distance;
  final int nodeCount;
  final String message;

  RouteResponse({
    required this.status,
    this.routeId,
    required this.path,
    required this.distance,
    required this.nodeCount,
    required this.message,
  });

  factory RouteResponse.fromJson(Map<String, dynamic> json) {
    return RouteResponse(
      status: json['status'],
      routeId: json['route_id'],
      path: (json['path'] as List<dynamic>?)
              ?.map((e) => NodeData.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      distance: (json['distance'] as num).toDouble(),
      nodeCount: json['node_count'] ?? 0,
      message: json['message'] ?? '',
    );
  }
}
