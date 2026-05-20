from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
import json
import os

app = FastAPI()

# 이미지 파일 서비스 (정적 파일)
if not os.path.exists("uploads"):
    os.makedirs("uploads")
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

# 모든 접속 허용 (앱과 연결하기 위해 필수)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# 데이터 저장 폴더
SAVE_DIR = "indoor_maps"
if not os.path.exists(SAVE_DIR):
    os.makedirs(SAVE_DIR)

@app.post("/api/indoor_map/")
@app.post("/api/indoor_map")
async def save_indoor_map(request: Request):
    data = await request.json()
    map_id = data.get("map_id", "default_map")
    file_path = os.path.join(SAVE_DIR, f"{map_id}.json")
    
    with open(file_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
    
    print(f"✅ [실내지도 저장 완료] ID: {map_id}")
    return {"status": "success", "message": f"Map {map_id} saved."}

@app.get("/api/indoor_map")
async def load_indoor_map(map_id: str, response: Response):
    file_path = os.path.join(SAVE_DIR, f"{map_id}.json")
    if os.path.exists(file_path):
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return {"status": "success", "data": data}
    
    response.status_code = 404
    return {"status": "error", "message": "Map not found"}

@app.post("/api/location")
async def save_location(request: Request):
    data = await request.json()
    print(f"📍 [위치 수신] 사용자: {data.get('user_id')}, 위치: ({data.get('latitude')}, {data.get('longitude')})")
    return {"status": "success"}

if __name__ == "__main__":
    import uvicorn
    # 노트북의 모든 네트워크 인터페이스에서 접속 가능하도록 설정
    print("🚀 서버가 시작되었습니다! 노트북 주소: 165.229.229.173:8000")
    uvicorn.run(app, host="0.0.0.0", port=8000)
