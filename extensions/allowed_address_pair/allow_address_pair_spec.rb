include Validator::Api::CpiHelpers

fdescribe 'test virtual IP failover with allowed address pairs: ' do

  before(:all) do
    @compute = Validator::Api::FogOpenStack.compute
    @network = Validator::Api::FogOpenStack.network
    @config = Validator::Api.configuration
    @resource_tracker = Validator::Api::ResourceTracker.create
    $vip_port = nil;
    @stemcell_path     = stemcell_path
    @cpi = cpi(cpi_path, log_path)
    @fixed_ip = @config.validator['static_ip']
    @floating_ip_master = @config.validator['floating_ip']
    @network_id = @config.validator['network_id']
    @sudo_command = "echo c1oudc0w | sudo --prompt \"\" --stdin"

    extensions = Validator::Api.configuration.extensions
    aap = YAML.load_file(extensions['allowed_address_pair']['allowed_address_pair'])
    aap.each do |fip|
      @floating_ip_slave = fip['floating_ip_1']
      @floating_ip_vip = fip['floating_ip_2']
    end
  end


  it 'create network port with virtual floating IP' do
    # create placeholder port with fixed IP
    # Issue: FogOpenStack.send returns no resource so we cannot keep track of port -> delete manually later
    #port_cid = with_cpi('Network port could not be created') {
    #  @resource_tracker.produce(:ports, provide_as: :port_cid) {
        $vip_port = @network.create_port(@network_id, :name => "vipport", :fixed_ips => [{:ip_address => @fixed_ip}])
    #  }
    #}
    #expect(@port_cid).to be
    # associate virtual FIP with placeholder port
    floating_ip_id = @network.list_floating_ips('floating_ip_address' => @floating_ip_vip).data[:body]['floatingips'].first['id']
    @network.associate_floating_ip(floating_ip_id, $vip_port.data[:body]['port']['id'])
  end


  it 'prepare image' do
    stemcell_manifest = YAML.load_file(File.join(@stemcell_path, 'stemcell.MF'))
    stemcell_cid = with_cpi('Stemcell could not be uploaded') {
      @resource_tracker.produce(:images, provide_as: :stemcell_cid) {
        @cpi.create_stemcell(File.join(@stemcell_path, 'image'), stemcell_manifest['cloud_properties'])
      }
    }
    expect(stemcell_cid).to be
  end

  it 'create master VM with floating IP and allowed address pair' do
    stemcell_cid = @resource_tracker.consumes(:stemcell_cid, 'No stemcell to create VM from')
    @master_vm_cid = with_cpi('master VM could not be created.') {
      @resource_tracker.produce(:servers, provide_as: :master_vm_cid) {
        @cpi.create_vm(
          'agent-id',
          stemcell_cid,
          @config.default_vm_type_cloud_properties,
          network_spec_with_floating_ip,
          [],
          {}
        )
      }
    }

    @vm_master = @compute.servers.get(@master_vm_cid)
    #vm_master_ip = @vm_master.addresses.values.first.first['addr']
    @vm_master.wait_for { ready? }

    expect(@vm_master).to be

    # find master VM port
    master_server_nics = @network.list_ports('device_id' => @master_vm_cid).data[:body]['ports']
    master_port = (master_server_nics.select do |network_port| network_port['mac_address'] end).first
    # add virtual FIP as allowed address to master VM port
    @network.update_port(master_port['id'], :name => "aap_master", :port_security_enabled => true, :allowed_address_pairs => [{:ip_address => @fixed_ip}])
  end


  it 'create slave VM with floating IP and allowed address pair' do
    stemcell_cid = @resource_tracker.consumes(:stemcell_cid, 'No stemcell to create VM from')
    @slave_vm_cid = with_cpi('slave VM could not be created.') {
      @resource_tracker.produce(:servers, provide_as: :slave_vm_cid) {
        @cpi.create_vm(
          'agent-id',
          stemcell_cid,
          @config.default_vm_type_cloud_properties,
          network_spec,
          [],
          {}
        )
      }
    }

    @vm_slave = @compute.servers.get(@slave_vm_cid)
    #vm_slave_ip = @vm_slave.addresses.values.first.first['addr']
    @vm_slave.wait_for { ready? }

    expect(@vm_slave).to be

    # find slave VM port
    slave_server_nics = @network.list_ports('device_id' => @slave_vm_cid).data[:body]['ports']
    slave_port = (slave_server_nics.select do |network_port| network_port['mac_address'] end).first
    # add virtual FIP as allowed address to slave VM port
    @network.update_port(slave_port['id'], :name => "aap_slave", :port_security_enabled => true, :allowed_address_pairs => [{:ip_address => @fixed_ip}])
    # associate a FIP to slave VM so that it can be reached externally
    floating_ip_id = @network.list_floating_ips('floating_ip_address' => @floating_ip_slave).data[:body]['floatingips'].first['id']
    @network.associate_floating_ip(floating_ip_id, slave_port['id'])
  end


  it 'activate virtual IP on master VM and test connectivity' do
    master_vm_cid = @resource_tracker.consumes(:master_vm_cid, 'No VM to use')
    command = "#{@sudo_command} ip addr add #{@fixed_ip} dev `ls /sys/class/net/ | grep -v lo`"
    output, err, status = execute_ssh_command_on_vm_with_retry(@config.private_key_path, @floating_ip_master, command)
    expect(status.exitstatus).to eq(0),
    error_message("SSH connection to master VM via IP '#{@floating_ip_master}' didn't succeed.", command, err, output)

    # check if we can connect to master VM via virtual FIP
    command = "#{@sudo_command} cat /sys/class/dmi/id/product_uuid"
    output, err, status = execute_ssh_command_on_vm_with_retry(@config.private_key_path, @floating_ip_master, command)
    expect(status.exitstatus).to eq(0),
    error_message("SSH connection to VM via virtual IP '#{@floating_ip_vip}' didn't succeed.", command, err, output)

    # check if this was really executed on slave VM by comparing SMBIOS UUID == OpenStack VM ID
    output=output.downcase
    error = "Failover of VIP to slave VM via virtual IP #{@floating_ip_vip} failed. Expected VM ID #{master_vm_cid} not equal to actual ID #{output}"
    expect("#{output}".casecmp("#{master_vm_cid}\n")).to eq(0), error

    # remove VIP on master VM
    command = "#{@sudo_command} ip addr del #{@fixed_ip}/32 dev `ls /sys/class/net/ | grep -v lo`"
    output, err, status = execute_ssh_command_on_vm_with_retry(@config.private_key_path, @floating_ip_master, command)
    expect(status.exitstatus).to eq(0),
    error_message("SSH connection to master VM via IP '#{@floating_ip_master}' didn't succeed.", command, err, output)

  end

  it 'failover virtual IP to slave VM and test connectivity' do
    # add VIP on slave VM
    slave_vm_cid = @resource_tracker.consumes(:slave_vm_cid, 'No VM to use')
    #vm_ip_to_ssh = Validator::NetworkHelper.vm_ip_to_ssh(vm_cid, @config, @compute)

    command = "#{@sudo_command} ip addr add #{@fixed_ip} dev `ls /sys/class/net/ | grep -v lo`"
    output, err, status = execute_ssh_command_on_vm_with_retry(@config.private_key_path, @floating_ip_slave, command)
    expect(status.exitstatus).to eq(0),
    error_message("SSH connection to slave VM via IP '#{@floating_ip_slave}' didn't succeed.", command, err, output)

    # check if we can connect to slave VM via VIP
    command = "#{@sudo_command} cat /sys/class/dmi/id/product_uuid"
    output, err, status = execute_ssh_command_on_vm_with_retry(@config.private_key_path, @floating_ip_vip, command)
    expect(status.exitstatus).to eq(0),
    error_message("SSH connection to slave VM via virtual IP '#{@floating_ip_vip}' didn't succeed.", command, err, output)

    # check if this was really executed on slave VM by comparing SMBIOS UUID == OpenStack VM ID
    output=output.downcase
    error = "Failover of VIP to slave VM via virtual IP #{@floating_ip_vip} failed. Expected VM ID #{slave_vm_cid} not equal to actual ID #{output}"
    expect("#{output}".casecmp("#{slave_vm_cid}\n")).to eq(0), error
  end

  # Issue: ResourceTracker cannot keep track of port -> delete manually
  it 'delete network port' do
     @network.delete_port($vip_port.data[:body]['port']['id'])
  end

end
