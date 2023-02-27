ARG BASE_IMAGE

############ dependencies ######################################################
FROM ${BASE_IMAGE} as dependencies

USER root
SHELL ["/bin/bash", "-c"]

# create workspace folder structure
ENV WORKSPACE=/docker-ros/ws
WORKDIR $WORKSPACE
RUN mkdir -p src/target src/upstream src/downstream

# install ROS bootstrapping tools
RUN apt-get update && \
    apt-get install -y \
        python3-rosdep \
        python3-vcstool \
    && rm -rf /var/lib/apt/lists/*

# copy contents of repository
COPY . src/repository

# if repository is a top-level package, move contents to <PACKAGE_NAME> folder
RUN shopt -s dotglob && \
    if [[ -f "src/repository/package.xml" ]]; then \
        PACKAGE_NAME=$(sed -n 's/.*<name>\(.*\)<\/name>.*/\1/p' src/repository/package.xml) && \
        mkdir -p src/target/${PACKAGE_NAME} && \
        mv src/repository/* src/target/${PACKAGE_NAME} ; \
    else \
        mv src/repository/* src/target ; \
    fi && \
    rm -r src/repository

# clone .repos upstream dependencies
ARG GIT_HTTPS_URL=https://gitlab.ika.rwth-aachen.de
ARG GIT_HTTPS_USER=
ARG GIT_HTTPS_PASSWORD=
RUN if [ ! -z ${GIT_HTTPS_USER} ]; then \
        git config --global url.https://${GIT_HTTPS_USER}:${GIT_HTTPS_PASSWORD}@gitlab.ika.rwth-aachen.de.insteadOf ${GIT_HTTPS_URL} ; \
    fi
COPY docker/docker-ros/recursive_vcs_import.py /usr/local/bin
RUN apt-get update && \
    apt-get install -y python-is-python3 && \
    rm -rf /var/lib/apt/lists/*
RUN /usr/local/bin/recursive_vcs_import.py src src/upstream

# create install script with list of rosdep dependencies
RUN echo "set -e" >> $WORKSPACE/.install-dependencies.sh && \
    apt-get update && \
    rosdep init && \
    rosdep update && \
    export OS="ubuntu:$(lsb_release -c | awk '{print $2}')" && \
    if [[ "$ROS_DISTRO" = "rolling" && "$OS" = "ubuntu:focal" ]]; then export OS="ubuntu:jammy"; fi && \
    set -o pipefail && \
    ROS_PACKAGE_PATH=$(pwd):$ROS_PACKAGE_PATH rosdep install --os $OS -y --simulate --from-paths src --ignore-src | tee -a $WORKSPACE/.install-dependencies.sh && \
    chmod +x $WORKSPACE/.install-dependencies.sh && \
    rm -rf /var/lib/apt/lists/*

# add additionally specified apt dependencies to install script
RUN echo "apt-get install -y \\" >> $WORKSPACE/.install-dependencies.sh && \
    set -o pipefail && \
    find . -type f -name "additional.apt-dependencies" -exec cat {} \; | awk '{print "  " $0 " \\"}' >> $WORKSPACE/.install-dependencies.sh && \
    echo ";" >> $WORKSPACE/.install-dependencies.sh

# add custom installation commands to install script
RUN find . -type f -name "custom.sh" -exec cat {} >> $WORKSPACE/.install-dependencies.sh \;

############ dependencies-install ##############################################
FROM ${BASE_IMAGE} AS dependencies-install
ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH}

USER root
SHELL ["/bin/bash", "-c"]

# user setup
ENV DOCKER_USER=dockeruser
ENV DOCKER_UID=
ENV DOCKER_GID=

# set workspace
ENV WORKSPACE=/docker-ros/ws
WORKDIR $WORKSPACE

# install ROS dev tools (rosdep, vcs, ...) and other essentials
RUN apt-get update && \
    apt-get install -y \
        gosu \
        python3-catkin-tools \
        python3-rosdep \
        python3-vcstool \
        ros-dev-tools \
    && rm -rf /var/lib/apt/lists/*

# set colcon configuration directory, if needed
ENV COLCON_HOME=$WORKSPACE/.colcon

# source ROS
RUN echo "source /opt/ros/$ROS_DISTRO/setup.bash" >> ~/.bashrc

# copy contents of files-folder into image, if it exists (use yaml as existing dummy)
COPY docker/docker-compose.yaml docker/files* /docker-ros/files/
RUN rm /docker-ros/files/docker-compose.yaml

# copy install script from dependencies stage
COPY --from=dependencies $WORKSPACE/.install-dependencies.sh $WORKSPACE/.install-dependencies.sh

# install dependencies
RUN apt-get update && \
    $WORKSPACE/.install-dependencies.sh && \
    rm -rf /var/lib/apt/lists/*

# set entrypoint
COPY docker/docker-ros/entrypoint.sh /
ENTRYPOINT ["/entrypoint.sh"]

############ dev ###############################################################
FROM dependencies-install as dev

# copy contents of repository from dependencies stage
COPY --from=dependencies $WORKSPACE/src $WORKSPACE/src

CMD ["bash"]

############ build #############################################################
FROM dev as build

# build ROS workspace
RUN if [ -x "$(command -v colcon)" ]; then \
        colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release ; \
    elif [ -x "$(command -v catkin)" ]; then \
        catkin build -DCMAKE_BUILD_TYPE=Release --force-color --no-status --summarize ; \
    fi
RUN echo "[[ -f $WORKSPACE/devel/setup.bash ]] && source $WORKSPACE/devel/setup.bash" >> ~/.bashrc && \
    echo "[[ -f $WORKSPACE/install/setup.bash ]] && source $WORKSPACE/install/setup.bash" >> ~/.bashrc

############ run ###############################################################
FROM dependencies-install as run

# copy ROS install space from build stage
COPY --from=build $WORKSPACE/install install
RUN echo "[[ -f $WORKSPACE/devel/setup.bash ]] && source $WORKSPACE/devel/setup.bash" >> ~/.bashrc && \
    echo "[[ -f $WORKSPACE/install/setup.bash ]] && source $WORKSPACE/install/setup.bash" >> ~/.bashrc

# setup command
ARG COMMAND
RUN echo "#!/bin/bash" > .cmd.sh && \
    echo ${COMMAND} >> .cmd.sh && \
    chmod a+x .cmd.sh
CMD ["./.cmd.sh"]
