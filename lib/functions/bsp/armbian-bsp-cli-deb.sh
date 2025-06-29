#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

function compile_armbian-bsp-cli-transitional() {
	: "${artifact_version:?artifact_version is not set}"
	: "${artifact_name:?artifact_name is not set}"
	: "${BOARD:?BOARD is not set}"
	: "${BRANCH:?BRANCH is not set}"

	display_alert "Creating bsp-cli transitional package on board '${BOARD}' branch '${BRANCH}'" "armbian-bsp-cli-${BOARD} :: ${artifact_version}" "info"

	# "destination" is used a lot in hooks already. keep this name, even if only for compatibility.
	declare cleanup_id="" destination=""
	prepare_temp_dir_in_workdir_and_schedule_cleanup "deb-bsp-cli" cleanup_id destination # namerefs

	mkdir -p "${destination}"/DEBIAN
	cd "${destination}" || exit_with_error "Failed to cd to ${destination}"

	# Add transitional package
	cat <<- EOF > "${destination}"/DEBIAN/control
		Package: armbian-bsp-cli-${BOARD}${EXTRA_BSP_NAME}
		Version: ${artifact_version}
		Architecture: $ARCH
		Maintainer: $MAINTAINER <$MAINTAINERMAIL>
		Section: oldlibs
		Priority: optional
		Description: Armbian CLI BSP for board '${BOARD}' - transitional package
	EOF

	# Build / close the package. This will run shellcheck / show the generated files if debugging
	dpkg_deb_build "${destination}" "armbian-bsp-cli-transitional"

	done_with_temp_dir "${cleanup_id}" # changes cwd to "${SRC}" and fires the cleanup function early

	display_alert "Done building BSP CLI transitional package" "${destination}" "debug"
}

function reversion_armbian-bsp-cli-transitional_deb_contents() {
	if [[ "${1}" != "armbian-bsp-cli-transitional" ]]; then
		return 0 # Not our deb, nothing to do.
	fi
	display_alert "Reversion" "reversion_armbian-bsp-cli-transitional_deb_contents: '$*'" "debug"

	# Depends on the new package
	cat <<- EOF >> "${control_file_new}"
		Depends: ${artifact_name} (= ${REVISION})
	EOF

}

function compile_armbian-bsp-cli() {
	: "${artifact_version:?artifact_version is not set}"
	: "${artifact_name:?artifact_name is not set}"
	: "${BOARD:?BOARD is not set}"
	: "${BRANCH:?BRANCH is not set}"

	display_alert "Creating bsp-cli on board '${BOARD}' branch '${BRANCH}'" "${artifact_name} :: ${artifact_version}" "info"

	# "destination" is used a lot in hooks already. keep this name, even if only for compatibility.
	declare cleanup_id="" destination=""
	prepare_temp_dir_in_workdir_and_schedule_cleanup "deb-bsp-cli" cleanup_id destination # namerefs

	mkdir -p "${destination}"/DEBIAN
	cd "${destination}" || exit_with_error "Failed to cd to ${destination}"

	# array of code to be included in preinst, postinst, prerm and postrm scripts (more than default code)
	declare -a preinst_functions=()
	declare -a postinst_functions=()
	declare -a postrm_functions=()

	declare -a extra_description=()
	[[ "${EXTRA_BSP_NAME}" != "" ]] && extra_description+=("(variant '${EXTRA_BSP_NAME}')")

	cat <<- EOF > "${destination}"/DEBIAN/control
		Package: ${artifact_name}
		Version: ${artifact_version}
		Architecture: $ARCH
		Maintainer: $MAINTAINER <$MAINTAINERMAIL>
		Section: kernel
		Priority: optional
		Recommends: bsdutils, parted, util-linux, toilet
		Description: Armbian CLI BSP for board '${BOARD}' branch '${BRANCH}' ${extra_description[@]}
	EOF

	# armhwinfo, firstrun, armbianmonitor, etc. config file; also sourced in postinst
	mkdir -p "${destination}"/etc
	cat <<- EOF > "${destination}"/etc/armbian-release
		# PLEASE DO NOT EDIT THIS FILE
		BOARD=$BOARD
		BOARD_NAME="$BOARD_NAME"
		BOARDFAMILY=${BOARDFAMILY}
		BUILD_REPOSITORY_URL=${BUILD_REPOSITORY_URL}
		BUILD_REPOSITORY_COMMIT=${BUILD_REPOSITORY_COMMIT}
		LINUXFAMILY=$LINUXFAMILY
		ARCH=$ARCHITECTURE
		BOOT_SOC=$BOOT_SOC
		IMAGE_TYPE=$IMAGE_TYPE
		BOARD_TYPE=$BOARD_TYPE
		INITRD_ARCH=$INITRD_ARCH
		KERNEL_IMAGE_TYPE=$KERNEL_IMAGE_TYPE
		KERNEL_TARGET=$KERNEL_TARGET
		KERNEL_TEST_TARGET=$KERNEL_TEST_TARGET
		FORCE_BOOTSCRIPT_UPDATE=$FORCE_BOOTSCRIPT_UPDATE
		FORCE_UBOOT_UPDATE=$FORCE_UBOOT_UPDATE
		OVERLAYDIR="$OVERLAYDIR"
		VENDOR="$VENDOR"
		VENDORDOCS="$VENDORDOCS"
		VENDORURL="$VENDORURL"
		VENDORSUPPORT="$VENDORSUPPORT"
		VENDORBUGS="$VENDORBUGS"
	EOF

	# copy general overlay from packages/bsp-cli
	# in practice: packages/bsp-cli and variations of config/optional/...
	copy_all_packages_files_for "bsp-cli"

	# copy common files from a premade directory structure
	# @TODO this includes systemd config, assumes things about serial console, etc, that need dynamism or just to not exist with modern systemd
	display_alert "Copying common bsp files" "packages/bsp/common" "info"
	run_host_command_logged rsync -av "${SRC}"/packages/bsp/common/* "${destination}"
	wait_for_disk_sync "after rsync'ing package/bsp/common for bsp-cli"

	mkdir -p "${destination}"/usr/share/armbian/

	# get bootscript information.
	declare -A bootscript_info=()
	get_bootscript_info

	if [[ "${bootscript_info[has_bootscript]}" == "yes" ]]; then
		# Append some of it to armbian-release
		cat <<- EOF >> "${destination}"/etc/armbian-release
			BOOTSCRIPT_FORCE_UPDATE="${bootscript_info[bootscript_force_update]}"
			BOOTSCRIPT_DST="${bootscript_info[bootscript_dst]}"
		EOF

		# Using bootscript, copy it to /usr/share/armbian
		run_host_command_logged cp -pv "${bootscript_info[bootscript_file_fullpath]}" "${destination}/usr/share/armbian/${bootscript_info[bootscript_dst]}"

		if [[ "${bootscript_info[has_bootenv]}" == "yes" ]]; then
			run_host_command_logged cp -pv "${bootscript_info[bootenv_file_fullpath]}" "${destination}"/usr/share/armbian/armbianEnv.txt
		fi

		# add to postinst, to update bootscript if forced or missing
		postinst_functions+=(board_side_bsp_cli_postinst_update_uboot_bootscript)
	fi

	# PRETTY_NAME stuff is now done in armbian-base-files artifact

	# add configuration for setting uboot environment from userspace with: fw_setenv fw_printenv
	if [[ -n $UBOOT_FW_ENV ]]; then
		UBOOT_FW_ENV=($(tr ',' ' ' <<< "$UBOOT_FW_ENV"))
		echo "# Device to access      offset           env size" > "${destination}"/etc/fw_env.config
		echo "/dev/mmcblk0	${UBOOT_FW_ENV[0]}	${UBOOT_FW_ENV[1]}" >> "${destination}"/etc/fw_env.config
	fi

	# won't recreate files if they were removed by user
	# TODO: Add proper handling for updated conffiles
	# We are runing this script each time apt runs. If this package is removed, file is removed and error is triggered.
	# Keeping armbian-apt-updates as a configuration, solve the problem
	cat <<- EOF > "${destination}"/DEBIAN/conffiles
		/usr/lib/armbian/armbian-apt-updates
		/etc/X11/xorg.conf.d/01-armbian-defaults.conf
	EOF

	# trigger uInitrd creation after installation, to apply
	# /etc/initramfs/post-update.d/99-uboot
	cat <<- EOF > "${destination}"/DEBIAN/triggers
		activate update-initramfs
	EOF

	# copy distribution support and upgrade status
	# this information is used in motd to show status and within armbian-config to perform upgrades
	local releases=($(find ${SRC}/config/distributions -iname '*order*' -exec echo {} \; -exec cat {} \; | xargs -n2 -d'\n' | sort -nk2 | sed "s/\/order.*//g"))
	for i in "${releases[@]}"; do
		echo "$(echo $i | sed 's/.*\///')=$(cat $i/support)$(echo ";upgrade" | sed 's/.*\///')=$(cat $i/upgrade)" >> "${destination}"/etc/armbian-distribution-status
	done

	# execute $LINUXFAMILY-specific tweaks
	if [[ $(type -t family_tweaks_bsp) == function ]]; then
		display_alert "Running family_tweaks_bsp" "${LINUXFAMILY} - ${BOARDFAMILY}" "debug"
		family_tweaks_bsp
		display_alert "Done with family_tweaks_bsp" "${LINUXFAMILY} - ${BOARDFAMILY}" "debug"
	fi

	call_extension_method "post_family_tweaks_bsp" <<- 'POST_FAMILY_TWEAKS_BSP'
		*family_tweaks_bsp overrrides what is in the config, so give it a chance to override the family tweaks*
		This should be implemented by the config to tweak the BSP, after the board or family has had the chance to.
		You can write to `$destination` here and it will be packaged.
		You can also append to the `preinst_functions`, `postinst_functions` and `postrm` array, and the _content_
		of those functions will be added to the preinst, postinst and postrm scripts respectively.
	POST_FAMILY_TWEAKS_BSP

	# Render the postinst/postrm/etc
	# set up pre install script; use inline functions
	# This is never run in build context; instead, it's source code is dumped inside a file that is packaged.
	# It is done this way so we get shellcheck and formatting instead of a huge heredoc.
	### preinst
	artifact_package_hook_helper_board_side_functions "preinst" board_side_bsp_cli_preinst "${preinst_functions[@]}"
	unset board_side_bsp_cli_preinst

	### postrm
	artifact_package_hook_helper_board_side_functions "postrm" board_side_bsp_cli_postrm "${postrm_functions[@]}"
	unset board_side_bsp_cli_postrm

	### postinst -- a bit more complex, extendable via postinst_functions which can be customized in hook above
	artifact_package_hook_helper_board_side_functions "postinst" board_side_bsp_cli_postinst_base "${postinst_functions[@]}" board_side_bsp_cli_postinst_finish
	unset board_side_bsp_cli_postinst_base board_side_bsp_cli_postinst_update_uboot_bootscript board_side_bsp_cli_postinst_finish

	### preventing upgrading stable kernels beyond version if defined
	# if freeze variable is removed, upgrade becomes possible again
	if [[ "${BETA}" != "yes" ]]; then
		for pin_variants in $(echo $KERNEL_UPGRADE_FREEZE | sed "s/,/ /g"); do
		extracted_pins=(${pin_variants//@/ })
			if [[ "${BRANCH}-${LINUXFAMILY}" == "${extracted_pins[0]}" ]]; then
				cat <<- EOF >> "${destination}"/etc/apt/preferences.d/frozen-armbian
				Package: linux-*-${extracted_pins[0]}
				Pin: version ${extracted_pins[1]}
				Pin-Priority: 999
				EOF
			fi
		done
	else
		touch "${destination}"/etc/apt/preferences.d/frozen-armbian
	fi

	# add some summary to the image # @TODO: another?
	fingerprint_image "${destination}/etc/armbian.txt"

	# fixing permissions (basic), reference: dh_fixperms
	find "${destination}" -print0 2> /dev/null | xargs -0r chown --no-dereference 0:0
	find "${destination}" ! -type l -print0 2> /dev/null | xargs -0r chmod 'go=rX,u+rw,a-s'

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		run_tool_batcat --file-name "/etc/armbian-release.sh" "${destination}"/etc/armbian-release
	fi

	# Build / close the package. This will run shellcheck / show the generated files if debugging
	dpkg_deb_build "${destination}" "armbian-bsp-cli"

	done_with_temp_dir "${cleanup_id}" # changes cwd to "${SRC}" and fires the cleanup function early

	display_alert "Done building BSP CLI package" "${destination}" "debug"
}

# Reversion function is called with the following parameters:
# ${1} == deb_id
function reversion_armbian-bsp-cli_deb_contents() {
	if [[ "${1}" != "armbian-bsp-cli" ]]; then
		return 0 # Not our deb, nothing to do.
	fi
	display_alert "Reversion" "reversion_armbian-bsp-cli_deb_contents: '$*'" "debug"

	# Replaces: base-files is needed to replace the distro's base-files
	# Depends: linux-base is needed for "linux-version" command in initrd cleanup script
	# Depends: fping is needed for armbianmonitor to upload armbian-hardware-monitor.log
	# Depends: base-files (>= ${REVISION}) is to force usage of our base-files package (not the original Distro's).
	declare depends_base_files=", base-files (>= ${REVISION})"
	if [[ "${KEEP_ORIGINAL_OS_RELEASE:-"no"}" == "yes" ]]; then
		depends_base_files=""
	fi
	cat <<- EOF >> "${control_file_new}"
		Depends: bash, linux-base, u-boot-tools, initramfs-tools, lsb-release, fping, device-tree-compiler${depends_base_files}
		Replaces: zram-config, armbian-bsp-cli-${BOARD}${EXTRA_BSP_NAME} (<< ${REVISION})
		Breaks: armbian-bsp-cli-${BOARD}${EXTRA_BSP_NAME} (<< ${REVISION})
	EOF

	artifact_deb_reversion_unpack_data_deb
	: "${data_dir:?data_dir is not set}"

	cat <<- EOF >> "${data_dir}"/etc/armbian-release
		VERSION=${REVISION}
		REVISION=$REVISION
	EOF

	# Show results if debugging
	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		run_tool_batcat --file-name "armbian-release.sh" "${data_dir}"/etc/armbian-release
	fi

	artifact_deb_reversion_repack_data_deb

	return 0
}

function get_bootscript_info() {
	bootscript_info[has_bootscript]="no"
	bootscript_info[has_extlinux]="no"
	if [[ -n "${BOOTSCRIPT}" ]] && [[ $SRC_EXTLINUX != yes ]]; then
		bootscript_info[has_bootscript]="yes"

		declare bootscript_source="${BOOTSCRIPT%%:*}"
		declare bootscript_destination="${BOOTSCRIPT##*:}"

		# outer scope
		bootscript_info[bootscript_force_update]="${FORCE_BOOTSCRIPT_UPDATE:-"no"}"
		bootscript_info[bootscript_src]="${bootscript_source}"
		bootscript_info[bootscript_dst]="${bootscript_destination}"
		bootscript_info[bootscript_file_contents]=""

		bootscript_info[bootscript_file_fullpath]="${SRC}/config/bootscripts/${bootscript_source}"
		if [ -f "${USERPATCHES_PATH}/bootscripts/${bootscript_source}" ]; then
			bootscript_info[bootscript_file_fullpath]="${USERPATCHES_PATH}/bootscripts/${bootscript_source}"
		fi
		bootscript_info[bootscript_file_contents]="$(cat "${bootscript_info[bootscript_file_fullpath]}")"

		bootscript_info[bootenv_file_fullpath]=""
		bootscript_info[has_bootenv]="no"
		bootscript_info[bootenv_file_contents]=""
		if [[ -n $BOOTENV_FILE && -f $SRC/config/bootenv/$BOOTENV_FILE ]]; then
			bootscript_info[has_bootenv]="yes"
			bootscript_info[bootenv_file_fullpath]="${SRC}/config/bootenv/${BOOTENV_FILE}"
			bootscript_info[bootenv_file_contents]="$(cat "${SRC}/config/bootenv/${BOOTENV_FILE}")"
		fi
	elif [[ $SRC_EXTLINUX == yes ]]; then
		bootscript_info[has_extlinux]="yes"
		display_alert "Using extlinux, regular bootscripts ignored" "SRC_EXTLINUX=${SRC_EXTLINUX}" "info"
	fi

	debug_dict bootscript_info
}

function board_side_bsp_cli_postinst_update_uboot_bootscript() {
	if [[ ${BOOTSCRIPT_FORCE_UPDATE} == yes || ! -f /boot/${BOOTSCRIPT_DST} ]]; then

		[ -z ${BOOTSCRIPT_BACKUP_VERSION} ] && BOOTSCRIPT_BACKUP_VERSION="$(date +%s)"
		if [ -f /boot/${BOOTSCRIPT_DST} ]; then
			cp -v /boot/${BOOTSCRIPT_DST} /usr/share/armbian/${BOOTSCRIPT_DST}-${BOOTSCRIPT_BACKUP_VERSION}
			echo "NOTE: You can find previous bootscript versions in /usr/share/armbian !"
		fi

		echo "Recreating boot script"
		cp -v /usr/share/armbian/${BOOTSCRIPT_DST} /boot
		rootdev=$(sed -e 's/^.*root=//' -e 's/ .*\$//' < /proc/cmdline)
		rootfstype=$(sed -e 's/^.*rootfstype=//' -e 's/ .*$//' < /proc/cmdline)

		# recreate armbianEnv.txt if it and extlinux does not exists
		if [ ! -f /boot/armbianEnv.txt ] && [ ! -f /boot/extlinux/extlinux.conf ]; then
			cp -v /usr/share/armbian/armbianEnv.txt /boot
			echo "rootdev="\$rootdev >> /boot/armbianEnv.txt
			echo "rootfstype="\$rootfstype >> /boot/armbianEnv.txt
		fi

		# update boot.ini if it exists? @TODO: why? who uses this?
		[ -f /boot/boot.ini ] && sed -i "s/setenv rootdev.*/setenv rootdev \\"$rootdev\\"/" /boot/boot.ini
		[ -f /boot/boot.ini ] && sed -i "s/setenv rootfstype.*/setenv rootfstype \\"$rootfstype\\"/" /boot/boot.ini

		[ -f /boot/boot.cmd ] && mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr > /dev/null 2>&1
	fi
}

function board_side_bsp_cli_preinst() {
	# tell people to reboot at next login
	[ "$1" = "upgrade" ] && touch /var/run/.reboot_required

	# fixing ramdisk corruption when using lz4 compression method
	sed -i "s/^COMPRESS=.*/COMPRESS=gzip/" /etc/initramfs-tools/initramfs.conf

	# swap
	grep -q vm.swappiness /etc/sysctl.conf
	case $? in
		0)
			sed -i 's/vm\.swappiness.*/vm.swappiness=100/' /etc/sysctl.conf
			;;
		*)
			echo vm.swappiness=100 >> /etc/sysctl.conf
			;;
	esac
	sysctl -p > /dev/null 2>&1
	# replace canonical advertisement
	if [ -d "/var/lib/ubuntu-advantage/messages/" ]; then
		echo -e "\nSupport Armbian! \nLearn more at https://armbian.com/donate" > /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status
		cp /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status /var/lib/ubuntu-advantage/messages/apt-pre-invoke-no-packages-apps.tmpl
		cp /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status /var/lib/ubuntu-advantage/messages/apt-pre-invoke-packages-apps
		cp /var/lib/ubuntu-advantage/messages/apt-pre-invoke-esm-service-status /var/lib/ubuntu-advantage/messages/apt-pre-invoke-packages-apps.tmpl
	fi
	# disable deprecated services
	[ -f "/etc/profile.d/activate_psd_user.sh" ] && rm /etc/profile.d/activate_psd_user.sh
	[ -f "/etc/profile.d/check_first_login.sh" ] && rm /etc/profile.d/check_first_login.sh
	[ -f "/etc/profile.d/check_first_login_reboot.sh" ] && rm /etc/profile.d/check_first_login_reboot.sh
	[ -f "/etc/profile.d/ssh-title.sh" ] && rm /etc/profile.d/ssh-title.sh
	[ -f "/etc/update-motd.d/10-header" ] && rm /etc/update-motd.d/10-header
	[ -f "/etc/update-motd.d/30-sysinfo" ] && rm /etc/update-motd.d/30-sysinfo
	[ -f "/etc/update-motd.d/35-tips" ] && rm /etc/update-motd.d/35-tips
	[ -f "/etc/update-motd.d/40-updates" ] && rm /etc/update-motd.d/40-updates
	[ -f "/etc/update-motd.d/98-autoreboot-warn" ] && rm /etc/update-motd.d/98-autoreboot-warn
	[ -f "/etc/update-motd.d/99-point-to-faq" ] && rm /etc/update-motd.d/99-point-to-faq
	[ -f "/etc/update-motd.d/80-esm" ] && rm /etc/update-motd.d/80-esm
	[ -f "/etc/update-motd.d/80-livepatch" ] && rm /etc/update-motd.d/80-livepatch
	[ -f "/etc/apt/apt.conf.d/02compress-indexes" ] && rm /etc/apt/apt.conf.d/02compress-indexes
	[ -f "/etc/apt/apt.conf.d/02periodic" ] && rm /etc/apt/apt.conf.d/02periodic
	[ -f "/etc/apt/apt.conf.d/no-languages" ] && rm /etc/apt/apt.conf.d/no-languages
	[ -f "/etc/init.d/armhwinfo" ] && rm /etc/init.d/armhwinfo
	[ -f "/etc/logrotate.d/armhwinfo" ] && rm /etc/logrotate.d/armhwinfo
	[ -f "/etc/init.d/firstrun" ] && rm /etc/init.d/firstrun
	[ -f "/etc/init.d/resize2fs" ] && rm /etc/init.d/resize2fs
	[ -f "/lib/systemd/system/firstrun-config.service" ] && rm /lib/systemd/system/firstrun-config.service
	[ -f "/lib/systemd/system/firstrun.service" ] && rm /lib/systemd/system/firstrun.service
	[ -f "/lib/systemd/system/resize2fs.service" ] && rm /lib/systemd/system/resize2fs.service
	[ -f "/usr/lib/armbian/apt-updates" ] && rm /usr/lib/armbian/apt-updates
	[ -f "/usr/lib/armbian/firstrun-config.sh" ] && rm /usr/lib/armbian/firstrun-config.sh
	# fix for https://bugs.launchpad.net/ubuntu/+source/lightdm-gtk-greeter/+bug/1897491
	[ -d "/var/lib/lightdm" ] && (
		chown -R lightdm:lightdm /var/lib/lightdm
		chmod 0750 /var/lib/lightdm
	)
}

function board_side_bsp_cli_postrm() { # not run here
	if [[ remove == "$1" ]] || [[ abort-install == "$1" ]]; then
		systemctl disable armbian-hardware-monitor.service armbian-hardware-optimize.service > /dev/null 2>&1
		systemctl disable armbian-zram-config.service armbian-ramlog.service > /dev/null 2>&1
		systemctl disable armbian-live-patch.service > /dev/null 2>&1
	fi
}

function board_side_bsp_cli_postinst_base() {
	# Source the armbian-release information file
	# shellcheck source=/dev/null
	[ -f /etc/armbian-release ] && . /etc/armbian-release

	# ARMBIAN_PRETTY_NAME is now set in armbian-base-files.

	# Force ramlog to be enabled if it exists. @TODO: why?
	[ -f /etc/lib/systemd/system/armbian-ramlog.service ] && systemctl --no-reload enable armbian-ramlog.service

	# check if it was disabled in config and disable in new service
	if [ -n "$(grep -w '^ENABLED=false' /etc/default/log2ram 2> /dev/null)" ]; then
		sed -i "s/^ENABLED=.*/ENABLED=false/" /etc/default/armbian-ramlog
	fi

	# fix boot delay "waiting for suspend/resume device"
	if [ -f "/etc/initramfs-tools/initramfs.conf" ]; then
		if ! grep --quiet "RESUME=none" /etc/initramfs-tools/initramfs.conf; then
			echo "RESUME=none" >> /etc/initramfs-tools/initramfs.conf
		fi
	fi
}

function board_side_bsp_cli_postinst_finish() {
	ln -sf /var/run/motd /etc/motd
	rm -f /etc/update-motd.d/00-header /etc/update-motd.d/10-help-text

	if [ ! -f "/etc/default/armbian-motd" ]; then
		mv /etc/default/armbian-motd.dpkg-dist /etc/default/armbian-motd
	fi
	if [ ! -f "/etc/default/armbian-ramlog" ] && [ -f /etc/default/armbian-ramlog.dpkg-dist ]; then
		mv /etc/default/armbian-ramlog.dpkg-dist /etc/default/armbian-ramlog
	fi
	if [ ! -f "/etc/default/armbian-zram-config" ] && [ -f /etc/default/armbian-zram-config.dpkg-dist ]; then
		mv /etc/default/armbian-zram-config.dpkg-dist /etc/default/armbian-zram-config
	fi
    if [ ! -f "/etc/default/armbian-firstrun" ]; then
		mv /etc/default/armbian-firstrun.dpkg-dist /etc/default/armbian-firstrun
	fi

	if [ -L "/usr/lib/chromium-browser/master_preferences.dpkg-dist" ]; then
		mv /usr/lib/chromium-browser/master_preferences.dpkg-dist /usr/lib/chromium-browser/master_preferences
	fi

	# Reload services
	systemctl --no-reload enable armbian-hardware-monitor.service armbian-hardware-optimize.service armbian-zram-config.service armbian-led-state.service > /dev/null 2>&1
}

# Helper to add files, from stdin, to the bsp-cli package.
# First and only argument is the destination path, relative to the root of the package -- do NOT include $destination -- it is already included.
# Containing directory, if any, is created automatically.
# The full path (including $destination) is set in $file_added_to_bsp_destination, declare in outer scope to get it.
function add_file_from_stdin_to_bsp_destination() {
	declare dest_file="${1}"
	declare dest_dir
	dest_dir="$(dirname "${dest_file}")"
	declare dest_dir_fullpath="${destination}/${dest_dir}"
	declare dest_file_fullpath="${destination}/${dest_file}"
	display_alert "add_file_from_stdin_to_bsp_destination" "dest_file='${dest_file}' dest_dir='${dest_dir}'" "debug"
	mkdir -p "${dest_dir_fullpath}"
	cat - > "${dest_file_fullpath}"
	file_added_to_bsp_destination="${dest_file_fullpath}" # outer scope
	return 0
}
