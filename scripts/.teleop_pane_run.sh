#!/usr/bin/env bash
set +e

echo -e '\033[0;36m[Terminal 3] easim 遥操 — Docker 容器\033[0m'
echo -e '\033[1;32m场景：抓纸团果皮 | 设备：pico_handtracking\033[0m'
echo -e '\033[1;32m数据集：datasets/imit_learning/pick_paper_balls_skill_260629_1654.hdf5\033[0m'
echo ''
echo -e '\033[1;32m[Pico 连接地址] https://10.169.21.19:8080\033[0m'
echo '  easim 启动后：Isaac Sim GUI → AR → Start'
echo '  Pico 浏览器输入上方地址 → Accept → Connect → Play'
echo ''

read -rp '等待 Terminal 1、2 服务就绪后，按 Enter 启动遥操... '
if [ $? -ne 0 ]; then
    TELEOP_STATUS=130
else
    docker exec -it kxq_easim_container bash /deploy_scripts/.teleop_run.sh
    TELEOP_STATUS=$?
fi

echo ''
echo '[INFO] 遥操进程已退出，3 秒后关闭 tmux session 并返回入口菜单...'
sleep 3
tmux kill-session -t "easim_teleop" 2>/dev/null
exit $TELEOP_STATUS
