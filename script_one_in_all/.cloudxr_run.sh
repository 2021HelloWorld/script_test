#!/usr/bin/env bash
source /root/.bashrc 2>/dev/null || true
echo '[INFO] Starting CloudXR service in foreground; this pane should stay occupied.'
# 清理残留的 CloudXR 进程，释放端口（兼容没有 fuser 的容器）
pkill -f 'isaacteleop.cloudxr' 2>/dev/null || true
sleep 2
for port in 49100 48322; do
    pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1)
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
done
cd /easim
echo '[INFO] Launching isaacteleop.cloudxr. If the last line is "Using python from:", wait 1-3 minutes, then start Terminal 3.'
export PYTHONUNBUFFERED=1
exec ./isaac_workspace/IsaacLab/isaaclab.sh -p -m isaacteleop.cloudxr --accept-eula \
    --cloudxr-env-config $HOME/.cloudxr/hand_tracking_ab.env
