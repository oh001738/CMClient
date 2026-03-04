#!/bin/bash

# 1. 同步程式碼
git fetch --all
git reset --hard origin/main

# 2. 執行 Compose (注意服務名稱是 callmesh-client)
sudo docker-compose up -d --build callmesh-client

# 3. 清理沒用的舊 Image 佔空間
sudo docker image prune -f

echo "✅ 部署完成！請執行 'sudo docker logs -f callmesh-client' 查看運行狀況。"
