function flash_full_rom()
{
    echo_green "\nInstall/Update UEFI Full ROM Firmware"
    echo_yellow "IMPORTANT: flashing the firmware has the potential to brick your device,
requiring relatively inexpensive hardware and some technical knowledge to
recover.Not all boards can be tested prior to release, and even then slight
differences in hardware can lead to unforseen failures.
If you don't have the ability to recover from a bad flash, you're taking a risk.

You have been warned."

    [[ "$isChromeOS" = true ]] && echo_yellow "Also, flashing Full ROM firmware will remove your ability to run ChromeOS."

    read -rep "Do you wish to continue? [y/N] "
    [[ "$REPLY" = "y" || "$REPLY" = "Y" ]] || return

    #spacing
    echo -e ""

    # ensure hardware write protect disabled
    [[ "$wpEnabled" = true ]] && { exit_red "\nHardware write-protect enabled, cannot flash Full ROM firmware."; return 1; }

    #special warning for CR50 devices
    if [[ "$isStock" = true && "$hasCR50" = true ]]; then
    echo_yellow "NOTICE: flashing your Chromebook is serious business.
To ensure recovery in case something goes wrong when flashing,
be sure to set the ccd capability 'FlashAP Always' using your
USB-C debug cable, otherwise recovery will involve disassembling
your device (which is very difficult in some cases)."

    echo_yellow "If you wish to continue, type: 'I ACCEPT' and press enter."
    read -re
    [[ "$REPLY" = "I ACCEPT" ]] || return
    fi

    #UEFI notice if flashing from ChromeOS or Legacy
    if [[ ! -d /sys/firmware/efi ]]; then
        [[ "$isChromeOS" = true ]] && currOS="ChromeOS" || currOS="Your Legacy-installed OS"
        echo_yellow "
NOTE: After flashing UEFI firmware, you will need to install a UEFI-compatible
OS; ${currOS} will no longer be bootable. See https://mrchromebox.tech/#faq"
        REPLY=""
        read -rep "Press Y to continue or any other key to abort. "
        [[ "$REPLY" = "y" || "$REPLY" = "Y" ]] || return
    fi

    # PCO boot device notice
    if [[ "$isPCO" = true && ! -d /sys/firmware/efi ]]; then
        echo_yellow "
NOTE: Booting from eMMC on AMD Picasso-based devices does not currently work --
only NVMe, SD and USB. If you have a device with eMMC storage you will not be
able to boot from it after installing the UEFI Full ROM firmware."
        REPLY=""
        read -rep "Press Y to continue or any other key to abort. "
        [[ "$REPLY" = "y" || "$REPLY" = "Y" ]] || return
    fi

    #determine correct file / URL
    firmware_source=${fullrom_source}
    eval coreboot_file="$`echo "coreboot_uefi_${device}"`"

    #rammus special case (upgrade from older UEFI firmware)
    if [ "$device" = "rammus" ]; then
        echo -e ""
        echo_yellow "Unable to determine Chromebook model"
        echo -e "Because of your current firmware, I'm unable to
determine the exact mode of your Chromebook.  Are you using
an Asus C425 (LEONA) or Asus C433/C434 (SHYVANA)?
"
        REPLY=""
        while [[ "$REPLY" != "L" && "$REPLY" != "l" && "$REPLY" != "S" && "$REPLY" != "s"  ]]
        do
            read -rep "Enter 'L' for LEONA, 'S' for SHYVANA: "
            if [[ "$REPLY" = "S" || "$REPLY" = "s" ]]; then
                coreboot_file=${coreboot_uefi_shyvana}
            else
                coreboot_file=${coreboot_uefi_leona}
            fi
        done
    fi

    #coral special case (variant not correctly identified)
    if [ "$device" = "coral" ]; then
        echo -e ""
        echo_yellow "Unable to determine correct Chromebook model"
        echo -e "Because of your current firmware, I'm unable to determine the exact mode of your Chromebook.
Please select the number for the correct option from the list below:"

        coral_boards=(
            "ASTRONAUT (Acer Chromebook 11 [C732])"
            "BABYMEGA (Asus Chromebook C223NA)"
            "BABYTIGER (Asus Chromebook C523NA)"
            "BLACKTIP (CTL Chromebook NL7/NL7T)"
            "BLUE (Acer Chromebook 15 [CB315])"
            "BRUCE (Acer Chromebook Spin 15 [CP315])"
            "EPAULETTE (Acer Chromebook 514)"
            "LAVA (Acer Chromebook Spin 11 [CP311])"
            "NASHER (Dell Chromebook 11 5190)"
            "NASHER360 (Dell Chromebook 11 5190 2-in-1)"
            "RABBID (Asus Chromebook C423)"
            "ROBO (Lenovo 100e Chromebook)"
            "ROBO360 (Lenovo 500e Chromebook)"
            "SANTA (Acer Chromebook 11 [CB311-8H])"
            "WHITETIP (CTL Chromebook J41/J41T)"
            )

        select board in "${coral_boards[@]}"; do
            board=$(echo ${board,,} | cut -f1 -d ' ')
            eval coreboot_file=$`echo "coreboot_uefi_${board}"`
            break;
        done
    fi

    # ensure we have a file to flash
    if [[ "$coreboot_file" = "" ]]; then
        exit_red "The script does not currently have a firmware file for your device (${device^^}); cannot continue."; return 1
    fi

    #extract device serial if present in cbfs
    ${cbfstoolcmd} /tmp/bios.bin extract -n serial_number -f /tmp/serial.txt >/dev/null 2>&1

    #extract device HWID
    if [[ "$isStock" = "true" ]]; then
        ${gbbutilitycmd} /tmp/bios.bin --get --hwid | sed 's/[^ ]* //' > /tmp/hwid.txt 2>/dev/null
    else
        ${cbfstoolcmd} /tmp/bios.bin extract -n hwid -f /tmp/hwid.txt >/dev/null 2>&1
    fi

    # create backup if existing firmware is stock
    if [[ "$isStock" = "true" ]]; then
        if [[ "$isEOL" = "false" ]]; then
            REPLY=y
        else
            echo_yellow "\nCreate a backup copy of your stock firmware?"
            read -erp "This is highly recommended in case you wish to return your device to stock
configuration/run ChromeOS, or in the (unlikely) event that things go south
and you need to recover using an external EEPROM programmer. [Y/n] "
        fi
        [[ "$REPLY" = "n" || "$REPLY" = "N" ]] && true || backup_firmware
        #check that backup succeeded
        [ $? -ne 0 ] && return 1
    fi

    #download firmware file
    cd /tmp || { exit_red "Error changing to tmp dir; cannot proceed"; return 1; }
    echo_yellow "\nDownloading Full ROM firmware\n(${coreboot_file})"
    if ! $CURL -sLO "${firmware_source}${coreboot_file}"; then
        exit_red "Firmware download failed; cannot flash. curl error code $?"; return 1
    fi
    if ! $CURL -sLO "${firmware_source}${coreboot_file}.sha1"; then
        exit_red "Firmware checksum download failed; cannot flash."; return 1
    fi

    #verify checksum on downloaded file
    if ! sha1sum -c "${coreboot_file}.sha1" > /dev/null 2>&1; then
        exit_red "Firmware image checksum verification failed; download corrupted, cannot flash."; return 1
    fi

    #persist serial number?
    if [ -f /tmp/serial.txt ]; then
        echo_yellow "Persisting device serial number"
        ${cbfstoolcmd} "${coreboot_file}" add -n serial_number -f /tmp/serial.txt -t raw > /dev/null 2>&1
    fi

    #persist device HWID?
    if [ -f /tmp/hwid.txt ]; then
        echo_yellow "Persisting device HWID"
        ${cbfstoolcmd} "${coreboot_file}" add -n hwid -f /tmp/hwid.txt -t raw > /dev/null 2>&1
    fi

    #Persist RW_MRC_CACHE UEFI Full ROM firmware
    ${cbfstoolcmd} /tmp/bios.bin read -r RW_MRC_CACHE -f /tmp/mrc.cache > /dev/null 2>&1
    if [[ $isFullRom = "true" && $? -eq 0 ]]; then
        ${cbfstoolcmd} "${coreboot_file}" write -r RW_MRC_CACHE -f /tmp/mrc.cache > /dev/null 2>&1
    fi

    #Persist SMMSTORE if exists
    if ${cbfstoolcmd} /tmp/bios.bin read -r SMMSTORE -f /tmp/smmstore > /dev/null 2>&1; then
        ${cbfstoolcmd} "${coreboot_file}" write -r SMMSTORE -f /tmp/smmstore > /dev/null 2>&1
    fi

    # persist VPD if possible
    if extract_vpd /tmp/bios.bin; then
        # try writing to RO_VPD FMAP region
        if ! ${cbfstoolcmd} "${coreboot_file}" write -r RO_VPD -f /tmp/vpd.bin > /dev/null 2>&1; then
            # fall back to vpd.bin in CBFS
            ${cbfstoolcmd} "${coreboot_file}" add -n vpd.bin -f /tmp/vpd.bin -t raw > /dev/null 2>&1
        fi
    fi

    #disable software write-protect
    echo_yellow "Disabling software write-protect and clearing the WP range"
    if ! ${flashromcmd} --wp-disable > /dev/null 2>&1 && [[ "$swWp" = "enabled" ]]; then
        exit_red "Error disabling software write-protect; unable to flash firmware."; return 1
    fi

    #clear SW WP range
    if ! ${flashromcmd} --wp-range 0 0 > /dev/null 2>&1; then
        # use new command format as of commit 99b9550
        if ! ${flashromcmd} --wp-range 0,0 > /dev/null 2>&1 && [[ "$swWp" = "enabled" ]]; then
            exit_red "Error clearing software write-protect range; unable to flash firmware."; return 1
        fi
    fi

    #flash Full ROM firmware

    # clear log file
    rm -f /tmp/flashrom.log

    echo_yellow "Installing Full ROM firmware (may take up to 90s)"
    #check if flashrom supports logging to file
    if ${flashromcmd} -V -o /dev/null > /dev/null 2>&1; then
        output_params=">/dev/null 2>&1 -o /tmp/flashrom.log"
        ${flashromcmd} ${flashrom_params} ${noverify} -w ${coreboot_file} >/dev/null 2>&1 -o /tmp/flashrom.log
    else
        output_params=">/tmp/flashrom.log 2>&1"
        ${flashromcmd} ${flashrom_params} ${noverify} -w ${coreboot_file} >/tmp/flashrom.log 2>&1
    fi
    if [ $? -ne 0 ]; then
        echo_red "Error running cmd: ${flashromcmd} ${flashrom_params} ${noverify} -w ${coreboot_file} ${output_params}"
        if [ -f /tmp/flashrom.log ]; then
            read -rp "Press enter to view the flashrom log file, then space for next page, q to quit"
            more /tmp/flashrom.log
        fi
        exit_red "An error occurred flashing the Full ROM firmware. DO NOT REBOOT!"; return 1
    else
        echo_green "Full ROM firmware successfully installed/updated."

        #Prevent from trying to boot stock ChromeOS install
        if [[ "$isStock" = true && "$isChromeOS" = true && "$boot_mounted" = true ]]; then
            rm -rf /tmp/boot/efi > /dev/null 2>&1
            rm -rf /tmp/boot/syslinux > /dev/null 2>&1
        fi

        #Warn about long RAM training time
        echo_yellow "IMPORTANT:\nThe first boot after flashing may take substantially
longer than subsequent boots -- up to 30s or more.
Be patient and eventually your device will boot :)"

        # Add note on touchpad firmware for EVE
        if [[ "${device^^}" = "EVE" && "$isStock" = true ]]; then
            echo_yellow "IMPORTANT:\n
If you're going to run Windows on your Pixelbook, you must downgrade
the touchpad firmware now (before rebooting) otherwise it will not work.
Select the D option from the main main in order to do so."
        fi
        #set vars to indicate new firmware type
        isStock=false
        isFullRom=true
        # Add NVRAM reset note for 4.12 release
        if [[ "$isUEFI" = true && "$useUEFI" = true ]]; then
            echo_yellow "IMPORTANT:\n
This update uses a new format to store UEFI NVRAM data, and
will reset your BootOrder and boot entries. You may need to
manually Boot From File and reinstall your bootloader if
booting from the internal storage device fails."
        fi
        firmwareType="Full ROM / UEFI (pending reboot)"
        isUEFI=true
    fi

    read -rep "Press [Enter] to return to the main menu."
}
