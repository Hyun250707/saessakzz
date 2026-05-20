import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:camera/camera.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../services/api_service.dart';
import '../models/indoor_map.dart';
import '../utils/indoor_pathfinding.dart';
import 'package:pytorch_lite/pytorch_lite.dart';
/// 실내 도면 이미지 위에 핀을 찍고, 핀 간 경로를 찾는 화면
class IndoorMapScreen extends StatefulWidget {
  const IndoorMapScreen({super.key});

  @override
  State<IndoorMapScreen> createState() => _IndoorMapScreenState();
}

class _IndoorMapScreenState extends State<IndoorMapScreen> {
  IndoorMapData _mapData = IndoorMapData(
    imagePath: 'assets/indoor_floor_plan.png',
    name: '실내 지도',
    pins: [],
    edges: [],
  );

  String? _startPinId;
  String? _endPinId;
  List<IndoorPin> _path = [];
  bool _connectMode = false; // 통로 연결 모드
  bool _showEdges = true; // 통로(엣지) 표시
  String? _pendingConnectFromId; // 연결 시작 핀
  final String _mapId = "building_1_floor_1"; // 필요하면 나중에 층/건물별로 변경
  final ApiService apiService = ApiService();
  final TransformationController _transformController = TransformationController();
  final GlobalKey _mapKey = GlobalKey();
  bool _isLoadingFromServer = false;

  /// 도면 PNG 원본 픽셀 크기 (BoxFit.contain 영역 계산용)
  double? _imageNaturalW;
  double? _imageNaturalH;
  ImageStream? _imageDimStream;
  ImageStreamListener? _imageDimListener;
  String? _imageDimBoundPath;

  @override
  void initState() {
    super.initState();
    // 1) 앱 실행 전에 미리 세팅된 지도(JSON)를 assets에서 먼저 로드
    // 2) 그 다음 서버에 저장된 지도가 있으면 덮어쓰기(동기화)
    _loadMapFromAssets().then((_) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _bindImageNaturalSize());
      }
      return _loadMapFromServer();
    });
  }

  @override
  void dispose() {
    _detachImageDimListener();
    _transformController.dispose();
    super.dispose();
  }

  void _detachImageDimListener() {
    if (_imageDimStream != null && _imageDimListener != null) {
      _imageDimStream!.removeListener(_imageDimListener!);
    }
    _imageDimStream = null;
    _imageDimListener = null;
    _imageDimBoundPath = null;
  }

  /// `indoor_floor_plan` 등 도면의 실제 픽셀 비율로, 탭/핀 좌표가 이미지와 일치하도록 함.
  void _bindImageNaturalSize() {
    if (!mounted) return;
    final path = _mapData.imagePath;
    if (_imageDimBoundPath == path &&
        _imageNaturalW != null &&
        _imageNaturalH != null) {
      return;
    }
    _detachImageDimListener();
    _imageDimBoundPath = path;
    _imageNaturalW = null;
    _imageNaturalH = null;

    _imageDimListener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted) return;
        setState(() {
          _imageNaturalW = info.image.width.toDouble();
          _imageNaturalH = info.image.height.toDouble();
        });
      },
      onError: (_, __) {
        if (!mounted) return;
        setState(() {
          _imageNaturalW = null;
          _imageNaturalH = null;
        });
      },
    );
    _imageDimStream =
        AssetImage(path).resolve(createLocalImageConfiguration(context));
    _imageDimStream!.addListener(_imageDimListener!);
  }

  /// 컨테이너 안에서 `BoxFit.contain`과 동일한 도면 표시 영역.
  Rect _imageRectInContainer(double cw, double ch) {
    final nw = _imageNaturalW;
    final nh = _imageNaturalH;
    if (nw == null || nh == null || nw <= 0 || nh <= 0) {
      return Rect.fromLTWH(0, 0, cw, ch);
    }
    final scale = (cw / nw < ch / nh) ? cw / nw : ch / nh;
    final bw = nw * scale;
    final bh = nh * scale;
    final dx = (cw - bw) / 2;
    final dy = (ch - bh) / 2;
    return Rect.fromLTWH(dx, dy, bw, bh);
  }

  /// 화면 탭 → 도면 기준 정규화 좌표 (0~1). 레터박스 밖이면 null.
  (double, double)? _tapToNormalizedOnImage(Offset local, double cw, double ch) {
    final r = _imageRectInContainer(cw, ch);
    if (!r.contains(local)) return null;
    final nx = ((local.dx - r.left) / r.width).clamp(0.0, 1.0);
    final ny = ((local.dy - r.top) / r.height).clamp(0.0, 1.0);
    return (nx, ny);
  }

  void _addPin(double nx, double ny) {
    // 통로(엣지)가 이미 있을 경우, 가장 가까운 통로 선분 위로 스냅
    final snapped = _snapToNearestEdge(nx, ny);
    final sx = snapped.$1;
    final sy = snapped.$2;
    final id = 'pin_${DateTime.now().millisecondsSinceEpoch}';
    showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('핀 이름'),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '예: 로비, 엘리베이터, 101호',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.isNotEmpty ? v : '위치'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, '위치'),
            child: const Text('확인'),
          ),
        ],
      ),
    ).then((name) {
      if (name == null) return;
      setState(() {
        _mapData = _mapData.copyWith(
          pins: [..._mapData.pins, IndoorPin(id: id, name: name, x: sx, y: sy)],
        );
        _path = [];
      });
      // 핀 추가 후 자동으로 서버에 저장
      _saveMapToServer(silent: true);
    });
  }

  /// 현재 통로(엣지) 기준으로, (nx, ny)를 가장 가까운 통로 선분 위로 스냅.
  /// 엣지가 없거나 너무 멀면 원래 좌표를 그대로 사용.
  (double, double) _snapToNearestEdge(double nx, double ny) {
    if (_mapData.edges.isEmpty || _mapData.pins.length < 2) {
      return (nx, ny);
    }
    final pinsById = {for (final p in _mapData.pins) p.id: p};
    double bestDist2 = double.infinity;
    double bestX = nx;
    double bestY = ny;

    for (final e in _mapData.edges) {
      final a = pinsById[e.fromId];
      final b = pinsById[e.toId];
      if (a == null || b == null) continue;

      final ax = a.x;
      final ay = a.y;
      final bx = b.x;
      final by = b.y;

      final vx = bx - ax;
      final vy = by - ay;
      final wx = nx - ax;
      final wy = ny - ay;

      final len2 = vx * vx + vy * vy;
      if (len2 == 0) continue;

      final t = (vx * wx + vy * wy) / len2;
      final tt = t.clamp(0.0, 1.0);
      final projX = ax + vx * tt;
      final projY = ay + vy * tt;

      final dx = projX - nx;
      final dy = projY - ny;
      final dist2 = dx * dx + dy * dy;

      if (dist2 < bestDist2) {
        bestDist2 = dist2;
        bestX = projX;
        bestY = projY;
      }
    }

    // 임계값: 통로에서 너무 멀면 스냅하지 않음 (정규화 좌표 기준 약 3% 이내일 때만)
    const threshold = 0.03 * 0.03;
    if (bestDist2 > threshold) {
      return (nx, ny);
    }
    return (bestX, bestY);
  }

  void _removePin(String id) {
    setState(() {
      _mapData = _mapData.copyWith(
        pins: _mapData.pins.where((p) => p.id != id).toList(),
        edges: _mapData.edges.where((e) => e.fromId != id && e.toId != id).toList(),
      );
      if (_startPinId == id) _startPinId = null;
      if (_endPinId == id) _endPinId = null;
      _path = [];
    });
    // 핀 삭제 후 자동으로 서버에 저장
    _saveMapToServer(silent: true);
  }

  void _findPath() {
    if (_startPinId == null || _endPinId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('출발 핀과 도착 핀을 모두 선택해 주세요.')),
      );
      return;
    }
    if (_mapData.edges.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('통로 연결(엣지)이 없어서 경로를 찾을 수 없어요. 먼저 통로를 연결해 주세요.')),
      );
      setState(() => _path = []);
      return;
    }
    final path = IndoorPathfinding.findPath(
      pins: _mapData.pins,
      edges: _mapData.edges,
      startPinId: _startPinId!,
      endPinId: _endPinId!,
    );
    setState(() => _path = path);
    if (path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('경로를 찾을 수 없습니다.')),
      );
    }
  }

  void _clearPath() {
    setState(() {
      _startPinId = null;
      _endPinId = null;
      _path = [];
    });
  }

  /// 카메라를 켜서 호실을 인식하고 위치를 설정함
  Future<void> _openCameraRecognition() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('사용 가능한 카메라가 없습니다.')),
      );
      return;
    }

    if (!mounted) return;
    final String? recognizedRoom = await showDialog<String>(
      context: context,
      builder: (ctx) => _CameraRecognitionDialog(camera: cameras.first),
    );

    if (recognizedRoom != null && recognizedRoom.isNotEmpty) {
      if (recognizedRoom.startsWith("인식실패") || recognizedRoom.startsWith("에러:")) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(recognizedRoom), // 상세 오류 메시지 출력
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      final match = _findBestMatchingPin(recognizedRoom);

      if (match != null) {
        setState(() {
          _startPinId = match.id;
          _path = [];
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('\'$recognizedRoom호\'를 인식했습니다. 현재 위치를 "${match.name}"으로 설정합니다.'),
            backgroundColor: Colors.blueAccent,
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('인식된 \'$recognizedRoom\'와 일치하는 장소를 찾을 수 없습니다.'),
            backgroundColor: Colors.redAccent,
            action: SnackBarAction(label: '확인', textColor: Colors.white, onPressed: () {}),
          ),
        );
      }
    }
  }

  /// 인식된 텍스트와 가장 잘 매칭되는 핀(노드)을 찾는 알고리즘
  IndoorPin? _findBestMatchingPin(String text) {
    if (text.isEmpty) return null;
    
    // 1. 공백 제거 및 소문자화 (정규화)
    final cleanText = text.replaceAll(' ', '').toLowerCase();
    
    // 2. 정확히 일치하는 이름 찾기
    for (final pin in _mapData.pins) {
      final pinName = pin.name.replaceAll(' ', '').toLowerCase();
      if (pinName == cleanText) return pin;
    }
    
    // 3. 포함 관계 확인 (예: 인식된 게 "319"인데 핀 이름이 "319호")
    for (final pin in _mapData.pins) {
      final pinName = pin.name.replaceAll(' ', '').toLowerCase();
      if (pinName.contains(cleanText) || cleanText.contains(pinName)) {
        return pin;
      }
    }
    
    // 4. 숫자만 추출해서 비교 (호실 번호 특화)
    final numRegex = RegExp(r'\d+');
    final textNumbers = numRegex.allMatches(cleanText).map((m) => m.group(0)).join();
    
    if (textNumbers.isNotEmpty) {
      for (final pin in _mapData.pins) {
        final pinNumbers = numRegex.allMatches(pin.name).map((m) => m.group(0)).join();
        if (pinNumbers.isNotEmpty && pinNumbers == textNumbers) {
          return pin;
        }
      }
    }

    return null;
  }

  Future<void> _saveMapToServer({bool silent = false}) async {
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('실내 지도 정보를 서버에 저장 중입니다...')),
      );
    }

    final success = await apiService.saveIndoorMap(_mapId, _mapData.toJson());

    if (!mounted) return;

    if (success) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('실내 지도 정보를 서버에 저장했습니다.')),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('서버 저장에 실패했습니다.')),
      );
    }
  }

  Future<void> _loadMapFromAssets() async {
    final assetPath = 'indoor_maps/$_mapId.json'; // 'assets/'는 rootBundle이 자동으로 처리하거나 중복될 수 있음
    try {
      final jsonStr = await rootBundle.loadString(assetPath);
      final mapJson = jsonDecode(jsonStr) as Map<String, dynamic>;

      setState(() {
        _mapData = IndoorMapData.fromJson(mapJson);
        _startPinId = null;
        _endPinId = null;
        _path = [];
      });
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _bindImageNaturalSize());
      }
    } catch (_) {
      // assets에 파일이 없거나 JSON이 깨져 있어도 서버 로드로 대체 시도
    }
  }

  Future<void> _loadMapFromServer() async {
    setState(() => _isLoadingFromServer = true);

    final mapJson = await apiService.loadIndoorMap(_mapId);

    if (!mounted) return;

    if (mapJson != null) {
      setState(() {
        _mapData = IndoorMapData.fromJson(mapJson);
        _startPinId = null;
        _endPinId = null;
        _path = [];
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _bindImageNaturalSize());

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('서버에서 실내 지도 정보를 불러왔습니다.')),
      );
    } else {
      if (_mapData.pins.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('서버에서 데이터를 불러오지 못했습니다.')),
        );
      }
    }
    
    setState(() => _isLoadingFromServer = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('실내 길찾기'),
        actions: [
          if (_isLoadingFromServer)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: '서버에서 불러오기',
            onPressed: _loadMapFromServer,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '현재 핀/엣지 JSON 복사',
            onPressed: _mapData.pins.isEmpty
                ? null
                : () async {
                    final jsonStr = jsonEncode(_mapData.toJson());
                    await Clipboard.setData(ClipboardData(text: jsonStr));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('핀/엣지 JSON을 클립보드에 복사했어요.')),
                    );
                  },
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '서버에 저장',
            onPressed: _mapData.pins.isEmpty ? null : _saveMapToServer,
          ),
          IconButton(
            icon: Icon(_showEdges ? Icons.visibility : Icons.visibility_off),
            tooltip: _showEdges ? '통로 숨기기' : '통로 보이기',
            onPressed: () => setState(() => _showEdges = !_showEdges),
          ),
          IconButton(
            icon: Icon(_connectMode ? Icons.link_off : Icons.link),
            tooltip: _connectMode ? '통로 연결 모드 끄기' : '통로 연결 모드 켜기',
            onPressed: () {
              setState(() {
                _connectMode = !_connectMode;
                _pendingConnectFromId = null;
                _path = [];
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _connectMode
                        ? '통로 연결 모드: 핀 2개를 차례로 눌러 연결하세요.'
                        : '통로 연결 모드 종료',
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_input_component),
            tooltip: '통로 관리',
            onPressed: _mapData.edges.isEmpty ? null : _showEdgeManager,
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt),
            onPressed: _openCameraRecognition,
            tooltip: '카메라로 위치 인식 (호실 인식)',
          ),
  IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _path.isEmpty ? null : _clearPath,
            tooltip: '경로 초기화',
          ),
        ],
      ),
      body: Column(
        children: [
          // 도면 + 핀 + 경로
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return InteractiveViewer(
                  transformationController: _transformController,
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: GestureDetector(
                    onTapUp: (details) {
                      final w = constraints.maxWidth;
                      final h = constraints.maxHeight;
                      if (w <= 0 || h <= 0) return;
                      final norm = _tapToNormalizedOnImage(details.localPosition, w, h);
                      if (norm == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('도면 이미지 영역 안을 탭해 노드를 추가하세요.'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                        return;
                      }
                      _addPin(norm.$1, norm.$2);
                    },
                    child: Stack(
                      key: _mapKey,
                      clipBehavior: Clip.none,
                      children: [
                        _buildFloorPlan(constraints.maxWidth, constraints.maxHeight),
                        if (_showEdges && _mapData.edges.isNotEmpty)
                          _buildEdgesLine(constraints.maxWidth, constraints.maxHeight),
                        ..._mapData.pins.map((p) => _buildPin(p, constraints.maxWidth, constraints.maxHeight)),
                        if (_path.length >= 2) _buildPathLine(constraints.maxWidth, constraints.maxHeight),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          _buildBottomPanel(),
        ],
      ),
    );
  }

  Widget _buildFloorPlan(double w, double h) {
    return Container(
      width: w,
      height: h,
      color: Colors.grey[200],
      child: Image.asset(
        _mapData.imagePath,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.map_outlined, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                'assets/indoor_floor_plan.png 를 추가해 주세요',
                style: TextStyle(color: Colors.grey[600], fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '도면 위를 탭하면 핀을 추가할 수 있어요',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPin(IndoorPin pin, double w, double h) {
    final r = _imageRectInContainer(w, h);
    final isStart = pin.id == _startPinId;
    final isEnd = pin.id == _endPinId;
    final onPath = _path.any((p) => p.id == pin.id);
    final isPendingFrom = _pendingConnectFromId == pin.id;

    Color color = Colors.blue;
    if (isStart) color = Colors.green;
    if (isEnd) color = Colors.red;
    if (onPath && !isStart && !isEnd) color = Colors.orange;
    if (_connectMode && isPendingFrom) color = Colors.purple;

    return Positioned(
      left: r.left + pin.x * r.width - 20,
      top: r.top + pin.y * r.height - 20,
      width: 40,
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onPinTap(pin.id),
          onLongPress: () => _showPinMenu(pin),
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                isStart ? Icons.my_location : (isEnd ? Icons.flag : Icons.place),
                color: color,
                size: 36,
              ),
              if (pin.name.isNotEmpty)
                Positioned(
                  bottom: -16,
                  left: 0,
                  right: 0,
                  child: Text(
                    pin.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.black87,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _onPinTap(String pinId) {
    setState(() {
      if (_connectMode) {
        if (_pendingConnectFromId == null) {
          _pendingConnectFromId = pinId;
          _path = [];
        } else {
          final from = _pendingConnectFromId!;
          final to = pinId;
          if (from != to) {
            _addOrToggleEdge(from, to);
          }
          _pendingConnectFromId = null;
          _path = [];
        }
        return;
      }

      if (_startPinId == null) {
        _startPinId = pinId;
      } else if (_endPinId == null) {
        _endPinId = pinId;
        _findPath();
      } else {
        _startPinId = pinId;
        _endPinId = null;
        _path = [];
      }
    });
  }

  void _addOrToggleEdge(String a, String b) {
    bool sameUndirected(IndoorEdge e) =>
        (e.fromId == a && e.toId == b) || (e.fromId == b && e.toId == a);

    final exists = _mapData.edges.any(sameUndirected);
    if (exists) {
      setState(() {
        _mapData = _mapData.copyWith(
          edges: _mapData.edges.where((e) => !sameUndirected(e)).toList(),
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('통로 연결을 삭제했어요.')),
      );
    } else {
      setState(() {
        _mapData = _mapData.copyWith(
          edges: [..._mapData.edges, IndoorEdge(fromId: a, toId: b)],
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('통로 연결을 추가했어요.')),
      );
    }
    // 엣지 변경 후 자동으로 서버에 저장
    _saveMapToServer(silent: true);
  }

  void _showPinMenu(IndoorPin pin) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.place),
              title: Text(pin.name),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow, color: Colors.green),
              title: const Text('출발지로 설정'),
              onTap: () {
                setState(() {
                  _startPinId = pin.id;
                  _path = [];
                });
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag, color: Colors.red),
              title: const Text('도착지로 설정'),
              onTap: () {
                setState(() {
                  _endPinId = pin.id;
                  _findPath();
                });
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link, color: Colors.purple),
              title: const Text('통로 연결 시작(이 핀부터)'),
              onTap: () {
                setState(() {
                  _connectMode = true;
                  _pendingConnectFromId = pin.id;
                  _path = [];
                });
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('이제 연결할 다른 핀을 눌러 통로를 연결하세요.')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('핀 삭제'),
              onTap: () {
                _removePin(pin.id);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEdgesLine(double w, double h) {
    final r = _imageRectInContainer(w, h);
    return IgnorePointer(
      child: CustomPaint(
        size: Size(w, h),
        painter: _EdgesPainter(
          pins: _mapData.pins,
          edges: _mapData.edges,
          imageRect: r,
          strokeWidth: 3,
          color: Colors.black54,
        ),
      ),
    );
  }

  Widget _buildPathLine(double w, double h) {
    final r = _imageRectInContainer(w, h);
    return IgnorePointer(
      child: CustomPaint(
        size: Size(w, h),
        painter: _PathPainter(
          path: _path,
          imageRect: r,
          color: Colors.blue,
          strokeWidth: 6,
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 8, offset: const Offset(0, -2)),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('통로 연결 모드', style: TextStyle(fontSize: 14)),
                    subtitle: Text(
                      _connectMode ? '핀 2개를 눌러 통로를 연결/해제' : '길찾기 모드',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    value: _connectMode,
                    onChanged: (v) {
                      setState(() {
                        _connectMode = v;
                        _pendingConnectFromId = null;
                        _path = [];
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _mapData.edges.isEmpty ? null : _showEdgeManager,
                  icon: const Icon(Icons.tune),
                  tooltip: '통로 관리',
                ),
              ],
            ),
            if (_mapData.pins.isNotEmpty) ...[
              Text(
                '핀 ${_mapData.pins.length}개 · 도면을 탭하면 핀 추가',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_mapData.pins.isEmpty || _connectMode) ? null : _findPath,
                      icon: const Icon(Icons.route, size: 20),
                      label: Text(_path.isEmpty ? '경로 찾기' : '경로 다시 찾기'),
                    ),
                  ),
                  const SizedBox(width: 8),
                if (_startPinId != null) ...[
                  Chip(
                    avatar: const Icon(Icons.my_location, color: Colors.green, size: 18),
                    label: Text(
                      _mapData.pins.firstWhere((p) => p.id == _startPinId, orElse: () => _mapData.pins.first).name,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onDeleted: () => setState(() {
                      _startPinId = null;
                      _path = [];
                    }),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    onPressed: () => _removePin(_startPinId!),
                    tooltip: '출발 핀 삭제',
                  ),
                ],
                if (_endPinId != null) ...[
                  const SizedBox(width: 8),
                  Chip(
                    avatar: const Icon(Icons.flag, color: Colors.red, size: 18),
                    label: Text(
                      _mapData.pins.firstWhere((p) => p.id == _endPinId, orElse: () => _mapData.pins.first).name,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onDeleted: () => setState(() {
                      _endPinId = null;
                      _path = [];
                    }),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    onPressed: () => _removePin(_endPinId!),
                    tooltip: '도착 핀 삭제',
                  ),
                ],
                  if (_endPinId != null) ...[
                    const SizedBox(width: 4),
                    Chip(
                      avatar: const Icon(Icons.flag, color: Colors.red, size: 18),
                      label: Text(
                        _mapData.pins.firstWhere((p) => p.id == _endPinId, orElse: () => _mapData.pins.first).name,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ],
              ),
              if (_path.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '경로: ${_path.map((p) => p.name).join(' → ')}',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ] else
              Text(
                '도면 위를 탭해서 핀을 추가한 뒤, 출발·도착 핀을 선택하고 "경로 찾기"를 누르세요.',
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
          ],
        ),
      ),
    );
  }

  void _showEdgeManager() {
    final idToName = {for (final p in _mapData.pins) p.id: p.name};
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.link),
              title: Text('통로(엣지) 목록'),
              subtitle: Text('탭하면 해당 통로를 삭제합니다.'),
            ),
            if (_mapData.edges.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('연결된 통로가 없습니다.'),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemBuilder: (_, i) {
                    final e = _mapData.edges[i];
                    final a = idToName[e.fromId] ?? e.fromId;
                    final b = idToName[e.toId] ?? e.toId;
                    return ListTile(
                      leading: const Icon(Icons.remove_circle_outline, color: Colors.red),
                      title: Text('$a ↔ $b'),
                      onTap: () {
                        setState(() {
                          _mapData = _mapData.copyWith(
                            edges: _mapData.edges.where((x) => x != e).toList(),
                          );
                          _path = [];
                        });
                        Navigator.pop(ctx);
                      },
                    );
                  },
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemCount: _mapData.edges.length,
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _PathPainter extends CustomPainter {
  final List<IndoorPin> path;
  final Rect imageRect;
  final Color color;
  final double strokeWidth;

  _PathPainter({
    required this.path,
    required this.imageRect,
    required this.color,
    this.strokeWidth = 6,
  });

  Offset _pinToOffset(IndoorPin p) {
    return Offset(
      imageRect.left + p.x * imageRect.width,
      imageRect.top + p.y * imageRect.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (path.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (int i = 0; i < path.length - 1; i++) {
      final a = path[i];
      final b = path[i + 1];
      canvas.drawLine(_pinToOffset(a), _pinToOffset(b), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PathPainter old) =>
      old.path != path ||
      old.imageRect != imageRect ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

class _EdgesPainter extends CustomPainter {
  final List<IndoorPin> pins;
  final List<IndoorEdge> edges;
  final Rect imageRect;
  final Color color;
  final double strokeWidth;

  _EdgesPainter({
    required this.pins,
    required this.edges,
    required this.imageRect,
    required this.color,
    required this.strokeWidth,
  });

  Offset _pinToOffset(IndoorPin p) {
    return Offset(
      imageRect.left + p.x * imageRect.width,
      imageRect.top + p.y * imageRect.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (pins.isEmpty || edges.isEmpty) return;
    final byId = {for (final p in pins) p.id: p};
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (final e in edges) {
      final a = byId[e.fromId];
      final b = byId[e.toId];
      if (a == null || b == null) continue;
      canvas.drawLine(_pinToOffset(a), _pinToOffset(b), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EdgesPainter old) =>
      old.pins != pins ||
      old.edges != edges ||
      old.imageRect != imageRect ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

/// 카메라 인식용 다이얼로그 (여기에 AI 모델 연동 예정)
class _CameraRecognitionDialog extends StatefulWidget {
  final CameraDescription camera;
  const _CameraRecognitionDialog({required this.camera});

  @override
  State<_CameraRecognitionDialog> createState() => _CameraRecognitionDialogState();
}

class _CameraRecognitionDialogState extends State<_CameraRecognitionDialog> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  bool _isProcessing = false;
  ModelObjectDetection? _objectModel;
  bool _isModelLoaded = false;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    _initializeControllerFuture = _controller.initialize();
    _loadModel();
  }

  Future<void> _loadModel() async {
    if (kIsWeb) {
      debugPrint("⚠️ 웹 환경에서는 AI 모델(PyTorch Lite)을 로드할 수 없습니다. (모바일 기기에서만 지원)");
      return;
    }
    
    try {
      // YOLOv8 모델은 반드시 TorchScript 포맷(.torchscript)이어야 모바일에서 돌아갑니다.
      // best.torchscript 출력: [1, 10+4, 8400] (YOLOv8)
      _objectModel = await PytorchLite.loadObjectDetectionModel(
        "assets/models/best.torchscript",
        10,
        640,
        640,
        labelPath: "assets/models/labels.txt",
        objectDetectionModelType: ObjectDetectionModelType.yolov8,
      );
      setState(() {
        _isModelLoaded = true;
      });
      debugPrint("✅ AI 모델 로드 성공!");
    } catch (e) {
      debugPrint("❌ AI 모델 로드 실패: $e");
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _takePictureAndRecognize() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      await _initializeControllerFuture;
      final image = await _controller.takePicture();

      // -------------------------------------------------------
      // 🧠 AI 모델(PT 파일) 실제 연동
      // -------------------------------------------------------
      String recognizedText = "";

      if (!_isModelLoaded || _objectModel == null) {
        if (mounted) Navigator.pop(context, "에러: 모델 파일(best.torchscript)이 올바르게 로드되지 않았습니다.");
        return;
      }

      final imageBytes = await File(image.path).readAsBytes();
      List<ResultObjectDetection> objDetect = await _objectModel!.getImagePredictionList(
        imageBytes,
        minimumScore: 0.25,
        preProcessingMethod: PreProcessingMethod.native,
      );

      final labels = _objectModel!.labels;
      for (final det in objDetect) {
        final idx = det.classIndex;
        if (idx >= 0 && idx < labels.length) {
          det.className = labels[idx];
        }
      }

      if (objDetect.isNotEmpty) {
        // 정확도(score)가 가장 높은 결과를 선택
        objDetect.sort((a, b) => b.score.compareTo(a.score));
        recognizedText = objDetect.first.className ?? "";
        debugPrint("🎯 AI 인식 결과: $recognizedText (정확도: ${objDetect.first.score})");
      }

      if (mounted) {
        if (recognizedText.isEmpty) {
          Navigator.pop(context, "인식실패: 발견된 객체 없음"); 
        } else {
          Navigator.pop(context, recognizedText);
        }
      }
    } catch (e) {
      debugPrint('Camera error: $e');
      if (mounted) Navigator.pop(context, "에러: $e");
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('호실 인식 (AI)'),
      content: SizedBox(
        width: double.maxFinite,
        height: 380, // 입력창을 위해 높이 증가
        child: Column(
          children: [
            Expanded(
              child: FutureBuilder<void>(
                future: _initializeControllerFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        CameraPreview(_controller),
                        if (_isProcessing)
                          const CircularProgressIndicator(color: Colors.white),
                        // 가이드 라인
                        Container(
                          width: 200,
                          height: 100,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.green, width: 2),
                          ),
                        ),
                      ],
                    );
                  } else {
                    return const Center(child: CircularProgressIndicator());
                  }
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        ElevatedButton.icon(
          onPressed: _isProcessing ? null : _takePictureAndRecognize,
          icon: const Icon(Icons.camera),
          label: const Text('인식하기'),
        ),
      ],
    );
  }
}
