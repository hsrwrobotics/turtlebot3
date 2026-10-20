ARG ROS_DISTRO=jazzy
ARG LDS_MODEL=LDS-01

# ---------- builder ----------
FROM ros:${ROS_DISTRO}-ros-base AS builder
ARG ROS_DISTRO
ENV DEBIAN_FRONTEND=noninteractive \
    TB3_WS=/root/turtlebot3_ws

# Build-time only deps: build-essential, libboost-system-dev, libudev-dev,
# python3-colcon-common-extensions, python3-rosdep. The runtime stage starts
# from ros-base and only installs what the launch files actually need.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-colcon-common-extensions \
        python3-rosdep \
        build-essential \
        libboost-system-dev \
        libudev-dev \
        ros-${ROS_DISTRO}-hls-lfcd-lds-driver \
        ros-${ROS_DISTRO}-turtlebot3-msgs \
        ros-${ROS_DISTRO}-dynamixel-sdk \
        ros-${ROS_DISTRO}-xacro \
        ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    && rm -rf /var/lib/apt/lists/*

# REBUILD_AT forces this layer's checksum to change every build (CI passes
# $(date +%s) via --build-arg). Without it, `git clone` layers cache by the
# command string and would never see upstream updates. The shallow clone +
# reset-to-origin trick guarantees a fresh tip on each rebuild.
ARG REBUILD_AT
RUN git clone --depth=1 --branch ${ROS_DISTRO} https://github.com/ROBOTIS-GIT/turtlebot3.git ${TB3_WS}/src/turtlebot3 \
 && git -C ${TB3_WS}/src/turtlebot3 fetch --depth=1 origin ${ROS_DISTRO} \
 && git -C ${TB3_WS}/src/turtlebot3 reset --hard origin/${ROS_DISTRO} \
 && git clone --depth=1 --branch ${ROS_DISTRO} https://github.com/ROBOTIS-GIT/ld08_driver.git ${TB3_WS}/src/ld08_driver \
 && git clone --depth=1 --branch ${ROS_DISTRO} https://github.com/ROBOTIS-GIT/coin_d4_driver.git ${TB3_WS}/src/coin_d4_driver

WORKDIR ${TB3_WS}
RUN rm -rf src/turtlebot3/turtlebot3_cartographer src/turtlebot3/turtlebot3_navigation2 \
 && rosdep update --rosdistro=${ROS_DISTRO} \
 && rosdep install --from-paths src --ignore-src -r -y --rosdistro=${ROS_DISTRO} \
 && . /opt/ros/${ROS_DISTRO}/setup.sh \
 && colcon build --merge-install \
 && rm -rf build log src/*/build src/*/.git src/*/log

# ---------- runtime ----------
FROM ros:${ROS_DISTRO}-ros-base
ARG ROS_DISTRO
ARG LDS_MODEL
ENV DEBIAN_FRONTEND=noninteractive \
    TB3_WS=/root/turtlebot3_ws \
    LDS_MODEL=${LDS_MODEL}

# LDS-01 ships as an apt package; LDS-02/LDS-03 are built from the local
# ld08_driver / coin_d4_driver sources and live in ${TB3_WS}/install, so the
# runtime only needs the apt driver when LDS_MODEL=LDS-01.
RUN apt-get update \
 && case "${LDS_MODEL}" in \
        LDS-01) apt-get install -y --no-install-recommends ros-${ROS_DISTRO}-hls-lfcd-lds-driver ;; \
        LDS-02|LDS-03) ;; \
        *) echo "Unknown LDS_MODEL: ${LDS_MODEL}"; exit 1 ;; \
    esac \
 && apt-get install -y --no-install-recommends \
        python3-argcomplete \
        ros-${ROS_DISTRO}-turtlebot3-msgs \
        ros-${ROS_DISTRO}-dynamixel-sdk \
        ros-${ROS_DISTRO}-xacro \
        ros-${ROS_DISTRO}-rmw-zenoh-cpp \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder ${TB3_WS}/install ${TB3_WS}/install

COPY --chmod=755 <<'EOF' /tb3_entrypoint.sh
#!/bin/bash
set -e
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source "${TB3_WS}/install/setup.bash"
exec "$@"
EOF

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc \
 && echo "source ${TB3_WS}/install/setup.bash" >> /root/.bashrc

ENV ROS_DOMAIN_ID=30 \
    TURTLEBOT3_MODEL=burger

ENTRYPOINT ["/tb3_entrypoint.sh"]
CMD ["ros2", "launch", "turtlebot3_bringup", "robot.launch.py"]
