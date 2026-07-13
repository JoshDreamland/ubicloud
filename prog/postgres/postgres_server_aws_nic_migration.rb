# frozen_string_literal: true

require "aws-sdk-ec2"

# :nocov:
class Prog::Postgres::PostgresServerAwsNicMigration < Prog::Base
  subject_is :postgres_server
  semaphore :connections_drained

  frame_accessor :old_nic_id, :new_nic_id, :dns_propagation_waited

  def before_run
    if postgres_server.nil? || postgres_server.vm.nil? || postgres_server.destroy_set?
      # Before the flip, the new nic has no vm_id, so the vm destroy path would
      # not clean it up; trigger its own destroy to release the ENI and EIP.
      if (nic = Nic[new_nic_id]) && nic.vm_id.nil?
        nic.incr_destroy
      end
      pop "postgres server or vm is destroyed"
    end
    super
  end

  label def start
    fail "PostgresServer #{postgres_server.ubid} is not on AWS" unless postgres_server.aws?
    pop "vm already has a management nic" if vm.management_nic

    register_deadline(nil, 48 * 60 * 60)
    self.old_nic_id = vm.user_nic.id
    hop_ensure_mgmt_sg
  end

  label def ensure_mgmt_sg
    # Old subnets have a single group used as both the mgmt and user group
    # (mgmt_security_group_id was backfilled to it); create the SSH-only mgmt
    # group, keeping the shared group as the user group.
    ps_aws = private_subnet.private_subnet_aws_resource
    sg_id = ps_aws.mgmt_security_group_id
    if sg_id.nil? || sg_id == ps_aws.user_security_group_id
      group_name = "aws-#{private_subnet.location.name}-#{private_subnet.ubid}-mgmt"
      sg_id = begin
        client.create_security_group(
          group_name:,
          description: "Mgmt security group for aws-#{private_subnet.location.name}-#{private_subnet.ubid}",
          vpc_id: ps_aws.vpc_id,
          tag_specifications: Util.aws_tag_specifications("security-group", private_subnet.name),
        ).group_id
      rescue Aws::EC2::Errors::InvalidGroupDuplicate
        client.describe_security_groups(filters: [{name: "group-name", values: [group_name]}]).security_groups[0].group_id
      end
<<<<<<< HEAD
=======

      Config.control_plane_outbound_cidrs.each do |cidr|
        authorize_mgmt_ssh_ingress(sg_id, cidr)
      end

      ps_aws.update(mgmt_security_group_id: sg_id)
>>>>>>> 6568a967b15aee2515df3d5cc95ee8b53e7b0046
    end

    # Idempotent; also backfills IPv6 rules onto mgmt groups created before
    # control_plane_outbound_cidrs included IPv6 entries.
    Config.control_plane_outbound_cidrs.each do |cidr|
      authorize_mgmt_ssh_ingress(sg_id, cidr)
    end
    ps_aws.update(mgmt_security_group_id: sg_id)

    # When CloudWatch logs are enabled the GuardDuty interface endpoint and its
    # 443 ingress live on the mgmt group, matching what VpcNexus sets up for
    # dual-NIC subnets. Old subnets put the endpoint in the shared group that is
    # now the user group, so authorize 443 here and move the endpoint over.
    if private_subnet.project.get_ff_aws_cloudwatch_logs
      mgmt_sg_id = ps_aws.mgmt_security_group_id

      begin
        client.authorize_security_group_ingress(group_id: mgmt_sg_id, ip_permissions: [{ip_protocol: "tcp", from_port: 443, to_port: 443, ip_ranges: [{cidr_ip: private_subnet.net4.to_s}]}])
      rescue Aws::EC2::Errors::InvalidPermissionDuplicate
      end

      if (endpoint = guardduty_endpoint)
        current_sg_ids = endpoint.groups.map(&:group_id)
        to_add = [mgmt_sg_id] - current_sg_ids
        to_remove = current_sg_ids - [mgmt_sg_id]
        if to_add.any? || to_remove.any?
          params = {vpc_endpoint_id: endpoint.vpc_endpoint_id}
          params[:add_security_group_ids] = to_add if to_add.any?
          params[:remove_security_group_ids] = to_remove if to_remove.any?
          client.modify_vpc_endpoint(params)
        end
      end
    end

    hop_attach_mgmt_sg
  end

  label def attach_mgmt_sg
    # Attach the mgmt group before flip_to_user_nic points SSH at the mgmt
    # IPv6, which only the mgmt group's rules allow. Keep the user group;
    # customer traffic uses it until downgrade_old_sg.
    ps_aws = private_subnet.private_subnet_aws_resource
    client.modify_network_interface_attribute(
      network_interface_id: old_nic.nic_aws_resource.network_interface_id,
      groups: [ps_aws.user_security_group_id, ps_aws.mgmt_security_group_id],
    )
    hop_create_new_nic
  end

  label def create_new_nic
    hop_wait_new_nic_created if new_nic_id

    old_nar = old_nic.nic_aws_resource
    name = "#{old_nic.name}-mig"

    eni = client.create_network_interface(
      subnet_id: old_nar.subnet_id,
      ipv_6_prefix_count: 1,
      groups: [private_subnet.private_subnet_aws_resource.user_security_group_id],
      tag_specifications: Util.aws_tag_specifications("network-interface", name),
      client_token: "#{old_nic.id}-mig",
    ).network_interface

    client.modify_network_interface_attribute(
      network_interface_id: eni.network_interface_id,
      source_dest_check: {value: false},
    )

    ubid = Nic.generate_ubid
    id = ubid.to_uuid
    DB.transaction do
      Nic.create_with_id(
        id,
        private_subnet_id: old_nic.private_subnet_id,
        private_ipv4: "#{eni.private_ip_address}/32",
        private_ipv6: private_subnet.random_private_ipv6.to_s,
        mac: nil,
        name:,
        state: "active",
        is_management: false,
      )
      NicAwsResource.create_with_id(
        id,
        network_interface_id: eni.network_interface_id,
        subnet_id: old_nar.subnet_id,
        subnet_az: old_nar.subnet_az,
        aws_subnet_id: old_nar.aws_subnet_id,
      )

      Strand.create_with_id(id, prog: "Vnet::Aws::NicNexus", label: "wait", stack: [{}])
    end
    self.new_nic_id = id
    hop_wait_new_nic_created
  end

  label def wait_new_nic_created
    nap 1 unless (eni = get_network_interface(new_nic))&.status == "available"
    # The ENI is created with only an IPv6 prefix; assign an individual address
    # too (as NicNexus#assign_ipv6_address does) so ephemeral_net6 can be
    # repointed to the new NIC at the flip. Guarded so re-runs don't add a second.
    if eni.ipv_6_addresses.empty?
      client.assign_ipv_6_addresses(network_interface_id: eni.network_interface_id, ipv_6_address_count: 1)
    end
    hop_attach_new_nic
  end

  label def attach_new_nic
    nap 1 unless (eni = get_network_interface(new_nic))
    unless eni.attachment
      client.attach_network_interface(
        network_interface_id: eni.network_interface_id,
        instance_id: vm.aws_instance.instance_id,
        device_index: 1,
      )
    end
    hop_disable_old_nic_source_dest_check
  end

  label def disable_old_nic_source_dest_check
    client.modify_network_interface_attribute(
      network_interface_id: old_nic.nic_aws_resource.network_interface_id,
      source_dest_check: {value: false},
    )
    hop_allocate_new_eip
  end

  label def allocate_new_eip
    nar = new_nic.nic_aws_resource
    if nar.eip_allocation_id.nil?
      eip_allocation_id = client.allocate_address(tag_specifications: Util.aws_tag_specifications("elastic-ip", new_nic.name)).allocation_id
      nar.update(eip_allocation_id:)
    end
    hop_associate_new_eip
  end

  label def associate_new_eip
    address = client.describe_addresses(
      filters: [{name: "allocation-id", values: [new_nic.nic_aws_resource.eip_allocation_id]}],
    ).addresses.first
    nap 1 unless address
    unless address.network_interface_id
      client.associate_address(
        allocation_id: address.allocation_id,
        network_interface_id: new_nic.nic_aws_resource.network_interface_id,
      )
    end
    hop_setup_routing
  end

  label def setup_routing
    mgmt_nic_id = old_nic.nic_aws_resource.network_interface_id
    user_nic_id = new_nic.nic_aws_resource.network_interface_id
    nis = client.describe_network_interfaces(network_interface_ids: [mgmt_nic_id, user_nic_id]).network_interfaces.to_h { [it.network_interface_id, it] }
    mgmt_nic = nis[mgmt_nic_id]
    user_nic = nis[user_nic_id]
    nap 1 unless mgmt_nic && user_nic

    guardduty_ips = if private_subnet.project.get_ff_aws_cloudwatch_logs
      client.describe_network_interfaces(network_interface_ids: guardduty_endpoint.network_interface_ids).network_interfaces.map(&:private_ip_address)
    else
      []
    end

    subnet6 = if private_subnet.postgres_aws_ssh_ipv6?
      fail "AWS subnet #{new_nic.nic_aws_resource.aws_subnet.id} is missing ipv6_cidr" if new_nic.nic_aws_resource.aws_subnet.ipv6_cidr.to_s.empty?
      NetAddr::IPv6Net.parse(new_nic.nic_aws_resource.aws_subnet.ipv6_cidr.to_s)
    end

    netplan_install = AwsDualNicNetplan.install_script(
      mgmt: mgmt_nic,
      user: user_nic,
      subnet: NetAddr::IPv4Net.parse(new_nic.nic_aws_resource.aws_subnet.ipv4_cidr.to_s),
      guardduty_ips:,
      subnet6:,
    )
    setup_user_nic_script = <<~SCRIPT
    set -e
    echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    if [ -f /etc/netplan/50-cloud-init.yaml ]; then mv /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak; fi
    rm -f /etc/netplan/61-user-nic.yaml
    #{netplan_install.chomp}
    for i in $(seq 1 30); do
      iface=$(ip -o link | grep -i "#{user_nic.mac_address}" | awk -F': ' '{print $2; exit}')
      [ -n "$iface" ] && ip -4 addr show "$iface" | grep -q "inet " && break
      sleep 1
    done
    iface=$(ip -o link | grep -i "#{user_nic.mac_address}" | awk -F': ' '{print $2; exit}')
    [ -n "$iface" ] && ip -4 addr show "$iface" | grep -q "inet "
    SCRIPT
    vm.sshable.cmd("sudo bash", stdin: setup_user_nic_script)
    hop_flip_to_user_nic
  rescue Sshable::SshError
    nap 5
  end

  label def flip_to_user_nic
    eni = get_network_interface(new_nic)
    nap 1 unless (association = eni&.association) && eni.ipv_6_addresses.first

    # Rename to match native dual-NIC naming (user: <vm>-nic, mgmt: <vm>-mgmt-nic).
    # Demote the old NIC first so the user name is free for the new one.
    old_nic.update(is_management: true, name: "#{vm.name}-mgmt-nic")
    new_nic.update(vm_id: vm.id, name: "#{vm.name}-nic")
    AssignedVmAddress.where(dst_vm_id: vm.id).update(ip: association.public_ip)
    vm.aws_instance.update(ipv4_dns_name: association.public_dns_name)
    # Point ephemeral_net6 at the new user NIC, matching what VM creation records
    # for native dual-NIC VMs (the old NIC's IPv6 now belongs to the mgmt NIC).
    vm.update(ephemeral_net6: eni.ipv_6_addresses.first.ipv_6_address)

    # Move the Sshable host to the mgmt NIC public IPv6; drop the cached SSH
    # session keyed by the old IPv4 host first. The EIP is released only at
    # release_old_eip, since customer DNS resolves to it until update_dns_record
    # propagates.
    if private_subnet.postgres_aws_ssh_ipv6?
      mgmt_ipv6 = get_network_interface(old_nic).ipv_6_addresses.first.ipv_6_address
      begin
        Socket.tcp(mgmt_ipv6, 22, connect_timeout: 5) {}
      rescue SystemCallError, IO::TimeoutError => e
        Clog.emit("mgmt IPv6 ssh preflight failed", {aws_nic_migration_preflight: {server_ubid: postgres_server.ubid, mgmt_ipv6:, error: e.class.name}})
        nap 10
      end
      vm.sshable.invalidate_cache_entry
      vm.sshable.update(host: mgmt_ipv6)
    end

    # Keep the AWS Name tags consistent with the renamed records.
    retag_nic_aws_resources(new_nic)
    retag_nic_aws_resources(old_nic)

    resource.servers.each(&:incr_configure)
    hop_wait_configure_propagated
  end

  label def wait_configure_propagated
    nap 5 if resource.servers.any?(&:configure_set?) || resource.servers.any? { it.strand.label != "wait" }
    hop_update_dns_record
  end

  label def update_dns_record
    resource.incr_refresh_dns_record
    hop_wait_dns_propagated
  end

  label def wait_dns_propagated
    nap 5 if resource.refresh_dns_record_set? || resource.strand.label != "wait"
    unless dns_propagation_waited
      self.dns_propagation_waited = true
      nap 60
    end
    hop_wait_connections_drain
  end

  label def wait_connections_drain
    when_connections_drained_set? do
      decr_connections_drained
      hop_downgrade_old_sg
    end
    Clog.emit("waiting for operator to confirm old NIC connections drained", {
      aws_nic_migration_drain_gate: {
        server_ubid: postgres_server.ubid,
        confirm_with: "Semaphore.incr(\"#{strand.id}\", \"connections_drained\")",
      },
    })
    nap 60 * 60
  end

  label def downgrade_old_sg
    client.modify_network_interface_attribute(
      network_interface_id: old_nic.nic_aws_resource.network_interface_id,
      groups: [private_subnet.private_subnet_aws_resource.mgmt_security_group_id],
    )
    hop_release_old_eip
  end

  label def release_old_eip
    release_nic_eip(old_nic) if private_subnet.postgres_aws_ssh_ipv6?
    hop_refresh_internal_firewall
  end

  label def refresh_internal_firewall
    # Rewrite the internal firewall rules: with every VM on a management NIC
    # they no longer include port 22 (PostgresResource#mgmt_ssh_via_user_sg?),
    # so Vnet::Aws::UpdateFirewallRules revokes it from the user security
    # group on the next sync.
    resource.internal_firewall.replace_firewall_rules(resource.internal_firewall_rules)
    resource.servers.each { it.vm.incr_update_firewall_rules }
    Clog.emit("AWS NIC migration complete", {
      aws_nic_migration_complete: {server_ubid: postgres_server.ubid, new_network_interface_id: new_nic.nic_aws_resource.network_interface_id},
    })
    pop "aws nic migration complete"
  end

  def vm
    @vm ||= postgres_server.vm
  end

  def old_nic
    @old_nic ||= Nic[old_nic_id]
  end

  def new_nic
    @new_nic ||= Nic[new_nic_id]
  end

  def private_subnet
    @private_subnet ||= old_nic.private_subnet
  end

  def resource
    @resource ||= postgres_server.resource
  end

  def client
    @client ||= vm.location.location_credential_aws.client
  end

  def authorize_mgmt_ssh_ingress(sg_id, cidr)
    # IPv4 sources go in ip_ranges, IPv6 sources in ipv_6_ranges
    ranges = if cidr.include?(":")
      {ipv_6_ranges: [{cidr_ipv_6: cidr}]}
    else
      {ip_ranges: [{cidr_ip: cidr}]}
    end
    client.authorize_security_group_ingress(group_id: sg_id, ip_permissions: [{ip_protocol: "tcp", from_port: 22, to_port: 22, **ranges}])
  rescue Aws::EC2::Errors::InvalidPermissionDuplicate
<<<<<<< HEAD
=======
    nil
>>>>>>> 6568a967b15aee2515df3d5cc95ee8b53e7b0046
  end

  def get_network_interface(nic)
    client.describe_network_interfaces(
      filters: [{name: "network-interface-id", values: [nic.nic_aws_resource.network_interface_id]}],
    ).network_interfaces.first
  end

  def retag_nic_aws_resources(nic)
    nar = nic.nic_aws_resource
    client.create_tags(resources: [nar.network_interface_id, nar.eip_allocation_id].compact, tags: [{key: "Name", value: nic.name}])
  end

  # Disassociate and release a NIC's EIP and clear the stored allocation id.
  def release_nic_eip(nic)
    nar = nic.nic_aws_resource
    return unless (allocation_id = nar.eip_allocation_id)

    if (association = get_network_interface(nic)&.association)
      begin
        client.disassociate_address(association_id: association.association_id)
      rescue Aws::EC2::Errors::InvalidAssociationIDNotFound
      end
    end
    begin
      client.release_address(allocation_id:)
    rescue Aws::EC2::Errors::InvalidAllocationIDNotFound, Aws::EC2::Errors::InvalidAddressIDNotFound => e
      Clog.emit("EIP already released for nic", {ignored_aws_eip_release: {nic_ubid: nic.ubid, error: e.class.name}})
    end
    nar.update(eip_allocation_id: nil)
  end

  def guardduty_service_name
    "com.amazonaws.#{private_subnet.location.name}.guardduty-data"
  end

  def guardduty_endpoint
    client.describe_vpc_endpoints(filters: [
      {name: "vpc-id", values: [private_subnet.private_subnet_aws_resource.vpc_id]},
      {name: "service-name", values: [guardduty_service_name]},
    ]).vpc_endpoints.first
  end
end
# :nocov:
