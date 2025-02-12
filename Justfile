export repo_organization := "centos-workstation"
export image_name := "main"
export centos_version := "stream10"

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

build $centos_version="stream10" $tag="latest":
    #!/usr/bin/env bash

    # Get Version
    ver="${tag}-${centos_version}.$(date +%Y%m%d)"

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "MAJOR_VERSION=${centos_version}")
    # BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${image_name}")
    # BUILD_ARGS+=("--build-arg" "IMAGE_VENDOR=${repo_organization}")
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    LABELS=()
    LABELS+=("--label" "org.opencontainers.image.title=${image_name}")
    LABELS+=("--label" "org.opencontainers.image.version=${ver}")
    # LABELS+=("--label" "ostree.linux=${kernel_release}")
    LABELS+=("--label" "io.artifacthub.package.readme-url=https://raw.githubusercontent.com/ublue-os/bluefin/bluefin/README.md")
    LABELS+=("--label" "io.artifacthub.package.logo-url=https://avatars.githubusercontent.com/u/120078124?s=200&v=4")
    LABELS+=("--label" "org.opencontainers.image.description=CentOS based images")

    podman build \
        "${BUILD_ARGS[@]}" \
        "${LABELS[@]}" \
        --tag "${image_name}:${tag}" \
        .

build-vm $target_image=("localhost/" + image_name) $tag="latest" $type="qcow2":
    #!/usr/bin/env bash
    set -euo pipefail

    if ! sudo podman image exists "${target_image}" ; then
      echo "Ensuring image is on root storage"
      COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
      sudo podman image scp "$USER@localhost::${target_image}" root@localhost::
      rm -rf "${COPYTMP}"
    fi

    echo "Cleaning up previous build"
    sudo rm -rf output || true
    mkdir -p output

    args="--type ${type}"

    if [[ $target_image == localhost/* ]]; then
      args+=" --local"
    fi

    echo "${args}"
    sudo podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --security-opt label=type:unconfined_t \
      -v $(pwd)/image-builder.config.toml:/config.toml:ro \
      -v $(pwd)/output:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      quay.io/centos-bootc/bootc-image-builder:latest \
      ${args} \
      "${target_image}"

      sudo chown -R $USER:$USER output
      echo "making the image biggerer"
      sudo qemu-img resize output/qcow2/disk.qcow2 80G

run-vm:
    virsh dominfo centos-workstation-main &> /dev/null && \
    ( virsh destroy centos-workstation-main ; virsh undefine centos-workstation-main ) 
    virt-install --import \
    --name centos-workstation-main \
    --disk output/qcow2/disk.qcow2,format=qcow2,bus=virtio \
    --memory 4096 \
    --vcpus 4 \
    --os-variant centos-stream9 \
    --network bridge:virbr0 \
    --graphics vnc

    virsh start centos-workstation-main

[private]
centos_version:
    echo "{{ centos_version }}"

[private]
image_name:
    echo "{{ image_name }}"

# Generate Default Tag
[group('Utility')]
generate-default-tag tag="latest":
    #!/usr/bin/bash
    set -eou pipefail

    echo "{{ tag }}"

# Generate Tags
[group('Utility')]
generate-build-tags tag="latest" ghcr="0" $version="" github_event="" github_number="":
    #!/usr/bin/bash
    set -eoux pipefail

    TODAY="$(date +%A)"
    if [[ {{ ghcr }} == "0" ]]; then
        rm -f /tmp/manifest.json
    fi
    CENTOS_VERSION="{{ centos_version }}"
    DEFAULT_TAG=$(just generate-default-tag {{ tag }})
    IMAGE_NAME={{ image_name }}
    # Use Build Version from Rechunk
    if [[ -z "${version:-}" ]]; then
        version="{{ tag }}-${CENTOS_VERSION}.$(date +%Y%m%d)"
    fi
    version=${version#{{ tag }}-}

    # Arrays for Tags
    BUILD_TAGS=()
    COMMIT_TAGS=()

    BUILD_TAGS+=($(date +%Y%m%d))

    # Commit Tags
    github_number="{{ github_number }}"
    SHA_SHORT="$(git rev-parse --short HEAD)"
    if [[ "{{ ghcr }}" == "1" ]]; then
        COMMIT_TAGS+=(pr-${github_number:-}-{{ tag }}-${version})
        COMMIT_TAGS+=(${SHA_SHORT}-{{ tag }}-${version})
    fi

    # Convenience Tags
    BUILD_TAGS+=("{{ tag }}")

    # Weekly Stable / Rebuild Stable on workflow_dispatch
    github_event="{{ github_event }}"
    BUILD_TAGS+=("${CENTOS_VERSION}" "${version}")

    if [[ "${github_event}" == "pull_request" ]]; then
        alias_tags=("${COMMIT_TAGS[@]}")
    else
        alias_tags=("${BUILD_TAGS[@]}")
    fi

    echo "${alias_tags[*]}"

[group('Utility')]
tag-images image_name="" default_tag="" tags="":
    #!/usr/bin/bash
    set -eou pipefail

    # Get Image, and untag
    IMAGE=$(podman inspect localhost/{{ image_name }}:{{ default_tag }} | jq -r .[].Id)
    podman untag localhost/{{ image_name }}:{{ default_tag }}

    # Tag Image
    for tag in {{ tags }}; do
        podman tag $IMAGE {{ image_name }}:${tag}
    done

    # Show Images
    podman images
