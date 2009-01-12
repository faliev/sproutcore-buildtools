require 'yaml'

module SproutCore

  # Describes a single library that can contain one or more clients and
  # frameworks. This class is used to automatically locate all installed
  # libraries and to register the clients within them.
  #
  # Libraries are chained, with the child library replacing the parent
  # library's settings. In general, the root library is always the current app
  # while its parent libraries are those found in the load path or explicitly
  # stated in the configs.
  class Library

    # Creates a chained set of libraries from the passed location and the load 
    # path
    def self.library_for(root_path, opts = {})

      # Find libraries in the search paths, build chain
      root_path = File.expand_path(root_path)
      
      # Walk up the root_path until we find a library
      # If no library is found and we reach the top, then return nil.
      while !is_library?(root_path)
        new_root_path, removed_filename = File.split(root_path)
        return nil if new_root_path == root_path
        root_path = new_root_path
      end
      
      paths = libraries_in($:).reject { |x| x == root_path }
      paths.unshift(root_path)
      ret = nil

      # Convert chain to library objects.  The last path processed should be
      # the one passed in to this method.
      while path = paths.pop
        ret = self.new(path, opts, ret)
      end

      # Return library object for root_path
      return ret
    end

    # Searches the array of paths, returning the array of paths that are 
    # actually libraries.
    #
    # ==== Params
    # paths<Array>:: Array of libraries.
    #
    def self.libraries_in(paths)
      ret = paths.map do |p|
        p = File.expand_path(p) # expand
        [p, p.gsub(/\/lib$/,'')].reject { |x| !is_library?(x) }
      end
      ret.flatten.compact.uniq
    end

    # Heuristically determines if the library is a path or not.
    #
    # ==== Params
    # path:: the path to check
    #
    # ==== Returns
    # true if path appears to be a library
    #
    def self.is_library?(path)
      ['sc-config.rb', 'sc-config'].each do |filename|
        return true if File.exists?(File.join(path, filename))
      end
      return false
    end

    # The root path for this library
    attr_reader :root_path

    # The raw environment hash loaded from disk.  Generally use computed_environment,
    # which combines the parent.
    attr_reader :environment

    # The parent library, used for load order dependency
    attr_accessor :next_library

    # Any proxy info stored for development
    attr_accessor :proxies

    # The client directories found in this library.  This usually maps directly to a
    # client name but it may not if you have set up some other options.
    def client_directories
      return @client_dirs unless @client_dirs.nil?
      client_path = File.join(@root_path, 'clients')
      if File.exists?(client_path)
        @client_dirs = Dir.entries(client_path).reject do |x|
          (/^\./ =~ x) || !File.directory?(File.join(client_path,x))
        end
      else
        @client_dirs = []
      end

      return @client_dirs
    end

    # The framework directories found in this library
    def framework_directories
      return @framework_dirs unless @framework_dirs.nil?
      framework_path = File.join(@root_path, 'frameworks')
      if File.exists?(framework_path)
        @framework_dirs = Dir.entries(framework_path).reject do |x|
          (/^\./ =~ x) || !File.directory?(File.join(framework_path,x))
        end
      else
        @framework_dirs = []
      end

      return @framework_dirs
    end

    # Returns all of the client names known to the current environment, including
    # through parent libraries.
    def client_names
      return @cache_client_names unless @cache_client_names.nil?

      ret = next_library.nil? ? [] : next_library.client_directories
      ret += client_directories
      return @cache_client_names = ret.compact.uniq.sort
    end

    # Returns all of the framework names known to the current environment, including
    # through parent libraries.
    def framework_names
      return @cache_framework_names unless @cache_framework_names.nil?

      ret = next_library.nil? ? [] : next_library.framework_directories
      ret += framework_directories
      return @cache_framework_names = ret.compact.uniq.sort
    end

    # ==== Returns
    # A hash of all bundle names mapped to root url.  This method is optimized for frequent
    # requests so you can use it to route incoming requests.
    def bundles_grouped_by_url
      return @cached_bundles_by_url unless @cached_bundles_by_url.nil?
      ret = {}
      bundles.each { |b| ret[b.url_root] = b; ret[b.index_root] = b }
      return @cached_bundles_by_url = ret
    end

    # ==== Returns
    # A bundle for the specified name.  If the bundle has not already been created, then
    # it will be created.
    def bundle_for(bundle_name)
      bundle_name = bundle_name.to_sym
      @bundles ||= {}
      return @bundles[bundle_name] ||= Bundle.new(bundle_name, environment_for(bundle_name))
    end

    # ==== Returns
    # All of the bundles for registered clients
    def client_bundles
      @cached_client_bundles ||= client_names.map { |x| bundle_for(x) }
    end

    # ==== Returns
    # All of the bundles for registered frameworks
    def framework_bundles
      @cached_framework_bundles ||= framework_names.map { |x| bundle_for(x) }
    end

    # ==== Returns
    # All known bundles, both framework & client
    def bundles
      @cached_all_bundles ||= (client_bundles + framework_bundles)
    end
    
    # ==== Returns
    # All known bundles, except those whose autobuild setting is off.
    def default_bundles_for_build
      bundles.reject { |x| !x.autobuild? }
    end

    # Reloads the manifest for all bundles.
    def reload_bundles!
      bundles.each { |b| b.reload! }
    end

    def invalidate_bundle_caches
      @cached_all_bundles = 
      @cached_framework_bundles = 
      @cached_client_bundles = 
      @bundles = 
      @cached_bundles_by_url = nil
    end
    
    # Build all of the bundles in the library.  This can take awhile but it is the simple
    # way to get all of your code onto disk in a deployable state
    def build(*languages)
      (client_bundles + framework_bundles).each do |bundle|
        bundle.build(*languages)
      end
    end

    # Returns the computed environment for a particular client or framework.
    # This will go up the chain of parent libraries, retrieving and merging
    # any known environment settings.  The returned options are suitable for
    # passing to the ClientBuilder for registration.
    #
    # The process here is:
    #
    # 1. merge together the :all configs.
    # 2. Find the deepest config for the bundle specifically and merge that.
    #
    def environment_for(bundle_name=nil)

      # If no bundle name is provided, then just return the base environment.
      return base_environment if bundle_name.nil?
      
      # Get the bundle location info.  This will return nil if the bundle
      # is not found anywhere.  In that case, return nil to indicate bundle
      # does not exist.
      bundle_location = bundle_location_for(bundle_name)
      return nil if bundle_location.nil?

      # A bundle was found, so collect the base environment and any bundle-
      # specific configs provided by the developer.
      base_env = base_environment
      config_env = bundle_environment_for(bundle_name)

      # Now we have the relevant pieces. Join them together.  Start with the
      # base environment and fill in some useful defaults...
      ret = base_env.dup.merge(config_env).merge(bundle_location)
      ret[:required] = [:sproutcore] if ret[:required].nil?

      # Add local library so we get proper deployment paths, etc.
      ret[:library] = self

      # Done!  return...
      return ret
    end

    # Returns a re-written proxy URL for the passed URL or nil if no proxy
    # is registered.  The URL should NOT include a hostname.
    #
    # === Returns
    # the converted proxy_url and the proxy options or nil if no match
    #
    def proxy_url_for(url)

      # look for a matching proxy.
      matched = nil
      matched_url = nil

      @proxies.each do |proxy_url, opts|
        matched_url = proxy_url
        matched = opts if url =~ /^#{proxy_url}/
        break if matched
      end

      # If matched, rewrite the URL
      if matched

        # rewrite the matched_url if needed...
        if matched[:url]
          url = url.gsub(/^#{matched_url}/, matched[:url])
        end

        # prepend the hostname and protocol
        url = [(matched[:protocol] || 'http'), '://', matched[:to], url].join('')

      # otherwise nil
      else
        url = nil
      end

      return [url, matched]

    end

    # ==== Returns 
    # The current minification settings.
    #
    def minify_build_modes(bundle_name=nil)
      env = environment_for(bundle_name) || {}
      [(env[:minify_javascript] || :production)].flatten
    end
    
    # ==== Returns
    # The build modes wherein javascript should be combined.
    def combine_javascript_build_modes(bundle_name=nil)
      env = environment_for(bundle_name) || {}
      [(env[:combine_javascript] || :production)].flatten
    end

    # ==== Returns
    # The build modes wherein javascript should be combined.
    def combine_stylesheets_build_modes(bundle_name=nil)
      env = environment_for(bundle_name) || {}
      [(env[:combine_stylesheets] || :production)].flatten
    end

    # ==== Returns
    # The build modes where fixtures should be included.
    def include_fixtures_build_modes(bundle_name=nil)
      env = environment_for(bundle_name) || {}
      [(env[:include_fixtures] || :development)].flatten
    end

    # ==== Returns
    # The build modes where debug code should be included.
    def include_debug_build_modes(bundle_name=nil)
      env = environment_for(bundle_name) || {}
      [(env[:include_debug] || :development)].flatten
    end
    
    # ==== Returns
    # A BundleInstaller configured for the receiver library.
    #
    def bundle_installer
      @bundle_installer ||= BundleInstaller.new(:library => self)  
    end
    
    # Install a named bundle from github.  This feature requires
    # git to be installed unless you are on a system that supports
    # tar, in which case it can install using tar.
    #
    # ==== Params
    # bundle_name :: the bundle name
    #
    # ==== Options
    # :github_path :: the root path on github for the project.  By default 
    #  this is calculated from the bundle name.
    # :install_path :: optional path to install 
    # :method :: optional preferred method.  May be :git, :zip, :tar
    # :force :: If a directory already exists at the install path, deletes
    #   and replaces it.
    #
    def install_bundle(bundle_name, opts = {})
      self.bundle_installer.install(bundle_name, opts)
    end

    # Update a named bundle.  This feature required git to be installed
    #
    def update_bundle(bundle_name, opts = {})
      self.bundle_installer.update(bundle_name, opts)
    end

    # Removed a named bundle.
    #
    def remove_bundle(bundle_name, opts = {})
      self.bundle_installer.remove(bundle_name, opts)
    end
    
    # Computes a build number for the bundle by generating a SHA1 hash.  The
    # return value is cached to speed up future requests.
    def compute_build_number(bundle)
      @cached_build_numbers ||= {}
      src = bundle.source_root
      ret = @cached_build_numbers[src]
      return ret unless ret.nil?

      digests = Dir.glob(File.join(src, '**', '*.*')).map do |path|
        (File.exists?(path) && !File.directory?(path)) ? Digest::SHA1.hexdigest(File.read(path)) : '0000'
      end
      ret = @cached_build_numbers[src] = Digest::SHA1.hexdigest(digests.join)
      return ret 
    end
      
    protected

    # Load the library at the specified path.  Loads the sc-config.rb if it
    # exists and then detects all clients and frameworks in the library.  If
    # you pass any options, those will overlay any :all options you specify in
    # your sc-config file.
    #
    # You cannot create a library directly using this method.  Instead is
    # library_in()
    #
    def initialize(rp, opts = {}, next_lib = nil)
      @root_path = rp
      @next_library = next_lib
      @load_opts = opts.dup
      @proxies = {}
      load_environment!(opts)
    end

    # Internal method loads the actual environment.  Get the ruby file and
    # eval it in the context of the library object.
    def load_environment!(opts=nil)
      env_path = File.join(root_path, 'sc-config')
      env_path = File.join(root_path, 'sc-config.rb') if !File.exists?(env_path)
      
      @environment = {}
      if File.exists?(env_path)
        f = File.read(env_path)
        eval(f) # execute the config file as if it belongs.
      end

      # Override any all options with load_opts
      if build_numbers = @load_opts[:build_numbers]
        @load_opts.delete(:build_numbers)
        build_numbers.each do | bundle_name, build_number |
          env = @environment[bundle_name.to_sym] ||= {}
          env[:build_number] = build_number
        end
      end
      
      (@environment[:all] ||= {}).merge!(@load_opts)

    end

    # This can be called from within a configuration file to actually setup
    # the environment.  Passes the relative environment hash to the block.
    #
    # ==== Params
    # bundle_name: the bundle these settings are for or :all for every bundle.
    # opts: optional set of parameters to merge into this bundle environment
    #
    # ==== Yields
    # If block is given, yield to the block, passing an options hash the block
    # can work on.
    #
    def config(bundle_name, opts=nil)
      env = @environment[bundle_name.to_sym] ||= {}
      env.merge!(opts) unless opts.nil?
      yield(env) if block_given?
    end

    # Adds a proxy to the local library.  This does NOT inherit from parent
    # libraries.
    #
    # ==== Params
    # url: the root URL to match
    # opts: options.
    #
    # ==== Options
    # :to: the new hostname
    # :url: an optional rewriting of the URL path as well.
    #
    def proxy(url, opts={})
      @proxies[url] = opts
    end

    # ==== Returns
    # the first :all environment config...
    def base_environment
      environment[:all] || (next_library.nil? ? {} : next_library.base_environment)
    end


    # ==== Returns
    # the first config found for the specified bundle
    def bundle_environment_for(bundle_name)
      bundle_name = bundle_name.to_sym
      return environment[bundle_name] || (next_library.nil? ? {} : next_library.bundle_environment_for(bundle_name))
    end

    # ==== Returns
    # path info for the bundle.  Used by bundle object.
    def bundle_location_for(bundle_name)
      bundle_name = bundle_name.to_sym
      is_local_client = client_directories.include?(bundle_name.to_s)
      is_local_framework = framework_directories.include?(bundle_name.to_s)

      ret = nil
      if is_local_client || is_local_framework
        bundle_type = is_local_framework ? :framework : :client
        ret = {
          :bundle_name => bundle_name,
          :bundle_type => bundle_type,
          :source_root => File.join(root_path, bundle_type.to_s.pluralize, bundle_name.to_s)
        }
      else
        ret = next_library.nil? ? nil : next_library.bundle_location_for(bundle_name)
      end

      return ret
    end

  end

end
