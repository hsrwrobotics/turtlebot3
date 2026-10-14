ARG ROS_DISTRO=jazzy
FROM ros:${ROS_DISTRO}-ros-base
ARG ROS_DISTRO

ENV DEBIAN_FRONTEND=noninteractive \
    TB3_WS=/root/turtlebot3_ws

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3-argcomplete \
        python3-colcon-common-extensions \
        libboost-system-dev \
        build-essential \
        libudev-dev \
        ros-${ROS_DISTRO}-hls-lfcd-lds-driver \
        ros-${ROS_DISTRO}-turtlebot3-msgs \
        ros-${ROS_DISTRO}-dynamixel-sdk \
        ros-${ROS_DISTRO}-xacro \
    && rm -rf /var/lib/apt/lists/*

ADD https://github.com/ROBOTIS-GIT/turtlebot3.git#${ROS_DISTRO} ${TB3_WS}/src/turtlebot3
ADD https://github.com/ROBOTIS-GIT/ld08_driver.git#${ROS_DISTRO} ${TB3_WS}/src/ld08_driver
ADD https://github.com/ROBOTIS-GIT/coin_d4_driver.git#${ROS_DISTRO} ${TB3_WS}/src/coin_d4_driver

WORKDIR ${TB3_WS}
RUN rm -r src/turtlebot3/turtlebot3_cartographer src/turtlebot3/turtlebot3_navigation2 \
    && . /opt/ros/${ROS_DISTRO}/setup.sh \
    && colcon build \
    && rm -rf build log

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
    TURTLEBOT3_MODEL=burger \
    LDS_MODEL=LDS-01

ENTRYPOINT ["/tb3_entrypoint.sh"]
CMD ["ros2", "launch", "turtlebot3_bringup", "robot.launch.py"]
