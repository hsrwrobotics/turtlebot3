# TurtleBot3 Burger SBC image

The software of the ROBOTIS [TurtleBot3 SBC Setup][manual] manual, packaged in a
Docker image so nothing ROS-related has to be installed on the Raspberry Pi
itself.

Images (linux/arm64) are pushed to Docker Hub by GitHub Actions on every push to `main`:
- `<DOCKERHUB_USERNAME>/turtlebot3:jazzy`
- `<DOCKERHUB_USERNAME>/turtlebot3:humble`
- `<DOCKERHUB_USERNAME>/turtlebot3:<distro>-<git sha>`

## Manual parity

| Manual step | Container |
| --- | --- |
| ROS 2 Jazzy/Humble, "ROS-Base (Bare Bones)" | base image `ros:${ROS_DISTRO}-ros-base` |
| `apt install python3-argcomplete python3-colcon-common-extensions libboost-system-dev build-essential` | same |
| `apt install ros-$ROS_DISTRO-hls-lfcd-lds-driver` | same |
| `apt install ros-$ROS_DISTRO-turtlebot3-msgs` | same |
| `apt install ros-$ROS_DISTRO-dynamixel-sdk` | same |
| `apt install ros-$ROS_DISTRO-xacro` | same |
| `apt install libudev-dev` | same |
| `git clone -b $ROS_DISTRO turtlebot3 ld08_driver coin_d4_driver` into `~/turtlebot3_ws/src` | same |
| `rm -r turtlebot3_cartographer turtlebot3_navigation2` | same |
| `colcon build --symlink-install --parallel-workers 1` | same |
| `source /opt/ros/$ROS_DISTRO/setup.bash` + `~/turtlebot3_ws/install/setup.bash` | `~/.bashrc` and the entrypoint |
| `export ROS_DOMAIN_ID=30` | `ENV ROS_DOMAIN_ID=30` |
| `export LDS_MODEL=LDS-01\|02\|03` | `ENV LDS_MODEL=LDS-01`, override in compose |
| `export TURTLEBOT3_MODEL=burger` | `ENV TURTLEBOT3_MODEL=burger` |
| udev rules for OpenCR/LDS | host step, see below |
| OpenCR Setup: `dpkg --add-architecture armhf`, `apt install libc6:armhf`, `wget opencr_update.tar.bz2`, `./update.sh $OPENCR_PORT $OPENCR_MODEL.opencr` | `flash-opencr` in the image, see below |
| `ros2 launch turtlebot3_bringup robot.launch.py` | container `CMD` |

One package is added: `ros-$ROS_DISTRO-rmw-zenoh-cpp`. It is installed but not
selected, so a plain `docker run` behaves exactly like the manual (DDS). The
Zenoh router setup is opt-in through `docker-compose.yml`.

## Raspberry Pi host setup

Steps from the manual that must stay on the host:

1. Flash a 64-bit OS (Ubuntu Server 24.04 or Raspberry Pi OS), configure Wi-Fi and SSH.
2. Disable auto-upgrades, mask sleep targets and add swap for 2 GB models as in the manual.
3. Install Docker and docker compose
4. Install the OpenCR/LDS udev rules from the image:

   ```bash
   docker run --rm <DOCKERHUB_USERNAME>/turtlebot3:jazzy bash -c 'cat $(ros2 pkg prefix turtlebot3_bringup)/share/turtlebot3_bringup/script/99-turtlebot3-cdc.rules' | sudo tee /etc/udev/rules.d/99-turtlebot3-cdc.rules
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```

   The rules set `ID_MM_DEVICE_IGNORE=1` for the OpenCR USB serial device, so
   ModemManager does not swallow the port.

5. OpenCR firmware: the image can flash it, see "OpenCR firmware" below.

## OpenCR firmware

The image carries the official OpenCR updater (`opencr_update.tar.bz2` from
`OpenCR-Binaries`) plus the `armhf` libc its loader needs, so the flash runs
in the container like the manual runs it on the SBC:

```bash
docker compose stop turtlebot3
docker compose --profile tools run --rm opencr-flash
```

Stop the robot first: the updater needs exclusive access to the OpenCR port
(`/dev/ttyACM0`) and `turtlebot3_ros` holds it while running.

Overrides via `.env`:

```bash
OPENCR_PORT=/dev/ttyACM0
OPENCR_MODEL=burger   # burger or waffle
```

If the upload fails, put the board in recovery mode and run it again: hold
`PUSH SW2`, press `Reset`, release `Reset`, release `PUSH SW2` (the STATUS LED
blinks while in recovery mode).

## Run

Default command is `ros2 launch turtlebot3_bringup robot.launch.py`.
Set `LDS_MODEL` to the lidar on your robot (`LDS-01`, `LDS-02` or `LDS-03`).

```bash
docker compose up -d
docker compose logs -f
```

Shell inside the running container:

```bash
docker exec -it turtlebot3 bash
```

Environment defaults: `ROS_DOMAIN_ID=30`, `TURTLEBOT3_MODEL=burger`, `LDS_MODEL=LDS-01`.

## Zenoh

The robot uses `rmw_zenoh_cpp` instead of DDS and connects to an existing Zenoh router
on `tcp/<ZENOH_ROUTER_IP>:7447`. Set the router IP and domain ID on the Pi, e.g. in a
`.env` file next to `docker-compose.yml`:

```bash
ZENOH_ROUTER_IP=192.168.1.10
ROS_DOMAIN_ID=30
```

Remote PC nodes must use the same router, `RMW_IMPLEMENTATION=rmw_zenoh_cpp` and `ROS_DOMAIN_ID`.

The container runs the Zenoh session in `client` mode: one session to the router, and
the router forwards between the hosts. `peer` mode would learn the other hosts'
loopback-only listen addresses from the router and try to dial them, which cannot
work across machines.

## Build

```bash
docker build --build-arg ROS_DISTRO=jazzy --build-arg REBUILD_AT=$(date +%s) -t turtlebot3:jazzy .
```

`REBUILD_AT` is not used by the build, it only invalidates the clone layer so every
build fetches the current upstream tip instead of a cached clone.

## Verify

```bash
ros2 node list     # /turtlebot3_node must be there
ros2 topic list    # /imu /battery_state /odom /scan /joint_states
```

## Troubleshooting

`Failed connection with Devices` from `turtlebot3_ros`: the OpenCR did not answer on
`/dev/ttyACM0`. The driver then aborts (upstream calls `rclcpp::shutdown()` and keeps
constructing the node, so the first publisher creation throws). Check on the host:

```bash
lsusb                              # OpenCR = 0483:5740, LDS-01 = 10c4:ea60
sudo fuser -v /dev/ttyACM0         # nobody else may hold the port
systemctl status ModemManager      # must not grab /dev/ttyACM0
```

Then replug the OpenCR USB, power-cycle the robot and restart the container.

[manual]: https://emanual.robotis.com/docs/en/platform/turtlebot3/sbc_setup/
[opencr]: https://emanual.robotis.com/docs/en/platform/turtlebot3/opencr_setup/
