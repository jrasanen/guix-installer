#!/bin/sh

die() {
    printf '%s\n' "$@" >&2
    exit 1
}

guix time-machine -C './guix/base-channels.scm' -- \
     describe -f channels > './guix/channels.scm'

printf 'Attempting to build the image...\n\n'
image=$(guix time-machine -C './guix/channels.scm' --substitute-urls='https://ci.guix.gnu.org https://bordeaux.guix.gnu.org https://nonguix-proxy.ditigal.xyz' -- system image -t iso9660 './guix/installer.scm') \
    || die 'Could not create image.'

release_tag=$(date +"%Y%m%d%H%M")
cp "${image}" "./guix-installer-${release_tag}.iso" ||
    die 'An error occurred while copying.'

printf 'Image was succesfully built: %s\n' "${image}"
