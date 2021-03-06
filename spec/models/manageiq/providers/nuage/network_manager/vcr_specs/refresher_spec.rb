describe ManageIQ::Providers::Nuage::NetworkManager::Refresher do
  ALL_REFRESH_SETTINGS = [
    {
      :inventory_object_refresh => false
    },
    {
      :inventory_object_refresh => true,
      :inventory_collections    => {
        :saver_strategy => :default,
      },
    }, {
      :inventory_object_refresh => true,
      :inventory_collections    => {
        :saver_strategy => :batch,
        :use_ar_object  => true,
      },
    }, {
      :inventory_object_refresh => true,
      :inventory_collections    => {
        :saver_strategy => :batch,
        :use_ar_object  => false,
      },
    }, {
      :inventory_object_saving_strategy => :recursive,
      :inventory_object_refresh         => true
    }
  ].freeze

  before(:each) do
    @ems = FactoryGirl.create(:ems_nuage_with_vcr_authentication, :port => 8443, :api_version => "v5_0", :security_protocol => "ssl-with-validation")
  end

  before(:each) do
    userid   = Rails.application.secrets.nuage_network.try(:[], 'userid') || 'NUAGE_USER_ID'
    password = Rails.application.secrets.nuage_network.try(:[], 'password') || 'NUAGE_PASSWORD'
    hostname = @ems.hostname

    # Ensure that VCR will obfuscate the basic auth
    VCR.configure do |c|
      # workaround for escaping host
      c.before_playback do |interaction|
        interaction.filter!(CGI.escape(hostname), hostname)
        interaction.filter!(CGI.escape('NUAGE_NETWORK_HOST'), 'nuagenetworkhost')
      end
      c.filter_sensitive_data('NUAGE_NETWORK_AUTHORIZATION') { Base64.encode64("#{userid}:#{password}").chomp }
    end
  end

  it ".ems_type" do
    expect(described_class.ems_type).to eq(:nuage_network)
  end

  describe ".to_cidr" do
    let(:parser) { ManageIQ::Providers::Nuage::Inventory::Parser::NetworkManager.new }

    it "normal" do
      expect(parser.send(:to_cidr, '192.168.0.0', '255.255.255.0')).to eq('192.168.0.0/24')
    end

    it "address and netmask nil" do
      expect(parser.send(:to_cidr, nil, nil)).to be_nil
    end
  end

  describe "refresh" do
    let(:network_group_ref1) { "713d0ba0-dea8-44b4-8ac7-6cab9dc321a7" }
    let(:network_group_ref2) { "e0819464-e7fc-4a37-b29a-e72da7b5956c" }
    let(:security_group_ref) { "02e072ef-ca95-4164-856d-3ff177b9c13c" }
    let(:cloud_subnet_ref1)  { "d60d316a-c1ac-4412-813c-9652bdbc4e41" }
    let(:cloud_subnet_ref2)  { "debb9f88-f252-4c30-9a17-d6ae3865e365" }

    ALL_REFRESH_SETTINGS.each do |settings|
      context "with settings #{settings}" do
        before(:each) do
          stub_settings_merge(
            :ems_refresh => {
              :nuage_network => settings
            }
          )
        end

        it "will perform a full refresh" do
          2.times do # Run twice to verify that a second run with existing data does not change anything
            @ems.reload

            VCR.use_cassette(described_class.name.underscore, :allow_unused_http_interactions => true) do
              EmsRefresh.refresh(@ems)
            end

            @ems.reload
            assert_table_counts
            assert_ems
            assert_network_groups
            assert_security_groups
            assert_cloud_subnets
          end
        end
      end
    end
  end

  def assert_table_counts
    expect(ExtManagementSystem.count).to eq(1)
    expect(NetworkGroup.count).to eq(2)
    expect(SecurityGroup.count).to eq(1)
    expect(CloudSubnet.count).to eq(2)
    expect(FloatingIp.count).to eq(0)
    expect(NetworkPort.count).to eq(0)
    expect(NetworkRouter.count).to eq(0)
  end

  def assert_ems
    expect(@ems.network_groups.count).to eq(2)
    expect(@ems.security_groups.count).to eq(1)
    expect(@ems.cloud_subnets.count).to eq(2)

    expect(@ems.network_groups.map(&:ems_ref))
      .to match_array([network_group_ref1, network_group_ref2])
    expect(@ems.security_groups.map(&:ems_ref))
      .to match_array([security_group_ref])
    expect(@ems.cloud_subnets.map(&:ems_ref))
      .to match_array([cloud_subnet_ref1, cloud_subnet_ref2])
  end

  def assert_network_groups
    g1 = NetworkGroup.find_by(:ems_ref => network_group_ref1)
    expect(g1).to have_attributes(
      :name                   => "Ansible-Test",
      :cidr                   => nil,
      :status                 => "active",
      :enabled                => nil,
      :ems_id                 => @ems.id,
      :orchestration_stack_id => nil,
      :type                   => "ManageIQ::Providers::Nuage::NetworkManager::NetworkGroup"
    )
    expect(g1.cloud_subnets.count).to eq(0)
    expect(g1.security_groups.count).to eq(0)

    g2 = NetworkGroup.find_by(:ems_ref => network_group_ref2)
    expect(g2).to have_attributes(
      :name                   => "XLAB",
      :cidr                   => nil,
      :status                 => "active",
      :enabled                => nil,
      :ems_id                 => @ems.id,
      :orchestration_stack_id => nil,
      :type                   => "ManageIQ::Providers::Nuage::NetworkManager::NetworkGroup"
    )
    expect(g2.cloud_subnets.count).to eq(2)
    expect(g2.security_groups.count).to eq(1)

    expect(g2.cloud_subnets.map(&:ems_ref))
      .to match_array([cloud_subnet_ref1, cloud_subnet_ref2])
    expect(g2.security_groups.map(&:ems_ref))
      .to match_array([security_group_ref])
  end

  def assert_security_groups
    g1 = SecurityGroup.find_by(:ems_ref => security_group_ref)
    expect(g1).to have_attributes(
      :name                   => "Test Policy Group",
      :description            => nil,
      :type                   => "ManageIQ::Providers::Nuage::NetworkManager::SecurityGroup",
      :ems_id                 => @ems.id,
      :cloud_network_id       => nil,
      :cloud_tenant_id        => nil,
      :orchestration_stack_id => nil
    )
    expect(g1.network_group.ems_ref).to eq(network_group_ref2)
  end

  def assert_cloud_subnets
    s1 = CloudSubnet.find_by(:ems_ref => cloud_subnet_ref1)
    expect(s1).to have_attributes(
      :name                           => "Subnet 1",
      :ems_id                         => @ems.id,
      :availability_zone_id           => nil,
      :cloud_network_id               => nil,
      :cidr                           => "10.10.20.0/24",
      :status                         => nil,
      :dhcp_enabled                   => false,
      :gateway                        => "10.10.20.1",
      :network_protocol               => "ipv4",
      :cloud_tenant_id                => nil,
      :dns_nameservers                => nil,
      :ipv6_router_advertisement_mode => nil,
      :ipv6_address_mode              => nil,
      :type                           => "ManageIQ::Providers::Nuage::NetworkManager::CloudSubnet",
      :network_router_id              => nil,
      :network_group_id               => NetworkGroup.find_by(:ems_ref => network_group_ref2).id,
      :parent_cloud_subnet_id         => nil,
      :extra_attributes               => {
        "enterprise_name" => "XLAB",
        "enterprise_id"   => network_group_ref2,
        "domain_name"     => "BaseL3",
        "domain_id"       => "75ad8ee8-726c-4950-94bc-6a5aab64631d",
        "zone_name"       => "Zone 1",
        "zone_id"         => "6256954b-9dd6-43ed-94ff-9daa683ab8b0"
      }
    )

    s2 = CloudSubnet.find_by(:ems_ref => cloud_subnet_ref2)
    expect(s2).to have_attributes(
      :name                           => "Subnet 0",
      :ems_id                         => @ems.id,
      :availability_zone_id           => nil,
      :cloud_network_id               => nil,
      :cidr                           => "10.10.10.0/24",
      :status                         => nil,
      :dhcp_enabled                   => false,
      :gateway                        => "10.10.10.1",
      :network_protocol               => "ipv4",
      :cloud_tenant_id                => nil,
      :dns_nameservers                => nil,
      :ipv6_router_advertisement_mode => nil,
      :ipv6_address_mode              => nil,
      :type                           => "ManageIQ::Providers::Nuage::NetworkManager::CloudSubnet",
      :network_router_id              => nil,
      :network_group_id               => NetworkGroup.find_by(:ems_ref => network_group_ref2).id,
      :parent_cloud_subnet_id         => nil,
      :extra_attributes               => {
        "enterprise_name" => "XLAB",
        "enterprise_id"   => network_group_ref2,
        "domain_name"     => "BaseL3",
        "domain_id"       => "75ad8ee8-726c-4950-94bc-6a5aab64631d",
        "zone_name"       => "Zone 0",
        "zone_id"         => "3b11a2d0-2082-42f1-92db-0b05264f372e"
      }
    )
  end
end
