# esim docker 环境构建

1. 重瑞给的输入



```Plain Text
https://gitlab.senseauto.com/kaiwu/simulation/utils/easim/-/commits/feature%2Fnav2-integration-dev-20260410?ref_type=heads 
这个分支最新的提交
dockerfile:    docker/dockerfile.easimnew
docker run --rm -itd   --gpus all   --name easim_v0.2   --network host   -e ROS_DOMAIN_ID=0  -v /mnt/data2T/source/Robot:/data/robot_control_framework   easim:v0.3
进入容器后：
1.下载easim代码，切换到对应分支（）
2.执行bash scritps/init_env.sh （不需要执行以前的setup_env.sh， 这个脚本只在上面的分支有，可以先copy过来）
3.下载asset
4.进入conda activate env_isaaclab_easim 就可以执行了
应该就可以跑了
```



1. 环境问题解决

    1. 创建

    ```Plain Text
    
    #构建docker images
    cd easim/
    docker build -f docker/Dockerfile.easimnew -t easim:v0.3 .
    
    #宿主机
    xhost +local:docker
    
    
    #1. 生成 CDI 规格（宿主机）
    sudo mkdir -p /etc/cdi
    
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    ##若提示没有安装nvidia-ctk，可以使用如下命令进行安装后再运行上面的命令
    sudo apt update
    sudo apt install -y nvidia-container-toolkit
    
    
    ls -l /etc/cdi/nvidia.yaml
    grep -cE 'nvidia_icd|libGLX_nvidia|libnvidia-glcore|libEGL_nvidia|libnvidia-vulkan' /etc/cdi/nvidia.yaml
    sudo nvidia-ctk cdi list
    
    #2. 确认 Docker 识别 CDI 设备（宿主机）(注意docker --version ≥ 25.0)
    docker --version
    docker info 2>/dev/null | grep -iE 'runtime|cdi'
    
    #3. 清掉旧容器，用 CDI 重启（宿主机）
    docker rm -f kxq_easim_container 2>/dev/null
    # 把宿主的 XAUTHORITY cookie 复制到一个任何人可读的位置(cp /run/user/1001/gdm/Xauthority /tmp/.docker.xauth 这步：每次宿主机重启、或你退出当前桌面会话再登入，都要重做（因为 GDM 会换 cookie）)
    cp /run/user/1001/gdm/Xauthority /tmp/.docker.xauth
    chmod 644 /tmp/.docker.xauth
    
    #注意修改如下命令参数-v /mnt/hdd1/kongxiaoqiang1/git_code/docker_easim/easim:/easim中的/mnt/hdd1/kongxiaoqiang1/git_code/docker_easim/easim需要替换为当前电脑的easim绝对路径
    docker run --rm -itd \
      --name kxq_easim_container \
      --network host \
      --device nvidia.com/gpu=all \
      -e NVIDIA_DRIVER_CAPABILITIES=all \
      -e NVIDIA_VISIBLE_DEVICES=all \
      -e DISPLAY=$DISPLAY \
      -e XAUTHORITY=/tmp/.docker.xauth \
      -e QT_X11_NO_MITSHM=1 \
      -v /tmp/.X11-unix:/tmp/.X11-unix \
      -v /tmp/.docker.xauth:/tmp/.docker.xauth \
      --ipc=host \
      --shm-size=16g \
      -e ROS_DOMAIN_ID=0 \
      -v /mnt/hdd1/kongxiaoqiang1/git_code/docker_easim/easim:/easim \
      easim:v0.3
    
    #进入docker container
    docker exec -it kxq_easim_container /bin/bash
    
    
    #先在宿主机执行如下命令，看宿主机输出是否为几，然后后面在docker中的export DISPLAY也要为同样的数字。如下为例如宿主机输出为0.
    echo $DISPLAY
    #然后在docker内执行
    #这里的重点：你之后跑 Isaac Sim 前，同一个 shell 也要先 export DISPLAY=:0，因为容器里本来就是 :1.0。或者写进 ~/.bashrc 里：
    echo 'export DISPLAY=:0' >> /root/.bashrc
    
    #设一个环境变量，让 Kit 允许 root 启动
    # 也写进 ~/.bashrc，避免以后新开 shell 又忘
    echo 'export OMNI_KIT_ALLOW_ROOT=1' >> /root/.bashrc
    
    #让环境变量修改生效
    source /root/.bashrc
    
    # 1)创建软连接
    cd /easim
    ln -s /data/isaac_workspace isaac_workspace 
    
    # 2) 把 Isaac Lab 的 source 包装进 Isaac Sim bundled Python
    cd /easim/isaac_workspace/IsaacLab
    ./isaaclab.sh --install         # 或 ./isaaclab.sh -i
    
    # 3) 把 easim 装进同一个 Python
    /easim/isaac_workspace/IsaacLab/_isaac_sim/python.sh -m pip install -e /easim
    
    # 4) 现在可以跑 run_unified.py 了(验证环境)
    4.1)
    cd /easim
    ./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \
        --task pick_place_skill --mode scene_preview
    4.2)
    ./isaac_workspace/IsaacLab/isaaclab.sh -s
    
    
    #进入一个docker container后,运行如下命令，可以使用easim模块
    cd /easim
    pip install -e .
    
    
    #如果你中途想重来：(把这两行跑掉就回到"什么都没配"的干净状态，重新从 1 走起。)
    docker rm -f kxq_easim_container 2>/dev/null
    sudo rm -f /etc/cdi/nvidia.yaml
    
    
    #安装工具，支持将h264转换为mp4
    apt update
    apt install -y ffmpeg
    
    #安装pyarrow，用于支持fastwam_robotwin2.0数据验证(没使用conda的情况)
    ./isaac_workspace/IsaacLab/isaaclab.sh -p -m pip install pyarrow
    
    #安装遥操中pink ik依赖
    ./isaac_workspace/IsaacLab/isaaclab.sh -p -m pip install "numpy>=1.26.0,<2.0"
    ./isaac_workspace/IsaacLab/isaaclab.sh -p -m pip install --no-deps "osqp>=1.0.0,<2.0.0"
    
    #解决回放环境问题
    /easim/isaac_workspace/IsaacLab/_isaac_sim/python.sh -m pip install "scipy==1.15.3" "warp-lang==1.12.1"
    /easim/isaac_workspace/IsaacLab/_isaac_sim/python.sh -m pip install "onnxruntime==1.26.0"
    ```

    1. `nvidia-ctk: command not found` 说明系统中没有安装 **NVIDIA Container Toolkit**

        

        ```Plain Text
        #Ubuntu 22.04 安装 NVIDIA Container Toolkit
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        
        sudo apt update
        
        sudo apt install -y nvidia-container-toolkit
        
        #安装后确认
        which nvidia-ctk
        ```

2. 

    

