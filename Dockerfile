# TurtleBot3 SBC image.
#
# Reproduces the ROBOTIS "TurtleBot3 SBC Setup" manual inside a container:
#   https://emanual.robotis.com/docs/en/platform/turtlebot3/sbc_setup/
#
# Manual steps, in order:
#   1. ROS 2 Jazzy/Humble, "ROS-Base (Bare Bones)" -> base image ros:${ROS_DISTRO}-ros-base
#   2. apt install python3-argcomplete python3-colcon-common-extensions
#        libboost-system-dev build-essential
#      apt install ros-${ROS_DISTRO}-hls-lfcd-lds-driver
#      apt install ros-${ROS_DISTRO}-turtlebot3-msgs
#      apt install ros-${ROS_DISTRO}-dynamixel-sdk
#      apt install ros-${ROS_DISTRO}-xacro
#      apt install libudev-dev
#   3. git clone turtlebot3, ld08_driver, coin_d4_driver into ~/turtlebot3_ws/src
#   4. rm -r turtlebot3_cartographer turtlebot3_navigation2
#   5. colcon build --symlink-install --parallel-workers 1
#   6. source /opt/ros/<distro>/setup.bash and ~/turtlebot3_ws/install/setup.bash
#   7. ros2 launch turtlebot3_bringup robot.launch.py
#
# Only addition to the manual: ros-${ROS_DISTRO}-rmw-zenoh-cpp is installed.
# The RMW is not switched here, so a plain `docker run` behaves exactly like
# the manual (DDS). docker-compose.yml selects rmw_zenoh_cpp when the robot
# talks to a Zenoh router.

ARG ROS_DISTRO=jazzy

FROM ros:${ROS_DISTRO}-ros-base
ARG ROS_DISTRO

ENV DEBIAN_FRONTEND=noninteractive \
    TB3_WS=/root/turtlebot3_ws \
    ROS_DOMAIN_ID=30 \
    TURTLEBOT3_MODEL=burger \
    LDS_MODEL=LDS-01

# 2. Packages (manual: "Install and Build ROS Packages")
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-argcomplete \
        python3-colcon-common-extensions \
        libboost-system-dev \
        build-essential \
        ros-${ROS_DISTRO}-hls-lfcd-lds-driver \
        ros-${ROS_DISTRO}-turtlebot3-msgs \
        ros-${ROS_DISTRO}-dynamixel-sdk \
        ros-${ROS_DISTRO}-xacro \
        libudev-dev \
        ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    && rm -rf /var/lib/apt/lists/*

# 3. Sources (manual: git clone into ~/turtlebot3_ws/src).
# REBUILD_AT is not used in the command; it only invalidates this layer so
# every build fetches the current upstream tip instead of a cached clone.
ARG REBUILD_AT
RUN mkdir -p ${TB3_WS}/src \
 && git clone --depth=1 --branch ${ROS_DISTRO} https://github.com/ROBOTIS-GIT/turtlebot3.git ${TB3_WS}/src/turtlebot3 \
 && git clone --depth=1 --branch ${ROS_DISTRO} https://github.com/ROBOTIS-GIT/ld08_driver.git ${TB3_WS}/src/ld08_driver \
 && git clone --depth=1 --branch ${ROS_DISTRO} https://github.com/ROBOTIS-GIT/coin_d4_driver.git ${TB3_WS}/src/coin_d4_driver

# 4. The manual drops these two packages before building.
RUN rm -r ${TB3_WS}/src/turtlebot3/turtlebot3_cartographer \
          ${TB3_WS}/src/turtlebot3/turtlebot3_navigation2

# 5. Build (manual: colcon build --symlink-install --parallel-workers 1).
# --symlink-install keeps install/ pointing at src/ and build/, so both stay
# in the image and the workspace can be rebuilt inside the container.
# --parallel-workers 1 is the manual's setting for 2 GB boards; a build
# machine with more RAM can override COLCON_BUILD_ARGS.
ARG COLCON_BUILD_ARGS="--symlink-install --parallel-workers 1"
RUN . /opt/ros/${ROS_DISTRO}/setup.sh \
 && cd ${TB3_WS} \
 && colcon build ${COLCON_BUILD_ARGS}

# 6. Environment (manual: source ... >> ~/.bashrc)
RUN echo 'source /opt/ros/${ROS_DISTRO}/setup.bash' >> /root/.bashrc \
 && echo 'source ${TB3_WS}/install/setup.bash' >> /root/.bashrc

# OpenCR firmware updater (manual: "OpenCR Setup" page).
# The loader inside opencr_update.tar.bz2 is a 32-bit ARM binary, so the armhf
# libc is needed, exactly as the manual installs it on the SBC.
RUN dpkg --add-architecture armhf \
 && { [ ! -f /etc/apt/sources.list.d/ubuntu.sources ] || sed -i -E 's/^Architectures:.*/Architectures: arm64 armhf/' /etc/apt/sources.list.d/ubuntu.sources; } \
 && apt-get update \
 && apt-get install -y --no-install-recommends libc6:armhf \
 && rm -rf /var/lib/apt/lists/*

ARG OPENCR_BINARIES_URL=https://github.com/ROBOTIS-GIT/OpenCR-Binaries/raw/master/turtlebot3/ROS2/latest/opencr_update.tar.bz2
# -f on curl so an HTTP error fails the build instead of writing an error page.
# tar reads the archive from the file operand, so no -C before it: with -C in
# front, tar takes the path as a member name and reads the archive from stdin.
RUN mkdir -p /opt/opencr_update \
 && curl -sSLf -o /tmp/opencr_update.tar.bz2 "$OPENCR_BINARIES_URL" \
 && cd /opt/opencr_update \
 && tar -xjf /tmp/opencr_update.tar.bz2 --strip-components=1 \
 && rm -f /tmp/opencr_update.tar.bz2 \
 && chmod +x update.sh opencr_ld_shell_arm opencr_ld_shell_x86

COPY --chmod=755 <<'EOF' /usr/local/bin/flash-opencr
#!/bin/bash
# Flash the OpenCR firmware (manual: OpenCR Setup page).
#   OPENCR_PORT=/dev/ttyACM0 OPENCR_MODEL=burger flash-opencr
# The robot must not be running, the updater needs the OpenCR port.
set -e
PORT="${OPENCR_PORT:-/dev/ttyACM0}"
MODEL="${OPENCR_MODEL:-burger}"
cd /opt/opencr_update
echo "Flashing ${MODEL}.opencr to ${PORT}"
exec ./update.sh "$PORT" "${MODEL}.opencr"
EOF
COPY --chmod=755 <<'EOF' /tb3_entrypoint.sh
#!/bin/bash
set -e
# Same as the base image entrypoint (ros_entrypoint.sh), plus the workspace.
source "/opt/ros/${ROS_DISTRO}/setup.bash" --
source "${TB3_WS}/install/setup.bash" --
exec "$@"
EOF

ENTRYPOINT ["/tb3_entrypoint.sh"]
CMD ["ros2", "launch", "turtlebot3_bringup", "robot.launch.py"]
