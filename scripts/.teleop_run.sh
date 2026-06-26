#!/usr/bin/env bash
source /root/.bashrc 2>/dev/null || true
cd /easim
source /root/.cloudxr/run/cloudxr.env
export XDG_RUNTIME_DIR=$HOME/.cloudxr/run
export XR_RUNTIME_JSON=$HOME/.cloudxr/openxr_cloudxr.json
exec ./isaac_workspace/IsaacLab/isaaclab.sh -p source/easim/cli/run_unified.py \
  --task pick_paper_balls_skill --mode teleop_record \
  --teleop_device pico_handtracking --enable_pinocchio \
  --num_success_steps 20 --no-vr-teleop-debug \
  --dataset_file datasets/imit_learning/pick_paper_balls_skill_260626_1109.hdf5
