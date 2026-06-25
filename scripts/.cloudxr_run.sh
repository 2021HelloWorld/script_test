#!/usr/bin/env bash
source /root/.bashrc 2>/dev/null || true
cd /easim
exec ./isaac_workspace/IsaacLab/isaaclab.sh -p -m isaacteleop.cloudxr --accept-eula \
    --cloudxr-env-config $HOME/.cloudxr/hand_tracking_ab.env
