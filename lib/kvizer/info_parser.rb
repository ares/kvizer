require 'nokogiri'

class Kvizer
  class InfoParser < Abstract

    attr_reader :raw_attributes, :attributes

    def initialize(kvizer)
      super kvizer
      @libvirt = kvizer.libvirt
      reload
    end

    def reload
      domains = @libvirt.list_defined_domains.map { |name| @libvirt.lookup_domain_by_name(name) }
      domains += @libvirt.list_domains.map { |id| @libvirt.lookup_domain_by_id(id) }
      reload_raw_attributes domains
      reload_attributes

      #kvizer.logger.debug "Attributes:\n" + attributes.pretty_inspect
      self
    end

    def vm_names
      attributes.keys
    end

    def table
      columns   = [-30, 15, 13, 20]
      format    = columns.map { |c| "%#{c}s" }.join('  ') + "\n"
      delimiter = columns.map { |c| '-'*c.abs }.join('  ') + "\n"
      head      = %w(name ip status os)
      data      = attributes.values.map do |attr|
        { :name => attr[:name], :ip => attr[:ip], :status => kvizer.vm(attr[:name]).status,
          :guest_os => attr[:guest_os] }
      end
      delimiter + format % head + delimiter + data.sort do |a, b|
        [a[:status].to_s, a[:name].to_s] <=> [b[:status].to_s, b[:name].to_s]
      end.map do |attr|
        format % [attr[:name], attr[:ip], attr[:status], attr[:guest_os]]
      end.join + delimiter
    end

    def reload_raw_attributes(domains)
      domains.map! do |domain|
        xml = Nokogiri.XML(domain.xml_desc)
        [xml.search('name').text, xml]
      end

      @raw_attributes = Hash[domains]
    end

    def reload_attributes
      mac_ip_map = get_mac_ip_map

      # TODO! refactor .search().text to helper
      @attributes = raw_attributes.values.inject({}) do |hash, raw_attributes|
        name     = raw_attributes.search('name').text
        # TODO maybe use libvirt metadata?
        # http://libvirt.org/formatdomain.html#elementsMetadata
        guest_os = raw_attributes.search('description').text
        # as long as we have only one network this will find mac
        mac_attr = raw_attributes.search('interface[type="network"]/mac')
        mac = !mac_attr.first.nil? ? mac_attr.first['address'] : 'N/A'
            hash[name] = { :name     => name,
                       :guest_os => guest_os,
                       :mac      => mac,
                       :ip       => mac_ip_map[mac] }
        hash
      end
    end

    def get_mac_ip_map
      result = host.shell(cmd = "sudo arp-scan --interface=#{config.hostonly.name} " +
          "#{config.hostonly.dhcp.lower_ip}-#{config.hostonly.dhcp.upper_ip}")
      return {} unless result.success

      result.out.each_line.inject({}) do |hash, line|
        next hash unless line =~ /^([\d\.]+)\s+([0-9a-f:]+)/
        hash[normalize_mac $2] = $1 if $1
        hash
      end
    end

    def normalize_mac(mac)
      return nil if mac.nil?
      if mac =~ /:/
        mac.split(':').map do |part|
          if part.size == 1
            '0' + part.downcase
          else
            part.downcase
          end
        end
      else
        mac.downcase.each_char.each_slice(2).map { |s| s.join }.to_a
      end.join(':')
    end

    def parse_nic(key, value)
      if key =~ /NIC \d$/
        value.split(/,\s+/).inject({}) do |hash, pair|
          k, v    = pair.split(/:\s+/)
          hash[k] = v
          hash
        end
      else
        value
      end
    end


  end
end