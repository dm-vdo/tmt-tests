#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of VDO Smoke Test
#   Description: Test basic VDO read/write and start/stop operations
#                using a dm-vdo device and the VDO user tools package.
#   Author: Susan LeGendre-McGhee <slegendr@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2024 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

arch=$(uname -m)

# Check whether we received a URL (via environment variables), and if not, let
# the system just use the enabled repositories to install the user tool package.
vdo_pkg=vdo
if [ ! -z ${vdo_url} ]; then
        vdo_pkg=${vdo_url}
fi

rlJournalStart

rlPhaseStartSetup "Create backing device"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        rlRun "df ."

        # If we end up with less than 10G of available space, then we can't
        # create a VDO volume sufficient for testing.  We should bail out as a
        # result.
        loopbackSize=$(($(df --sync --output=avail / | tail -1) * 1024 - 1024*1024*1024))
        if [ ${loopbackSize} -lt $((1024*1024*1024*10)) ]; then
          rlDie "Not enough space to create loopback device."
        fi
        rlRun "truncate -s ${loopbackSize} $TmpDir/loop0.bin" 0 "Laying out loopfile backing"
        rlRun "losetup /dev/loop0 $TmpDir/loop0.bin" 0 "Creating loopdevice"
        rlRun "mkdir -p /mnt/testmount" 0 "Creating test mountpoint dir"
rlPhaseEnd

rlPhaseStartSetup "Install VDO user tool software"
        if ! rlCheckRpm vdo
        then
               rlRun "yum install -y ${vdo_pkg}" 0 "Installing vdo" || rlDie "Unable to install 'vdo' package"
               rlAssertRpm vdo
        fi
rlPhaseEnd

rlPhaseStartTest "Gather Relevant Info"
        # Gather some system information for debug purposes
        rlRun "uname -a"
        rlRun "find /lib/modules -name dm-vdo.ko.xz"
        rlRun "modinfo dm-vdo"
        
        # Work around lvcreate modprobe issue with the incorrect module name by
        # loading the module directly
        rlRun "modprobe dm-vdo"
rlPhaseEnd

rlPhaseStartTest "Generate Test Data"
        # Write some data, check statistics
        rlRun "dd if=/dev/urandom of=${TmpDir}/urandom_fill_file bs=1M count=100"
        rlRun "ls -lh ${TmpDir}/urandom_fill_file"
rlPhaseEnd

for partition_type in "raw" "lvm"
do
        case $partition_type in
                "raw"*)
                        backing_device=/dev/loop0
                        ;;
                "lvm"*)
                        rlPhaseStartTest "Create LVM backing device"
                                rlRun "pvcreate /dev/loop0" 0 "Creating PV"
                                rlRun "vgcreate vdo_base /dev/loop0" 0 "Creating VG"
                                rlRun "lvcreate -n vdo_base -l100%FREE vdo_base" 0 "Creating LV"
                        rlPhaseEnd
                        backing_device=/dev/vdo_base/vdo_base
                        ;;
                *)
                        ;;
        esac

        rlPhaseStartTest "LVM-VDO Smoke Test"
                # Create the VDO volume and get the initial statistics
                rlRun "pvcreate --config devices/scan_lvs=1 ${backing_device}"
                rlRun "vgcreate --config devices/scan_lvs=1 vdo_data ${backing_device}"
                rlRun "lvcreate --config devices/scan_lvs=1 --type vdo -L 9G -V 100G -n vdo0 vdo_data/vdopool"

                # Create a filesystem and mount the device, check statistics
                rlRun "mkfs.xfs -K /dev/vdo_data/vdo0" 0 "Making xfs filesystem on VDO volume"
                rlRun "mount -o discard /dev/vdo_data/vdo0 /mnt/testmount" 0 "Mounting xfs filesystem on VDO volume"
                rlRun "df --sync /mnt/testmount"
                rlRun "vdostats vdo_data-vdopool-vpool"

                # Copy the test data onto VDO volume 4 times to get some deduplication
                for i in {1..4}
                do
                  rlRun "cp ${TmpDir}/urandom_fill_file /mnt/testmount/test_file-${i}"
                done
                rlRun "df --sync /mnt/testmount"
                rlRun "vdostats vdo_data-vdopool-vpool"

                # Verify the data
                for i in {1..4}
                do
                        rlRun "cmp ${TmpDir}/urandom_fill_file /mnt/testmount/test_file-${i}"
                done

                # Unmount and stop the volume, check statistics
                rlRun "umount /mnt/testmount" 0 "Unmounting testmount"
                rlRun "vdostats vdo_data-vdopool-vpool"
                rlRun "lvchange --config devices/scan_lvs=1 -an vdo_data/vdo0"

                # Start the VDO volume, mount it, check statistics, verify data.
                rlRun "lvchange --config devices/scan_lvs=1 -ay vdo_data/vdo0"
                rlRun "mount -o discard /dev/vdo_data/vdo0 /mnt/testmount" 0 "Mounting xfs filesystem on VDO volume"

                rlRun "df --sync /mnt/testmount"
                rlRun "vdostats vdo_data-vdopool-vpool"

                # Verify the data
                for i in {1..4}
                do
                        rlRun "cmp ${TmpDir}/urandom_fill_file /mnt/testmount/test_file-${i}"
                done
        rlPhaseEnd

        rlPhaseStartCleanup
                rlRun "umount /mnt/testmount" 0 "Unmounting testmount"
                rlRun "lvremove --config devices/scan_lvs=1 -ff vdo_data/vdo0" 0 "Removing VDO volume vdo0"
                case $partition_type in
                        "lvm"*)
                                rlPhaseStartCleanup
                                        rlRun "lvremove -ff ${backing_device}" 0 "Removing LV"
                                        rlRun "vgremove vdo_base" 0 "Removing VG"
                                        rlRun "pvremove /dev/loop0" 0 "Removing PV"
                                rlPhaseEnd
                                ;;
                        *)
                                ;;
                esac

                rlRun "dd if=/dev/zero of=/dev/loop0 bs=1M count=10 oflag=direct" 0 "Wiping Block Device"

        rlPhaseEnd
done

rlPhaseStartCleanup
        rlRun "losetup -d /dev/loop0" 0 "Deleting loopdevice"
        rlRun "rm -f $TmpDir/loop0.bin" 0 "Removing loopfile backing"
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
rlPhaseEnd

rlJournalPrintText
rlJournalEnd
