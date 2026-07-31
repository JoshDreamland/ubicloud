# frozen_string_literal: true

require_relative "../lib/walshadow_instance_store"

RSpec.describe WalshadowInstanceStore do
  subject(:store) { described_class.new("/var/lib/walshadow") }

  describe "#devices" do
    it "lists whole disks that don't back /" do
      expect(store).to receive(:_run_command).with("bash", stdin: instance_of(String)).and_return("/dev/nvme1n1\n/dev/nvme2n1\n")
      expect(store.devices).to eq ["/dev/nvme1n1", "/dev/nvme2n1"]
    end
  end

  describe "#setup" do
    it "is a no-op when the family has no instance store" do
      expect(store).to receive(:devices).and_return([])
      expect(store).not_to receive(:_run_command)
      store.setup
    end

    it "formats and mounts a single blank device" do
      expect(store).to receive(:devices).and_return(["/dev/nvme1n1"])
      expect(store).to receive(:_run_command).with("blkid", "-s", "UUID", "-o", "value", "/dev/nvme1n1", expect: [0, 2]).and_return("", "uuid-1\n")
      expect(store).to receive(:_run_command).with("mkfs", "--type", "ext4", "/dev/nvme1n1")
      expect(store).to receive(:_run_command).with("mkdir", "-p", "/var/lib/walshadow")
      expect(store).to receive(:_run_command).with(a_string_ending_with("/common/bin/add_to_fstab"), "UUID=uuid-1", "/var/lib/walshadow", "ext4", "defaults,nofail", "0", "0")
      expect(store).to receive(:_run_command).with("findmnt", "-rno", "SOURCE", "/var/lib/walshadow", expect: [0, 1]).and_return("")
      expect(store).to receive(:_run_command).with("mount", "/dev/nvme1n1", "/var/lib/walshadow")
      store.setup
    end

    it "stripes, formats, and mounts multiple blank devices" do
      expect(File).to receive(:blockdev?).with("/dev/md0").and_return(false)
      expect(store).to receive(:devices).and_return(["/dev/nvme1n1", "/dev/nvme2n1"])
      expect(store).to receive(:_run_command).with("mdadm", "--create", "--verbose", "/dev/md0", "--level=0", "--raid-devices=2", "/dev/nvme1n1", "/dev/nvme2n1")
      expect(store).to receive(:_run_command).with("bash", "-c", "mdadm --detail --scan >> /etc/mdadm/mdadm.conf")
      expect(store).to receive(:_run_command).with("update-initramfs", "-u")
      expect(store).to receive(:_run_command).with("blkid", "-s", "UUID", "-o", "value", "/dev/md0", expect: [0, 2]).and_return("", "uuid-2\n")
      expect(store).to receive(:_run_command).with("mkfs", "--type", "ext4", "/dev/md0")
      expect(store).to receive(:_run_command).with("mkdir", "-p", "/var/lib/walshadow")
      expect(store).to receive(:_run_command).with(a_string_ending_with("/common/bin/add_to_fstab"), "UUID=uuid-2", "/var/lib/walshadow", "ext4", "defaults,nofail", "0", "0")
      expect(store).to receive(:_run_command).with("findmnt", "-rno", "SOURCE", "/var/lib/walshadow", expect: [0, 1]).and_return("")
      expect(store).to receive(:_run_command).with("mount", "/dev/md0", "/var/lib/walshadow")
      store.setup
    end

    it "preserves an existing filesystem and skips a redundant mount" do
      expect(store).to receive(:devices).and_return(["/dev/nvme1n1"])
      expect(store).to receive(:_run_command).with("blkid", "-s", "UUID", "-o", "value", "/dev/nvme1n1", expect: [0, 2]).and_return("uuid-1\n")
      expect(store).not_to receive(:_run_command).with("mkfs", any_args)
      expect(store).to receive(:_run_command).with("mkdir", "-p", "/var/lib/walshadow")
      expect(store).to receive(:_run_command).with(a_string_ending_with("/common/bin/add_to_fstab"), "UUID=uuid-1", "/var/lib/walshadow", "ext4", "defaults,nofail", "0", "0")
      expect(store).to receive(:_run_command).with("findmnt", "-rno", "SOURCE", "/var/lib/walshadow", expect: [0, 1]).and_return("/dev/nvme1n1\n")
      expect(store).not_to receive(:_run_command).with("mount", any_args)
      store.setup
    end

    it "does not recreate an already-assembled array" do
      expect(File).to receive(:blockdev?).with("/dev/md0").and_return(true)
      expect(store).to receive(:devices).and_return(["/dev/nvme1n1", "/dev/nvme2n1"])
      expect(store).not_to receive(:_run_command).with("mdadm", any_args)
      expect(store).not_to receive(:_run_command).with("update-initramfs", any_args)
      expect(store).to receive(:_run_command).with("blkid", "-s", "UUID", "-o", "value", "/dev/md0", expect: [0, 2]).and_return("uuid-2\n")
      expect(store).not_to receive(:_run_command).with("mkfs", any_args)
      expect(store).to receive(:_run_command).with("mkdir", "-p", "/var/lib/walshadow")
      expect(store).to receive(:_run_command).with(a_string_ending_with("/common/bin/add_to_fstab"), "UUID=uuid-2", "/var/lib/walshadow", "ext4", "defaults,nofail", "0", "0")
      expect(store).to receive(:_run_command).with("findmnt", "-rno", "SOURCE", "/var/lib/walshadow", expect: [0, 1]).and_return("/dev/md0\n")
      store.setup
    end
  end
end
