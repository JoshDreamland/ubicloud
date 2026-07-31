# frozen_string_literal: true

require_relative "../../common/lib/util"

class WalshadowInstanceStore
  def initialize(mount_path)
    @mount_path = mount_path
  end

  # whole disks that don't back /
  def devices
    script = <<~SCRIPT
      set -ueo pipefail
      src=$(findmnt -no SOURCE /)
      root=$(lsblk -no PKNAME "$src")
      lsblk -d -n -e 7 -o NAME | awk -v root="${root:-${src##*/}}" '$1 != root {print "/dev/"$1}'
    SCRIPT
    r("bash", stdin: script).split
  end

  def state_device(devs)
    (devs.count > 1) ? "/dev/md0" : devs.first
  end

  # Idempotent: mkfs/mdadm --create only run when the target is still blank, so
  # a re-invocation (e.g. after a reboot that preserved the instance store)
  # neither wipes existing data nor fails on an already-assembled array.
  def setup
    devs = devices
    return if devs.empty?

    if devs.count > 1 && !File.blockdev?("/dev/md0")
      r "mdadm", "--create", "--verbose", "/dev/md0", "--level=0", "--raid-devices=#{devs.count}", *devs
      r "bash", "-c", "mdadm --detail --scan >> /etc/mdadm/mdadm.conf"
      r "update-initramfs", "-u"
    end

    device = state_device(devs)
    uuid = fs_uuid(device)
    if uuid.empty?
      r "mkfs", "--type", "ext4", device
      uuid = fs_uuid(device)
    end
    r "mkdir", "-p", @mount_path
    # nofail: a blank instance store after stop/start must not strand boot
    add_to_fstab = File.expand_path("../../common/bin/add_to_fstab", __dir__)
    r add_to_fstab, "UUID=#{uuid}", @mount_path, "ext4", "defaults,nofail", "0", "0"
    r "mount", device, @mount_path unless mounted?
  end

  # blkid exits 2 when the device carries no filesystem yet
  def fs_uuid(device)
    r("blkid", "-s", "UUID", "-o", "value", device, expect: [0, 2]).strip
  end

  def mounted?
    !r("findmnt", "-rno", "SOURCE", @mount_path, expect: [0, 1]).strip.empty?
  end
end
