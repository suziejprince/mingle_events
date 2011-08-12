module MingleEvents
  
  # fetch all unseen events and write them to disk for future processing
  class ProjectEventFetcher
    
    def initialize(project_identifier, mingle_access, state_dir=nil)
      @project_identifier = project_identifier
      @mingle_access = mingle_access
      base_uri = URI.parse(mingle_access.base_url)
      @state_dir = File.expand_path(state_dir || File.join('~', '.mingle_events', base_uri.host, base_uri.port.to_s, project_identifier, 'fetched_events'))
    end
    
    # blow away any existing state, when next used to fetch events from mingle
    # will crawl all the way back to time zero
    def reset
      FileUtils.rm_rf(@state_dir)
    end
    
    # fetch the latest events from mingle, i.e., the ones not previously seen
    def fetch_latest
      page = Feed::Page.new("/api/v2/projects/#{@project_identifier}/feeds/events.xml", @mingle_access)
      most_recent_new_entry = page.entries.first
      last_fetched_entry = load_last_fetched_entry
      last_fetched_entry_seen = false      
      next_entry = nil
      while !last_fetched_entry_seen && page
        page.entries.each do |entry|
                    
          if last_fetched_entry && entry.entry_id == last_fetched_entry.entry_id
            last_fetched_entry_seen = true
            break
          end
          
          write_entry_to_disk(entry, next_entry)
          next_entry = entry
        
        end
        page = page.next
      end
                  
      update_current_state(next_entry, most_recent_new_entry)
      Entries.new(file_for_entry(next_entry), file_for_entry(most_recent_new_entry))
    end
    
    # returns all previously fetched entries; can be used to reprocess the events for, say,
    # various historical analyses
    def all_fetched_entries
      current_state = load_current_state
      Entries.new(current_state[:first_fetched_entry_info_file], current_state[:last_fetched_entry_info_file])
    end 
    
    def first_entry_fetched
      current_state_entry(:first_fetched_entry_info_file)
    end
    
    def last_entry_fetched
      current_state_entry(:last_fetched_entry_info_file)
    end
    
    # only public to facilitate testing
    def update_current_state(oldest_new_entry, most_recent_new_entry)
      current_state = load_current_state
      if most_recent_new_entry
        current_state.merge!(:last_fetched_entry_info_file => file_for_entry(most_recent_new_entry))
        if current_state[:first_fetched_entry_info_file].nil?
          current_state.merge!(:first_fetched_entry_info_file => file_for_entry(oldest_new_entry))
        end
        File.open(current_state_file, 'w'){|out| YAML.dump(current_state, out)}
      end
    end 
    
    # only public to facilitate testing
    def write_entry_to_disk(entry, next_entry)
      file = file_for_entry(entry)
      FileUtils.mkdir_p(File.dirname(file))
      file_content = {:entry_xml => entry.raw_xml, :next_entry_file_path => file_for_entry(next_entry)}
      File.open(file, 'w'){|out| YAML.dump(file_content, out)}
    end
           
    private
    
    def current_state_entry(info_file_key)
      if info_file = load_current_state[info_file_key]
        entry_for_xml(YAML.load(File.new(info_file))[:entry_xml])
      else
        nil
      end
    end

    def file_for_entry(entry)
      return nil if entry.nil?
      
      entry_id_as_uri = URI.parse(entry.entry_id)
      relative_path_parts = entry_id_as_uri.path.split('/')
      entry_id_int = relative_path_parts.last
      insertions = ["#{entry_id_int.to_i/16384}", "#{entry_id_int.to_i%16384}"]
      relative_path_parts = relative_path_parts[0..-2] + insertions + ["#{entry_id_int}.yml"]  
      File.join(@state_dir, *relative_path_parts)
    end
    
    def current_state_file
      File.expand_path(File.join(@state_dir, 'current_state.yml'))
    end
    
    def load_last_fetched_entry
      current_state = load_current_state
      last_fetched_entry = if current_state[:last_fetched_entry_info_file]
        last_fetched_entry_info = YAML.load(File.new(current_state[:last_fetched_entry_info_file]))
        Feed::Entry.new(Nokogiri::XML(last_fetched_entry_info[:entry_xml]).at('/entry'))
      else 
        nil
      end
    end
        
    def load_current_state
      if File.exist?(current_state_file)
        YAML.load(File.new(current_state_file))
      else
        {:last_fetched_entry_info_file => nil, :first_fetched_entry_info_file => nil}
      end
    end
    
    def entry_for_xml(entry_xml)
      Feed::Entry.new(Nokogiri::XML(entry_xml).at('/entry'))
    end
    
    class Entries
      
      include Enumerable
      
      def initialize(first_info_file, last_info_file)
        @first_info_file = first_info_file
        @last_info_file = last_info_file
      end
      
      def entry_for_xml(entry_xml)
        Feed::Entry.new(Nokogiri::XML(entry_xml).at('/entry'))
      end
      
      def each(&block)
        current_file = @first_info_file
        while current_file
          current_entry_info = YAML.load(File.new(current_file))
          yield(entry_for_xml(current_entry_info[:entry_xml]))
          break if File.expand_path(current_file) == File.expand_path(@last_info_file)
          current_file = current_entry_info[:next_entry_file_path]
        end
      end
      
    end
          
  end
end