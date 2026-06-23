# easim teleop pico g1上半身环境搭建及使用说明

# 前置条件

1. 当前工作站已经部署了easim，并且可以正常运行；

2. 遥操设备与工作站可以ping通\(可以在工作站上ping通pico\)；

3. GPU要求：RTX 4090及以上配置；

# 环境搭建

1. 防火墙相关设置\(在宿主机执行\)

    ```Plain Text
    sudo ufw allow 49100,48322/tcp
    sudo ufw allow 47998/udp
    ```

2. 部署Isaac Teleop Web Client所需的后台服务\(避开pico依赖互联网的问题\)\-\-terminal1

    ```Plain Text
    #代码拉取
    git clone  https://github.com/NVIDIA/IsaacTeleop.git 
    cd IsaacTeleop
    source scripts/setup_cloudxr_env.sh
    scripts/download_cloudxr_sdk.sh
    cd deps/cloudxr/webxr_client
    
    #conda 环境构建
    conda create -n isaac_teleop_web_server_pico_env
    
    #nvm安装
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    source ~/.bashrc
    conda activate isaac_teleop_web_server_pico_env
    nvm install 20
    nvm use 20
    
    #如果是从其他电脑拷贝的已经编译后的IsaacTeleop工程，需要执行该步骤
    rm -rf node_modules
    
    npm install ../nvidia-cloudxr-6.1.0.tgz
    
    #启动Isaac Teleop Web Client所需的后台服务
    HOST=0.0.0.0 npm run dev-server:https
    
    #验证服务是否启动
    ##另外开一个terminal，检查是否监听
    ss -lntp | grep 8080
    ```

    1. 可能报错1

        1. `cross-env` 的 bin 脚本使用了相对路径 `../index.js`。当 `.bin/cross-env` 被错误安装或损坏时，Node 会从 `node_modules/.bin/` 解析该路径，最终指向不存在的 `node_modules/index.js`，从而报错：

            ```Plain Text
            Cannot find module '.../node_modules/index.js'
            ```

        2. Jiejuefangfa 

            ```Plain Text
            cd ~/kongxiaoqiang/IsaacTeleop/deps/cloudxr/webxr_client
            rm -rf node_modules && npm install ../nvidia-cloudxr-6.1.0.tgz
            ```

    2. 可能报错2

        1. 8080被占用

            ```Plain Text
            # 查看占用 8080 的进程
            lsof -i :8080 -sTCP:LISTEN
            
            # 结束对应 PID（将 <PID> 替换为实际值）
            kill <PID>
            ```

3. cloudxr环境配置\-\-terminal2

    ```Plain Text
    #在easim工程根目录，以及easim对应的conda环境或docker环境中，安装如下依赖
    pip install 'isaacteleop[cloudxr]==1.3.43rc1' \
      --extra-index-url https://pypi.nvidia.com
    
    mkdir -p "$HOME/.cloudxr"
    cat > "$HOME/.cloudxr/hand_tracking_ab.env" <<'EOF'
    NV_CXR_ENABLE_PUSH_DEVICES=false
    NV_CXR_ENABLE_TENSOR_DATA=true
    NV_CXR_FILE_LOGGING=true
    NV_DEVICE_PROFILE=auto-webrtc
    EOF
    
    #启动cloudxr服务(非docker环境)
    python -m isaacteleop.cloudxr --accept-eula \
      --cloudxr-env-config "$HOME/.cloudxr/hand_tracking_ab.env"
    
    #启动cloudxr服务(docker环境)
    ./isaac_workspace/IsaacLab/isaaclab.sh -p -m isaacteleop.cloudxr --accept-eula \
      --cloudxr-env-config $HOME/.cloudxr/hand_tracking_ab.env
    ```

4. easim启动端环境配置\-\-terminal3

    ```Plain Text
    #启动新的terminal都需要运行如下命令，重新配置
    source $HOME/.cloudxr/run/cloudxr.env
    export XDG_RUNTIME_DIR=$HOME/.cloudxr/run
    export XR_RUNTIME_JSON=$HOME/.cloudxr/openxr_cloudxr.json
    ```

# 使用说明

1. 按如下步骤启动（总共需要3个terminal）

    1. 启动Isaac Teleop Web Client所需的后台服务（terminal 1）

        1. 注意事项

            1. 若ip地址发生变化，需要重新运行该命令

            2. 使用ctr\+c可以结束该进程

        ```Plain Text
        #需要在如下工程路径下
        cd IsaacTeleop/deps/cloudxr/webxr_client/
        
        #需要在如下conda环境中
        conda activate isaac_teleop_web_server_pico_env
        
        #启动Isaac Teleop Web Client所需的后台服务
        HOST=0.0.0.0 npm run dev-server:https
        ```

    2. 启动cloudxr（terminal 2）

        1. 注意事项

            1. 若ip地址发送变化，需要重新运行该命令

            2. 使用ctr\+c可以结束该进程

        ```Plain Text
        #需要在如下工程路径下
        cd easim
        
        #需要在easim的conda环境中
        conda activate xxx
        
        #启动cloudxr服务
        ##非docker环境
        python -m isaacteleop.cloudxr --accept-eula \
          --cloudxr-env-config "$HOME/.cloudxr/hand_tracking_ab.env"
        ##docker环境
        ./isaac_workspace/IsaacLab/isaaclab.sh -p -m isaacteleop.cloudxr --accept-eula \
          --cloudxr-env-config $HOME/.cloudxr/hand_tracking_ab.env
        ```

    3. 启动easim pico遥操（terminal 3）

        ```Plain Text
        #启动新的terminal都需要运行如下命令，重新配置
        source $HOME/.cloudxr/run/cloudxr.env
        export XDG_RUNTIME_DIR=$HOME/.cloudxr/run
        export XR_RUNTIME_JSON=$HOME/.cloudxr/openxr_cloudxr.json
        
        #运行pico遥操命令
        ##非docker环境
        python source/easim/cli/run_unified.py \
          --task pick_fruits_skill --mode teleop_record \
          --teleop_device pico_handtracking --enable_pinocchio \
          --num_success_steps 20 --no-vr-teleop-debug \
          --dataset_file datasets/imit_learning/pick_fruit_pico_hand_dex11.hdf5
        ##docker环境
        ./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \
          --task pick_fruits_skill --mode teleop_record \
          --teleop_device pico_handtracking --enable_pinocchio \
          --num_success_steps 20 --no-vr-teleop-debug \
          --dataset_file datasets/imit_learning/pick_fruit_pico_hand_dex11.hdf5
        
        #待easim完全启动在，在isaacsim的gui中，点击AR,再点击start
        
        #戴上pico，点击浏览器，输入如下地址
        https://<宿主机局域网IP>:8080
        
        #点击certificate accept(首次需要)
        
        #点击connect
        
        #进入pico的 遥操界面，点击play,倒计时结束后可以开始遥操，点击reset 可以重置场景，点击disconnect，可以退出pico遥操界面
        ```

        # 其他

        1. terminal2运行命令，报端口已经被占用，但又找不到占用该端口的进程\(docker环境中发现，如下命令需要在宿主机执行\)

            ```Plain Text
            #48322和49100在临时端口范围 32768–60999 内，将来也可能被浏览器等抢占。需要在宿主机把它和 48322 一起预留并持久化。
            
            ##单独持久化48322
            ## 1) 先预留 48322，防止断开后又被 Chrome 立刻抢回去
            sudo sysctl -w net.ipv4.ip_local_reserved_ports=48322
            
            ## 2) 立即断开当前占用 48322 的那条连接（只杀这一条 socket，不杀浏览器；Chrome 会自动换端口重连）
            sudo ss -K 'sport = 48322'
            
            ## 3) 确认已释放（应无输出或显示“已释放”）
            ss -tanp | grep ':48322 ' || echo "48322 已释放"
            
            ## 4) 持久化，重启后仍生效
            echo 'net.ipv4.ip_local_reserved_ports=48322' | sudo tee /etc/sysctl.d/99-cloudxr-reserved.conf
            
            ##48322和49100一起持久化
            ## 注意：ip_local_reserved_ports 是“整体覆盖”，要把 48322 一起写上
            sudo sysctl -w net.ipv4.ip_local_reserved_ports=48322,49100
            echo 'net.ipv4.ip_local_reserved_ports=48322,49100' | sudo tee /etc/sysctl.d/99-cloudxr-reserved.conf
            ```

        

        

